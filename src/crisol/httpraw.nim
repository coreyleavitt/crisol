## httpraw.nim — RFC-0005 C1b-i: the PRODUCTION `HttpFetcher` -- a minimal
## plaintext HTTP/1.1 client over raw `std/net`/`std/posix` sockets, wired
## by `cachehttp.nim`'s `http` adapter (test doubles wire a pure in-memory
## fake server instead -- `test_cachehttp.nim` -- so no other module ever
## needs to know a socket exists).
##
## ## Scope (RFC-0005 "B0 -- remote-I/O concurrency and the deadline
## mechanism", decision (a), split into C1b-i/ii/iii)
##
## - **C1b-i (this file):** plaintext GET/PUT, `Content-Length` REQUEST
##   framing (no chunked encoding on the request side), connect + recv
##   timeouts via `SO_RCVTIMEO`/`SO_SNDTIMEO` set to the DEADLINE REMAINDER
##   before every blocking read/write (never a fresh full timeout per call
##   -- that would let N slow reads add up to N times the intended budget),
##   the body-size cap enforced WHILE READING (never buffers an oversized
##   body in memory first), and `EINTR` retried (never treated as a hard
##   failure, never busy-spun past the deadline).
## - **C1b-ii (this file, response path only):** chunked RESPONSE decoding,
##   via the pure decoder in `crisol/chunkedcodec.nim` -- see "Judgment
##   call: a chunked RESPONSE" below for how it's wired into this file's
##   cap/deadline machinery.
## - **C1b-iii (this file):** TLS under `-d:ssl` -- an `https://` request
##   wraps the connected socket (`std/net`'s `newContext`/
##   `wrapConnectedSocket`) with the SAME deadline discipline as everything
##   else here. See "Judgment call: TLS (C1b-iii)" below.
##   `tests/unit/ssl/test_https_handshake_compiles.nim` is this slice's
##   compile-time (link/typecheck, no I/O) coverage, alongside C1a's
##   existing `test_ssl_link.nim`. **RFC-0005 review fix (T5):**
##   certificate/hostname verification itself is now an AUTOMATED, in-suite
##   check -- `tests/unit/ssl/test_https_reject_selfsigned.nim` drives a
##   real handshake against a real `openssl s_server` on loopback serving a
##   self-signed cert generated at test runtime, and asserts this file
##   rejects it (`toUnreachable`, never a served body). Only the
##   POSITIVE-path handshake against a REAL, publicly-trusted endpoint
##   stays manual, out-of-suite (`tools/verify_https_manual.sh`'s remaining
##   check) -- that needs actual outbound network access, which the suite
##   must not depend on.
##
## ## Total-function contract
##
## `rawHttpFetcher(...)` returns an `HttpFetcher` that NEVER raises --
## every failure mode (bad/unsupported URL, connect refusal, connect
## timeout, send/recv timeout, a connection that closes mid-response,
## a malformed status line) resolves to one of `HttpReply`'s three
## `TransportOutcome`s (`cachewire.nim`). An outer `except CatchableError`
## in `rawHttpFetcher`'s returned closure is the last-resort net (defense
## in depth over the specific `except` clauses below it) -- consistent with
## `cachehttp.nim`'s own stance that a misbehaving fetcher must never let an
## exception escape the port.
##
## ## Judgment call: a chunked RESPONSE (C1b-ii)
##
## A response carrying `Transfer-Encoding: chunked` is decoded via
## `crisol/chunkedcodec.ChunkedDecoder` -- a pure, vector-tested state
## machine (no socket knowledge) fed one `recv()`'s worth of bytes at a
## time. This file owns the two things the decoder deliberately does NOT
## know about, so they apply to a chunked body EXACTLY as they already do
## to a `Content-Length`-bounded one:
##
## - **The recv deadline** -- every `recvChunk` call while decoding a
##   chunked body re-arms `SO_RCVTIMEO` to the SAME remaining-deadline
##   bookkeeping as every other read in this file; a `rioTimeout` mid-decode
##   maps to `toTimeout`, a `rioError` (peer closed) while the decoder still
##   `needsMore` maps to `toUnreachable` -- symmetric with the existing
##   bounded-`Content-Length` rule ("closed before the declared length
##   arrived -> `toUnreachable`"; EOF is only ever "natural" for an
##   UNDECLARED-length body, which chunked framing is not).
## - **The body cap** -- checked against `decoder.body.len` after every
##   `feed`, exactly like the existing bounded-body loop's `capTarget`
##   check. Once it exceeds `bodyCapBytes`, reading stops immediately (the
##   connection is simply closed -- `Connection: close` was always sent)
##   and the TRUNCATED decoded-so-far body is returned via `toOk`, letting
##   `cachehttp.nim`'s existing post-hoc `body.len > bodyCapBytes ->
##   cvCorrupt` check fire, same as the bounded-body path.
##
## A MALFORMED chunked stream (bad hex, a violated CRLF, or a chunk-size
## that overflows `int` -- `chunkedcodec.ChunkedError`) is a live,
## responding server sending framing this transport cannot understand, not
## a connectivity failure -- so it reuses C1b-i's own precedent for exactly
## this situation: `toOk` with `status`/`headers` parsed through but
## `body = ""`. `cachehttp.nim`'s EXISTING pinned rule for a 2xx response
## ("an oversized/undecodable body -> `cvCorrupt`") then fires on the empty
## body exactly as it always has, never mistaken for a transport-level
## outage (`cvOffline`/`cvTimeout`, which would incorrectly trip the
## caller's circuit breaker for what is, in fact, a live and responding
## server).
##
## ## Judgment call: enforcing the body cap AT the raw layer
##
## `cachehttp.nim` already rejects an oversized 2xx body post-hoc
## (`reply.body.len > bodyCapBytes -> cvCorrupt`) -- but doing the check
## only there would mean an attacker/misbehaving server that claims a
## multi-gigabyte `Content-Length` gets read into memory in FULL before
## being rejected, defeating the point of a cap. This module enforces the
## SAME cap while reading: it never reads more than `bodyCapBytes + 1`
## bytes of body (the `+1` is deliberate -- it keeps `body.len >
## bodyCapBytes` true so `cachehttp.nim`'s existing post-hoc check still
## fires correctly, with no protocol change needed on either side). A
## bounded (`Content-Length`-declared) body that exceeds the cap is read up
## to that limit and no further; the connection is then simply closed
## (`Connection: close` is always sent, so a real server tolerates this).
##
## ## Judgment call: no `Content-Length` and not chunked
##
## Some legitimate responses (e.g. `204`/`304`, or a body-less error page)
## carry neither header. Since every request sends `Connection: close`,
## this is read as an EOF-DELIMITED body (read until the peer closes or the
## cap is hit) rather than assumed to be always-empty -- more correct than
## silently returning `body = ""`, and free given `Connection: close`
## already guarantees the peer closes when it's done.
##
## ## Judgment call: TLS (C1b-iii)
##
## The RFC pins ONLY "TLS via `wrapConnectedSocket` under `-d:ssl`" (B0(a))
## plus the deadline mechanism (below) -- it is silent on verify mode and
## SNI. This file makes the secure-by-default call: `newContext(verifyMode
## = CVerifyPeer)` (also `newContext`'s own default) verifies the peer
## certificate against the SYSTEM CA store (`std/net`'s `scanSSLCertificates`
## -- a fixed list of well-known bundle paths, consulted automatically when
## no `caFile`/`caDir` is given); `wrapConnectedSocket`'s `hostname`
## parameter is set to the REQUEST's own host, which drives BOTH the SNI
## extension (`SSL_set_tlsext_host_name`) and the post-handshake
## certificate-name check (`checkCertName`, SAN/CN match) -- one field,
## two jobs, both from the URL the caller actually asked for. Nothing here
## is configurable (no `-k`/insecure knob): a cache transport that silently
## downgraded to unverified TLS on request would defeat the point of using
## TLS at all.
##
## Scheme detection is purely syntactic (`parseHttpUrl` below recognizes
## both `http://` and `https://` regardless of `-d:ssl` -- a `ParsedUrl` is
## just data). Whether this BUILD can actually service an `https://` request
## is a SEPARATE, compile-time question: without `-d:ssl`, `rawHttpFetcher`
## rejects a `tls: true` URL with `toUnreachable` before ever opening a
## socket -- "this fetcher simply cannot dial it", the exact same precedent
## an unparseable URL or unsupported scheme already gets. This keeps every
## OpenSSL symbol behind `when defined(ssl)`, so a default (non-`-d:ssl`)
## build of this module stays exactly as OpenSSL-free as it was before this
## slice.
##
## The handshake (`SSL_connect`, inside `wrapConnectedSocket`) is bounded by
## the SAME `SO_SNDTIMEO`/`SO_RCVTIMEO`-to-the-deadline-remainder mechanism
## as every other blocking call in this file -- RFC-0005 B0, fact (3):
## "TLS on `std/net` has no deadline either... a hand-rolled non-blocking
## TLS state machine is far beyond a 'minimal client'"; decision (a): "the
## only way to bound the blocking SSL path". A handshake failure (bad cert,
## connection reset mid-handshake, protocol mismatch) raises inside
## `wrapConnectedSocket` rather than returning a sentinel like this file's
## own raw send/recv helpers do -- so `performTlsHandshake` classifies the
## caught exception by comparing `epochTime()` against the SAME deadline at
## the moment of failure: still before it -> `toUnreachable` (a live peer
## rejected the handshake for cause -- bad cert, reset, etc.); at or past it
## -> `toTimeout` (the socket-level timeout fired inside the blocking
## `SSL_connect` and OpenSSL surfaced it as a handshake exception rather
## than a plain `EAGAIN` return, unlike this file's own raw I/O). Once the
## handshake succeeds, ALL further I/O for this request (the request send,
## the response read) goes through `std/net`'s own `send`/`recv` (which
## route to `SSL_write`/`SSL_read` when the socket `isSsl`) instead of a
## raw `posix.send`/`recv` on the fd -- see `sendAllRaw`/`recvChunk` below,
## which now take the `Socket` itself (constructed `buffered = false`, so
## the plaintext case still resolves to the exact same single
## `recv(fd,...)`/`send(fd,...)` syscall as before this slice -- only the
## TLS case actually changes behavior). The deadline/EINTR/cap discipline
## in those two procs is completely unaware of TLS -- it is exactly as
## total a function of "did this syscall return data, an error, or would it
## block" as it always was, whether that syscall happens to be a raw
## `recv(2)` or an OpenSSL `SSL_read` underneath.
import std/[net, os, posix, strutils, times]
import crisol/cachewire
import crisol/chunkedcodec

