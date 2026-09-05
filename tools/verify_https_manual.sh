#!/usr/bin/env bash
# tools/verify_https_manual.sh — RFC-0005 C1b-iii manual TLS verification.
#
# Run INSIDE the dev container: ./dev run bash tools/verify_https_manual.sh
#
# Not part of any automated gate -- a human runs this once to confirm
# httpraw.nim's TLS path works end to end; see httpraw.nim's own module
# doc comment ("Judgment call: TLS (C1b-iii)") and
# tests/unit/ssl/test_https_handshake_compiles.nim for this slice's
# compile-only suite coverage (no network, never invokes the fetcher).
#
# Two checks, both against crisol/httpraw's REAL rawHttpFetcher:
#   1. A real external https endpoint (verify-SUCCESS path: a publicly
#      trusted CA cert, real SNI, a real 2xx response decoded through the
#      whole connect+handshake+request+response pipeline).
#   2. A local `openssl s_server` on loopback serving a throwaway
#      self-signed cert (verify-FAILURE path: CVerifyPeer against the
#      system CA store must reject it -- proves the TLS path is not
#      silently permissive; there is no insecure/skip-verify knob).
#
# Prints what it did and the observed outcome; does not assert anything
# itself -- a human reads the output.
set -euo pipefail

REAL_URL="${1:-https://example.com/}"

echo "=== 1. Real external endpoint: ${REAL_URL} ==="
nim r --hints:off --warnings:off -d:ssl --path:src tools/verify_https_manual.nim "${REAL_URL}"

echo
echo "=== 2. Local self-signed openssl s_server (expect verify failure) ==="
WORKDIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -keyout "${WORKDIR}/key.pem" \
  -out "${WORKDIR}/cert.pem" -days 1 -nodes \
  -subj "/CN=crisol-manual-verify.invalid" >/dev/null 2>&1

PORT=18443
openssl s_server -quiet -accept "${PORT}" \
  -cert "${WORKDIR}/cert.pem" -key "${WORKDIR}/key.pem" \
  -www >"${WORKDIR}/s_server.log" 2>&1 &
SERVER_PID=$!
sleep 1

nim r --hints:off --warnings:off -d:ssl --path:src tools/verify_https_manual.nim \
  "https://127.0.0.1:${PORT}/" 1000 1000

echo
echo "Done. Check 1 should show 'transport: toOk' with a 2xx status (a"
echo "publicly trusted cert verified). Check 2 should show 'transport:"
echo "toUnreachable' (the self-signed cert is not in the system CA store,"
echo "so CVerifyPeer rejects it -- the secure-by-default judgment call"
echo "recorded in httpraw.nim's module doc)."
