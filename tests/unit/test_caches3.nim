## test_caches3.nim — RFC-0005 C2: the `s3` `CacheBackend` adapter, driven
## entirely by an in-memory fake `HttpFetcher` double (NO socket anywhere in
## this file — RFC-0005 "No network or hot-path disk in the test suite").
## Mirrors `test_cachehttp.nim`'s fake-server pattern; grows in place across
## later slices exactly like that file does.

import std/[options, sets, strutils, unittest]
import crisol/cacheport
import crisol/cachewire
import crisol/caches3
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Fixtures — duplicated in miniature from test_cachehttp.nim (same rationale:
# no import-graph reason for one test file to depend on another).
# ---------------------------------------------------------------------------

proc sampleCachedResult(exitCode: int = 0): CachedResult =
  CachedResult(
    run: ptypes.ProcessResult(
      exit:  ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
      cause: ptypes.Cause(by: ptypes.cbProcess),
      evidence: ptypes.Evidence(
        killDomain: ptypes.kdsProcessGroup,
        tree:       ptypes.toComplete,
        escapees:   @[],
        limits:     default(ptypes.LimitsAchieved),
        hermetic:   ptypes.hlIsolated,
        killSnapshot: @[],
        cooperativeUnavailable: false,
      ),
      rusage: none(ptypes.Rusage),
      durationUs: 42_000,
    ),
    records: @[],
    cachedAt: 1_700_001_000'i64,
    payloadChecksum: "",
  )

proc sampleEntry(key: SoundnessKey; exitCode = 0): StoredEntry =
  StoredEntry(
    key:            key,
    keyInputs:      none(KeyInputs),
    result:         sampleCachedResult(exitCode),
    storageVersion: storageFormatVersion,
    attestation:    none(Attestation),
  )

proc encodedBody(key: SoundnessKey; exitCode = 0): string =
  jsonCacheSerializer().encode(sampleEntry(key, exitCode))

# ---------------------------------------------------------------------------
# Fake server — identical shape to test_cachehttp.nim's.
# ---------------------------------------------------------------------------

type
  FakeServer = ref object
    calls*: seq[HttpRequest]
    replies: seq[HttpReply]
    idx: int
    raiseInstead: bool

proc newFakeServer(replies: varargs[HttpReply]): FakeServer =
  FakeServer(calls: @[], replies: @replies, idx: 0, raiseInstead: false)

proc raisingServer(): FakeServer =
  result = FakeServer(calls: @[], replies: @[], idx: 0, raiseInstead: true)

proc fetcher(fs: FakeServer): HttpFetcher =
  result = proc(req: HttpRequest): HttpReply =
    fs.calls.add req
    if fs.raiseInstead:
      raise newException(CatchableError, "fake server: injected failure")
    if fs.idx < fs.replies.len:
      result = fs.replies[fs.idx]
      inc fs.idx
    else:
      result = fs.replies[^1]

proc okReply(status: int; body = ""; contentType = "application/json"): HttpReply =
  HttpReply(transport: toOk, status: status,
            headers: @[("Content-Type", contentType)], body: body)

proc xmlReply(status: int; body: string): HttpReply =
  HttpReply(transport: toOk, status: status,
            headers: @[("Content-Type", "application/xml")], body: body)

proc timeoutReply(): HttpReply = HttpReply(transport: toTimeout)
proc unreachableReply(): HttpReply = HttpReply(transport: toUnreachable)

proc headerValue(headers: seq[(string, string)]; name: string): Option[string] =
  for (k, v) in headers:
    if k == name: return some(v)
  none(string)

# ---------------------------------------------------------------------------
# 1. GET roundtrip + path-style URL layout (MinIO shape).
# ---------------------------------------------------------------------------

block test_get_roundtrip_and_path_style_url_layout:
  let key = SoundnessKey("a1a1a1a1a1a1a1a1")
  let fs = newFakeServer(okReply(200, encodedBody(key, exitCode = 5)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000", pathStyle = true)
  let fetched = backend.get(key)
  assert fetched.verdict == cvOk
  assert fetched.value.result.run.exit.code == 5
  assert fetched.value.key == key
  assert fs.calls.len == 1
  assert fs.calls[0].meth == "GET"
  assert fs.calls[0].url ==
    "http://minio.local:9000/crisol/proj/" & $storageFormatVersion & "/" & $key
  assert fs.calls[0].body == ""
  assert headerValue(fs.calls[0].headers, "Authorization").isNone

block test_get_virtual_hosted_url_layout_no_endpoint:
  ## pathStyle = false, no endpoint -> AWS-default virtual-hosted host.
  let key = SoundnessKey("b2b2b2b2b2b2b2b2")
  let fs = newFakeServer(okReply(200, encodedBody(key)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           pathStyle = false)
  discard backend.get(key)
  assert fs.calls.len == 1
  assert fs.calls[0].url ==
    "https://crisol.s3.amazonaws.com/proj/" & $storageFormatVersion & "/" & $key

block test_get_virtual_hosted_url_layout_with_endpoint:
  ## pathStyle = false, custom endpoint -> bucket inserted as subdomain of
  ## the endpoint's own host.
  let key = SoundnessKey("c3c3c3c3c3c3c3c3")
  let fs = newFakeServer(okReply(200, encodedBody(key)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol",
                           endpoint = "http://s3.local:9000", pathStyle = false)
  discard backend.get(key)
  assert fs.calls[0].url ==
    "http://crisol.s3.local:9000/" & $storageFormatVersion & "/" & $key

block test_get_path_style_no_prefix:
  let key = SoundnessKey("d4d4d4d4d4d4d4d4")
  let fs = newFakeServer(okReply(200, encodedBody(key)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol",
                           endpoint = "http://minio.local:9000", pathStyle = true)
  discard backend.get(key)
  assert fs.calls[0].url ==
    "http://minio.local:9000/crisol/" & $storageFormatVersion & "/" & $key

block test_get_never_sends_authorization_header:
  ## Unsigned/MinIO only: no SigV4, no bearer token, no credential axis at
  ## all -- Authorization must never appear regardless of status.
  let key = SoundnessKey("e5e5e5e5e5e5e5e5")
  let fs = newFakeServer(okReply(200, encodedBody(key)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol",
                           endpoint = "http://minio.local:9000")
  discard backend.get(key)
  assert headerValue(fs.calls[0].headers, "Authorization").isNone

block test_get_404_and_410_are_miss:
  for status in [404, 410]:
    let key = SoundnessKey("f6f6f6f6f6f6f6f6")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.get(key).verdict == cvMiss, "status " & $status & " -> cvMiss"

block test_get_401_and_403_are_unauthorized:
  for status in [401, 403]:
    let key = SoundnessKey("07070707070707a0")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.get(key).verdict == cvUnauthorized, "status " & $status & " -> cvUnauthorized"

block test_get_408_429_5xx_are_offline:
  for status in [408, 429, 500, 503, 599]:
    let key = SoundnessKey("1717171717171717")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.get(key).verdict == cvOffline, "status " & $status & " -> cvOffline"

block test_get_3xx_is_offline:
  let key = SoundnessKey("1818181818181818")
  let fs = newFakeServer(okReply(301))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.get(key).verdict == cvOffline

block test_get_unpinned_status_is_corrupt:
  let key = SoundnessKey("2929292929292929")
  let fs = newFakeServer(okReply(400))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.get(key).verdict == cvCorrupt

block test_get_transport_timeout_and_unreachable:
  block:
    let key = SoundnessKey("3a3a3a3a3a3a3a3a")
    let fs = newFakeServer(timeoutReply())
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.get(key).verdict == cvTimeout
  block:
    let key = SoundnessKey("4b4b4b4b4b4b4b4b")
    let fs = newFakeServer(unreachableReply())
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.get(key).verdict == cvOffline

block test_get_2xx_wrong_content_type_is_corrupt:
  let key = SoundnessKey("5c5c5c5c5c5c5c5c")
  let fs = newFakeServer(okReply(200, encodedBody(key), contentType = "text/plain"))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.get(key).verdict == cvCorrupt

block test_get_2xx_oversized_body_is_corrupt:
  let key = SoundnessKey("6d6d6d6d6d6d6d6d")
  let bigBody = encodedBody(key) & repeat(" ", 100)
  let fs = newFakeServer(okReply(200, bigBody))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000",
                           bodyCapBytes = bigBody.len - 1)
  assert backend.get(key).verdict == cvCorrupt

block test_get_2xx_undecodable_body_is_corrupt:
  let key = SoundnessKey("7e7e7e7e7e7e7e7e")
  let fs = newFakeServer(okReply(200, "not json at all"))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.get(key).verdict == cvCorrupt

block test_put_2xx_is_ok_with_correct_headers_and_no_authorization:
  let key = SoundnessKey("8f8f8f8f8f8f8f8f")
  let fs = newFakeServer(okReply(200))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000")
  let verdict = backend.put(sampleEntry(key, exitCode = 3))
  assert verdict == cvOk
  assert fs.calls.len == 1
  assert fs.calls[0].meth == "PUT"
  assert fs.calls[0].url ==
    "http://minio.local:9000/crisol/proj/" & $storageFormatVersion & "/" & $key
  assert headerValue(fs.calls[0].headers, "Content-Type") == some("application/json")
  assert headerValue(fs.calls[0].headers, "Authorization").isNone
  assert fs.calls[0].body.len > 0

block test_put_409_and_412_are_unauthorized:
  for status in [409, 412]:
    let key = SoundnessKey("90909090909090a0")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.put(sampleEntry(key)) == cvUnauthorized, "status " & $status & " -> cvUnauthorized"

block test_put_413_is_corrupt:
  let key = SoundnessKey("a1a1a1a1a1a1a1b1")
  let fs = newFakeServer(okReply(413))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.put(sampleEntry(key)) == cvCorrupt

block test_put_401_403_are_unauthorized:
  for status in [401, 403]:
    let key = SoundnessKey("b2b2b2b2b2b2b2c2")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.put(sampleEntry(key)) == cvUnauthorized

block test_put_408_429_5xx_are_offline:
  for status in [408, 429, 500, 599]:
    let key = SoundnessKey("c3c3c3c3c3c3c3d3")
    let fs = newFakeServer(okReply(status))
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.put(sampleEntry(key)) == cvOffline

block test_put_3xx_is_offline:
  let key = SoundnessKey("d4d4d4d4d4d4d4e4")
  let fs = newFakeServer(okReply(301))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.put(sampleEntry(key)) == cvOffline

block test_put_unpinned_status_is_unauthorized:
  let key = SoundnessKey("e5e5e5e5e5e5e5f5")
  let fs = newFakeServer(okReply(400))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.put(sampleEntry(key)) == cvUnauthorized

block test_put_transport_timeout_and_unreachable:
  block:
    let key = SoundnessKey("0606060606060606")
    let fs = newFakeServer(timeoutReply())
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.put(sampleEntry(key)) == cvTimeout
  block:
    let key = SoundnessKey("1111111111111111")
    let fs = newFakeServer(unreachableReply())
    let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
    assert backend.put(sampleEntry(key)) == cvOffline

block test_put_pre_check_skips_oversized_entry_without_calling_fetcher:
  let key = SoundnessKey("2222222222222222")
  let entry = sampleEntry(key)
  let encodedLen = jsonCacheSerializer().encode(entry).len
  let fs = newFakeServer(okReply(200))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000",
                           bodyCapBytes = encodedLen - 1)
  let verdict = backend.put(entry)
  assert verdict == cvCorrupt
  assert fs.calls.len == 0, "pre-check must skip the fetcher call entirely"

block test_put_total_function_fetcher_raises_never_escapes:
  let fs = raisingServer()
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  let key = SoundnessKey("3333333333333333")
  assert backend.get(key).verdict == cvOffline
  assert backend.put(sampleEntry(key)) == cvOffline

block test_scheme_is_s3_and_probe_is_settable:
  let fs = newFakeServer(okReply(200))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.scheme == "s3"
  assert backend.canProbe

# ---------------------------------------------------------------------------
# probe via ListObjectsV2 -- minimal <Key>-extraction, no general XML parser.
# ---------------------------------------------------------------------------

proc listing(keys: openArray[string] = []; truncated = false): string =
  var contents = ""
  for k in keys:
    contents.add "<Contents><Key>" & k & "</Key><Size>10</Size></Contents>"
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>" &
    "<IsTruncated>" & (if truncated: "true" else: "false") & "</IsTruncated>" &
    contents & "</ListBucketResult>"

block test_probe_request_shape_list_type_2_and_prefix:
  let fs = newFakeServer(xmlReply(200, listing()))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000")
  discard backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")])
  assert fs.calls.len == 1
  assert fs.calls[0].meth == "GET"
  assert fs.calls[0].url == "http://minio.local:9000/crisol?list-type=2&prefix=proj%2F" &
    $storageFormatVersion & "%2F"
  assert headerValue(fs.calls[0].headers, "Authorization").isNone

block test_probe_extracts_present_keys_intersected_with_requested:
  let k1 = SoundnessKey("aaaaaaaaaaaaaaaa")
  let k2 = SoundnessKey("bbbbbbbbbbbbbbbb")
  let k3 = SoundnessKey("cccccccccccccccc")  # not listed
  let pfx = "proj/" & $storageFormatVersion & "/"
  let fs = newFakeServer(xmlReply(200, listing(@[pfx & $k1, pfx & $k2])))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000")
  let fetched = backend.probe(@[k1, k2, k3])
  assert fetched.verdict == cvOk
  assert fetched.value == toHashSet([k1, k2])

block test_probe_ignores_keys_outside_requested_set:
  let k1 = SoundnessKey("aaaaaaaaaaaaaaaa")
  let other = SoundnessKey("dddddddddddddddd")
  let pfx = "proj/" & $storageFormatVersion & "/"
  let fs = newFakeServer(xmlReply(200, listing(@[pfx & $k1, pfx & $other])))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000")
  let fetched = backend.probe(@[k1])
  assert fetched.verdict == cvOk
  assert fetched.value == toHashSet([k1])

block test_probe_decodes_xml_entities_in_key:
  ## A key containing XML-escaped characters (`&amp;`, `&#38;`) must decode
  ## to the literal bytes before comparison -- soundness keys themselves are
  ## always plain hex, but the extraction must be correct regardless (the
  ## project prefix is operator-controlled and not guaranteed hex-only).
  let raw = "we&ird"
  let escaped = "we&amp;ird"
  let pfx = "p&amp;p/" & $storageFormatVersion & "/"  # prefix itself entity-escaped on the wire
  let fs = newFakeServer(xmlReply(200, listing(@[pfx & escaped])))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "p&p",
                           endpoint = "http://minio.local:9000")
  let fetched = backend.probe(@[SoundnessKey(raw)])
  assert fetched.verdict == cvOk
  assert fetched.value == toHashSet([SoundnessKey(raw)])

block test_probe_truncated_page_is_still_ok_missing_keys_just_absent:
  ## RFC-0005 is silent on continuation/pagination for probe. Judgment call:
  ## cap at one page: `IsTruncated` is never inspected/followed. This is
  ## sound because a key omitted from a truncated page is indistinguishable,
  ## from the caller's side, from a key that is genuinely absent -- both
  ## degrade to "not reported present", which downstream (Stage C3c,
  ## unbuilt) falls back to a live rerun, never a false hit.
  let k1 = SoundnessKey("aaaaaaaaaaaaaaaa")
  let k2 = SoundnessKey("bbbbbbbbbbbbbbbb")  # would be on page 2, never fetched
  let pfx = "proj/" & $storageFormatVersion & "/"
  let fs = newFakeServer(xmlReply(200, listing(@[pfx & $k1], truncated = true)))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", prefix = "proj",
                           endpoint = "http://minio.local:9000")
  let fetched = backend.probe(@[k1, k2])
  assert fetched.verdict == cvOk
  assert fetched.value == toHashSet([k1])
  assert fs.calls.len == 1, "probe must never follow a continuation token"

block test_probe_empty_listing_is_ok_empty_set:
  let fs = newFakeServer(xmlReply(200, listing()))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  let fetched = backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")])
  assert fetched.verdict == cvOk
  assert fetched.value.len == 0

block test_probe_wrong_content_type_is_corrupt:
  let fs = newFakeServer(okReply(200, listing(), contentType = "text/plain"))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvCorrupt

block test_probe_oversized_body_is_corrupt:
  let body = listing(@["aaaaaaaaaaaaaaaa"]) & repeat(" ", 100)
  let fs = newFakeServer(xmlReply(200, body))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000",
                           bodyCapBytes = body.len - 1)
  assert backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvCorrupt

block test_probe_unparseable_body_is_corrupt:
  let fs = newFakeServer(xmlReply(200, "not xml at all"))
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvCorrupt

block test_probe_status_table_matches_get:
  let backend404 = s3Backend(newFakeServer(okReply(404)).fetcher, bucket = "crisol",
                              endpoint = "http://minio.local:9000")
  assert backend404.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvMiss
  let backend403 = s3Backend(newFakeServer(okReply(403)).fetcher, bucket = "crisol",
                              endpoint = "http://minio.local:9000")
  assert backend403.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvUnauthorized
  let backend500 = s3Backend(newFakeServer(okReply(500)).fetcher, bucket = "crisol",
                              endpoint = "http://minio.local:9000")
  assert backend500.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvOffline
  let backend301 = s3Backend(newFakeServer(okReply(301)).fetcher, bucket = "crisol",
                              endpoint = "http://minio.local:9000")
  assert backend301.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvOffline

block test_probe_transport_failures:
  let backendTimeout = s3Backend(newFakeServer(timeoutReply()).fetcher, bucket = "crisol",
                                  endpoint = "http://minio.local:9000")
  assert backendTimeout.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvTimeout
  let backendUnreachable = s3Backend(newFakeServer(unreachableReply()).fetcher, bucket = "crisol",
                                      endpoint = "http://minio.local:9000")
  assert backendUnreachable.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvOffline

block test_probe_total_function_fetcher_raises_never_escapes:
  let fs = raisingServer()
  let backend = s3Backend(fs.fetcher, bucket = "crisol", endpoint = "http://minio.local:9000")
  assert backend.probe(@[SoundnessKey("aaaaaaaaaaaaaaaa")]).verdict == cvOffline

echo "test_caches3: all blocks passed"
