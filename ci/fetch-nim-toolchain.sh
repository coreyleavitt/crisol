#!/usr/bin/env bash
# Fetch a patched Nim toolchain artifact from ghcr.io/coreyleavitt/nim and
# unpack it. These are OCI artifacts (artifactType application/x-nim-toolchain,
# one zip/tar.xz layer holding a nim-2.2.10-patched/ tree built from
# github.com/coreyleavitt/Nim with the backport patch set the Linux CI image
# already carries) -- NOT container images, so the native windows/macos legs
# pull the layer blob directly instead of docker-running anything.
#
# Usage: fetch-nim-toolchain.sh <tag> <dest-dir>
#   e.g. fetch-nim-toolchain.sh 2.2.10-windows-x64  "$RUNNER_TEMP/nimtc"
#        fetch-nim-toolchain.sh 2.2.10-macos-arm64 "$RUNNER_TEMP/nimtc"
# Prints the unpacked toolchain's bin directory on the LAST line of stdout
# (the caller appends it to GITHUB_PATH).
set -euo pipefail

TAG="${1:?usage: fetch-nim-toolchain.sh <tag> <dest-dir>}"
DEST="${2:?usage: fetch-nim-toolchain.sh <tag> <dest-dir>}"
REPO="coreyleavitt/nim"

mkdir -p "$DEST"

# Anonymous pull tokens work for public packages; GITHUB_TOKEN is not needed.
TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:${REPO}:pull" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

MANIFEST=$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${REPO}/manifests/${TAG}")

read -r DIGEST TITLE < <(python3 - "$MANIFEST" <<'EOF'
import json, sys
m = json.loads(sys.argv[1])
layer = m["layers"][0]
print(layer["digest"], layer.get("annotations", {}).get("org.opencontainers.image.title", "toolchain.bin"))
EOF
)

echo "fetch-nim-toolchain: ${TAG} -> ${TITLE} (${DIGEST})" >&2
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/${REPO}/blobs/${DIGEST}" -o "${DEST}/${TITLE}"

case "$TITLE" in
  *.zip)    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
              "${DEST}/${TITLE}" "$DEST" ;;
  *.tar.xz) tar -xJf "${DEST}/${TITLE}" -C "$DEST" ;;
  *) echo "fetch-nim-toolchain: unknown payload format: ${TITLE}" >&2; exit 1 ;;
esac
rm -f "${DEST}/${TITLE}"

BIN=$(find "$DEST" -maxdepth 2 -type d -name bin | head -1)
[ -n "$BIN" ] || { echo "fetch-nim-toolchain: no bin/ dir in payload" >&2; exit 1; }
# Windows zips carry no unix exec bits; tar.xz payloads preserve them.
chmod +x "$BIN"/* 2>/dev/null || true
echo "$BIN"
