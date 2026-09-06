## caches3.nim — RFC-0005 C2: the `s3` `CacheBackend` adapter.
##
## GET/PUT object mapped onto the SAME injected `HttpFetcher` seam C1's
## `http` adapter uses (`cachewire.nim`) — unsigned/MinIO path-style
## addressing ONLY (no SigV4; RFC-0005's own dependency-decision text:
## "Initial S3 = unsigned/MinIO path-style (no SigV4). Authenticated S3 via
## SigV4 is a follow-on"). Import-pure like the other adapters (RFC-0005
## "Module layout": "one adapter each" importing only `cacheport`/
## `cachewire`) — this module does NOT import `cachehttp.nim`. The
## HTTP-status -> `CacheVerdict` mapping IS shared with `cachehttp.nim`
## (`cachewire.httpStatusVerdict`/`isRedirectStatus`) rather than duplicated:
## that mapping is pure status POLICY, not transport knowledge, so the RFC's
## "one adapter per file" boundary (which is about transport knowledge —
## sockets, URL layout, XML parsing — never about this table) does not
## require copying it per-adapter; both adapters already import
## `cachewire.nim` for `CacheSerializer`/`HttpFetcher`.
##
## No credential axis at all: unsigned means no SigV4 AND no bearer token —
## `Authorization` is never sent, unlike `cachehttp.nim`'s optional token
## (RFC-0005 "Secure-by-default": "Unsigned S3/MinIO has no transport-level
## write authorization" — the signing key on a verifying trust tier is the
## effective write credential instead; see `cachetrust.nim`, Stage C).
##
## ## URL layout (RFC-0005 "Adapters" + C2 scope)
##
## Path-style (the shipped/tested mode — `endpoint` set, MinIO):
##   `<endpoint>/<bucket>/<prefix?>/<storageFormatVersion>/<key>`
## Virtual-hosted (`pathStyle = false`):
##   `<scheme>://<bucket>.<host>/<prefix?>/<storageFormatVersion>/<key>`
##   where `<scheme>://<host>` is `endpoint` when set, else the AWS default
##   (see the judgment call on `bucketBase`, below). This constructor takes
##   `bucket`/`prefix`/`endpoint`/`pathStyle` as plain params, not a parsed
##   `s3://` URL — splitting `RemoteTier.url` into these is the future
##   registry factory's job (C3a/C3b), exactly as `cacheregistry.
##   fileBackendFactory` strips `"file://"` before calling `localFsBackend`
##   with a bare `root: string` today.
##
## ## Status table
##
## IDENTICAL to `cachehttp.nim`'s pinned table, via the SAME shared
## `cachewire.httpStatusVerdict` mapping (see `cachewire.nim` for the full
## per-code rationale) — GET: 200 -> decode; 404/410 -> cvMiss (S3
## NoSuchKey); 401/403 -> cvUnauthorized (S3 AccessDenied-class); 408/429/5xx
## -> cvOffline; 3xx -> cvOffline + one-time stderr hint; 2xx wrong
## Content-Type / oversized / undecodable -> cvCorrupt. PUT: 2xx -> cvOk;
## 409/412 -> cvUnauthorized; 413 -> cvCorrupt; 401/403 -> cvUnauthorized;
## 408/429/5xx -> cvOffline; 3xx -> cvOffline; unpinned -> cvUnauthorized. A
## put pre-check skips entries over the body cap, same as http.
##
## ## probe via ListObjectsV2 (RFC-0005 "(c) Plan-time lookups")
##
## One `GET <bucket-root>?list-type=2&prefix=<prefix?>/<storageFormatVersion>/`
## request; a `<Key>`-extraction over the raw XML body via plain substring
## scanning (`extractKeys`/`decodeXmlEntities`, below — NO
## `std/xmlparser`/`std/parsexml`, per the RFC's explicit "no general XML
## parser" instruction); each extracted key is stripped of the listing
## prefix and intersected with the requested key set.
##
## **Judgment call (truncation/continuation — silent in the RFC):** the
## probe reads exactly ONE page and never follows `NextContinuationToken`,
## even when `<IsTruncated>true</IsTruncated>` (never even parsed). This is
## SOUND despite being incomplete: `BackendProbeProc`'s only contract is
## "which of these keys EXIST" (`cacheport.nim`: "optional bulk-existence
## check"), and a key missing from a truncated first page is
## indistinguishable, from the caller's side, from a key that is genuinely
## absent — both degrade to "not reported present", which the RFC's own
## Stage C3c prefetch treats as a plan-time miss, i.e. a
## live rerun that (self-healingly) republishes — exactly the fallback the
## RFC already accepts for a dropped signing key ("Entries signed with the
## dropped key become misses (self-healing: re-run re-publishes)"). The
## UNSOUND direction — reporting a key present when it is not — can never
## happen from a truncated page (a truncated response only ever OMITS
## entries, never fabricates one), so the cap is safe by construction, not
## merely convenient.

import std/[strutils, uri, unicode, sets]
import crisol/cacheport
import crisol/cachewire

