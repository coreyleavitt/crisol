## test_httpraw_real.nim — RFC-0005 C1b-i: THE SINGLE SANCTIONED SOCKET TEST.
##
## `httpraw.nim`'s `rawHttpFetcher` is the one place in the whole suite that
## opens a real socket (RFC-0005 "No network or hot-path disk in the test
## suite... C1b's loopback listener is the single sanctioned socket"). No
## other test file may add a second one -- everything else (`cachehttp.nim`
## and friends) is driven by the in-memory fake `HttpFetcher` double in
## `test_cachehttp.nim`.
##
## Lives in tests/integration/ (the "_real" convention -- see
## test_compiledriver_real.nim/test_measureworker_real.nim) since it touches
## a real OS resource (a loopback TCP socket), not just synthetic seams.
##
## One in-process loopback listener on an ephemeral 127.0.0.1 port, covering
## exactly the RFC's four scenarios, no more:
##
##   1. A 200 exchange (GET, and a PUT to prove the request-side
##      Content-Length framing) against a real accept/reply loop, run on a
##      background thread so the single-threaded client and the fake
##      server can both block on their own sockets concurrently. Only a
##      raw `SocketHandle` (a plain cint) and a `ServerScenario` enum value
##      cross the thread boundary -- both value types, so no GC'd data
##      (Socket refs, strings) is ever shared across threads.
##   1b. A CHUNKED 200 (RFC-0005 C1b-ii) -- multiple chunks, a chunk
##      extension, and a trailer, proving `httpraw.nim` decodes a real
##      chunked response end to end through `rawHttpFetcher` (not just the
##      pure `chunkedcodec` unit -- see tests/unit/test_chunkedcodec.nim
##      for the exhaustive RFC-7230-shape/malformed-input vectors; this is
##      the ONE wiring proof the RFC's single-socket-test rule allows).
##   2. A 404 (status-line/verdict passthrough distinct from 200).
##   3. A connect-timeout to a non-listening port. **Judgment call:**
##      loopback connect to a definitely-unbound port on Linux returns
##      `ECONNREFUSED` in well under a millisecond (verified empirically),
##      never an actual multi-second hang -- so this scenario cannot
##      literally exercise the connect DEADLINE without an OS-dependent
##      trick (filling a listen backlog to force silently-dropped SYNs),
##      which would be slow and non-portable, exactly what "keep it
##      deterministic and fast" rules out. What this scenario proves --
##      and all that actually matters for crisol's "never blocks" contract
##      -- is that a connect failure returns PROMPTLY (bounded, asserted
##      well under `connectTimeoutMs`) with a typed, non-raising outcome
##      (`toUnreachable`, the OSError/ECONNREFUSED path) rather than a
##      hang or an escaping exception. The DEADLINE-FIRING mechanism itself
##      (SO_RCVTIMEO) is what scenario 4 actually exercises.
##   4. TCP accept then silent server => recv deadline fires. The server
##      thread accepts the connection (completing the handshake) and then
##      sleeps well past the client's `recvTimeoutMs` before ever writing a
##      byte -- proving `SO_RCVTIMEO` (not the connect path) is what bounds
##      a peer that accepts but never answers.
##   5. A present-but-invalid `Content-Length` (`-1`, an overflowing value,
##      and garbage) -- each must resolve to `toUnreachable`, never be
##      reclassified as the "header absent" EOF-delimited path (the bug
##      this slice fixes; see httpraw.nim's `hasContentLength`/
##      `contentLengthValid` split).
##   6. A lying `Content-Length` (declares more than the peer actually
##      sends, then closes) -- `toUnreachable` (httpraw.nim:529's
##      truncation rule).
##   7. A garbage status line (not an HTTP response at all) -- the
##      `parseStatusAndHeaders`-rejects-it -> `toUnreachable` branch.
##
## Timeouts are short (low hundreds of ms) but margined generously against
## each other (server sleeps are >=5x the client's deadline) so the test is
## fast and immune to CI scheduling jitter -- see
## [[dev-test-verification-gotchas]] on why timing tests must not race a
## tight window.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_httpraw_real.nim

import std/[nativesockets, net, os, posix, strutils, times]
import crisol/cachewire
import crisol/httpraw

# ---------------------------------------------------------------------------
# The in-process fake server: accepts exactly one connection on a raw
# SocketHandle (passed across the thread boundary by value -- a plain cint,
# not a GC'd Socket ref) and plays one scripted scenario.
# ---------------------------------------------------------------------------