export cachewire.HttpFetcher

const
  DefaultConnectTimeoutMs* = 2000
    ## RFC-0005 B0(b)'s "default per-call deadline 2000 ms" split across
    ## this module's two separately-dialable knobs (connect vs. recv).
  DefaultRecvTimeoutMs* = 2000
  DefaultBodyCapBytes* = 8 * 1024 * 1024
    ## RFC-0005 B0(a): "a body size cap (default 8 MiB)". Mirrors
    ## `cachehttp.DefaultBodyCapBytes` -- kept as its own constant here
    ## (this module must not import `cachehttp.nim`; the adapter layer
    ## imports the transport, never the reverse).
  MaxHeaderBytes* = 64 * 1024
    ## Defensive cap on the status-line+headers block only (never the
    ## body, which has its own explicit cap parameter). Guards against a
    ## server that never sends a blank line at all -- otherwise the header
    ## accumulator would grow unbounded while still (correctly) respecting
    ## the recv deadline; this is a second, independent guard against a
    ## pathological peer that dribbles bytes forever within the deadline.

type
  RawIoResult* = enum
    rioOk
    rioTimeout
    rioError

# ---------------------------------------------------------------------------
# URL parsing -- deliberately hand-rolled and minimal. "http://" and
# "https://" are the only two recognized schemes; anything else
# (unparseable authority, missing host, unsupported scheme) is a transport-
# level `toUnreachable` -- this fetcher simply cannot dial it, exactly like
# a real DNS/connect failure would be. Recognizing "https://" here is
# PURELY syntactic and does not depend on `-d:ssl` -- see the module doc's
# "Judgment call: TLS (C1b-iii)" for why whether this build can actually
# SERVICE a `tls: true` URL is a separate question, decided in
# `rawHttpFetcher` below.
# ---------------------------------------------------------------------------

