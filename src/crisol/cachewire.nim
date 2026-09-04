## cachewire.nim — RFC-0005 A1: the JSON `CacheSerializer` — the ONE
## on-disk/on-wire encoding of `StoredEntry`, used by every adapter
## (`local-fs` included, from A2a on) — see RFC-0005 "One format,
## everywhere".
##
## ## Wire shape
##
## A superset of the landed RFC-0004/rfc-0007 result-cache file
## (`resultcache.nim`'s `header`/`payloadChecksum`/`payload`, byte-identical)
## plus three OPTIONAL top-level keys:
##
## ```json
## {
##   "header":          { "formatVersion": <resultCacheFormatVersion> },
##   "payloadChecksum": "<16 hex chars>",
##   "payload":         { ... resultcache.payloadToJson, verbatim ... },
##   "keyInputs":       { ... }?,              -- absent on a pre-0005 file
##   "attestation":      { "sigAlg", "signer", "signature", "signedAt" }?,
##   "storage":          { "version": <storageFormatVersion> }?
## }
## ```
##
## `header`/`payloadChecksum`/`payload` are read exactly as `loadCached`
## reads them today, so **a pre-0005 crisol reads a 0005 L1 file unchanged**,
## and a 0005 reader reads a pre-0005 file unchanged (the three additive keys
## are simply absent).
##
## ## Two hashes, two layers (RFC-0005 "Integrity vs. trust")
##
## `payloadChecksum` is FNV-1a-64 over `canonicalPayload(result)`
## (`resultcache.nim`) — an INTEGRITY check against torn/tampered bytes, not
## a trust decision. Mismatch ⇒ `cvCorrupt`. The embedded
## `resultCacheFormatVersion` (the `header` block) and the envelope's own
## `storageFormatVersion` (the `storage` block, when present) are two
## INDEPENDENT version axes — either mismatching ⇒ `cvVersionSkew`. Trust
## (SHA-256 + ed25519/HMAC over `envelopeBytes`) is Stage C; this module
## stays crypto-free.
##
## ## `key` is never on the wire
##
## `StoredEntry.key` is the content ADDRESS, not content — it is always
## contextual (a filename, a URL path, a table key), never encoded/decoded
## here. `decode`'s returned entry carries `key` at its zero value; the
## backend that owns the addressing scheme (see `cachememory.nim`) fills it
## in from context after a successful decode.
##
## ## `verifyEntryIntegrity` — one check, two callers
##
## The checksum-recompute + storage-version check is factored out so it
## governs `decode` (below) AND `cachememory`'s `memory` double identically
## — `CacheBackend.get`'s integrity contract (`cvCorrupt`/`cvVersionSkew` on
## stale/tampered data) is a property of the PORT, not an artifact of
## byte-serialization; a backend that never touches bytes (the in-memory
## object double) must honor it exactly the same as one that does.

import std/[json, options, tables]
import crisol/cacheport
import crisol/resultcache
import crisol/fnv
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Version coupling (RFC-0005 "Integrity vs. trust", point 3).
# ---------------------------------------------------------------------------

const storageFormatVersion* = 1
  ## `StoredEntry` ENVELOPE schema version — independent of, but coupled to,
  ## `resultCacheFormatVersion` (`resultcache.nim`), the PAYLOAD's own
  ## schema version. Covers the envelope shape only (which optional keys
  ## exist and how they are shaped) — never the payload's own schema, which
  ## `resultCacheFormatVersion`/`header.formatVersion` alone governs.

static:
  doAssert resultCacheFormatVersion == 3 and storageFormatVersion == 1,
    "RFC-0005 version coupling (cachewire.nim): any resultCacheFormatVersion " &
    "bump MUST bump storageFormatVersion in the SAME change. The key/URL " &
    "carries only storageVersion (SoundnessKey excludes schema by design), " &
    "so a payload-schema bump without an envelope-schema bump would make a " &
    "mixed fleet thrash one key with mutually-cvVersionSkew payloads. " &
    "Update the pair this assert expects together with whichever constant " &
    "you just bumped."

# ---------------------------------------------------------------------------
# Limits <-> JSON (KeyInputs' resource-limit-REQUEST component).
# ---------------------------------------------------------------------------

