## cachehttp.nim — RFC-0005 C1: the `http` `CacheBackend` adapter.
##
## GET/PUT over a content-addressed URL `<base>/<storageFormatVersion>/<key>`
## (RFC-0005 "Adapters") through an INJECTED `HttpFetcher` (`cachewire.nim`'s
## transport seam) — this module knows nothing about sockets, DNS, or TLS;
## production wires the raw-`std/net` client (`httpraw.nim`, Stage C1b),
## tests wire a pure in-memory fake server (`test_cachehttp.nim`).
##
## Import-pure like the other adapters (`cachelocalfs.nim`, `cachememory.nim`
## import only `cacheport`/`cachewire` plus what they strictly need for I/O)
## -- this module adds no `std/net`/`std/httpclient`/socket dependency of its
## own; the only transport knowledge it holds is the `HttpFetcher` closure
## type itself.
##
## ## The pinned status table (RFC-0005 "Adapters", round 3)
##
## GET: `200` -> decode; `404`/`410` -> `cvMiss`; `401`/`403` ->
## `cvUnauthorized`; `408`/`429`/`5xx` -> `cvOffline` (transient, trips the
## caller's circuit breaker); `3xx` -> `cvOffline` + a ONE-TIME stderr hint
## ("remote redirected; use the final URL") — no redirect is ever followed.
## Any `2xx` with the wrong `Content-Type`, an oversized body (over the
## configured cap), or an undecodable/version-skewed body -> `cvCorrupt`
## (the last case propagated verbatim from `CacheSerializer.decode`, which
## already distinguishes `cvCorrupt` from `cvVersionSkew`).
##
## **Judgment call (unpinned status, e.g. `400`/`405`/`1xx`):** the RFC's
## table does not name every possible status. Total-function coverage
## still requires ONE typed outcome. `cvCorrupt` — "this response is not
## something the adapter understands or trusts" — is the closest existing
## bucket: it is not a miss (something WAS returned), not an auth problem,
## and, critically, it must NOT be `cvOffline`/`cvTimeout` (those trip the
## per-tier circuit breaker for the rest of the run over what is, for an
## unpinned code, more likely a server-side protocol mismatch than a
## transient outage).
##
## PUT: `2xx` -> `cvOk`; `409`/`412` -> `cvUnauthorized` (the RFC's own
## "best-effort non-ok, first publisher wins" bucket — reusing
## `cvUnauthorized` as the generic "the write did not land" verdict is the
## SAME precedent `cachelocalfs.nim` documents for its own non-reachability
## write failures); `413` -> `cvCorrupt` (the entry, as sent, is unusable to
## the server); `401`/`403` -> `cvUnauthorized`; `408`/`429`/`5xx` -> `cvOffline`;
## `3xx` -> `cvOffline` + the same one-time hint. **Judgment call:** an
## unpinned PUT status also falls to `cvUnauthorized` — the generic
## write-did-not-land bucket — rather than `cvCorrupt`, since (unlike GET) a
## non-2xx PUT response carries no body the adapter needs to trust; the
## write simply did not succeed, for a reason the table does not name.
##
## A **put pre-check** (RFC-0005 "Adapters": "a `put` pre-check skips
## entries over the body cap") never even calls the fetcher for an entry
## whose encoded size exceeds the cap — `cvCorrupt`, symmetric with the
## oversized-GET-response case, and zero transport calls (so a byte cap
## never becomes a hung/timed-out request).
import std/strutils
import crisol/cacheport
import crisol/cachewire

const DefaultBodyCapBytes* = 8 * 1024 * 1024
  ## RFC-0005 B0(a): "a body size cap (default 8 MiB — `records[].msg` is
  ## unbounded test output; `maxOutputBytes` is 10 MiB per entrypoint)".
  ## C1b's production fetcher enforces this at the transport layer too;
  ## this adapter enforces it independently on both the response it reads
  ## (GET) and the request it would send (PUT pre-check), so the cap holds
  ## even against a fetcher double that does not enforce it itself.

const JsonContentType = "application/json"

proc urlFor(base: string; key: SoundnessKey): string =
  ## `<base>/<storageFormatVersion>/<key>` (RFC-0005 "Adapters"). `base` is
  ## used verbatim except for a single trailing `/` strip, so a configured
  ## base with or without a trailing slash produces the same URL.
  var b = base
  if b.len > 0 and b[^1] == '/':
    b = b[0 ..< b.high]
  b & "/" & $storageFormatVersion & "/" & $key