const DefaultBodyCapBytes* = 8 * 1024 * 1024
  ## Same cap/rationale as `cachehttp.DefaultBodyCapBytes` (RFC-0005 B0(a)).

const JsonContentType = "application/json"

# ---------------------------------------------------------------------------
# URL building (RFC-0005 "Adapters": s3 "same contract" over path-style
# addressing).
# ---------------------------------------------------------------------------

proc stripTrailingSlash(s: string): string =
  if s.len > 0 and s[^1] == '/': s[0 ..< s.high] else: s

proc stripSlashes(s: string): string =
  var a = 0
  var b = s.len
  while a < b and s[a] == '/': inc a
  while b > a and s[b - 1] == '/': dec b
  s[a ..< b]

proc bucketBase(bucket, endpoint: string; pathStyle: bool): string =
  ## The URL up to and including the bucket segment, no trailing slash.
  ##
  ## **Judgment call (AWS default host, `endpoint == ""`):** the RFC pins
  ## "absent -> AWS default host" but no literal string. `s3.amazonaws.com`
  ## is the well-known AWS default -- kept total (never a runtime error)
  ## even though 0005 ships and tests only the MinIO/path-style/
  ## endpoint-set path (RFC "(c) Initial S3 = unsigned/MinIO path-style").
  let ep = stripTrailingSlash(if endpoint.len > 0: endpoint else: "https://s3.amazonaws.com")
  if pathStyle:
    ep & "/" & bucket
  else:
    let idx = ep.find("://")
    if idx < 0:
      "https://" & bucket & "." & ep
    else:
      ep[0 ..< idx] & "://" & bucket & "." & ep[idx + 3 .. ^1]

proc keyPrefixPath(prefix: string): string =
  ## `<prefix>/` when non-empty, "" otherwise — the path segment inserted
  ## between the bucket and `<storageFormatVersion>`.
  let p = stripSlashes(prefix)
  if p.len > 0: p & "/" else: ""

proc objectUrl(bucket, prefix, endpoint: string; pathStyle: bool; key: SoundnessKey): string =
  ## `<endpoint>/<bucket>/<prefix?>/<storageFormatVersion>/<key>` (path-style,
  ## the shipped/tested mode) — RFC-0005's own key-layout instruction.
  bucketBase(bucket, endpoint, pathStyle) & "/" & keyPrefixPath(prefix) &
    $storageFormatVersion & "/" & $key

proc listingPrefix(prefix: string): string =
  ## The version-scoped listing prefix: `<prefix?>/<storageFormatVersion>/`
  ## — everything `objectUrl` inserts between the bucket and the key itself.
  keyPrefixPath(prefix) & $storageFormatVersion & "/"

proc listingUrl(bucket, prefix, endpoint: string; pathStyle: bool): string =
  ## ListObjectsV2 over the SAME bucket-root URL `objectUrl` addresses,
  ## `?list-type=2&prefix=<listingPrefix>` (RFC-0005 "(c) Plan-time
  ## lookups": "s3 via a ListObjectsV2 prefix listing under `<ver>/`").
  bucketBase(bucket, endpoint, pathStyle) & "?list-type=2&prefix=" &
    encodeUrl(listingPrefix(prefix), usePlus = false)

# ---------------------------------------------------------------------------
# Minimal `<Key>` extraction (RFC-0005: "a `<Key>`-extraction over the
# response, no general XML parser") — plain substring scanning, NOT
# `std/xmlparser`/`std/parsexml`.
# ---------------------------------------------------------------------------

proc decodeXmlEntities(s: string): string =
  ## Decodes the 5 predefined XML entities plus numeric character
  ## references (`&#NN;` decimal, `&#xHH;`/`&#XHH;` hex) via plain substring
  ## scanning. NOT a general XML/entity parser (no DTD/custom-entity
  ## support) — deliberately: an S3 object key never needs one; this exists
  ## only so a listing prefix/key containing `&`, `<`, `>`, `"`, or `'`
  ## round-trips correctly through the response's mandatory XML escaping.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', i + 1)
      if semi > i and semi - i <= 10:
        let ent = s[i + 1 ..< semi]
        var decoded = ""
        var ok = true
        if ent == "amp": decoded = "&"
        elif ent == "lt": decoded = "<"
        elif ent == "gt": decoded = ">"
        elif ent == "quot": decoded = "\""
        elif ent == "apos": decoded = "'"
        elif ent.len > 1 and ent[0] == '#':
          try:
            let code =
              if ent.len > 2 and (ent[1] == 'x' or ent[1] == 'X'):
                parseHexInt(ent[2 .. ^1])
              else:
                parseInt(ent[1 .. ^1])
            decoded = toUTF8(Rune(code))
          except ValueError:
            ok = false
        else:
          ok = false
        if ok:
          result.add decoded
          i = semi + 1
          continue
      result.add s[i]
      inc i
    else:
      result.add s[i]
      inc i