proc limitKindName(k: ptypes.LimitKind): string =
  ## crisol's OWN mapping (never the auto `$`, so a Nim identifier rename can
  ## never silently change the wire) — mirrors `process/resultjson.nim`'s
  ## convention for every other wire enum.
  case k
  of ptypes.lkAddressSpace: "addressSpace"
  of ptypes.lkCpu: "cpu"
  of ptypes.lkFileSize: "fileSize"
  of ptypes.lkOpenFiles: "openFiles"
  of ptypes.lkCore: "core"

proc limitsToJson(l: ptypes.Limits): JsonNode =
  result = newJObject()
  for k in ptypes.LimitKind:
    if l.req[k].isSome:
      result[limitKindName(k)] = newJInt(l.req[k].get)
    else:
      result[limitKindName(k)] = newJNull()

proc limitsFromJson(node: JsonNode): Option[ptypes.Limits] =
  if node == nil or node.kind != JObject: return
  var l: ptypes.Limits
  for k in ptypes.LimitKind:
    let n = node{limitKindName(k)}
    if n == nil: return
    case n.kind
    of JNull: l.req[k] = none(int64)
    of JInt:  l.req[k] = some(n.getBiggestInt)
    else: return
  some(l)

# ---------------------------------------------------------------------------
# KeyInputs <-> JSON (`keyInputsToJson`/`keyInputsFromJson`) — advisory
# sidecar/wire data, NOT checksum-covered (unlike `payload`).
# ---------------------------------------------------------------------------

proc keyInputsToJson*(inp: KeyInputs): JsonNode =
  result = newJObject()
  result["closureContentHash"] = newJString(inp.closureContentHash)
  result["flagHash"]           = newJString(inp.flagHash)
  result["nimVersion"]         = newJString(inp.nimVersion)
  result["ccVersion"]          = newJString(inp.ccVersion)
  result["fixtureHash"]        = newJString(inp.fixtureHash)
  let argvArr = newJArray()
  for a in inp.argv:
    argvArr.add newJString(a)
  result["argv"]              = argvArr
  result["limits"]            = limitsToJson(inp.limits)
  result["hermeticEnvHash"]   = newJString(inp.hermeticEnvHash)
  result["protocolMajor"]     = newJInt(inp.protocolMajor)

proc keyInputsFromJson*(node: JsonNode): Option[KeyInputs] =
  if node == nil or node.kind != JObject: return
  let closureN = node{"closureContentHash"}
  let flagN    = node{"flagHash"}
  let nimN     = node{"nimVersion"}
  let ccN      = node{"ccVersion"}
  let fixN     = node{"fixtureHash"}
  let argvN    = node{"argv"}
  let limitsN  = node{"limits"}
  let envN     = node{"hermeticEnvHash"}
  let protoN   = node{"protocolMajor"}
  if closureN == nil or closureN.kind != JString: return
  if flagN == nil or flagN.kind != JString: return
  if nimN == nil or nimN.kind != JString: return
  if ccN == nil or ccN.kind != JString: return
  if fixN == nil or fixN.kind != JString: return
  if argvN == nil or argvN.kind != JArray: return
  var argv: seq[string]
  for a in argvN:
    if a.kind != JString: return
    argv.add a.getStr
  let limits = limitsFromJson(limitsN)
  if limits.isNone: return
  if envN == nil or envN.kind != JString: return
  if protoN == nil or protoN.kind != JInt: return
  some(KeyInputs(
    closureContentHash: closureN.getStr,
    flagHash:           flagN.getStr,
    nimVersion:         nimN.getStr,
    ccVersion:          ccN.getStr,
    fixtureHash:        fixN.getStr,
    argv:               argv,
    limits:             limits.get,
    hermeticEnvHash:    envN.getStr,
    protocolMajor:      protoN.getInt,
  ))

# ---------------------------------------------------------------------------
# Sidecar <-> JSON (RFC-0005 B1b: the path-keyed explain-miss sidecar) —
# hand-written, following `keyInputsToJson`/`keyInputsFromJson`'s pattern
# (never `std/jsonutils`). This is a LOCAL-FS implementation detail, not
# part of the `CacheBackend` port contract (`cachelocalfs.nim` owns the
# path/read/write I/O; this module owns only the type + wire shape, exactly
# as it owns `StoredEntry`'s own codec).
#
# `Sidecar` stores a small map `flagHash -> {inputs, envDigest}`,
# most-recent-per-flagHash (`upsertSidecarRecord` below), pruned on write.
# `order` records write-recency (oldest first) so pruning and "most recent
# prior record" (`mostRecentRecord`) are O(1) — the JSON `records` object is
# unordered (JSON object key order is not a place to hang a soundness-load-
# bearing invariant on), so recency is carried explicitly in `order`.
#
# Values are NEVER stored: `envDigest` entries are `(name, hash16(value))`
# pairs — see `keys.envDigest`, whose own doc comment is the one authority
# on this guarantee; this module never receives a raw value to begin with.
# ---------------------------------------------------------------------------