type
  ParsedUrl = object
    ok: bool
    tls: bool
    host: string
    port: Port
    path: string

proc parseHttpUrl(url: string): ParsedUrl =
  const httpPrefix = "http://"
  const httpsPrefix = "https://"
  var rest: string
  var tls: bool
  var defaultPort: int
  if url.startsWith(httpsPrefix):
    rest = url[httpsPrefix.len .. ^1]
    tls = true
    defaultPort = 443
  elif url.startsWith(httpPrefix):
    rest = url[httpPrefix.len .. ^1]
    tls = false
    defaultPort = 80
  else:
    return ParsedUrl(ok: false)
  let slashIdx = rest.find('/')
  let authority = if slashIdx < 0: rest else: rest[0 ..< slashIdx]
  let path = if slashIdx < 0: "/" else: rest[slashIdx .. ^1]
  if authority.len == 0:
    return ParsedUrl(ok: false)
  let colonIdx = authority.rfind(':')
  var host = authority
  var portNum = defaultPort
  if colonIdx >= 0:
    host = authority[0 ..< colonIdx]
    try:
      portNum = parseInt(authority[colonIdx + 1 .. ^1])
    except ValueError:
      return ParsedUrl(ok: false)
  if host.len == 0 or portNum <= 0 or portNum > 65535:
    return ParsedUrl(ok: false)
  ParsedUrl(ok: true, tls: tls, host: host, port: Port(portNum), path: path)

