## test_cachehttp.nim — RFC-0005 C1: the `http` `CacheBackend` adapter,
## driven entirely by an in-memory fake `HttpFetcher` double (NO socket
## anywhere in this file — RFC-0005 "No network or hot-path disk in the
## test suite"). Grows in place through C6 (RFC-0005 fixture inventory:
## "one test_cachehttp.nim across C1/C6").
##
## Coverage (C1):
##   1. GET roundtrip: URL layout `<base>/<storageFormatVersion>/<key>`,
##      no request body, no Authorization header when no token configured,
##      200 -> decode.
##   2. Bearer header sent when a token is configured.
##   3. GET pinned status table: 404/410 -> cvMiss; 401/403 ->
##      cvUnauthorized; 408/429/5xx -> cvOffline; 3xx -> cvOffline (+
##      one-time stderr hint, asserted via call count only -- stderr
##      content is not captured here); an unpinned status (e.g. 400) ->
##      cvCorrupt (documented fallback -- see cachehttp.nim).
##   4. Transport failures: toTimeout -> cvTimeout; toUnreachable ->
##      cvOffline.
##   5. 2xx wrong Content-Type -> cvCorrupt; 2xx oversized body (over the
##      configured cap) -> cvCorrupt; 2xx undecodable JSON -> cvCorrupt
##      (propagated from the serializer).
##   6. PUT: 2xx -> cvOk; correct Content-Type + bearer header sent.
##   7. PUT pinned non-2xx: 409/412 -> cvUnauthorized (best-effort non-ok,
##      first-publisher-wins bucket); 413 -> cvCorrupt; 401/403 ->
##      cvUnauthorized; 408/429/5xx -> cvOffline; 3xx -> cvOffline; an
##      unpinned status -> cvUnauthorized (generic "write did not land"
##      bucket, same precedent `cachelocalfs.nim` documents).
##   8. PUT pre-check: an entry whose encoded size exceeds the body cap is
##      never sent to the fetcher at all -> cvCorrupt, zero fetcher calls.
##   9. PUT transport failures: toTimeout -> cvTimeout; toUnreachable ->
##      cvOffline.
##   10. `probe` is nil (`canProbe == false`) -- no bulk-existence op for
##       http. `scheme == "http"`.
##   11. Total-function: a fetcher that raises never escapes `get`/`put` --
##       both surface as `cvOffline`.
##
## Coverage (C6 -- secure-by-default credential scopes end to end): this
## adapter forwards exactly ONE opaque bearer token (RFC-0005 "Env":
## `$CRISOL_CACHE_TOKEN[_<TIER>]`, resolved once in `api.nim`) on EVERY
## request, GET or PUT alike -- it has no notion of "read" vs "write"
## itself. Read/write SCOPE is a property the SERVER attaches to a given
## token's value; C6's job is proving crisol behaves correctly against a
## server that actually enforces that split, via the `AuthValidatingServer`
## double below (unlike `FakeServer`'s scripted reply queue, this one
## inspects the incoming `Authorization` header itself and decides):
##   12. A read-scoped token authorizes GET, is refused (403 ->
##       cvUnauthorized) on PUT.
##   13. A write-scoped token authorizes both GET and PUT.
##   14. No token configured against a public-read server -> GET still
##       serves; PUT is still refused (a public mirror is never
##       write-open).
##   15. No token configured against a private server -> GET is refused
##       too (cvUnauthorized) -- credential-less access is not a special
##       case, it is simply "no read token".
##   16. An unauthorized PUT is a clean one-call no-op: no retry, exactly
##       one fetcher call.

import std/[options, strutils, unittest]
import crisol/cacheport
import crisol/cachewire
import crisol/cachehttp
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Fixtures shared with test_cachetier.nim's convention (sampleProcessResult/
# sampleCachedResult/sampleEntry) -- duplicated in miniature here rather than
# imported: this file has no import-graph reason to depend on test_cachetier
# (test files are not a shared-library surface), and the fixture is tiny.
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
# Fake server -- an in-memory HttpFetcher double, no sockets. Programmable
# per-call replies (queue, last one repeats), records every request for
# assertion, and can be told to raise instead of replying (total-function
# probe).
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

