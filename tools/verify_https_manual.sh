#!/usr/bin/env bash
# tools/verify_https_manual.sh — RFC-0005 C1b-iii manual TLS verification.
#
# Run INSIDE the dev container: ./dev run bash tools/verify_https_manual.sh
#
# Not part of any automated gate -- a human runs this to confirm
# httpraw.nim's TLS path performs a real handshake against a REAL, publicly
# trusted endpoint end to end; see httpraw.nim's own module doc comment
# ("Judgment call: TLS (C1b-iii)") and
# tests/unit/ssl/test_https_handshake_compiles.nim for this slice's
# compile-only suite coverage (no network, never invokes the fetcher).
#
# One check, against crisol/httpraw's REAL rawHttpFetcher: a real external
# https endpoint (verify-SUCCESS path -- a publicly trusted CA cert, real
# SNI, a real 2xx response decoded through the whole
# connect+handshake+request+response pipeline). This needs actual outbound
# network access, which the automated suite must never depend on -- that is
# the one thing left that stays manual.
#
# RFC-0005 review fix (T5): the verify-FAILURE half this script used to
# cover (a local self-signed openssl s_server, expected to be rejected) is
# now an AUTOMATED, in-suite test instead --
# tests/unit/ssl/test_https_reject_selfsigned.nim -- so it is no longer
# duplicated here as a manual step.
#
# Prints what it did and the observed outcome; does not assert anything
# itself -- a human reads the output.
set -euo pipefail

REAL_URL="${1:-https://example.com/}"

echo "=== Real external endpoint: ${REAL_URL} ==="
nim r --hints:off --warnings:off -d:ssl --path:src tools/verify_https_manual.nim "${REAL_URL}"

echo
echo "Done. Should show 'transport: toOk' with a 2xx status (a publicly"
echo "trusted cert verified). For the verify-FAILURE (self-signed-reject)"
echo "path, see the automated"
echo "tests/unit/ssl/test_https_reject_selfsigned.nim instead."