type
  SidecarEntry* = object
    key*:       SoundnessKey
      ## The soundness key this record was stored under — carried
      ## redundantly (the dispatch seam already has it as `KeyDerivation.key`
      ## when writing) so a reader can check entry-liveness (`<key>.json`
      ## exists?) WITHOUT decoding `inputs` and recomputing `soundnessKey`.
      ## `resultcache.gcResultCacheAt`'s sidecar-prune pass is the reader
      ## that matters: it sits BELOW `cachewire`/`cacheport` in the import
      ## graph (this module already imports `resultcache` — the reverse
      ## edge would cycle) and reads this one scalar field with a minimal,
      ## cachewire-independent JSON walk rather than importing this codec.
    inputs*:    KeyInputs
    envDigest*: seq[(string, string)]
      ## `(name, hash16(value))` pairs — see `keys.envDigest`. NEVER a raw
      ## value.

  Sidecar* = object
    order*:   seq[string]              ## flagHash write order, oldest first
    records*: Table[string, SidecarEntry]  ## flagHash -> most-recent record

const DefaultMaxSidecarRecords* = 8
  ## Bound on distinct flagHash records retained per sidecar (RFC-0005
  ## "Miss-explanation": "most-recent-per-flagHash, pruned on write").

proc envDigestToJson(d: seq[(string, string)]): JsonNode =
  result = newJArray()
  for (name, digest) in d:
    let o = newJObject()
    o["name"]   = newJString(name)
    o["digest"] = newJString(digest)
    result.add o

proc envDigestFromJson(node: JsonNode): Option[seq[(string, string)]] =
  if node == nil or node.kind != JArray: return
  var res: seq[(string, string)] = @[]
  for item in node:
    if item.kind != JObject: return
    let n = item{"name"}
    let d = item{"digest"}
    if n == nil or n.kind != JString: return
    if d == nil or d.kind != JString: return
    res.add (n.getStr, d.getStr)
  some(res)

proc sidecarEntryToJson(e: SidecarEntry): JsonNode =
  result = newJObject()
  result["key"]       = newJString($e.key)
  result["inputs"]    = keyInputsToJson(e.inputs)
  result["envDigest"] = envDigestToJson(e.envDigest)

proc sidecarEntryFromJson(node: JsonNode): Option[SidecarEntry] =
  if node == nil or node.kind != JObject: return
  let keyN = node{"key"}
  if keyN == nil or keyN.kind != JString: return
  let inputs = keyInputsFromJson(node{"inputs"})
  if inputs.isNone: return
  let env = envDigestFromJson(node{"envDigest"})
  if env.isNone: return
  some(SidecarEntry(key: SoundnessKey(keyN.getStr), inputs: inputs.get, envDigest: env.get))

proc sidecarToJson*(s: Sidecar): JsonNode =
  result = newJObject()
  let orderArr = newJArray()
  for f in s.order: orderArr.add newJString(f)
  result["order"] = orderArr
  let recsObj = newJObject()
  for f in s.order:
    if f in s.records:
      recsObj[f] = sidecarEntryToJson(s.records[f])
  result["records"] = recsObj

proc sidecarFromJson*(node: JsonNode): Option[Sidecar] =
  if node == nil or node.kind != JObject: return
  let orderN = node{"order"}
  let recsN  = node{"records"}
  if orderN == nil or orderN.kind != JArray: return
  if recsN == nil or recsN.kind != JObject: return
  var order: seq[string] = @[]
  for o in orderN:
    if o.kind != JString: return
    order.add o.getStr
  var records = initTable[string, SidecarEntry]()
  for f in order:
    let e = sidecarEntryFromJson(recsN{f})
    if e.isNone: return
    records[f] = e.get
  some(Sidecar(order: order, records: records))