proc timeoutReply(): HttpReply = HttpReply(transport: toTimeout)
proc unreachableReply(): HttpReply = HttpReply(transport: toUnreachable)

proc headerValue(headers: seq[(string, string)]; name: string): Option[string] =
  for (k, v) in headers:
    if k == name: return some(v)
  none(string)

# ---------------------------------------------------------------------------
# 1. GET roundtrip + URL layout + no auth header when no token.
# ---------------------------------------------------------------------------

block test_get_roundtrip_and_url_layout:
  let key = SoundnessKey("a1a1a1a1a1a1a1a1")
  let fs = newFakeServer(okReply(200, encodedBody(key, exitCode = 5)))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com/crisol")
  let fetched = backend.get(key)
  assert fetched.verdict == cvOk
  assert fetched.value.result.run.exit.code == 5
  assert fetched.value.key == key
  assert fs.calls.len == 1
  assert fs.calls[0].meth == "GET"
  assert fs.calls[0].url ==
    "https://cache.example.com/crisol/" & $storageFormatVersion & "/" & $key
  assert fs.calls[0].body == ""
  assert headerValue(fs.calls[0].headers, "Authorization").isNone

block test_get_sends_bearer_token_when_configured:
  let key = SoundnessKey("b2b2b2b2b2b2b2b2")
  let fs = newFakeServer(okReply(200, encodedBody(key)))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com",
                             token = "s3cr3t-token")
  discard backend.get(key)
  assert fs.calls.len == 1
  assert headerValue(fs.calls[0].headers, "Authorization") == some("Bearer s3cr3t-token")

block test_get_404_and_410_are_miss:
  for status in [404, 410]:
    let key = SoundnessKey("c3c3c3c3c3c3c3c3")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    let fetched = backend.get(key)
    assert fetched.verdict == cvMiss, "status " & $status & " -> cvMiss"

block test_get_401_and_403_are_unauthorized:
  for status in [401, 403]:
    let key = SoundnessKey("d4d4d4d4d4d4d4d4")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    let fetched = backend.get(key)
    assert fetched.verdict == cvUnauthorized, "status " & $status & " -> cvUnauthorized"

block test_get_408_429_5xx_are_offline:
  for status in [408, 429, 500, 503, 599]:
    let key = SoundnessKey("e5e5e5e5e5e5e5e5")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    let fetched = backend.get(key)
    assert fetched.verdict == cvOffline, "status " & $status & " -> cvOffline"

block test_get_3xx_is_offline:
  let key = SoundnessKey("f6f6f6f6f6f6f6f6")
  let fs = newFakeServer(okReply(301))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  let fetched = backend.get(key)
  assert fetched.verdict == cvOffline

block test_get_unpinned_status_is_corrupt:
  let key = SoundnessKey("07070707070707a0")
  let fs = newFakeServer(okReply(400))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  let fetched = backend.get(key)
  assert fetched.verdict == cvCorrupt

block test_get_transport_timeout_and_unreachable:
  block:
    let key = SoundnessKey("1717171717171717")
    let fs = newFakeServer(timeoutReply())
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.get(key).verdict == cvTimeout
  block:
    let key = SoundnessKey("1818181818181818")
    let fs = newFakeServer(unreachableReply())
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.get(key).verdict == cvOffline

block test_get_2xx_wrong_content_type_is_corrupt:
  let key = SoundnessKey("2929292929292929")
  let fs = newFakeServer(okReply(200, encodedBody(key), contentType = "text/plain"))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.get(key).verdict == cvCorrupt

block test_get_2xx_oversized_body_is_corrupt:
  let key = SoundnessKey("3a3a3a3a3a3a3a3a")
  let bigBody = encodedBody(key) & repeat(" ", 100)
  let fs = newFakeServer(okReply(200, bigBody))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com",
                             bodyCapBytes = bigBody.len - 1)
  assert backend.get(key).verdict == cvCorrupt

block test_get_2xx_undecodable_body_is_corrupt:
  let key = SoundnessKey("4b4b4b4b4b4b4b4b")
  let fs = newFakeServer(okReply(200, "not json at all"))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.get(key).verdict == cvCorrupt

