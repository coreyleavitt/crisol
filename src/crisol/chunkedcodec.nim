## chunkedcodec.nim — RFC-0005 C1b-ii: the PURE, vector-tested RFC 7230
## §4.1 chunked-transfer-coding decoder that plugs into `httpraw.nim`'s
## response path (C1b-i's placeholder: a chunked response was recognized
## and returned with an empty body -- this module is the "C1b-ii" follow-on
## that placeholder's doc comment named).
##
## ## Design: incremental, streaming-friendly, no I/O
##
## `ChunkedDecoder` is a plain value type; `feed` is a pure function
## `(ChunkedDecoder, string) -> ChunkedDecoder` -- no sockets, no timers, no
## exceptions. A caller (`httpraw.nim`) owns the socket and the deadline; it
## reads whatever bytes arrive and hands them to `feed` one recv()'s worth
## at a time, checking `.phase`/`.body`/`.error` after each call. This keeps
## the ENTIRE chunked-framing state machine unit-testable without a socket
## (RFC-0005's "pure, vector-tested" requirement) while still being genuine
## streaming: `feed` only ever appends new bytes to a small carry-over
## buffer of not-yet-parsed bytes and consumes from its front, so decoding
## an N-byte body does O(N) total work regardless of how many `feed` calls
## it arrives across (never re-scans already-consumed bytes).
##
## ## Judgment call: the decoder does NOT know about the body cap
##
## `httpraw.nim` enforces `bodyCapBytes` (RFC-0005 B0(a)) the same way for
## chunked as it already does for a `Content-Length`-bounded body: check
## `.body.len` after every increment and stop reading/feeding once it
## exceeds the cap, then close the connection -- this module never takes a
## cap parameter. Splitting it this way keeps the decoder a pure RFC-7230
## grammar question ("is this a well-formed chunked stream, and what body
## does it encode") separate from a resource-limit POLICY question that
## belongs to the transport layer, exactly like `MaxHeaderBytes` in
## `httpraw.nim` is enforced by the header-reading loop, not by
## `parseStatusAndHeaders`.
##
## ## Judgment call: "oversized declared chunk" is an overflow guard, not a
## ## cap check
##
## A single chunk-size line can claim any size a valid hex number can
## express. Guarding against the cap is the fetcher's job (above); this
## module's OWN error (`ceChunkSizeOverflow`) fires only when the declared
## hex value cannot be represented at all without wrapping `int` -- i.e. a
## chunk-size line is malformed independent of any policy, the same way "not
## valid hex" is malformed independent of any policy.
##
## ## Judgment call: "truncated chunk" is never a decoder-level error
##
## A decoder fed a PREFIX of an otherwise-valid stream cannot distinguish
## "more bytes are still coming" from "the peer just vanished" -- only the
## transport layer (EOF vs. timeout vs. deadline) can. So a truncated input
## simply leaves `.phase` in a non-terminal state (`needsMore` true,
## `isDone`/`isError` both false) forever -- deterministic, never an
## exception, never a hang. `httpraw.nim` is the layer that turns "socket
## EOF/timeout while `needsMore`" into the SAME typed `toUnreachable`/
## `toTimeout` outcome it already uses for a truncated `Content-Length`
## body (symmetric with the existing "closed before the declared length
## arrived" rule) -- this module's vector tests instead prove the decoder
## side of that contract: feeding a truncated prefix never raises and never
## reports `isDone`/`isError`.
##
## ## Malformed-stream outcome (documented for `httpraw.nim`'s integration)
##
## Once `.phase` reaches `cpError` (bad hex, chunk-size overflow, or a
## violated CRLF), that failure is a live, responding server sending
## framing this transport cannot understand -- NOT a connectivity failure.
## `httpraw.nim` therefore reuses ITS OWN existing precedent for this exact
## situation (the C1b-i placeholder's documented judgment call): return
## `toOk` with the status/headers already parsed but `body = ""`, letting
## `cachehttp.nim`'s existing "2xx body undecodable -> `cvCorrupt`" rule
## fire exactly as it does today. No new `TransportOutcome` is introduced.

import std/strutils

const MaxChunkLineBytes = 4096
  ## Sanity bound on a single chunk-size (or trailer) LINE only -- never the
  ## body, which has no bound here (see module doc: cap enforcement is the
  ## fetcher's job). Guards a peer that dribbles a chunk-size/trailer line
  ## that never terminates, the same role `MaxHeaderBytes` plays for the
  ## header block in `httpraw.nim`.