type
  ServerScenario = enum
    ssOk200
    ssChunked
    ss404
    ssSilent
    ssNegativeContentLength
    ssContentLengthOverflow
    ssContentLengthGarbage
    ssLyingContentLength
    ssGarbageStatusLine

  ServerArgs = tuple[fd: SocketHandle, scenario: ServerScenario]

proc serverThreadProc(args: ServerArgs) {.thread.} =
  let clientFd = accept(args.fd, nil, nil)
  if clientFd == osInvalidSocket:
    return
  case args.scenario
  of ssOk200:
    let body = "{\"ok\":true}"
    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Fake: yes\r\n" &
               "Content-Length: " & $body.len & "\r\n\r\n" & body
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssNegativeContentLength:
    # T2: `Content-Length: -1` must never be read as the "header absent"
    # sentinel -- it's malformed framing, not an EOF-delimited body.
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nhello"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssContentLengthOverflow:
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\nhello"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssContentLengthGarbage:
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\nhello"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssLyingContentLength:
    # T1a: declares 100 bytes of body, sends 40, then closes -- must map to
    # `toUnreachable` (httpraw.nim:529's claimed "closed before the
    # declared length arrived" rule), never a served (truncated) body.
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n" & "x".repeat(40)
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssGarbageStatusLine:
    # T1b: not an HTTP response at all -- `parseStatusAndHeaders` must
    # reject it (`parsedOk == false`), mapping to `toUnreachable`.
    let resp = "NOT AN HTTP RESPONSE\r\n\r\ntrailing junk that must never be parsed"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssChunked:
    # Multiple chunks, a chunk extension (ignored), and a trailer -- the
    # same RFC-7230 shapes test_chunkedcodec.nim vector-tests in isolation,
    # here proving the real socket path decodes them identically.
    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" &
               "Transfer-Encoding: chunked\r\n\r\n" &
               "4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: done\r\n\r\n"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ss404:
    let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
    discard send(clientFd, resp.cstring, resp.len, 0)
  of ssSilent:
    # Accept completes the TCP handshake; then say nothing for well past
    # the client's recv deadline before ever touching the socket again.
    sleep(1500)
  discard posix.close(clientFd)

proc startFakeServer(scenario: ServerScenario): tuple[thr: ref Thread[ServerArgs], listener: Socket, port: Port] =
  var listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let (_, port) = listener.getLocalAddr()
  var thr = new(Thread[ServerArgs])
  createThread(thr[], serverThreadProc, (fd: listener.getFd(), scenario: scenario))
  (thr, listener, port)

# ---------------------------------------------------------------------------
# 1. A 200 exchange: GET decodes status/headers/body; PUT proves the
#    request-side Content-Length framing (asserted indirectly -- the fake
#    server above doesn't echo the request, so this exercises the CLIENT's
#    write path by simply proving it completes and gets a reply rather than
#    hanging on its own send).
# ---------------------------------------------------------------------------

block test_200_get_and_put_exchange:
  let (thr, listener, port) = startFakeServer(ssOk200)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toOk
  assert reply.status == 200
  assert reply.body == "{\"ok\":true}"
  var sawFakeHeader = false
  for (k, v) in reply.headers:
    if k == "X-Fake" and v == "yes": sawFakeHeader = true
  assert sawFakeHeader, "response headers must be parsed through"

block test_200_put_with_body_completes:
  let (thr, listener, port) = startFakeServer(ssOk200)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "PUT", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[("Content-Type", "application/json")],
                        body: "{\"payload\":true}")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toOk
  assert reply.status == 200

# ---------------------------------------------------------------------------
# 1b. A chunked 200 (RFC-0005 C1b-ii) -- through the real fetcher.
# ---------------------------------------------------------------------------

block test_chunked_200_decodes_through_real_fetcher:
  let (thr, listener, port) = startFakeServer(ssChunked)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toOk
  assert reply.status == 200
  assert reply.body == "Wikipedia",
    "chunked body must be decoded (extension ignored, trailer consumed), got: " & reply.body

# ---------------------------------------------------------------------------
# 2. A 404.
# ---------------------------------------------------------------------------

block test_404_status_passthrough:
  let (thr, listener, port) = startFakeServer(ss404)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/missing",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toOk
  assert reply.status == 404