proc extractKeys(xml: string): seq[string] =
  ## Every `<Key>...</Key>` payload, XML-entity-decoded, in document order.
  ## Ignores everything else in the document (namespaces, `<Contents>`
  ## wrapper, `<IsTruncated>`, …) — the ONE thing `probe` needs.
  result = @[]
  var i = 0
  while true:
    let openIdx = xml.find("<Key>", i)
    if openIdx < 0: break
    let contentStart = openIdx + 5
    let closeIdx = xml.find("</Key>", contentStart)
    if closeIdx < 0: break
    result.add decodeXmlEntities(xml[contentStart ..< closeIdx])
    i = closeIdx + 6

# ---------------------------------------------------------------------------
# Status mapping — IDENTICAL to `cachehttp.nim`'s pinned table (RFC-0005
# "Adapters", round 3: "s3 (same contract...)"). Shared via
# `cachewire.httpStatusVerdict`/`isRedirectStatus` (this pure status POLICY
# carries no transport knowledge, so it does not belong to either adapter
# individually — see `cachewire.nim`'s module doc comment for the full
# rationale behind each unpinned-status fallback; the same reasoning applies
# verbatim here since S3's REST surface reuses plain HTTP status semantics).
# ---------------------------------------------------------------------------

proc headerValue(headers: seq[(string, string)]; name: string): string =
  for (k, v) in headers:
    if cmpIgnoreCase(k, name) == 0: return v
  ""

proc s3Backend*(fetcher: HttpFetcher; bucket: string; prefix: string = "";
               endpoint: string = ""; pathStyle: bool = true;
               bodyCapBytes: int = DefaultBodyCapBytes): CacheBackend =
  var redirectWarned = false
  proc warnRedirectOnce() =
    if redirectWarned: return
    redirectWarned = true
    stderr.write("crisol: warning: remote redirected; use the final URL\n")

  CacheBackend(
    scheme: "s3",
    get: proc(key: SoundnessKey): Fetched[StoredEntry] =
      let req = HttpRequest(meth: "GET",
                             url: objectUrl(bucket, prefix, endpoint, pathStyle, key),
                             headers: @[], body: "")
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

      if isRedirectStatus(reply.status):
        warnRedirectOnce()
        return Fetched[StoredEntry](verdict: cvOffline)

      Fetched[StoredEntry](verdict: httpStatusVerdict(reply.status, forGet = true))
    ,
    put: proc(entry: StoredEntry): CacheVerdict =
      let body = jsonCacheSerializer().encode(entry)
      if body.len > bodyCapBytes:
        return cvCorrupt  # pre-check: never sent

      let req = HttpRequest(meth: "PUT",
                             url: objectUrl(bucket, prefix, endpoint, pathStyle, entry.key),
                             headers: @[("Content-Type", JsonContentType)], body: body)
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

      if isRedirectStatus(reply.status):
        warnRedirectOnce()
        return cvOffline

      httpStatusVerdict(reply.status, forGet = false)
    ,
    probe: proc(keys: openArray[SoundnessKey]): Fetched[HashSet[SoundnessKey]] =
      let req = HttpRequest(meth: "GET",
                             url: listingUrl(bucket, prefix, endpoint, pathStyle),
                             headers: @[], body: "")
      var reply: HttpReply
      try:
        reply = fetcher(req)
      except CatchableError:
        return Fetched[HashSet[SoundnessKey]](verdict: cvOffline)

      case reply.transport
      of toTimeout: return Fetched[HashSet[SoundnessKey]](verdict: cvTimeout)
      of toUnreachable: return Fetched[HashSet[SoundnessKey]](verdict: cvOffline)
      of toOk: discard

      if reply.status >= 200 and reply.status <= 299:
        let ct = headerValue(reply.headers, "Content-Type")
        if not (ct.startsWith("application/xml") or ct.startsWith("text/xml")):
          return Fetched[HashSet[SoundnessKey]](verdict: cvCorrupt)
        if reply.body.len > bodyCapBytes:
          return Fetched[HashSet[SoundnessKey]](verdict: cvCorrupt)
        if not reply.body.contains("<ListBucketResult"):
          return Fetched[HashSet[SoundnessKey]](verdict: cvCorrupt)

        # Single page only (RFC-0005 is silent on continuation/pagination for
        # probe) -- see the module doc comment's soundness argument: a key
        # omitted from a truncated page just never joins `present`, which is
        # indistinguishable, downstream, from a genuine absence. Never
        # unsound (a truncated response only ever omits entries).
        let pfx = listingPrefix(prefix)
        var wanted = initHashSet[SoundnessKey]()
        for k in keys: wanted.incl k
        var present = initHashSet[SoundnessKey]()
        for rawKey in extractKeys(reply.body):
          if rawKey.startsWith(pfx):
            let bare = SoundnessKey(rawKey[pfx.len .. ^1])
            if bare in wanted:
              present.incl bare
        return Fetched[HashSet[SoundnessKey]](verdict: cvOk, value: present)

      if isRedirectStatus(reply.status):
        warnRedirectOnce()
        return Fetched[HashSet[SoundnessKey]](verdict: cvOffline)

      Fetched[HashSet[SoundnessKey]](verdict: httpStatusVerdict(reply.status, forGet = true))
    ,
  )