type
  ChunkedError* = enum
    ceNone
    ceBadChunkSize      ## the chunk-size line's hex portion is empty or
                         ## contains a non-hex character
    ceChunkSizeOverflow  ## the declared chunk-size cannot be represented
                         ## without overflowing `int` (see module doc)
    ceMissingCrlf        ## a mandatory CRLF terminator (after a chunk-size
                         ## line, after chunk-data, or after a trailer line)
                         ## was violated

  ChunkedPhase = enum
    cpSize        ## awaiting a `chunk-size [";" chunk-ext] CRLF` line
    cpData        ## awaiting the current chunk's data bytes
    cpDataCrlf    ## awaiting the CRLF that must follow chunk-data
    cpTrailer     ## awaiting trailer lines up to and incl. the final blank
                  ## line (RFC 7230 4.1.2 trailer-part) -- consumed, ignored
    cpDone        ## terminal: body complete
    cpError       ## terminal: malformed input, see `.error`

  ChunkedDecoder* = object
    ## Pure, incremental RFC-7230 §4.1 chunked-transfer-coding decoder.
    ## Construct with `initChunkedDecoder()`, then repeatedly `feed` newly
    ## arrived bytes and inspect `.body`/`isDone`/`isError`/`.error`. Never
    ## raises. `feed` is a no-op once `isDone`/`isError` is true.
    phase: ChunkedPhase
    error*: ChunkedError
    body*: string
    buf: string     ## unconsumed bytes carried between `feed` calls
    remaining: int  ## bytes still owed for the chunk-data in progress

proc initChunkedDecoder*(): ChunkedDecoder =
  ChunkedDecoder(phase: cpSize)

proc isDone*(d: ChunkedDecoder): bool {.inline.} = d.phase == cpDone
proc isError*(d: ChunkedDecoder): bool {.inline.} = d.phase == cpError
proc needsMore*(d: ChunkedDecoder): bool {.inline.} = d.phase notin {cpDone, cpError}

proc hexDigitValue(c: char): int =
  ## -1 for a non-hex-digit char; the codec's own mapping (never relies on
  ## a stdlib hex parser's error signal, which is exception-based).
  if c in {'0'..'9'}: ord(c) - ord('0')
  elif c in {'a'..'f'}: ord(c) - ord('a') + 10
  elif c in {'A'..'F'}: ord(c) - ord('A') + 10
  else: -1

proc parseChunkSizeLine(line: string): tuple[ok: bool, err: ChunkedError, size: int] =
  ## `line` excludes the trailing CRLF. Chunk extensions (`;name=value...`)
  ## are recognized only to be discarded -- RFC 7230 4.1.1 says a recipient
  ## that does not understand an extension MUST ignore it.
  let semi = line.find(';')
  let hexPart = if semi >= 0: line[0 ..< semi] else: line
  if hexPart.len == 0:
    return (false, ceBadChunkSize, 0)
  var size = 0
  for ch in hexPart:
    let v = hexDigitValue(ch)
    if v < 0:
      return (false, ceBadChunkSize, 0)
    if size > (high(int) shr 4):
      return (false, ceChunkSizeOverflow, 0)
    size = (size shl 4) or v
  (true, ceNone, size)

proc fail(d: var ChunkedDecoder; err: ChunkedError) =
  d.phase = cpError
  d.error = err

proc feed*(d: sink ChunkedDecoder; bytes: string): ChunkedDecoder =
  ## Pure -- returns a NEW decoder value combining `d` with `bytes`. `d` is
  ## `sink` so the idiomatic `decoder = decoder.feed(more)` call pattern
  ## (every caller's, including this module's own tests) MOVES `d`'s
  ## buffers into `result` instead of deep-copying them -- without this, a
  ## decoder value's growing `.body` would be copied in full on every
  ## `feed` call, making an N-byte body cost O(N^2) total across many
  ## small `feed` calls instead of the O(N) the module doc promises.
  result = d
  if not result.needsMore: return
  result.buf.add(bytes)

  while true:
    case result.phase
    of cpSize, cpTrailer:
      let lf = result.buf.find('\n')
      if lf < 0:
        if result.buf.len > MaxChunkLineBytes:
          result.fail(ceMissingCrlf)
        return
      if lf == 0 or result.buf[lf - 1] != '\r':
        result.fail(ceMissingCrlf)
        return
      let line = result.buf[0 ..< lf - 1]
      result.buf = result.buf[lf + 1 .. ^1]
      if result.phase == cpTrailer:
        if line.len == 0:
          result.phase = cpDone
          return
        # else: a trailer header line -- consumed, ignored; loop continues.
      else:
        let (ok, err, size) = parseChunkSizeLine(line)
        if not ok:
          result.fail(err)
          return
        if size == 0:
          result.phase = cpTrailer   # last-chunk -> straight to trailer-part
        else:
          result.remaining = size
          result.phase = cpData
    of cpData:
      if result.buf.len == 0: return
      let take = min(result.remaining, result.buf.len)
      result.body.add(result.buf[0 ..< take])
      result.buf = result.buf[take .. ^1]
      result.remaining -= take
      if result.remaining > 0: return
      result.phase = cpDataCrlf
    of cpDataCrlf:
      if result.buf.len < 2:
        if result.buf.len == 1 and result.buf[0] != '\r':
          result.fail(ceMissingCrlf)
        return
      if result.buf[0] != '\r' or result.buf[1] != '\n':
        result.fail(ceMissingCrlf)
        return
      result.buf = result.buf[2 .. ^1]
      result.phase = cpSize
    of cpDone, cpError:
      return
