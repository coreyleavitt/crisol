## verify_https_manual.nim — RFC-0005 C1b-iii: manual, out-of-suite
## verification that `httpraw.nim`'s TLS path (`rawHttpFetcher` under
## `-d:ssl`) performs a real handshake end to end. NOT part of the suite
## (RFC-0005's C1b bullet: "manual/out-of-suite") -- run this by hand, or
## via `tools/verify_https_manual.sh`'s convenience wrapper, inside the dev
## container (which has both OpenSSL and, usually, outbound network).
##
## Usage:
##   ./dev run nim r --hints:off --warnings:off -d:ssl --path:src \
##     tools/verify_https_manual.nim <https-url> [connectTimeoutMs] [recvTimeoutMs]
##
## Prints the resolved `TransportOutcome` and, on `toOk`, the status code
## and a body preview. Always exits 0 -- this is a diagnostic tool, not an
## assertion; a human reads the printed outcome.

import std/[os, strutils]
import crisol/cachewire
import crisol/httpraw

let args = commandLineParams()
if args.len < 1:
  stderr.write("usage: verify_https_manual <https-url> [connectTimeoutMs] [recvTimeoutMs]\n")
  quit(1)

let url = args[0]
let connectTimeoutMs = if args.len > 1: parseInt(args[1]) else: 3000
let recvTimeoutMs = if args.len > 2: parseInt(args[2]) else: 3000

let fetcher = rawHttpFetcher(connectTimeoutMs = connectTimeoutMs, recvTimeoutMs = recvTimeoutMs)
let req = HttpRequest(meth: "GET", url: url, headers: @[], body: "")
let reply = fetcher(req)

echo "url: ", url
echo "transport: ", $reply.transport
if reply.transport == toOk:
  echo "status: ", reply.status
  let preview = if reply.body.len > 200: reply.body[0 ..< 200] else: reply.body
  echo "body (first ", preview.len, " bytes): ", preview
