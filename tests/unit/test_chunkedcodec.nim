## test_chunkedcodec.nim — RFC-0005 C1b-ii: the pure chunked-transfer-coding
## decoder (`crisol/chunkedcodec.nim`). Pure vector tests, no sockets.
##
## Coverage (RFC 7230 §4.1 shapes + malformed-input vectors):
##   1. single chunk, zero-size terminal chunk, no trailers.
##   2. multiple chunks assembled in order.
##   3. chunk extensions (`;name=value`) ignored.
##   4. trailers consumed/ignored (one trailer line, and none at all).
##   5. lowercase AND uppercase hex chunk-sizes.
##   6. byte-at-a-time feed == whole-input-at-once feed (genuine streaming).
##   7. malformed: bad hex chunk-size -> ceBadChunkSize.
##   8. malformed: chunk-size hex overflow -> ceChunkSizeOverflow.
##   9. malformed: missing CRLF after the chunk-size line, after chunk-data,
##      and after a trailer line -> ceMissingCrlf (three distinct vectors).
##   10. malformed: truncated input at several cut points -> needsMore
##       stays true forever (never isDone/isError, never raises/hangs).
##   11. feeding past a terminal state (done or error) is a no-op.

import std/strutils
import crisol/chunkedcodec

# ---------------------------------------------------------------------------
# 1/2/3/4/5: well-formed RFC 7230 4.1 shapes.
# ---------------------------------------------------------------------------

block test_single_chunk_no_trailers:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhello\r\n0\r\n\r\n")
  assert d.isDone
  assert not d.isError
  assert d.body == "hello"

block test_zero_size_terminal_chunk_alone:
  var d = initChunkedDecoder()
  d = d.feed("0\r\n\r\n")
  assert d.isDone
  assert d.body == ""

block test_multiple_chunks_assembled_in_order:
  var d = initChunkedDecoder()
  d = d.feed("4\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n")
  assert d.isDone
  assert d.body == "Wikipedia in\r\n\r\nchunks."

block test_chunk_extension_ignored:
  var d = initChunkedDecoder()
  d = d.feed("5;foo=bar\r\nhello\r\n0;final=1\r\n\r\n")
  assert d.isDone
  assert d.body == "hello"

block test_trailers_consumed_and_ignored:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhello\r\n0\r\nX-Trailer: value\r\nX-Other: v2\r\n\r\n")
  assert d.isDone
  assert d.body == "hello"

block test_no_trailers_just_final_blank_line:
  var d = initChunkedDecoder()
  d = d.feed("3\r\nabc\r\n0\r\n\r\n")
  assert d.isDone
  assert d.body == "abc"

block test_lowercase_and_uppercase_hex_sizes:
  var lower = initChunkedDecoder()
  lower = lower.feed("a\r\n0123456789\r\n0\r\n\r\n")
  assert lower.isDone
  assert lower.body == "0123456789"

  var upper = initChunkedDecoder()
  upper = upper.feed("A\r\n0123456789\r\n0\r\n\r\n")
  assert upper.isDone
  assert upper.body == "0123456789"

  var mixed = initChunkedDecoder()
  mixed = mixed.feed("1A\r\n" & "x".repeat(26) & "\r\n0\r\n\r\n")
  assert mixed.isDone
  assert mixed.body == "x".repeat(26)

# ---------------------------------------------------------------------------
# 6. Streaming: byte-at-a-time feed must reach the identical result as
#    feeding the whole input in one call -- proves the decoder is genuinely
#    incremental, not just a single-shot parser disguised as one.
# ---------------------------------------------------------------------------

block test_byte_at_a_time_feed_matches_whole_input_feed:
  let whole = "4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Trailer: v\r\n\r\n"

  var oneShot = initChunkedDecoder()
  oneShot = oneShot.feed(whole)

  var incremental = initChunkedDecoder()
  for ch in whole:
    incremental = incremental.feed($ch)

  assert oneShot.isDone
  assert incremental.isDone
  assert oneShot.body == incremental.body
  assert incremental.body == "Wikipedia"

# ---------------------------------------------------------------------------
# 7/8/9: malformed inputs -> typed error, never exception.
# ---------------------------------------------------------------------------

block test_bad_hex_chunk_size:
  var d = initChunkedDecoder()
  d = d.feed("zz\r\nhello\r\n0\r\n\r\n")
  assert d.isError
  assert d.error == ceBadChunkSize

block test_empty_chunk_size_line:
  var d = initChunkedDecoder()
  d = d.feed(";ext-only\r\nhello\r\n0\r\n\r\n")
  assert d.isError
  assert d.error == ceBadChunkSize

block test_chunk_size_hex_overflow:
  var d = initChunkedDecoder()
  # 17 hex digits: no value overflows `int` (64-bit) on fewer than 16 f's,
  # but a 17th digit always wraps regardless of platform int width.
  d = d.feed("fffffffffffffffff\r\nhello\r\n0\r\n\r\n")
  assert d.isError
  assert d.error == ceChunkSizeOverflow

block test_missing_crlf_after_chunk_size_line:
  var d = initChunkedDecoder()
  d = d.feed("5\nhello\r\n0\r\n\r\n")  # bare LF, no CR
  assert d.isError
  assert d.error == ceMissingCrlf

block test_missing_crlf_after_chunk_data:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhelloXX0\r\n\r\n")  # chunk-data not followed by CRLF
  assert d.isError
  assert d.error == ceMissingCrlf

block test_missing_crlf_after_trailer_line:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhello\r\n0\r\nX-Trailer: v\n\r\n")  # bare LF in trailer line
  assert d.isError
  assert d.error == ceMissingCrlf

# ---------------------------------------------------------------------------
# 10. Truncated input at several cut points -> deterministic needsMore
#     forever, never isDone/isError, never raises/hangs. (The transport
#     layer, not this module, turns "still needsMore at EOF/timeout" into a
#     typed failure -- see the module doc's "truncated chunk" judgment call.)
# ---------------------------------------------------------------------------

block test_truncated_mid_chunk_size_line:
  var d = initChunkedDecoder()
  d = d.feed("5")
  assert d.needsMore
  assert not d.isDone
  assert not d.isError

block test_truncated_mid_chunk_data:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhel")
  assert d.needsMore
  assert d.body == "hel"

block test_truncated_mid_chunk_data_crlf:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhello\r")
  assert d.needsMore
  assert d.body == "hello"

block test_truncated_mid_trailer:
  var d = initChunkedDecoder()
  d = d.feed("0\r\nX-Trailer: v")
  assert d.needsMore

block test_truncated_before_final_blank_line:
  var d = initChunkedDecoder()
  d = d.feed("5\r\nhello\r\n0\r\n")
  assert d.needsMore
  assert d.body == "hello"

# ---------------------------------------------------------------------------
# 11. Feeding past a terminal state is a no-op.
# ---------------------------------------------------------------------------

block test_feed_after_done_is_noop:
  var d = initChunkedDecoder()
  d = d.feed("3\r\nabc\r\n0\r\n\r\n")
  assert d.isDone
  let again = d.feed("garbage that would otherwise be parsed as a new chunk")
  assert again.isDone
  assert again.body == "abc"

block test_feed_after_error_is_noop:
  var d = initChunkedDecoder()
  d = d.feed("zz\r\n")
  assert d.isError
  let again = d.feed("5\r\nhello\r\n0\r\n\r\n")
  assert again.isError
  assert again.error == ceBadChunkSize

echo "test_chunkedcodec: all blocks passed"