# ---------------------------------------------------------------------------
# Deadline-remainder bookkeeping + raw send/recv, both EINTR-retrying and
# both re-arming SO_SNDTIMEO/SO_RCVTIMEO to the REMAINING time before every
# syscall (RFC-0005 B0(a): "set to the deadline remainder ... before each
# recv" -- the only way a multi-read response, or an EINTR-interrupted
# syscall, can't silently balloon past the intended total budget).
# ---------------------------------------------------------------------------

proc remainingMs(deadline: float): int =
  let rem = (deadline - epochTime()) * 1000.0
  if rem <= 0.0: 0
  else: int(rem) + 1  # ceiling -- never round a nonzero remainder down to 0

proc setTimeoutOpt(fd: SocketHandle; opt: cint; ms: int) =
  # ms is always >= 1 here (callers check remainingMs > 0 first) -- a zero
  # Timeval means "block forever" to the kernel, which is exactly the one
  # value this proc must never be asked to set.
  var tv: Timeval
  tv.tv_sec = posix.Time(ms div 1000)
  tv.tv_usec = Suseconds(ms mod 1000 * 1000)
  discard setsockopt(fd, SOL_SOCKET, opt, addr tv, SockLen(sizeof(tv)))

proc sendAllRaw(socket: Socket; data: string; deadline: float): RawIoResult =
  ## Takes the `Socket` (not a bare `fd`) so a TLS-wrapped connection's
  ## `send` routes to `SSL_write` -- see the module doc's "Judgment call:
  ## TLS (C1b-iii)". `socket.send(pointer, size)` is `std/net`'s own
  ## low-level, non-raising overload: for a plaintext (non-SSL) socket it
  ## is the exact same single `send(fd,...)` syscall this proc issued
  ## before this slice (`socket` is always constructed `buffered = false`,
  ## so no internal buffering machinery is involved); it never raises
  ## either way, so this loop's own errno-based EINTR/EAGAIN handling below
  ## is unchanged and applies identically to both cases.
  var sent = 0
  while sent < data.len:
    let rem = remainingMs(deadline)
    if rem <= 0: return rioTimeout
    setTimeoutOpt(socket.getFd(), SO_SNDTIMEO, rem)
    let n = send(socket, unsafeAddr data[sent], data.len - sent)
    if n > 0:
      inc(sent, n)
    elif n == 0:
      return rioError
    else:
      let err = osLastError()
      if err == OSErrorCode(EINTR):
        continue
      elif err == OSErrorCode(EAGAIN) or err == OSErrorCode(EWOULDBLOCK):
        return rioTimeout
      else:
        return rioError
  rioOk