proc authHeaders(token: string): seq[(string, string)] =
  if token.len > 0:
    @[("Authorization", "Bearer " & token)]
  else:
    @[]

proc headerValue(headers: seq[(string, string)]; name: string): string =
  for (k, v) in headers:
    if cmpIgnoreCase(k, name) == 0: return v
  ""

proc isRedirect(status: int): bool = status >= 300 and status <= 399
proc isServerBusy(status: int): bool =
  status == 408 or status == 429 or (status >= 500 and status <= 599)

proc getVerdictForUnhandledStatus(status: int): CacheVerdict =
  ## The pinned GET buckets that do not need the response body, PLUS the
  ## unpinned-status fallback (see module doc comment above). Callers
  ## handle `2xx` and `3xx` themselves (2xx needs the body; 3xx needs the
  ## one-time-warning side effect) before falling back here.
  if status == 404 or status == 410: cvMiss
  elif status == 401 or status == 403: cvUnauthorized
  elif isServerBusy(status): cvOffline
  else: cvCorrupt  # unpinned -- documented fallback

proc putVerdictForUnhandledStatus(status: int): CacheVerdict =
  if status == 409 or status == 412: cvUnauthorized  # best-effort non-ok, first-writer-wins
  elif status == 413: cvCorrupt
  elif status == 401 or status == 403: cvUnauthorized
  elif isServerBusy(status): cvOffline
  else: cvUnauthorized  # unpinned -- generic "write did not land" bucket

proc httpBackend*(fetcher: HttpFetcher; base: string; token: string = "";
                  bodyCapBytes: int = DefaultBodyCapBytes): CacheBackend =
  var redirectWarned = false
  proc warnRedirectOnce() =
    if redirectWarned: return
    redirectWarned = true
    stderr.write("crisol: warning: remote redirected; use the final URL\n")

  CacheBackend(
    scheme: "http",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      let req = HttpRequest(meth: "GET", url: urlFor(base, key),
                             headers: authHeaders(token), body: "")
      var reply: HttpReply
      try:
        reply = fetcher(req)
      except CatchableError:
        return Fetched[StoredEntry](verdict: cvOffline)

      case reply.transport
      of toTimeout: return Fetched[StoredEntry](verdict: cvTimeout)
      of toUnreachable: return Fetched[StoredEntry](verdict: cvOffline)
      of toOk: discard

      if reply.status >= 200 and reply.status <= 299:
        if not headerValue(reply.headers, "Content-Type").startsWith(JsonContentType):
          return Fetched[StoredEntry](verdict: cvCorrupt)
        if reply.body.len > bodyCapBytes:
          return Fetched[StoredEntry](verdict: cvCorrupt)
        let decoded = jsonCacheSerializer().decode(reply.body)
        if decoded.verdict != cvOk:
          return Fetched[StoredEntry](verdict: decoded.verdict)
        var e = decoded.value
        e.key = key
        return Fetched[StoredEntry](verdict: cvOk, value: e)

      if isRedirect(reply.status):
        warnRedirectOnce()
        return Fetched[StoredEntry](verdict: cvOffline)

      Fetched[StoredEntry](verdict: getVerdictForUnhandledStatus(reply.status))
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      let body = jsonCacheSerializer().encode(entry)
      if body.len > bodyCapBytes:
        return cvCorrupt  # pre-check: never sent

      var headers = authHeaders(token)
      headers.add ("Content-Type", JsonContentType)
      let req = HttpRequest(meth: "PUT", url: urlFor(base, entry.key),
                             headers: headers, body: body)
      var reply: HttpReply
      try:
        reply = fetcher(req)
      except CatchableError:
        return cvOffline

      case reply.transport
      of toTimeout: return cvTimeout
      of toUnreachable: return cvOffline
      of toOk: discard

      if reply.status >= 200 and reply.status <= 299:
        return cvOk

      if isRedirect(reply.status):
        warnRedirectOnce()
        return cvOffline

      putVerdictForUnhandledStatus(reply.status)
    ,
    # No standard bulk-existence op over plain HTTP (RFC-0005 "Adapters":
    # "http has no standard bulk-existence so probe = nil").
    probe: nil,
  )
