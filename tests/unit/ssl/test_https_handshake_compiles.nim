## test_https_handshake_compiles.nim — RFC-0005 C1b-iii: compile/link
## coverage for the TLS request path in `httpraw.nim`, under `-d:ssl`.
##
## Same "link/typecheck probe, no I/O" contract as C1a's
## `test_ssl_link.nim` (this directory's `config.nims` doc comment explains
## why `-d:ssl` is scoped to this one directory): constructing
## `rawHttpFetcher()`'s returned closure VALUE forces the WHOLE of
## `httpraw.nim` -- including the `when defined(ssl)`-guarded
## `performTlsHandshake` (`newContext`/`wrapConnectedSocket`/`CVerifyPeer`/
## `handshakeAsClient`/`destroyContext`, and every OpenSSL FFI symbol they
## in turn reach) -- to typecheck and codegen. Nim compiles a proc's full
## body once ANY caller in the program is itself compiled, regardless of
## which runtime branch a given test happens to exercise -- so this proves
## the TLS path is reachable, well-typed code, not dead weight sitting
## behind an untested `when`.
##
## The closure is never INVOKED here -- that would open a real socket, and
## `test_httpraw_real.nim` (`tests/integration/`) is the suite's one
## sanctioned socket, scoped to the plaintext scenarios the RFC pins.
##
## Manual, out-of-suite verification that the TLS handshake actually WORKS
## end to end (real certificate verification, a rejected self-signed cert,
## SNI) lives in `tools/verify_https_manual.sh` -- see that script and
## `httpraw.nim`'s own module doc comment ("Judgment call: TLS (C1b-iii)").
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/ssl/test_https_handshake_compiles.nim

import std/unittest
import crisol/httpraw
import crisol/cachewire

suite "C1b-iii — https path compiles and links (-d:ssl)":

  test "rawHttpFetcher builds a closure that closes over the TLS path, no I/O":
    let fetcher: HttpFetcher = rawHttpFetcher()
    check fetcher != nil