proc upsertSidecarRecord*(s: Sidecar; flagHash: string; entry: SidecarEntry;
                          maxRecords = DefaultMaxSidecarRecords): Sidecar =
  ## Insert/replace `flagHash`'s record as the MOST RECENT, then prune to
  ## `maxRecords` distinct flagHashes (oldest-touched dropped first).  PURE.
  ## `maxRecords <= 0` means no bound.
  var order = s.order
  var records = s.records
  var idx = -1
  for i, f in order:
    if f == flagHash: idx = i; break
  if idx >= 0: order.delete(idx)
  order.add flagHash
  records[flagHash] = entry
  if maxRecords > 0:
    while order.len > maxRecords:
      let victim = order[0]
      order.delete(0)
      records.del(victim)
  Sidecar(order: order, records: records)

proc mostRecentRecord*(s: Sidecar): Option[tuple[flagHash: string, entry: SidecarEntry]] =
  ## The globally most-recently-touched record, regardless of its flagHash
  ## — RFC-0005's "picks the most-recent prior record" (deliberately NOT
  ## keyed by the CURRENT flagHash: a flag change is the common case this
  ## mechanism exists to explain, so diffing against a record whose
  ## flagHash differs is exactly the point — it surfaces as `kcFlags`).
  ## PURE.  `none` iff the sidecar is empty (no prior record at all).
  if s.order.len == 0: return
  let f = s.order[^1]
  if f notin s.records: return
  some((flagHash: f, entry: s.records[f]))

# ---------------------------------------------------------------------------
# Attestation <-> JSON (private — SigAlg's wire mapping stays local to the
# one module that (de)serializes an Attestation; Stage C's `cachetrust.nim`
# constructs `Attestation` values but never needs to (de)serialize them).
# ---------------------------------------------------------------------------

proc sigAlgStr(a: SigAlg): string =
  case a
  of saNone:       "none"
  of saHmacSha256: "hmac-sha256"
  of saEd25519:    "ed25519"

proc parseSigAlg(s: string): Option[SigAlg] =
  case s
  of "none":         some(saNone)
  of "hmac-sha256":  some(saHmacSha256)
  of "ed25519":       some(saEd25519)
  else:                none(SigAlg)

proc attestationToJson(a: Attestation): JsonNode =
  result = newJObject()
  result["sigAlg"]    = newJString(sigAlgStr(a.sigAlg))
  result["signer"]    = newJString(a.signer)
  result["signature"] = newJString(a.signature)
  result["signedAt"]  = newJInt(a.signedAt)

proc attestationFromJson(node: JsonNode): Option[Attestation] =
  if node == nil or node.kind != JObject: return
  let algN    = node{"sigAlg"}
  let signerN = node{"signer"}
  let sigN    = node{"signature"}
  let atN     = node{"signedAt"}
  if algN == nil or algN.kind != JString: return
  let alg = parseSigAlg(algN.getStr)
  if alg.isNone: return
  if signerN == nil or signerN.kind != JString: return
  if sigN == nil or sigN.kind != JString: return
  if atN == nil or atN.kind != JInt: return
  some(Attestation(
    sigAlg:    alg.get,
    signer:    signerN.getStr,
    signature: sigN.getStr,
    signedAt:  atN.getBiggestInt,
  ))

# ---------------------------------------------------------------------------
# verifyEntryIntegrity — shared by `decode` and `cachememory.memory`.
# ---------------------------------------------------------------------------

proc verifyEntryIntegrity*(e: StoredEntry): CacheVerdict =
  ## Recompute the payload checksum and check the envelope's
  ## `storageVersion` — the two integrity axes meaningful on a LIVE
  ## `StoredEntry` (no wire/`header` concept exists once an object is in
  ## hand; that axis is `decode`-only, checked before a `StoredEntry` is
  ## even constructed — see below).
  let recomputed = toHex16(fnv1a64(canonicalPayload(e.result)))
  if recomputed != e.result.payloadChecksum: return cvCorrupt
  if e.storageVersion != storageFormatVersion: return cvVersionSkew
  cvOk

# ---------------------------------------------------------------------------
# CacheSerializer — StoredEntry <-> bytes.
# ---------------------------------------------------------------------------

type
  CacheSerializer* = object
    encode*: proc(e: StoredEntry): string {.closure.}
    decode*: proc(s: string): Fetched[StoredEntry] {.closure.}