proc recvChunk(socket: Socket; buf: var openArray[byte]; deadline: float): tuple[res: RawIoResult, n: int] =
  ## Same `Socket`-not-`fd` rationale as `sendAllRaw` above -- `socket.recv`
  ## routes to `SSL_read` for a TLS-wrapped connection, and to the exact
  ## same plain `recv(fd,...)` syscall as before this slice otherwise.
  while true:
    let rem = remainingMs(deadline)
    if rem <= 0: return (rioTimeout, 0)
    setTimeoutOpt(socket.getFd(), SO_RCVTIMEO, rem)
    let n = recv(socket, addr buf[0], buf.len)
    if n > 0:
      return (rioOk, n)
    elif n == 0:
      return (rioError, 0)  # peer closed (EOF)
    else:
      let err = osLastError()
      if err == OSErrorCode(EINTR):
        continue  # re-check the deadline and re-arm SO_RCVTIMEO, then retry
      elif err == OSErrorCode(EAGAIN) or err == OSErrorCode(EWOULDBLOCK):
        return (rioTimeout, 0)
      else:
        return (rioError, 0)

# ---------------------------------------------------------------------------
# TLS handshake (RFC-0005 C1b-iii) -- see the module doc's "Judgment call:
# TLS (C1b-iii)" for the verify-mode/SNI/deadline rationale. Entirely
# behind `when defined(ssl)`: every symbol this proc names
# (`SslContext`/`newContext`/`wrapConnectedSocket`/`CVerifyPeer`/
# `handshakeAsClient`/`destroyContext`) exists in `std/net` ONLY under
# `-d:ssl` (or `-d:nimdoc`) -- referencing any of them outside this guard
# would fail to compile a default build, exactly the import-purity property
# `tests/unit/ssl/config.nims` polices for `test_ssl_link.nim`.
# ---------------------------------------------------------------------------

when defined(ssl):
  proc performTlsHandshake(socket: Socket; host: string; deadline: float): TransportOutcome =
    ## Wraps an already-TCP-connected `socket` in TLS as a client, verifying
    ## the peer against the system CA store and checking the certificate
    ## name against `host` (which also drives SNI) -- `wrapConnectedSocket`
    ## does both from its one `hostname` parameter. Bounded by the SAME
    ## deadline-remainder discipline as every other blocking call in this
    ## file (`SO_SNDTIMEO`/`SO_RCVTIMEO` re-armed immediately before the
    ## blocking `SSL_connect`, since there is no non-blocking TLS path in
    ## `std/net` -- RFC-0005 B0 fact (3)/decision (a)). Never raises: a
    ## fresh `SslContext` per call keeps this proc free of any state a
    ## concurrent/later request could observe, and is `destroyContext`'d
    ## before returning either way (OpenSSL reference-counts the
    ## underlying `SSL_CTX`; `SSL_new`, called inside `wrapConnectedSocket`,
    ## already took its own reference, so freeing the Nim wrapper's copy
    ## immediately after the handshake is the standard, safe OpenSSL
    ## idiom -- the live `SSL*`/`sslHandle` on `socket` is unaffected).
    let rem = remainingMs(deadline)
    if rem <= 0:
      return toTimeout
    setTimeoutOpt(socket.getFd(), SO_SNDTIMEO, rem)
    setTimeoutOpt(socket.getFd(), SO_RCVTIMEO, rem)

    var ctx: SslContext
    try:
      ctx = newContext(verifyMode = CVerifyPeer)
    except CatchableError:
      # No usable system CA store, or context construction otherwise
      # failed -- can't verify a peer, so can't proceed; never a crash.
      return toUnreachable

    try:
      wrapConnectedSocket(ctx, socket, handshakeAsClient, host)
      result = toOk
    except CatchableError:
      # `SSL_connect` (inside `wrapConnectedSocket`) raises on failure
      # instead of returning a sentinel the way this file's own raw
      # send/recv helpers do -- classify by the SAME deadline this proc
      # itself re-armed the socket to: still before it fired -> a live
      # peer rejected the handshake for cause (bad/self-signed cert,
      # reset mid-handshake, protocol mismatch) -> `toUnreachable`; at or
      # past it -> the socket-level timeout is what actually ended the
      # blocking `SSL_connect` -> `toTimeout`.
      result = (if epochTime() >= deadline: toTimeout else: toUnreachable)
    finally:
      destroyContext(ctx)

