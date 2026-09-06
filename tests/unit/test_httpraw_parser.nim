## test_httpraw_parser.nim — RFC-0005 C1b-i: pure/socket-free coverage of
## `httpraw.nim`'s response-parsing seams, fed synthetic bytes directly (no
## socket -- see tests/integration/test_httpraw_real.nim for the real-socket
## wiring proofs, which this file deliberately does not duplicate).
##
## `parseStatusAndHeaders` was already a pure `string -> tuple` proc; it only
## needed exporting. `readHeaderBlock` was widened to take a `HeaderReader`
## closure (a one-call "fill this buffer" seam with `recvChunk`'s own
## return shape) instead of a `Socket` -- production wires a one-line
## closure over `recvChunk`/`socket`/`deadline` (see `readResponse`), tests
## wire a closure over an in-memory byte source. No module restructuring
## beyond that.
##
## Coverage:
##   1. `parseStatusAndHeaders` status-line variants: well-formed, missing
##      fields, a status code that overflows `int`, and a block with no
##      CRLF at all.
##   2. `parseStatusAndHeaders` header handling as CURRENTLY implemented,
##      pinned rather than idealized: duplicate header names both survive
##      (first-match-wins is a consumer-side, `headerValue`-only rule, not
##      a parse-time dedup), and an obs-fold continuation line (no colon)
##      is silently dropped, not appended to the preceding value.
##   3. `readHeaderBlock`'s `MaxHeaderBytes` cap: a peer that never sends
##      the blank-line terminator is cut off at the cap with `rioError`,
##      not an unbounded accumulation (and, trivially, not a hang -- this
##      unit test has no socket or deadline at all, so a real hang is not
##      even possible; the assertion that matters is the CAP itself firing
##      before the accumulator grows without bound).

import std/strutils
import crisol/httpraw

# ---------------------------------------------------------------------------
# 1. parseStatusAndHeaders: status-line variants.
# ---------------------------------------------------------------------------

block test_well_formed_status_and_headers:
  let (ok, status, headers) = parseStatusAndHeaders(
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Fake: yes")
  assert ok
  assert status == 200
  assert headers == @[("Content-Type", "text/plain"), ("X-Fake", "yes")]

block test_missing_fields_in_status_line:
  let (ok, _, _) = parseStatusAndHeaders("HTTP/1.1")
  assert not ok, "a status line with no status-code field must not parse"

block test_huge_status_code_overflows_int:
  let (ok, _, _) = parseStatusAndHeaders("HTTP/1.1 99999999999999999999 OK")
  assert not ok, "a status code overflowing int must not parse"

block test_no_crlf_at_all:
  # No "\r\n" anywhere -- `split("\r\n")` yields the WHOLE block as a single
  # "line", so it's read (and, if parseable, accepted) as the status line
  # alone; there is no second line to hold headers, so none are produced.
  # Pinning current behavior, not idealizing it.
  let (ok, status, headers) = parseStatusAndHeaders("HTTP/1.1 200 OK")
  assert ok
  assert status == 200
  assert headers.len == 0

# ---------------------------------------------------------------------------
# 2. parseStatusAndHeaders: header handling as currently implemented.
# ---------------------------------------------------------------------------

block test_duplicate_header_names_both_survive_parse:
  let (ok, _, headers) = parseStatusAndHeaders(
    "HTTP/1.1 200 OK\r\nX-Custom: a\r\nX-Custom: b")
  assert ok
  assert headers == @[("X-Custom", "a"), ("X-Custom", "b")],
    "parse time keeps every occurrence; first-match-wins is a " &
    "headerValue()-only, consumer-side rule"

block test_obs_fold_continuation_line_is_silently_dropped:
  # A continuation line (leading whitespace, no colon of its own) is not
  # specially folded into the preceding header's value -- it has no colon,
  # so the `colonIdx < 0: continue` branch silently drops it.
  let (ok, _, headers) = parseStatusAndHeaders(
    "HTTP/1.1 200 OK\r\nX-Custom: a\r\n more-value-on-a-folded-line\r\nX-Other: b")
  assert ok
  assert headers == @[("X-Custom", "a"), ("X-Other", "b")],
    "an obs-fold continuation line is dropped, not appended, under the " &
    "current (unfolded) parser"

# ---------------------------------------------------------------------------
# 3. readHeaderBlock: the MaxHeaderBytes cap, fed synthetic bytes.
# ---------------------------------------------------------------------------

block test_header_block_cap_fires_without_terminator:
  # A peer that dribbles bytes forever without ever sending "\r\n\r\n" --
  # each `read` call hands back one more full 4096-byte chunk of filler, no
  # terminator ever appears. Must cut off at (just past) MaxHeaderBytes,
  # not accumulate unboundedly.
  var chunk: array[4096, byte]
  for i in 0 ..< chunk.len: chunk[i] = byte('a')
  var callCount = 0
  let reader = proc(buf: var openArray[byte]): tuple[res: RawIoResult, n: int] =
    inc callCount
    for i in 0 ..< chunk.len: buf[i] = chunk[i]
    (rioOk, chunk.len)

  let (res, raw) = readHeaderBlock(reader)
  assert res == rioError, "no terminator ever arrives -- must hit the cap, not rioOk"
  assert raw.len > MaxHeaderBytes,
    "the accumulator must have actually reached the cap before erroring out"
  assert raw.len <= MaxHeaderBytes + chunk.len,
    "must stop at (just past) the cap, not keep reading indefinitely"
  # MaxHeaderBytes (64 KiB) / 4096-byte chunks -> 16 calls to reach the cap
  # exactly, +1 more (whose result the NEXT loop iteration's check catches).
  assert callCount <= (MaxHeaderBytes div chunk.len) + 1,
    "must stop reading at the cap, not keep calling the reader past it"

echo "test_httpraw_parser: all blocks passed"
