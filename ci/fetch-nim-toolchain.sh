#!/usr/bin/env bash
# Fetch a patched Nim toolchain artifact from ghcr.io/coreyleavitt/nim and
# unpack it. These are OCI artifacts (artifactType application/x-nim-toolchain,
# one zip/tar.xz layer holding a nim-2.2.10-patched/ tree built from
# github.com/coreyleavitt/Nim with the backport patch set the Linux CI image
# already carries) -- NOT container images, so the native windows/macos legs
# pull the layer blob directly instead of docker-running anything.
#
# Usage: fetch-nim-toolchain.sh <tag> <dest-dir> [<manifest-digest>]
#   e.g. fetch-nim-toolchain.sh 2.2.10-windows-x64 "$RUNNER_TEMP/nimtc" sha256:eddee4f5...
#        fetch-nim-toolchain.sh 2.2.10-macos-arm64 "$RUNNER_TEMP/nimtc" sha256:db3ea697...
#
# Pinning: <tag> is mutable (a repush moves it silently), so callers pass the
# manifest digest they expect. With a digest, the manifest is fetched BY
# DIGEST and its bytes are hashed locally and compared -- the registry is not
# trusted to have honored the content address. The layer blob is always
# hashed and compared against the manifest's layer digest before unpacking,
# so a pinned manifest transitively pins the payload. Without a digest the
# tag is resolved as before (for local/ad-hoc use); the log line says so.
# Repin: resolve the new manifest digest (the fetch log prints it when run
# unpinned) and update the caller in the same commit as the artifact bump.
# Prints the unpacked toolchain's bin directory on the LAST line of stdout
# (the caller appends it to GITHUB_PATH).
set -euo pipefail

TAG="${1:?usage: fetch-nim-toolchain.sh <tag> <dest-dir>}"
DEST="${2:?usage: fetch-nim-toolchain.sh <tag> <dest-dir>}"
PIN="${3:-}"
REPO="coreyleavitt/nim"

mkdir -p "$DEST"

# Anonymous pull tokens work for public packages; GITHUB_TOKEN is not needed.
TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:${REPO}:pull" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# sha256 of a file as "sha256:<hex>", via python (macOS ships no sha256sum).
sha256_of() {
  local h
  h=$(python3 -c "import hashlib,sys; print('sha256:' + hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1")
  printf '%s' "${h%$'\r'}"
}

MANIFEST_FILE="${DEST}/manifest.json"
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${REPO}/manifests/${PIN:-$TAG}" -o "$MANIFEST_FILE"
MANIFEST_DIGEST=$(sha256_of "$MANIFEST_FILE")
if [ -n "$PIN" ]; then
  if [ "$MANIFEST_DIGEST" != "$PIN" ]; then
    echo "fetch-nim-toolchain: manifest digest mismatch for ${TAG}: expected ${PIN}, got ${MANIFEST_DIGEST}" >&2
    exit 1
  fi
else
  echo "fetch-nim-toolchain: WARNING: ${TAG} fetched UNPINNED (manifest ${MANIFEST_DIGEST})" >&2
fi

read -r DIGEST TITLE < <(python3 - "$MANIFEST_FILE" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
layer = m["layers"][0]
print(layer["digest"], layer.get("annotations", {}).get("org.opencontainers.image.title", "toolchain.bin"))
EOF
)
# Windows python writes CRLF even into pipes (text-mode stdout); a trailing
# \r on TITLE makes the *.zip case arm silently miss (CI run 35475575832).
DIGEST=${DIGEST%$'\r'}
TITLE=${TITLE%$'\r'}
# With a pin, the digest (not the tag) decides what is fetched, so a
# copy-pasted digest from another platform would otherwise install silently
# under this tag's name. The payload title carries the platform
# (nim-2.2.10-patched-<platform>.<ext>); require it to match the tag's.
case "$TITLE" in
  *"-${TAG#*-}."*) ;;
  *) echo "fetch-nim-toolchain: payload ${TITLE} does not match tag ${TAG} (wrong digest for this platform?)" >&2; exit 1 ;;
esac

echo "fetch-nim-toolchain: ${TAG}@${MANIFEST_DIGEST} -> ${TITLE} (${DIGEST})" >&2
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/${REPO}/blobs/${DIGEST}" -o "${DEST}/${TITLE}"
BLOB_DIGEST=$(sha256_of "${DEST}/${TITLE}")
if [ "$BLOB_DIGEST" != "$DIGEST" ]; then
  echo "fetch-nim-toolchain: payload digest mismatch: expected ${DIGEST}, got ${BLOB_DIGEST}" >&2
  exit 1
fi

case "$TITLE" in
  *.zip)    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
              "${DEST}/${TITLE}" "$DEST" ;;
  *.tar.xz) tar -xJf "${DEST}/${TITLE}" -C "$DEST" ;;
  *) echo "fetch-nim-toolchain: unknown payload format: ${TITLE}" >&2; exit 1 ;;
esac
rm -f "${DEST}/${TITLE}" "$MANIFEST_FILE"

BIN=$(find "$DEST" -maxdepth 2 -type d -name bin | head -1)
[ -n "$BIN" ] || { echo "fetch-nim-toolchain: no bin/ dir in payload" >&2; exit 1; }
# Windows zips carry no unix exec bits; tar.xz payloads preserve them.
chmod +x "$BIN"/* 2>/dev/null || true
echo "$BIN"