block test_put_2xx_is_ok_with_correct_headers:
  let key = SoundnessKey("5c5c5c5c5c5c5c5c")
  let fs = newFakeServer(okReply(200))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com",
                             token = "put-token")
  let verdict = backend.put(sampleEntry(key, exitCode = 3))
  assert verdict == cvOk
  assert fs.calls.len == 1
  assert fs.calls[0].meth == "PUT"
  assert fs.calls[0].url ==
    "https://cache.example.com/" & $storageFormatVersion & "/" & $key
  assert headerValue(fs.calls[0].headers, "Content-Type") == some("application/json")
  assert headerValue(fs.calls[0].headers, "Authorization") == some("Bearer put-token")
  assert fs.calls[0].body.len > 0

block test_put_409_and_412_are_unauthorized:
  for status in [409, 412]:
    let key = SoundnessKey("6d6d6d6d6d6d6d6d")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    let verdict = backend.put(sampleEntry(key))
    assert verdict == cvUnauthorized, "status " & $status & " -> cvUnauthorized"

block test_put_413_is_corrupt:
  let key = SoundnessKey("7e7e7e7e7e7e7e7e")
  let fs = newFakeServer(okReply(413))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.put(sampleEntry(key)) == cvCorrupt

block test_put_401_403_are_unauthorized:
  for status in [401, 403]:
    let key = SoundnessKey("8f8f8f8f8f8f8f8f")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.put(sampleEntry(key)) == cvUnauthorized

block test_put_408_429_5xx_are_offline:
  for status in [408, 429, 500, 599]:
    let key = SoundnessKey("90909090909090a0")
    let fs = newFakeServer(okReply(status))
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.put(sampleEntry(key)) == cvOffline

block test_put_3xx_is_offline:
  let key = SoundnessKey("a1a1a1a1a1a1a1b1")
  let fs = newFakeServer(okReply(301))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.put(sampleEntry(key)) == cvOffline

block test_put_unpinned_status_is_unauthorized:
  let key = SoundnessKey("b2b2b2b2b2b2b2c2")
  let fs = newFakeServer(okReply(400))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.put(sampleEntry(key)) == cvUnauthorized

block test_put_transport_timeout_and_unreachable:
  block:
    let key = SoundnessKey("c3c3c3c3c3c3c3d3")
    let fs = newFakeServer(timeoutReply())
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.put(sampleEntry(key)) == cvTimeout
  block:
    let key = SoundnessKey("d4d4d4d4d4d4d4e4")
    let fs = newFakeServer(unreachableReply())
    let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
    assert backend.put(sampleEntry(key)) == cvOffline

block test_put_pre_check_skips_oversized_entry_without_calling_fetcher:
  let key = SoundnessKey("e5e5e5e5e5e5e5f5")
  let entry = sampleEntry(key)
  let encodedLen = jsonCacheSerializer().encode(entry).len
  let fs = newFakeServer(okReply(200))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com",
                             bodyCapBytes = encodedLen - 1)
  let verdict = backend.put(entry)
  assert verdict == cvCorrupt
  assert fs.calls.len == 0, "pre-check must skip the fetcher call entirely"

block test_probe_is_nil_and_scheme_is_http:
  let fs = newFakeServer(okReply(200))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.scheme == "http"
  assert not backend.canProbe

block test_total_function_fetcher_raises_never_escapes:
  let fs = raisingServer()
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  let key = SoundnessKey("0606060606060606")
  assert backend.get(key).verdict == cvOffline
  assert backend.put(sampleEntry(key)) == cvOffline

block test_get_3xx_repeated_calls_still_return_offline:
  ## The one-time stderr hint is a cosmetic rate limit only -- it must never
  ## change the VERDICT of a second redirect on the same backend instance.
  let fs = newFakeServer(okReply(302), okReply(302))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")
  assert backend.get(SoundnessKey("1111111111111111")).verdict == cvOffline
  assert backend.get(SoundnessKey("2222222222222222")).verdict == cvOffline

