## test_ssl_link.nim — RFC-0005 C1a: TLS toolchain readiness, pinned as a
## real suite test rather than a one-off manual probe.
##
## This does NOT exercise any adapter/transport logic (that's C1b/C1b-iii) —
## it only proves the toolchain property the RFC bullet asks for: under
## `-d:ssl`, `std/net`'s TLS surface compiles and links, specifically
## `wrapConnectedSocket` (the exact proc C1b-iii's production HttpFetcher
## calls). No network I/O: an `SslContext` is constructed but never attached
## to a real connected socket, and `wrapConnectedSocket` is referenced as a
## proc value (never invoked) — invoking it performs an SSL handshake
## immediately (net.nim), which needs a live peer.
##
## `-d:ssl` itself comes from tests/unit/ssl/config.nims (this directory
## only — see that file for why), not from a flag on the invocation below.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/ssl/test_ssl_link.nim

import std/[net, unittest]

suite "C1a — TLS toolchain readiness (-d:ssl)":

  test "SslContext constructs and wrapConnectedSocket resolves, no I/O":
    let ctx: SslContext = newContext()
    check ctx != nil

    # Proc-value reference: this only needs `wrapConnectedSocket` to exist
    # and type-check under -d:ssl, so the compiler must resolve everything
    # it depends on (the OpenSSL FFI surface included) without this test
    # ever calling it.
    let wrapFn: proc (ctx: SslContext, socket: Socket,
                       handshake: SslHandshakeType,
                       hostname: string = "") = wrapConnectedSocket
    check wrapFn != nil