proc jsonEncode(e: StoredEntry): string =
  let payloadNode = payloadToJson(e.result)
  let checksum    = toHex16(fnv1a64(canonicalPayload(e.result)))

  let headerNode = newJObject()
  headerNode["formatVersion"] = newJInt(resultCacheFormatVersion)

  let fileNode = newJObject()
  fileNode["header"]          = headerNode
  fileNode["payloadChecksum"] = newJString(checksum)
  fileNode["payload"]         = payloadNode

  if e.keyInputs.isSome:
    fileNode["keyInputs"] = keyInputsToJson(e.keyInputs.get)
  if e.attestation.isSome:
    fileNode["attestation"] = attestationToJson(e.attestation.get)

  let storageNode = newJObject()
  storageNode["version"] = newJInt(e.storageVersion)
  fileNode["storage"]    = storageNode

  $fileNode

proc jsonDecode(s: string): Fetched[StoredEntry] =
  var node: JsonNode
  try:
    node = parseJson(s)
  except CatchableError:
    return Fetched[StoredEntry](verdict: cvCorrupt)
  if node.kind != JObject:
    return Fetched[StoredEntry](verdict: cvCorrupt)

  # Header / embedded payload-format-version check — BEFORE attempting a
  # payload parse, exactly as `loadCached` orders it: an old-format payload
  # is not safe to hand to the current `payloadFromJson`.
  let header = node{"header"}
  if header == nil or header.kind != JObject:
    return Fetched[StoredEntry](verdict: cvCorrupt)
  if header{"formatVersion"}.getInt(-1) != resultCacheFormatVersion:
    return Fetched[StoredEntry](verdict: cvVersionSkew)

  let payloadNode = node{"payload"}
  if payloadNode == nil:
    return Fetched[StoredEntry](verdict: cvCorrupt)
  let storedChecksum = node{"payloadChecksum"}.getStr("")
  if storedChecksum.len == 0:
    return Fetched[StoredEntry](verdict: cvCorrupt)

  let parsed = payloadFromJson(payloadNode)
  if parsed.isNone:
    return Fetched[StoredEntry](verdict: cvCorrupt)

  let recomputed = toHex16(fnv1a64(canonicalPayload(parsed.get)))
  if recomputed != storedChecksum:
    return Fetched[StoredEntry](verdict: cvCorrupt)

  # Envelope version — absent `storage` ⇒ a pre-0005 file, compatible by
  # definition (the envelope wraps only optional additive keys, which are
  # simply absent); present-and-mismatched ⇒ cvVersionSkew, independent of
  # the header check above (two axes — see the module doc comment).
  var storageVersion = storageFormatVersion
  let storageNode = node{"storage"}
  if storageNode != nil and storageNode.kind == JObject:
    let vN = storageNode{"version"}
    if vN == nil or vN.kind != JInt:
      return Fetched[StoredEntry](verdict: cvCorrupt)
    storageVersion = vN.getInt
    if storageVersion != storageFormatVersion:
      return Fetched[StoredEntry](verdict: cvVersionSkew)

  var keyInputs = none(KeyInputs)
  let kiNode = node{"keyInputs"}
  if kiNode != nil:
    let ki = keyInputsFromJson(kiNode)
    if ki.isNone:
      return Fetched[StoredEntry](verdict: cvCorrupt)
    keyInputs = ki

  var attestation = none(Attestation)
  let attNode = node{"attestation"}
  if attNode != nil:
    let att = attestationFromJson(attNode)
    if att.isNone:
      return Fetched[StoredEntry](verdict: cvCorrupt)
    attestation = att

  var res = parsed.get
  res.payloadChecksum = storedChecksum

  let entry = StoredEntry(
    key:            SoundnessKey(""),  # contextual — the backend fills it in
    keyInputs:      keyInputs,
    result:         res,
    storageVersion: storageVersion,
    attestation:    attestation,
  )
  Fetched[StoredEntry](verdict: cvOk, value: entry)

proc jsonCacheSerializer*(): CacheSerializer =
  ## The ONE on-disk/on-wire `StoredEntry` encoding — JSON-only ships in
  ## 0005 (the port exists so msgpack is a later adapter; see RFC-0005
  ## Non-Goals).
  CacheSerializer(encode: jsonEncode, decode: jsonDecode)