# ---------------------------------------------------------------------------
# Request framing.
# ---------------------------------------------------------------------------

proc buildRequestBytes(req: HttpRequest; host, path: string): string =
  var lines: seq[string] = @[req.meth & " " & path & " HTTP/1.1"]
  lines.add("Host: " & host)
  lines.add("Connection: close")
  if req.meth != "GET" or req.body.len > 0:
    lines.add("Content-Length: " & $req.body.len)
  for (k, v) in req.headers:
    lines.add(k & ": " & v)
  lines.join("\r\n") & "\r\n\r\n" & req.body

# ---------------------------------------------------------------------------
# Response parsing: read until the header block completes, parse the
# status line + headers, then read the body per Content-Length /
# chunked-detection / EOF-delimited, honoring the SAME deadline throughout.
# ---------------------------------------------------------------------------

proc headerValue(headers: seq[(string, string)]; name: string): string =
  for (k, v) in headers:
    if cmpIgnoreCase(k, name) == 0: return v
  ""

type
  HeaderReader* = proc(buf: var openArray[byte]): tuple[res: RawIoResult, n: int]
    ## The seam `readHeaderBlock` reads bytes through -- a single-call
    ## "fill this buffer" primitive with the SAME shape as `recvChunk`'s
    ## return, deliberately NOT `recvChunk` itself: this is what lets
    ## `tests/unit/test_httpraw_parser.nim` feed the header-accumulation
    ## loop (including the `MaxHeaderBytes` cap) synthetic bytes with no
    ## socket at all, while production (`readResponse` below) just wraps
    ## `recvChunk(socket, buf, deadline)` in a one-line closure.

proc readHeaderBlock*(read: HeaderReader): tuple[res: RawIoResult, raw: string] =
  var raw = ""
  var buf: array[4096, byte]
  while raw.find("\r\n\r\n") < 0:
    if raw.len > MaxHeaderBytes:
      return (rioError, raw)
    let (res, n) = read(buf)
    case res
    of rioOk:
      for i in 0 ..< n: raw.add(char(buf[i]))
    of rioTimeout: return (rioTimeout, raw)
    of rioError: return (rioError, raw)
  (rioOk, raw)

proc parseStatusAndHeaders*(headerBlock: string): tuple[ok: bool, status: int, headers: seq[(string, string)]] =
  let lines = headerBlock.split("\r\n")
  if lines.len == 0: return (false, 0, @[])
  let statusParts = lines[0].split(' ')
  if statusParts.len < 2: return (false, 0, @[])
  var status: int
  try:
    status = parseInt(statusParts[1])
  except ValueError:
    return (false, 0, @[])
  var headers: seq[(string, string)] = @[]
  for line in lines[1 .. ^1]:
    if line.len == 0: continue
    let colonIdx = line.find(':')
    if colonIdx < 0: continue
    let k = line[0 ..< colonIdx]
    var v = line[colonIdx + 1 .. ^1]
    v = v.strip()
    headers.add((k, v))
  (true, status, headers)