# ---------------------------------------------------------------------------
# RFC-0005 C6 -- an auth-validating fake server. Unlike `FakeServer`'s
# programmable status QUEUE (which returns whatever a test scripts
# regardless of the request), this double actually INSPECTS the incoming
# `Authorization` header and decides the status itself, per HTTP verb --
# modeling a real server's read/write credential split so these tests prove
# crisol's behavior against genuine enforcement, not just against a status
# code a test happened to script.
# ---------------------------------------------------------------------------

type
  AuthValidatingServer = ref object
    calls*: seq[HttpRequest]
    readTokens: seq[string]   ## accepted on GET (a write token also reads)
    writeTokens: seq[string]  ## accepted on PUT
    getStatus: int            ## status returned to an AUTHORIZED GET
    getBody: string

proc newAuthValidatingServer(readTokens, writeTokens: seq[string] = @[];
                              getStatus = 200; getBody = ""): AuthValidatingServer =
  AuthValidatingServer(calls: @[], readTokens: readTokens, writeTokens: writeTokens,
                        getStatus: getStatus, getBody: getBody)

proc bearerToken(req: HttpRequest): string =
  let auth = headerValue(req.headers, "Authorization")
  if auth.isSome and auth.get.startsWith("Bearer "):
    auth.get["Bearer ".len .. ^1]
  else:
    ""

proc fetcher(fs: AuthValidatingServer): HttpFetcher =
  result = proc(req: HttpRequest): HttpReply =
    fs.calls.add req
    let token = bearerToken(req)
    case req.meth
    of "GET":
      if token in fs.readTokens or token in fs.writeTokens:
        okReply(fs.getStatus, fs.getBody)
      else:
        okReply(403)
    of "PUT":
      if token in fs.writeTokens:
        okReply(200)
      else:
        okReply(403)
    else:
      okReply(400)

block test_c6_read_token_serves_get_but_refused_on_put:
  let key = SoundnessKey("c6c6c6c6c6c6c601")
  let fs = newAuthValidatingServer(readTokens = @["read-tok"], writeTokens = @["write-tok"],
                                    getBody = encodedBody(key))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com", token = "read-tok")
  assert backend.get(key).verdict == cvOk, "a read-scoped token must serve a GET"
  assert backend.put(sampleEntry(key)) == cvUnauthorized,
    "a read-only token must be refused (server 403) on PUT"
  assert fs.calls.len == 2

block test_c6_write_token_serves_both_get_and_put:
  let key = SoundnessKey("c6c6c6c6c6c6c602")
  let fs = newAuthValidatingServer(readTokens = @["read-tok"], writeTokens = @["write-tok"],
                                    getBody = encodedBody(key))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com", token = "write-tok")
  assert backend.get(key).verdict == cvOk
  assert backend.put(sampleEntry(key)) == cvOk

block test_c6_no_token_public_read_server_serves_get_but_refuses_put:
  let key = SoundnessKey("c6c6c6c6c6c6c603")
  let fs = newAuthValidatingServer(readTokens = @[""], writeTokens = @["write-tok"],
                                    getBody = encodedBody(key))
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")  # no token configured
  assert backend.get(key).verdict == cvOk,
    "a public-read mirror (bare token \"\" accepted) serves an unauthenticated GET"
  assert backend.put(sampleEntry(key)) == cvUnauthorized,
    "publish still requires the write credential, even against a public-read mirror"

block test_c6_no_token_private_server_refuses_get_too:
  let key = SoundnessKey("c6c6c6c6c6c6c604")
  let fs = newAuthValidatingServer(readTokens = @["read-tok"], writeTokens = @["write-tok"])
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com")  # no token configured
  assert backend.get(key).verdict == cvUnauthorized,
    "credential-less access to a private server is simply \"no read token\" -- not a special case"

block test_c6_unauthorized_put_is_a_clean_single_call_no_op:
  ## No retry logic exists in this adapter at all -- one call, one verdict.
  ## A refused publish must never storm the server with retries.
  let key = SoundnessKey("c6c6c6c6c6c6c605")
  let fs = newAuthValidatingServer(readTokens = @["read-tok"])
  let backend = httpBackend(fs.fetcher, base = "https://cache.example.com", token = "read-tok")
  assert backend.put(sampleEntry(key)) == cvUnauthorized
  assert fs.calls.len == 1, "an unauthorized put must not retry"

echo "test_cachehttp: all blocks passed"