# ---------------------------------------------------------------------------
# 3. Connect-timeout to a non-listening port (see module doc's judgment
#    call: realized as a fast ECONNREFUSED, not a literal deadline fire).
# ---------------------------------------------------------------------------

block test_connect_to_non_listening_port_fails_fast_and_typed:
  # Reserve an ephemeral port, then release it immediately so nothing is
  # listening there for the fetcher's connect attempt.
  var reserver = newSocket()
  reserver.setSockOpt(OptReuseAddr, true)
  reserver.bindAddr(Port(0), "127.0.0.1")
  let (_, deadPort) = reserver.getLocalAddr()
  reserver.close()

  let fetcher = rawHttpFetcher(connectTimeoutMs = 300, recvTimeoutMs = 300)
  let req = HttpRequest(meth: "GET",
                        url: "http://127.0.0.1:" & $deadPort.int & "/x",
                        headers: @[], body: "")
  let start = epochTime()
  let reply = fetcher(req)
  let elapsedMs = (epochTime() - start) * 1000.0

  assert reply.transport == toUnreachable
  # Generous window: proves the call never needed to wait out the connect
  # deadline (a real hang would take >=300ms; a refused connect resolves in
  # microseconds) without pinning an exact, flake-prone figure.
  assert elapsedMs < 250.0,
    "connect refusal should resolve far faster than the connect deadline, got " &
    $elapsedMs & "ms"

# ---------------------------------------------------------------------------
# 4. TCP accept then silent server => recv deadline fires.
# ---------------------------------------------------------------------------

block test_accept_then_silent_server_recv_deadline_fires:
  let (thr, listener, port) = startFakeServer(ssSilent)
  let recvTimeoutMs = 200
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = recvTimeoutMs)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let start = epochTime()
  let reply = fetcher(req)
  let elapsedMs = (epochTime() - start) * 1000.0
  joinThread(thr[])
  listener.close()

  assert reply.transport == toTimeout
  # Wide, generous window on both sides -- must have actually waited out
  # (approximately) the recv deadline, not returned instantly, but must
  # also not have hung anywhere near the server's 1500ms silence.
  assert elapsedMs >= (recvTimeoutMs.float * 0.5),
    "recv deadline fired suspiciously early: " & $elapsedMs & "ms"
  assert elapsedMs < 1200.0,
    "recv deadline should fire long before the server's silence ends, got " &
    $elapsedMs & "ms"

# ---------------------------------------------------------------------------
# T2: a present-but-invalid Content-Length is malformed framing, never the
# "header absent" EOF-delimited path -- see httpraw.nim's fixed
# `hasContentLength`/`contentLengthValid` split in `readResponse`.
# ---------------------------------------------------------------------------

block test_negative_content_length_is_transport_error_not_served_body:
  let (thr, listener, port) = startFakeServer(ssNegativeContentLength)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toUnreachable,
    "Content-Length: -1 must never be reclassified as an absent header"

block test_overflowing_content_length_is_transport_error:
  let (thr, listener, port) = startFakeServer(ssContentLengthOverflow)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toUnreachable

block test_garbage_content_length_is_transport_error:
  let (thr, listener, port) = startFakeServer(ssContentLengthGarbage)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toUnreachable

# ---------------------------------------------------------------------------
# T1a: a lying Content-Length (declares more than the peer actually sends,
# then closes) -- the truncation rule httpraw.nim:529 already claims,
# asserted here for the first time.
# ---------------------------------------------------------------------------

block test_lying_content_length_closes_early_is_transport_error:
  let (thr, listener, port) = startFakeServer(ssLyingContentLength)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toUnreachable,
    "a connection closed before the declared Content-Length arrived must " &
    "never be served as a (truncated) 200 body"

# ---------------------------------------------------------------------------
# T1b: a garbage status line -- `parseStatusAndHeaders`'s `not parsedOk`
# branch, asserted here for the first time.
# ---------------------------------------------------------------------------

block test_garbage_status_line_is_transport_error:
  let (thr, listener, port) = startFakeServer(ssGarbageStatusLine)
  let fetcher = rawHttpFetcher(connectTimeoutMs = 500, recvTimeoutMs = 500)
  let req = HttpRequest(meth: "GET", url: "http://127.0.0.1:" & $port.int & "/x",
                        headers: @[], body: "")
  let reply = fetcher(req)
  joinThread(thr[])
  listener.close()

  assert reply.transport == toUnreachable

echo "test_httpraw_real: all blocks passed"