proc readChunkedBody(socket: Socket; deadline: float; bodyCapBytes: int;
                     initial: string): tuple[res: RawIoResult, body: string] =
  ## Drives `chunkedcodec.ChunkedDecoder` from the socket: feeds `initial`
  ## (bytes already read past the header block by `readHeaderBlock`'s
  ## single-buffer overrun, exactly like the bounded-`Content-Length` path
  ## reuses `bodySoFar`), then further `recvChunk`'d bytes, re-arming the
  ## SAME deadline before every read. `res` reuses `RawIoResult`:
  ## `rioOk` covers a COMPLETE decode -- `isDone` (`decoder.body` is
  ## returned as-is) AND a MALFORMED one (`isError` -- an empty body is
  ## returned; see this file's module doc's "Judgment call: a chunked
  ## RESPONSE" for why a malformed stream is `rioOk`/`toOk`, not a
  ## transport failure). `rioTimeout`/`rioError` are true transport
  ## failures: the deadline fired, or the peer closed before the decoder
  ## reached a terminal state (symmetric with the bounded-body rule
  ## "closed before the declared length arrived -> toUnreachable").
  var decoder = initChunkedDecoder()
  decoder = decoder.feed(initial)
  var buf: array[4096, byte]
  while decoder.needsMore:
    if decoder.body.len > bodyCapBytes:
      # Cap hit while still mid-stream -- stop reading immediately (the
      # caller always sends `Connection: close`, so simply closing here is
      # sufficient) and hand back the truncated-so-far body so the
      # existing post-hoc `body.len > bodyCapBytes -> cvCorrupt` check
      # fires, same as the bounded-`Content-Length` path.
      return (rioOk, decoder.body)
    let (res, n) = recvChunk(socket, buf, deadline)
    case res
    of rioOk:
      var piece = newString(n)
      for i in 0 ..< n: piece[i] = char(buf[i])
      decoder = decoder.feed(piece)
    of rioTimeout:
      return (rioTimeout, "")
    of rioError:
      return (rioError, "")  # peer closed before the stream completed
  if decoder.isError:
    return (rioOk, "")  # malformed stream -- see this proc's doc comment
  (rioOk, decoder.body)

proc readResponse(socket: Socket; deadline: float; bodyCapBytes: int): HttpReply =
  let (headerRes, raw) = readHeaderBlock(proc(buf: var openArray[byte]): tuple[res: RawIoResult, n: int] =
    recvChunk(socket, buf, deadline))
  case headerRes
  of rioTimeout: return HttpReply(transport: toTimeout)
  of rioError: return HttpReply(transport: toUnreachable)
  of rioOk: discard

  let splitIdx = raw.find("\r\n\r\n")
  let headerBlock = raw[0 ..< splitIdx]
  var bodySoFar = raw[splitIdx + 4 .. ^1]

  let (parsedOk, status, headers) = parseStatusAndHeaders(headerBlock)
  if not parsedOk:
    return HttpReply(transport: toUnreachable)

  let isChunked = "chunked" in toLowerAscii(headerValue(headers, "Transfer-Encoding"))
  if isChunked:
    let (chunkedRes, chunkedBody) = readChunkedBody(socket, deadline, bodyCapBytes, bodySoFar)
    case chunkedRes
    of rioTimeout: return HttpReply(transport: toTimeout)
    of rioError: return HttpReply(transport: toUnreachable)
    of rioOk: return HttpReply(transport: toOk, status: status, headers: headers, body: chunkedBody)

  let contentLengthStr = headerValue(headers, "Content-Length")
  let hasContentLength = contentLengthStr.len > 0
  var contentLength = 0
  var contentLengthValid = true
  if hasContentLength:
    try:
      contentLength = parseInt(contentLengthStr)
      contentLengthValid = contentLength >= 0
    except ValueError:
      contentLengthValid = false  # garbage, or overflow -- parseInt raises on both

  if hasContentLength and not contentLengthValid:
    # A Content-Length header that IS present but is not a valid
    # non-negative integer (negative, overflow, or garbage) is malformed
    # framing, not an absent header -- must never fall through to
    # `bounded = false`'s EOF-delimited path (reserved for a genuinely
    # ABSENT header, see this file's module doc's "Judgment call: no
    # Content-Length and not chunked"). `hasContentLength`/
    # `contentLengthValid` are two independent booleans specifically so
    # "present but invalid" can never again collide with the "absent"
    # sentinel the way a literal `Content-Length: -1` used to (parseInt
    # happily returns -1, which was also this proc's old in-band marker
    # for "no header at all"). Classed like every other framing violation
    # below: a live peer sent bytes this transport cannot trust to frame
    # the response, so it's a transport failure, never a served body.
    return HttpReply(transport: toUnreachable)

  let bounded = hasContentLength
  let capTarget = if bounded: min(contentLength, bodyCapBytes + 1) else: bodyCapBytes + 1

  var body = bodySoFar
  if body.len > capTarget:
    body = body[0 ..< capTarget]

  var buf: array[4096, byte]
  while body.len < capTarget:
    let (res, n) = recvChunk(socket, buf, deadline)
    case res
    of rioOk:
      let want = capTarget - body.len
      let take = min(n, want)
      for i in 0 ..< take: body.add(char(buf[i]))
      if take < n:
        break  # hit the cap -- stop reading, discard the remainder
    of rioTimeout:
      return HttpReply(transport: toTimeout)
    of rioError:
      if bounded:
        return HttpReply(transport: toUnreachable)  # closed before the declared length arrived
      else:
        break  # EOF is the natural terminator for an undeclared-length body

  HttpReply(transport: toOk, status: status, headers: headers, body: body)

