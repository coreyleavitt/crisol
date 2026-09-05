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
## - **C1b-ii (follow-on, NOT here):** chunked RESPONSE decoding.
## - **C1b-iii (follow-on, NOT here):** TLS under `-d:ssl`.
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
## ## Judgment call: a chunked RESPONSE in C1b-i
##
## This slice does not implement chunked-transfer decoding (C1b-ii owns
## that). A response carrying `Transfer-Encoding: chunked` is recognized
## (case-insensitively) and deliberately returned as `toOk` with `status`/
## `headers` parsed through but `body = ""` -- the socket is closed
## immediately after without attempting to read (and mis-decode) the
## chunked stream. This composes cleanly with `cachehttp.nim`'s EXISTING
## pinned rule for a 2xx response ("an oversized/undecodable body ->
## `cvCorrupt`"): an empty body fails the JSON decode there and lands on
## exactly that bucket -- "this response is real (a genuine status came
## back) but this transport can't understand its framing yet", never
## mistaken for a transport-level outage (`cvOffline`/`cvTimeout`, which
## would incorrectly trip the caller's circuit breaker for what is, in
## fact, a live and responding server).
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
import std/[net, os, posix, strutils, times]
import crisol/cachewire

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
  MaxHeaderBytes = 64 * 1024
    ## Defensive cap on the status-line+headers block only (never the
    ## body, which has its own explicit cap parameter). Guards against a
    ## server that never sends a blank line at all -- otherwise the header
    ## accumulator would grow unbounded while still (correctly) respecting
    ## the recv deadline; this is a second, independent guard against a
    ## pathological peer that dribbles bytes forever within the deadline.

type
  RawIoResult = enum
    rioOk
    rioTimeout
    rioError

# ---------------------------------------------------------------------------
# URL parsing -- deliberately hand-rolled and minimal. Only "http://" is
# supported (https:// arrives with C1b-iii's TLS wiring); anything else
# (unparseable authority, missing host, unsupported scheme) is a transport-
# level `toUnreachable` -- this fetcher simply cannot dial it, exactly like
# a real DNS/connect failure would be.
# ---------------------------------------------------------------------------

type
  ParsedUrl = object
    ok: bool
    host: string
    port: Port
    path: string

proc parseHttpUrl(url: string): ParsedUrl =
  const prefix = "http://"
  if not url.startsWith(prefix):
    return ParsedUrl(ok: false)
  let rest = url[prefix.len .. ^1]
  let slashIdx = rest.find('/')
  let authority = if slashIdx < 0: rest else: rest[0 ..< slashIdx]
  let path = if slashIdx < 0: "/" else: rest[slashIdx .. ^1]
  if authority.len == 0:
    return ParsedUrl(ok: false)
  let colonIdx = authority.rfind(':')
  var host = authority
  var portNum = 80
  if colonIdx >= 0:
    host = authority[0 ..< colonIdx]
    try:
      portNum = parseInt(authority[colonIdx + 1 .. ^1])
    except ValueError:
      return ParsedUrl(ok: false)
  if host.len == 0 or portNum <= 0 or portNum > 65535:
    return ParsedUrl(ok: false)
  ParsedUrl(ok: true, host: host, port: Port(portNum), path: path)

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

proc sendAllRaw(fd: SocketHandle; data: string; deadline: float): RawIoResult =
  var sent = 0
  while sent < data.len:
    let rem = remainingMs(deadline)
    if rem <= 0: return rioTimeout
    setTimeoutOpt(fd, SO_SNDTIMEO, rem)
    let n = send(fd, unsafeAddr data[sent], data.len - sent, 0)
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

proc recvChunk(fd: SocketHandle; buf: var openArray[byte]; deadline: float): tuple[res: RawIoResult, n: int] =
  while true:
    let rem = remainingMs(deadline)
    if rem <= 0: return (rioTimeout, 0)
    setTimeoutOpt(fd, SO_RCVTIMEO, rem)
    let n = recv(fd, addr buf[0], buf.len, 0)
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

proc readHeaderBlock(fd: SocketHandle; deadline: float): tuple[res: RawIoResult, raw: string] =
  var raw = ""
  var buf: array[4096, byte]
  while raw.find("\r\n\r\n") < 0:
    if raw.len > MaxHeaderBytes:
      return (rioError, raw)
    let (res, n) = recvChunk(fd, buf, deadline)
    case res
    of rioOk:
      for i in 0 ..< n: raw.add(char(buf[i]))
    of rioTimeout: return (rioTimeout, raw)
    of rioError: return (rioError, raw)
  (rioOk, raw)

proc parseStatusAndHeaders(headerBlock: string): tuple[ok: bool, status: int, headers: seq[(string, string)]] =
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

proc readResponse(fd: SocketHandle; deadline: float; bodyCapBytes: int): HttpReply =
  let (headerRes, raw) = readHeaderBlock(fd, deadline)
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
    # C1b-ii's job to decode -- deliberately empty body (see module doc's
    # "Judgment call: a chunked RESPONSE in C1b-i").
    return HttpReply(transport: toOk, status: status, headers: headers, body: "")

  let contentLengthStr = headerValue(headers, "Content-Length")
  var contentLength = -1
  if contentLengthStr.len > 0:
    try:
      contentLength = parseInt(contentLengthStr)
    except ValueError:
      contentLength = -1

  let bounded = contentLength >= 0
  let capTarget = if bounded: min(contentLength, bodyCapBytes + 1) else: bodyCapBytes + 1

  var body = bodySoFar
  if body.len > capTarget:
    body = body[0 ..< capTarget]

  var buf: array[4096, byte]
  while body.len < capTarget:
    let (res, n) = recvChunk(fd, buf, deadline)
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
  ## Production `HttpFetcher` (RFC-0005 C1b-i): plaintext HTTP/1.1 GET/PUT
  ## over `std/net`/`std/posix` raw sockets. `connectTimeoutMs` bounds the
  ## TCP connect phase (via `Socket.connect`'s own non-blocking-connect +
  ## poll, `net.nim:2126`); `recvTimeoutMs` bounds EVERYTHING after connect
  ## succeeds (request send + status line + headers + body) as ONE
  ## deadline, re-armed via `SO_SNDTIMEO`/`SO_RCVTIMEO` before every
  ## syscall. Never raises -- see the module doc's "Total-function
  ## contract".
  result = proc(req: HttpRequest): HttpReply =
    try:
      let parsed = parseHttpUrl(req.url)
      if not parsed.ok:
        return HttpReply(transport: toUnreachable)

      var socket: Socket
      try:
        socket = newSocket()
      except OSError:
        return HttpReply(transport: toUnreachable)

      try:
        try:
          socket.connect(parsed.host, parsed.port, timeout = connectTimeoutMs)
        except TimeoutError:
          return HttpReply(transport: toTimeout)
        except OSError:
          return HttpReply(transport: toUnreachable)

        let fd = socket.getFd()
        let deadline = epochTime() + (recvTimeoutMs.float / 1000.0)
        let reqBytes = buildRequestBytes(req, parsed.host, parsed.path)

        let sendRes = sendAllRaw(fd, reqBytes, deadline)
        case sendRes
        of rioTimeout: return HttpReply(transport: toTimeout)
        of rioError: return HttpReply(transport: toUnreachable)
        of rioOk: discard

        readResponse(fd, deadline, bodyCapBytes)
      finally:
        socket.close()
    except CatchableError:
      # Last-resort net -- see module doc's "Total-function contract".
      HttpReply(transport: toUnreachable)
