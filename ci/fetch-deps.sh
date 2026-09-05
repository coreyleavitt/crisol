#!/usr/bin/env bash
# ci/fetch-deps.sh — materialize milpa.lock's vendored deps for CI (rfc-0007
# slice A0). CI never runs milpa (no CAS, no milpa binary on the runner), so
# this script is the CI-side substitute: it reads milpa.lock (the single
# source of truth for what's vendored) and, for each declared dep, clones the
# locked commit straight from its git remote into _deps/<name> — a real
# directory, not milpa's usual symlink into ~/.cache/milpa/cas/... nim.cfg
# already carries --path:"_deps/nkdl/src", so once this script runs, the
# compiler resolves `import nkdl` exactly as it does on a milpa-managed dev
# checkout.
#
# Usage:
#   ci/fetch-deps.sh              clone/verify every dep from milpa.lock
#   ci/fetch-deps.sh --print-only parse milpa.lock and print what would be
#                                  fetched, without touching the filesystem
#                                  or the network (used to sanity-check the
#                                  grep/sed parse in isolation)
#
# CRISOL_DEPS_DIR (default: _deps) overrides the target vendor directory —
# used for local verification so this script can be exercised against a
# scratch directory without touching the real milpa-managed _deps/nkdl
# symlink.
#
# milpa.lock is KDL. This script does NOT parse KDL generally — it greps for
# the handful of known keys inside each `dep "<name>" { ... }` block, which
# is exactly what milpa.lock's `provenance` stanza is for: an
# already-resolved, already-flat (name, url, ref, commit_sha) record meant to
# be read this way by tooling that isn't milpa itself. A top-level dep
# block's closing brace sits at column 0 (milpa's own formatting, verified
# against the committed lockfile); nested stanzas (`source { }`,
# `provenance { }`) are indented, so a per-dep block is delimited by
# `^dep "<name>" {$` .. the next `^}$`.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCKFILE="${PROJECT_DIR}/milpa.lock"
DEPS_DIR="${CRISOL_DEPS_DIR:-${PROJECT_DIR}/_deps}"
PRINT_ONLY=0

if [ "${1:-}" = "--print-only" ]; then
    PRINT_ONLY=1
fi

if [ ! -f "${LOCKFILE}" ]; then
    echo "fetch-deps.sh: no milpa.lock at ${LOCKFILE}" >&2
    exit 1
fi

# Prints the lines of the named dep's top-level block (exclusive of the
# `dep "name" {` / closing `}` delimiter lines themselves).
dep_block() {
    local name="$1"
    awk -v name="${name}" '
        BEGIN { inBlock = 0 }
        $0 == "dep \"" name "\" {" { inBlock = 1; next }
        inBlock && $0 == "}" { inBlock = 0; next }
        inBlock { print }
    ' "${LOCKFILE}"
}

dep_names() {
    grep -oE '^dep "[^"]+" \{' "${LOCKFILE}" | sed -E 's/^dep "//; s/" \{$//'
}

fail=0

for name in $(dep_names); do
    block="$(dep_block "${name}")"

    # provenance's url is the plain-quoted form (source's is the
    # type-annotated `url (url)"..."` form, without the .git suffix —
    # deliberately not what we want here). Deps vendored over ssh carry
    # ssh://git@... here; deps added with --git https://... carry https://.
    raw_url="$(printf '%s\n' "${block}" | grep -oE 'url "(ssh://git@|https://)[^"]+"' | tail -1 | sed -E 's/^url "//; s/"$//')"
    # ref appears in both `source` and `provenance`; provenance's (the last
    # occurrence in the block) is the one paired with commit_sha below.
    ref="$(printf '%s\n' "${block}" | grep -oE '^[[:space:]]*ref "[^"]+"' | tail -1 | sed -E 's/^[[:space:]]*ref "//; s/"$//')"
    commit_sha="$(printf '%s\n' "${block}" | grep -oE 'commit_sha "[^"]+"' | tail -1 | sed -E 's/^commit_sha "//; s/"$//')"

    if [ -z "${raw_url}" ] || [ -z "${ref}" ] || [ -z "${commit_sha}" ]; then
        echo "fetch-deps.sh: could not parse dep \"${name}\" out of ${LOCKFILE} (url=\"${raw_url}\" ref=\"${ref}\" commit_sha=\"${commit_sha}\")" >&2
        exit 1
    fi

    # ssh://git@github.com/OWNER/REPO(.git) -> https://github.com/OWNER/REPO(.git)
    https_url="$(printf '%s' "${raw_url}" | sed -E 's#^ssh://git@github\.com/#https://github.com/#')"

    target="${DEPS_DIR}/${name}"

    if [ "${PRINT_ONLY}" -eq 1 ]; then
        echo "dep=${name} url=${https_url} ref=${ref} commit_sha=${commit_sha} target=${target}"
        continue
    fi

    if [ -d "${target}" ] && [ ! -L "${target}" ]; then
        existing_sha="$(git -C "${target}" rev-parse "HEAD^{commit}" 2>/dev/null || true)"
        if [ "${existing_sha}" = "${commit_sha}" ]; then
            echo "fetch-deps.sh: ${name} already at ${commit_sha}, skipping"
            continue
        fi
    fi

    # Not present, or present but wrong (or a symlink, e.g. milpa's own
    # vendoring left in place) — start clean.
    rm -rf "${target}"
    mkdir -p "${DEPS_DIR}"

    echo "fetch-deps.sh: cloning ${name} (${https_url} @ ${ref}) -> ${target}"
    if ! git clone --depth 1 --branch "${ref}" "${https_url}" "${target}"; then
        echo "fetch-deps.sh: FAILED to clone ${name} from ${https_url} @ ${ref}" >&2
        fail=1
        continue
    fi

    cloned_sha="$(git -C "${target}" rev-parse "HEAD^{commit}")"
    if [ "${cloned_sha}" != "${commit_sha}" ]; then
        echo "fetch-deps.sh: VERIFY FAILED for ${name}: cloned commit ${cloned_sha} != milpa.lock commit_sha ${commit_sha}" >&2
        fail=1
        continue
    fi

    echo "fetch-deps.sh: ${name} verified at ${cloned_sha}"
done

# milpa generates nim.cfg alongside _deps/ (both gitignored — see
# .gitignore), so a CI checkout has neither. Without the --path lines the
# compiler cannot resolve vendored imports (`import nkdl`), which is exactly
# how A0's first CI run failed. Regenerate the equivalent file when absent;
# a dev checkout always has the milpa-generated one, so this never fires
# locally.
if [ "${PRINT_ONLY}" -eq 0 ] && [ "${fail}" -eq 0 ] && [ ! -f "${PROJECT_DIR}/nim.cfg" ]; then
    {
        echo '# generated by ci/fetch-deps.sh (CI substitute for milpa'"'"'s nim.cfg)'
        echo '# manifest: milpa.kdl'
        echo '# lockfile: milpa.lock'
        echo ''
        echo '--path:"src"'
        for name in $(dep_names); do
            # match milpa's layout detection: src/ layout when present,
            # else the repo root (e.g. nimcrypto keeps nimcrypto.nim at root)
            if [ -d "${DEPS_DIR}/${name}/src" ]; then
                echo "--path:\"_deps/${name}/src\""
            else
                echo "--path:\"_deps/${name}\""
            fi
        done
    } > "${PROJECT_DIR}/nim.cfg"
    echo "fetch-deps.sh: generated nim.cfg ($(grep -c -- '--path' "${PROJECT_DIR}/nim.cfg") path entries)"
fi

exit "${fail}"