# ---------------------------------------------------------------------------
# The production factory.
# ---------------------------------------------------------------------------

proc rawHttpFetcher*(connectTimeoutMs = DefaultConnectTimeoutMs;
                     recvTimeoutMs = DefaultRecvTimeoutMs;
                     bodyCapBytes = DefaultBodyCapBytes): HttpFetcher =
  ## Production `HttpFetcher` (RFC-0005 C1b-i/ii/iii): plaintext or TLS
  ## HTTP/1.1 GET/PUT over `std/net`/`std/posix` raw sockets, scheme-
  ## selected per request from the URL (`parseHttpUrl`'s `tls` field).
  ## `connectTimeoutMs` bounds the TCP connect phase (via `Socket.connect`'s
  ## own non-blocking-connect + poll, `net.nim:2126`); `recvTimeoutMs` bounds
  ## EVERYTHING after connect succeeds (the TLS handshake, when `tls`;
  ## request send; status line; headers; body) as ONE deadline, re-armed
  ## via `SO_SNDTIMEO`/`SO_RCVTIMEO` before every syscall. Never raises --
  ## see the module doc's "Total-function contract". Without `-d:ssl`, an
  ## `https://` URL resolves to `toUnreachable` before any socket is opened
  ## -- see the module doc's "Judgment call: TLS (C1b-iii)".
  result = proc(req: HttpRequest): HttpReply =
    try:
      let parsed = parseHttpUrl(req.url)
      if not parsed.ok:
        return HttpReply(transport: toUnreachable)

      when not defined(ssl):
        if parsed.tls:
          # This build has no TLS support at all (no OpenSSL symbol is even
          # linked in) -- exactly the same "this fetcher simply cannot dial
          # it" outcome an unsupported/unparseable URL already gets, never
          # attempted, and never a crash.
          return HttpReply(transport: toUnreachable)

      var socket: Socket
      try:
        socket = newSocket(buffered = false)
      except OSError:
        return HttpReply(transport: toUnreachable)

      try:
        try:
          socket.connect(parsed.host, parsed.port, timeout = connectTimeoutMs)
        except TimeoutError:
          return HttpReply(transport: toTimeout)
        except OSError:
          return HttpReply(transport: toUnreachable)

        let deadline = epochTime() + (recvTimeoutMs.float / 1000.0)

        when defined(ssl):
          if parsed.tls:
            let handshakeOutcome = performTlsHandshake(socket, parsed.host, deadline)
            if handshakeOutcome != toOk:
              return HttpReply(transport: handshakeOutcome)

        let reqBytes = buildRequestBytes(req, parsed.host, parsed.path)

        let sendRes = sendAllRaw(socket, reqBytes, deadline)
        case sendRes
        of rioTimeout: return HttpReply(transport: toTimeout)
        of rioError: return HttpReply(transport: toUnreachable)
        of rioOk: discard

        readResponse(socket, deadline, bodyCapBytes)
      finally:
        socket.close()
    except CatchableError:
      # Last-resort net -- see module doc's "Total-function contract".
      HttpReply(transport: toUnreachable)
