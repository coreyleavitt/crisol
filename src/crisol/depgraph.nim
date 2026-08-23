## depgraph.nim — D2: persisted source-dependency graph.
##
## Stores and loads the per-(entrypoint, flag-set) source-dependency closures
## that power impact analysis (D3+D4) and compile avoidance (D6).
##
## ## On-disk format
##
## JSON written atomically to `<projectRoot>/<stateDir>/depgraph`.
##
## ```json
## {
##   "header": {
##     "nimVersion":     "<string>",   -- e.g. "2.2.10"
##     "formatVersion":  <int>         -- DepGraphFormatVersion
##   },
##   "entries": [
##     {
##       "path":          "<string>",       -- entrypoint path (project-root-relative)
##       "flagHash":      "<16 hex chars>", -- 64-bit FNV-1a over sorted flags
##       "closure":       ["<string>", ...] -- project-root-relative source paths
##       "closureHash":   "<16 hex chars>", -- 64-bit chained FNV-1a over sorted closure file CONTENTS
##       "protocolMajor": <int>             -- crisol protocol major at build time
##     },
##     ...
##   ]
## }
## ```
##
## ## Key shape
##
## `(path: string, flagHash: string)` — a `Table[(string, string), DepGraphEntry]`.
## `flagHash` is 64-bit FNV-1a over the sorted, NUL-joined flag list, rendered as
## 16 lower-case hex chars.  `std/hashes` is NOT used (not stable across Nim versions).
##
## ## Invalidation rules
##
## - **Nim-version mismatch** (header): whole graph → empty (treat as absent).
##   This is a FRESHNESS judgment, not a fact about the stored file — see
##   "Two loaders" below for who applies it.
## - **Missing file** in closure: `isEntryStale` returns true.
## - **Absent entry**: `isEntryStale` returns true.
## - **Deleted-entrypoint GC**: `gcDeletedEntrypoints` drops keys absent from the
##   provided current-entrypoint set.
##
## ## Two loaders — stored vs. freshness view (issue #12)
##
## `loadStoredDepGraph*(config; discarded)` loads the graph AS PERSISTED: the
## header's `nimVersion` is preserved verbatim, with no comparison against
## "the current Nim version" at all. It still discards on a formatVersion
## mismatch or a malformed/unreadable file (those are facts about the
## stored bytes, not about freshness), and it still applies the M10
## on-disk-tamper guard to closure paths. A missing file loads as an empty
## graph with header nimVersion `""`.
##
## `loadDepGraph*(config; nimVersion; discarded)` is `loadStoredDepGraph`
## PLUS a freshness view: if the stored header's `nimVersion` disagrees with
## the caller's `nimVersion` (and that disagreement is observable — an inert
## `""`-header graph with zero entries, e.g. "no file yet", never counts),
## the graph is treated as absent (`dgdNimVersion`) and an empty graph
## stamped with the REQUESTED `nimVersion` is returned instead.
##
## Callers that make staleness/compile-avoidance decisions (`run`,
## `closure`, `list`, ...) MUST use `loadDepGraph` — a graph recorded by a
## different compiler cannot be trusted for those decisions.
##
## `crisol clean` MUST use `loadStoredDepGraph` instead: it only GCs the
## on-disk entry set against the discovered entrypoints and re-saves. Using
## the freshness view there was issue #12's bug — a graph written by the
## real pipeline is always stamped with the real probed Nim fingerprint
## (never `""`), so calling the freshness loader with the wrong/absent
## expected version (crisol clean historically passed `""`) discarded the
## WHOLE graph as empty before GC ever ran — so a clean GC'd nothing and
## reported 0 dropped on every real graph. `loadStoredDepGraph` sidesteps
## the whole problem: it never compares versions, so a clean cannot discard
## a real graph, and its save path (see `clean.nim`) never rewrites the
## header.
##
## ## Atomic writes
##
## `saveDepGraph` writes to `<depgraph>.tmp` in the same directory, then calls
## `moveFile` (rename(2)) for an atomic replacement.  Readers always see either
## the old or the new file, never a torn write.

import std/[algorithm, json, os, sequtils, sets, strutils, tables]
import std/posix as posix_mod
import crisol/types
import crisol/config   # for stateDirOf
import crisol/closure  # for extractClosure/extractCompileInputs/SourceIndex/
                        # ExternalSource (recordClosure); no cycle — closure.nim
                        # imports crisol/types, crisol/config, and crisol/ccprobe
                        # (a leaf) — never crisol/depgraph (see closure.nim's
                        # import comment for why: this module importing
                        # crisol/artifactid would have closed that cycle,
                        # issue #16).
import crisol/ccprobe   # for RunProc/realRun (recordClosure's ccRun param)
import crisol/ioutils  # for sanitizeControlBytes — the shared control/ANSI-byte
                        # sanitization primitive (bottom of the dep graph; no cycle)
import crisol/fnv       # FNV-1a primitives (fnv1a64/toHex16/fnvOffset64/
                        # fnvPrime64) and chainedContentHash — a leaf module,
                        # re-exported below so every existing
                        # `import crisol/depgraph` call site that uses these
                        # unqualified keeps compiling unchanged.
export fnv

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const DepGraphFormatVersion* = 5
  ## Increment this when the JSON schema changes in an incompatible way.
  ## A loaded file with a different formatVersion is treated as absent.
  ##
  ## History:
  ##   5 — issue #16: a `{.compile.}`d external's `#include`d headers are
  ##       tracked compile inputs. `DepGraphEntry` gains `externals` (one
  ##       `closure.ExternalSource` per single-path external: its source
  ##       path, object basename, and header set), and every header now also
  ##       joins `closure`/`closureHash` itself (`closure.extractCompileInputs`
  ##       replaces `extractClosure` as `recordClosure`'s extraction call).
  ##       Every v4 entry's `closure` is missing whatever headers its
  ##       externals (if any) `#include` — under-selecting exactly like a v3
  ##       entry was missing `{.compile.}`d sources themselves (issue #11) —
  ##       so the graph is discarded once (a one-time full recompile) rather
  ##       than served or migrated in place.
  ##   4 — issue #11: closures also cover non-module compile inputs —
  ##       `include`d files, `staticRead`/`slurp` targets, `nim.cfg`/
  ##       `config.nims` (from the manifest's `depfiles`, written under the
  ##       `-d:nimBetterRun` define crisol now injects), `{.compile.}`d
  ##       C/C++/ObjC sources and `{.link.}`ed prebuilt objects (from the
  ##       `link` array). Every v3 closure is incomplete in a way that
  ##       cannot be healed in place: a closure missing an input
  ##       hash-matches itself forever, so the entrypoint would stay fresh
  ##       across edits to that input, and its stable nimcache manifest
  ##       (compiled without the define) carries no `depfiles` to re-derive
  ##       from. The bump discards the graph once — a one-time full
  ##       recompile under the new define — rather than serve it.
  ##   3 — issue #5: closures are derived from the nimcache `link` array.
  ##       Every v2 entry is suspect (any entry rewritten after a warm
  ##       recompile is truncated or empty — see DepGraphEntry.closure,
  ##       invariant NONEMPTY-CLOSURE — so upgrading alone cannot heal it);
  ##       the bump discards the whole graph once — a one-time full
  ##       recompile — rather than serve it.
  ## v2: added closureHash and protocolMajor fields.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DepGraphHeader* = object
    nimVersion*:    string  ## Nim version string (e.g. "2.2.10")
    formatVersion*: int     ## DepGraphFormatVersion

  DepGraphEntry* = object
    closure*:       HashSet[string]
      ## project-root-relative closure paths.
      ##
      ## Invariant NONEMPTY-CLOSURE: a compiled entrypoint's closure always
      ## contains at least the entrypoint itself, so an empty closure is
      ## never a plausible scan result — it is a crisol defect (manifest
      ## misread, demangle regression, entrypoint outside every tracked
      ## root).  Recording one would make the entry permanently fresh (the
      ## content hash over nothing matches forever), so decideCompile, the
      ## result-cache key, and `--changed` selection could never observe a
      ## change.  `updateEntry` refuses to write an empty closure;
      ## `loadDepGraph` drops any that reach disk anyway (defense in depth).
      ## Every other site that touches this rule is a pointer back here.
    closureHash*:   string           ## 64-bit chained FNV-1a over sorted closure file CONTENTS (16 hex)
    protocolMajor*: int              ## crisol protocol major at build time
    externals*:     seq[ExternalSource]
      ## One entry per single-path `{.compile.}`d external this entrypoint
      ## names (issue #16) — its source path, object basename, and the
      ## header set it `#include`s. Every header here is ALSO a member of
      ## `closure` (closure/`--changed` selection see headers directly);
      ## this field exists so a WARM recompile — where Nim serves the
      ## external's object from its own cache and the manifest carries no
      ## `cc` command to re-probe — can carry the header set FORWARD instead
      ## of losing it (`closure.extractCompileInputs`'s `carried` parameter,
      ## fed from this field on the entry's previous `recordClosure`).

  DepGraphDiscardKind* = enum
    ## Why `loadDepGraph` discarded a persisted graph.
    dgdNone           ## no file, or loaded cleanly
    dgdNimVersion     ## header.nimVersion != current compiler fingerprint
    dgdFormatVersion  ## header.formatVersion != DepGraphFormatVersion
    dgdMalformed      ## file present but unreadable, unparseable, or an unexpected shape

  DepGraphDiscard* = object
    ## Load-time provenance of a discard decision: WHY a persisted graph was
    ## discarded (kind == dgdNone when nothing was discarded), and the two
    ## header values that disagreed (dgdNimVersion/dgdFormatVersion) or a
    ## short reason (dgdMalformed, in `stored`; `current` unused). Deliberately
    ## NOT a field on `DepGraph` — `DepGraph` is otherwise the exact
    ## persistence mirror of the on-disk JSON, so stapling a load-time-only
    ## fact onto it would leave that fact's validity window (one
    ## `loadDepGraph` call) as a docstring promise instead of something the
    ## type system enforces. Produced by the out-param overload of
    ## `loadDepGraph`; the caller (pipeline.nim's `buildRunPlan`) surfaces a
    ## non-dgdNone discard as a `ConfigWarning` via `key`/`message` below, so
    ## a discarded graph is a visible, structured diagnostic instead of a
    ## silent empty-graph fallback (issue: after a Nim upgrade, or when the
    ## file is corrupt, every entrypoint would otherwise show
    ## `recorded:false` indistinguishable from "never ran").
    kind*:    DepGraphDiscardKind
    stored*:  string  ## the mismatched header field, or the dgdMalformed reason ("" for dgdNone)
    current*: string  ## this run's value for that field, stringified ("" for dgdNone/dgdMalformed)

  DepGraph* = object
    header*:  DepGraphHeader
    entries*: Table[(string, string), DepGraphEntry]
      ## Key: (entrypoint path, flagHash)
      ## Value: DepGraphEntry with closure, content hash, and protocol major

# ---------------------------------------------------------------------------
# Public: DepGraphDiscard formatting (single authority — do not re-derive
# `key`/`message` elsewhere, e.g. with a `case` in pipeline.nim)
# ---------------------------------------------------------------------------

proc sanitizeOneSegment(s: string): string =
  ## Sanitize a single already-extracted segment: replace control/ANSI bytes
  ## via `ioutils.sanitizeControlBytes` (control/ANSI escape bytes cannot
  ## spoof or corrupt the terminal, or a log that captures it), then cap the
  ## length so a pathological value cannot blow up the message. The cap
  ## applies to THIS segment alone — callers that split a value into
  ## multiple segments (see `sanitizeHeaderField`) must cap each segment
  ## independently, or a long leading segment would consume the whole
  ## budget and hide the rest.
  const maxLen = 64
  let truncated = s.len > maxLen
  let clipped = if truncated: s[0 ..< maxLen] else: s
  result = sanitizeControlBytes(clipped)
  if truncated:
    result.add "..."

proc sanitizeHeaderField(s: string; pipeAware: bool = false): string =
  ## `stored`/`current` values may come from an on-disk depgraph file, which
  ## may be foreign, hand-edited, or corrupted, or from the Nim compiler
  ## fingerprint, which is itself MULTI-LINE and pipe-delimited
  ## ("Nim Compiler Version ...\nCompiled at ...\nactive boot switches
  ## ...|<binary hash>" — see nimprobe.cachedNimFingerprint). `message`
  ## below concatenates this text verbatim into a diagnostic that is later
  ## written raw to stderr, so this proc must both keep the diagnostic
  ## short and single-line, and preserve enough of the value to tell two
  ## different fingerprints apart.
  ##
  ## `pipeAware` gates the '|'-tail rendering below — it must be true ONLY
  ## for dgdNimVersion's `stored`/`current` (the Nim fingerprint, whose
  ## shape is documented above and genuinely ends in `|<hash>`). Every
  ## other caller (dgdFormatVersion, dgdMalformed) passes the default
  ## `false`: those values are arbitrary text — a dgdMalformed reason can be
  ## a filesystem path, and a path containing a literal '|' must render
  ## intact rather than being mangled by a heuristic meant for a completely
  ## different value shape (see the "F3" test below for the fingerprint
  ## case this heuristic exists for, and test_depgraph_guard.nim's
  ## "'|' hash heuristic" test for the dgdMalformed case it must NOT apply
  ## to).
  ##
  ## When `pipeAware` and the value contains '|', it is treated as
  ## `<multi-line version text>|<binary hash>`: the part before the FINAL
  ## '|' is reduced to its first line (the human-readable version string);
  ## the part after it is reduced to its last 12 characters (enough of the
  ## hash to distinguish two builds with an identical version line — e.g.
  ## a patched vs. stock compiler at the same reported version — without
  ## reproducing the whole hash). Each part is sanitized and capped
  ## independently (see `sanitizeOneSegment`) so the version-line cap
  ## cannot itself swallow the '|' and hide the hash suffix.
  ##
  ## Otherwise (pipeAware is false, or the value has no '|'): first line
  ## only, sanitized and capped — plain first-line/truncate rendering.
  if pipeAware:
    let pipePos = s.rfind('|')
    if pipePos >= 0:
      let versionSeg = s[0 ..< pipePos]
      let hashSeg     = s[pipePos + 1 .. ^1]
      let vNlPos = versionSeg.find('\n')
      let versionFirstLine = if vNlPos >= 0: versionSeg[0 ..< vNlPos] else: versionSeg
      let hashTail = if hashSeg.len > 12: hashSeg[^12 .. ^1] else: hashSeg
      return sanitizeOneSegment(versionFirstLine) & "|" & sanitizeOneSegment(hashTail)

  let nlPos = s.find('\n')
  let firstLine = if nlPos >= 0: s[0 ..< nlPos] else: s
  sanitizeOneSegment(firstLine)

proc key*(d: DepGraphDiscard): string =
  ## ConfigWarning `key` for a discard: "nimVersion" / "formatVersion" /
  ## "malformed" / "" (dgdNone). The single formatting authority for this
  ## fact.
  case d.kind
  of dgdNone:          ""
  of dgdNimVersion:    "nimVersion"
  of dgdFormatVersion: "formatVersion"
  of dgdMalformed:     "malformed"

proc message*(d: DepGraphDiscard): string =
  ## Human-readable diagnostic for a discard, or "" for dgdNone. The single
  ## formatting authority for this fact; `stored`/`current` are sanitized
  ## before being embedded (see `sanitizeHeaderField`). Worded neutrally —
  ## this is also printed by subcommands (e.g. `list`, `closure`) that never
  ## compile anything.
  case d.kind
  of dgdNone:
    ""
  of dgdNimVersion:
    "depgraph discarded: recorded for Nim " & sanitizeHeaderField(d.stored, pipeAware = true) &
    ", current compiler is " & sanitizeHeaderField(d.current, pipeAware = true) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"
  of dgdFormatVersion:
    "depgraph discarded: format version " & sanitizeHeaderField(d.stored) &
    ", current is " & sanitizeHeaderField(d.current) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"
  of dgdMalformed:
    "depgraph discarded: unreadable or malformed (" &
    sanitizeHeaderField(d.stored) &
    ") -- the recorded graph is treated as empty"

# ---------------------------------------------------------------------------
# Public: flagHash
# ---------------------------------------------------------------------------

proc flagHash*(flags: seq[string]): string =
  ## Stable 16-hex-char hash over a flag set.
  ## Flags are sorted before hashing so order does not matter.
  ## Uses 64-bit FNV-1a, not std/hashes (which is not stable across versions).
  var sorted = flags
  sorted.sort()
  let joined = sorted.join("\x00")
  result = toHex16(fnv1a64(joined))

# ---------------------------------------------------------------------------
# Public: closureContentHash
# ---------------------------------------------------------------------------

proc closureContentHash*(files: seq[string]; projectRoot: string): string =
  ## Compute a stable 64-bit FNV-1a hash over the CONTENTS of all closure files.
  ##
  ## Algorithm: iterate over sorted(files); for each file, chain the running hash
  ## through both the relative path AND the file content using FNV-1a:
  ##   running = fnv1a64(toHex16(running) & "\x00" & relPath & "\x00" & content)
  ##
  ## Properties:
  ##   - Order-independent for the same set (files are sorted before hashing).
  ##   - Position-sensitive AND path-sensitive: swapping file contents between two
  ##     paths changes the hash (R6 fix vs the old XOR scheme which is commutative
  ##     and self-cancelling).
  ##   - Non-self-cancelling: two files with identical content are distinguished by
  ##     their paths.
  ##
  ## Parameters:
  ##   `files`       — seq of project-root-relative file paths (sorted internally)
  ##   `projectRoot` — absolute path to project root for resolving relative paths
  ##
  ## Returns 16 lower-case hex chars (or all-zeros string if files is empty).
  ##
  ## Raises OSError if any file cannot be read.
  ##
  ## Delegates to `crisol/fnv.chainedContentHash` — the depgraph-facing name
  ## for the identical fold; `crisol/closure` (which cannot import this
  ## module — see closure.nim's import comment) calls `chainedContentHash`
  ## directly for the same result.
  chainedContentHash(files, projectRoot)

# ---------------------------------------------------------------------------
# Public: constructors
# ---------------------------------------------------------------------------

proc initDepGraph*(nimVersion: string): DepGraph =
  ## Construct a new, empty DepGraph with the given Nim version in the header.
  result = DepGraph(
    header:  DepGraphHeader(nimVersion: nimVersion,
                            formatVersion: DepGraphFormatVersion),
    entries: initTable[(string, string), DepGraphEntry]()
  )

# ---------------------------------------------------------------------------
# Public: mutation
# ---------------------------------------------------------------------------

proc updateEntry*(graph: var DepGraph;
                  path:          string;
                  fHash:         string;
                  closure:       HashSet[string];
                  closureHash:   string = "";
                  protocolMajor: int = 0;
                  externals:     seq[ExternalSource] = @[]) =
  ## Insert or replace the entry for (path, fHash).
  ##
  ## Refuses an EMPTY closure — see `DepGraphEntry.closure`, invariant
  ## NONEMPTY-CLOSURE.  Raises `CrisolError(cekInternal)` and leaves any
  ## existing entry untouched; the caller decides whether to
  ## `invalidateEntry` (`recordClosure`, below, does).
  if closure.len == 0:
    raise newCrisolError(cekInternal,
      "refusing to record an empty source closure (see DepGraphEntry.closure, " &
      "invariant NONEMPTY-CLOSURE)")
  graph.entries[(path, fHash)] = DepGraphEntry(
    closure:       closure,
    closureHash:   closureHash,
    protocolMajor: protocolMajor,
    externals:     externals,
  )

proc invalidateEntry*(graph: var DepGraph; path: string; fHash: string) =
  ## Drop the entry for (path, fHash) so the next plan sees "no closure
  ## record": decideCompile → cdStale (recompile) and narrowByDiff → unknown
  ## closure (force-included).  Idempotent; absent key is a no-op.
  ##
  ## Used by `recordClosure` (below) when a compile SUCCEEDED but the
  ## closure could not be recorded: the stable binary is already in place,
  ## so without this the PREVIOUS entry (arbitrarily stale) would keep
  ## being served as fresh.
  graph.entries.del((path, fHash))

# ---------------------------------------------------------------------------
# Public: invalidation
# ---------------------------------------------------------------------------

proc isEntryStale*(graph: DepGraph;
                   key:   (string, string);
                   projectRoot: string): bool =
  ## Returns true iff the entry should be re-scanned:
  ##   - key is absent from the graph, OR
  ##   - any file in the closure does not exist on disk.
  ##
  ## Closure paths may be absolute or project-root-relative.  Relative paths
  ## are resolved against `projectRoot` before the existence check, so the
  ## result is independent of the caller's CWD.  This prevents a file that
  ## happens to exist in CWD (but not under projectRoot) from falsely
  ## suppressing staleness (R4 soundness fix).
  if key notin graph.entries:
    return true
  let entry = graph.entries[key]
  for f in entry.closure:
    let absPath =
      if f.isAbsolute: f
      else: projectRoot / f
    if not fileExists(absPath):
      return true
  return false

proc gcDeletedEntrypoints*(graph:               var DepGraph;
                           currentKeys: HashSet[(string, string)]) =
  ## Drop all entries whose key is NOT in `currentKeys`.
  ## Modifies `graph` in place.
  var toDelete: seq[(string, string)]
  for key in graph.entries.keys:
    if key notin currentKeys:
      toDelete.add key
  for key in toDelete:
    graph.entries.del(key)

# ---------------------------------------------------------------------------
# Serialization helpers
# ---------------------------------------------------------------------------

proc toJson(graph: DepGraph): JsonNode =
  ## Serialize a DepGraph to a JsonNode.
  let headerNode = newJObject()
  headerNode["nimVersion"]    = newJString(graph.header.nimVersion)
  headerNode["formatVersion"] = newJInt(graph.header.formatVersion)

  let entriesArr = newJArray()
  for (key, entry) in graph.entries.pairs:
    let (path, fHash) = key
    let closureArr = newJArray()
    # Sort for deterministic output
    var sortedClosure = toSeq(entry.closure)
    sortedClosure.sort()
    for f in sortedClosure:
      closureArr.add newJString(f)
    let externalsArr = newJArray()
    var sortedExternals = entry.externals
    sortedExternals.sort(proc(a, b: ExternalSource): int = cmp(a.source, b.source))
    for ext in sortedExternals:
      let extNode = newJObject()
      extNode["source"] = newJString(ext.source)
      extNode["obj"]    = newJString(ext.obj)
      let hdrArr = newJArray()
      var sortedHeaders = ext.headers
      sortedHeaders.sort()
      for h in sortedHeaders:
        hdrArr.add newJString(h)
      extNode["headers"]     = hdrArr
      extNode["headersHash"] = newJString(ext.headersHash)
      externalsArr.add extNode

    let entryNode = newJObject()
    entryNode["path"]          = newJString(path)
    entryNode["flagHash"]      = newJString(fHash)
    entryNode["closure"]       = closureArr
    entryNode["closureHash"]   = newJString(entry.closureHash)
    entryNode["protocolMajor"] = newJInt(entry.protocolMajor)
    entryNode["externals"]     = externalsArr
    entriesArr.add entryNode

  result = newJObject()
  result["header"]  = headerNode
  result["entries"] = entriesArr

proc fromJson(node: JsonNode; discarded: var DepGraphDiscard): DepGraph =
  ## Deserialize a DepGraph from a JsonNode, preserving the STORED header
  ## verbatim (nimVersion + formatVersion) — this proc has no notion of
  ## "the current Nim version" and performs no nimVersion comparison; that
  ## freshness judgment belongs one layer up, in the public `loadDepGraph`
  ## (see "Two loaders" in the module doc, issue #12), because a
  ## caller like `clean` needs the graph AS PERSISTED — GCing it against the
  ## discovered entrypoint set must never depend on, or silently stamp over,
  ## the fingerprint the pipeline will compare on the next `run`.
  ##
  ## Returns an empty graph, header nimVersion "", on formatVersion mismatch
  ## or on any malformed shape. discarded reports WHY a persisted graph was
  ## discarded: dgdNone when nothing was discarded; dgdFormatVersion for a
  ## formatVersion mismatch; dgdMalformed for every shape/parse problem
  ## (missing/wrong-typed header fields, non-object root, non-array
  ## entries, ...) so a present-but-unusable file is never silently
  ## indistinguishable from dgdNone's "never ran".
  result = initDepGraph("")
  discarded = DepGraphDiscard(kind: dgdNone)

  if node.kind != JObject:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root not an object")
    return

  # Validate header
  let headerNode = node{"header"}
  if headerNode == nil or headerNode.kind != JObject:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header not an object")
    return

  let storedNimVer = headerNode{"nimVersion"}
  if storedNimVer == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header missing nimVersion")
    return
  if storedNimVer.kind != JString:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "nimVersion not a string")
    return
  let storedFmtVer = headerNode{"formatVersion"}
  if storedFmtVer == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header missing formatVersion")
    return
  if storedFmtVer.kind != JInt:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "formatVersion not an integer")
    return

  let storedNimVerStr = storedNimVer.getStr("")
  let storedFmtVerInt = storedFmtVer.getInt(-1)

  if storedFmtVerInt != DepGraphFormatVersion:
    discarded = DepGraphDiscard(kind: dgdFormatVersion, stored: $storedFmtVerInt, current: $DepGraphFormatVersion)
    return

  # Preserve the header exactly as stored — no comparison against "the
  # current Nim version" here (see the proc doc above).
  result.header.nimVersion    = storedNimVerStr
  result.header.formatVersion = DepGraphFormatVersion

  # Parse entries
  let entriesArr = node{"entries"}
  if entriesArr == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root missing entries")
    return
  if entriesArr.kind != JArray:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "entries not an array")
    return

  for entryNode in entriesArr:
    if entryNode.kind != JObject: continue
    let pathNode         = entryNode{"path"}
    let flagHashNode     = entryNode{"flagHash"}
    let closureNode      = entryNode{"closure"}
    let closureHashNode  = entryNode{"closureHash"}
    let protocolMajNode  = entryNode{"protocolMajor"}
    if pathNode == nil or flagHashNode == nil or closureNode == nil: continue
    if closureNode.kind != JArray: continue

    let path    = pathNode.getStr("")
    let fHash   = flagHashNode.getStr("")
    if path == "" or fHash == "": continue

    var closure = initHashSet[string]()
    for item in closureNode:
      let s = item.getStr("")
      if s != "": closure.incl s

    let closureHash   = if closureHashNode != nil: closureHashNode.getStr("") else: ""
    let protocolMajor = if protocolMajNode != nil: protocolMajNode.getInt(0)  else: 0

    var externals: seq[ExternalSource] = @[]
    let externalsNode = entryNode{"externals"}
    if externalsNode != nil and externalsNode.kind == JArray:
      for extNode in externalsNode:
        if extNode.kind != JObject: continue
        let srcNode = extNode{"source"}
        let objNode = extNode{"obj"}
        if srcNode == nil or objNode == nil: continue
        let src    = srcNode.getStr("")
        let objVal = objNode.getStr("")
        if src == "" or objVal == "": continue
        var headers: seq[string] = @[]
        let hdrNode = extNode{"headers"}
        if hdrNode != nil and hdrNode.kind == JArray:
          for h in hdrNode:
            let hs = h.getStr("")
            if hs != "": headers.add hs
        let hHashNode = extNode{"headersHash"}
        let hHash = if hHashNode != nil: hHashNode.getStr("") else: ""
        externals.add ExternalSource(source: src, obj: objVal, headers: headers,
                                     headersHash: hHash)

    result.entries[(path, fHash)] = DepGraphEntry(
      closure:       closure,
      closureHash:   closureHash,
      protocolMajor: protocolMajor,
      externals:     externals,
    )

# ---------------------------------------------------------------------------
# Public: persistence
# ---------------------------------------------------------------------------

proc depgraphPath*(config: Config): string =
  ## Absolute path to the depgraph file.
  stateDirOf(config) / "depgraph"

proc saveDepGraph*(graph: DepGraph; config: Config): bool =
  ## Write the graph to `<projectRoot>/<stateDir>/depgraph` atomically.
  ## Creates the state directory if absent.
  ##
  ## Returns `true` iff the graph was actually persisted (the final
  ## `moveFile` completed), `false` on ANY failure. Deliberately NOT
  ## `{.discardable.}` — every caller (issue #13.3) must decide what a
  ## failed persist means for what it just did in memory: `recordClosure`
  ## turns it into a recovery-policy failure so the runner discards the
  ## stable binary rather than leave it paired with a stale on-disk entry;
  ## `clean` must not report entries as dropped from disk when the drop
  ## never made it to disk. On any write failure: still warns to stderr
  ## with the cause (unchanged from before) — the bool lets a caller react
  ## structurally, the stderr line stays for a human watching the run — and
  ## never raises.
  ##
  ## Uses O_CREAT|O_EXCL|O_WRONLY so the temp-file open fails if any file or
  ## symlink already exists at the .tmp path — prevents a pre-planted symlink
  ## from redirecting the write to an attacker-chosen target (P5). This is
  ## also the fault every persist-failure test in the suite injects:
  ## `createDir(depgraphPath(config) & ".tmp")` makes the O_EXCL open fail
  ## with EEXIST (a directory occupies the path) without needing filesystem
  ## permissions the container's root user would bypass anyway.
  ## A stale .tmp from a previous crashed run is removed first.
  let stateDir  = stateDirOf(config)
  let finalPath = depgraphPath(config)
  let tmpPath   = finalPath & ".tmp"

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return false

  let jsonStr = $toJson(graph)
  # Best-effort removal of a stale .tmp from a prior crashed run.
  try: removeFile(tmpPath) except: discard

  var tmpFd: cint = -1
  try:
    let flags = posix_mod.O_CREAT or posix_mod.O_EXCL or posix_mod.O_WRONLY or
                posix_mod.O_CLOEXEC
    tmpFd = posix_mod.open(tmpPath.cstring, flags, posix_mod.Mode(0o600))
    if tmpFd < 0:
      let err = $posix_mod.strerror(posix_mod.errno)
      stderr.write("crisol: warning: could not create temp file for depgraph: " &
                   err & "\n")
      return false
    let written = posix_mod.write(tmpFd, jsonStr.cstring, jsonStr.len)
    discard posix_mod.close(tmpFd)
    tmpFd = -1
    if written < 0 or written != jsonStr.len:
      stderr.write("crisol: warning: short write to depgraph temp file\n")
      try: removeFile(tmpPath) except: discard
      return false
    moveFile(tmpPath, finalPath)
    return true
  except OSError as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: could not write depgraph: " & e.msg & "\n")
    try: removeFile(tmpPath) except: discard
    return false
  except Exception as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: unexpected error writing depgraph: " &
                 e.msg & "\n")
    try: removeFile(tmpPath) except: discard
    return false

# ---------------------------------------------------------------------------
# Public: recovery policy (issue #5)
# ---------------------------------------------------------------------------

proc recordClosure*(graph: var DepGraph; config: Config; ep: Entrypoint;
                    nimcacheDir, binaryName: string;
                    protocolMajor: int; index: SourceIndex;
                    ccRun: RunProc = realRun):
                    tuple[ok: bool, error: string] =
  ## Extract, hash, and persist one entrypoint's source closure after a
  ## successful compile — the single place issue #5's recovery policy lives.
  ##
  ## `index` — a `SourceIndex` (`buildSourceIndex(config)`) used to resolve
  ## `@p`/`@n` closure entries (issue #8).  Built ONCE per run by the caller
  ## (`runner.execute`) and passed through for every entrypoint — never
  ## rebuilt per entrypoint (it is a pure function of the source tree, not
  ## of any single compile).
  ##
  ## `ccRun` — the `cc -M` header-probe seam (issue #16), threaded through to
  ## `closure.extractCompileInputs`; defaults to `ccprobe.realRun`. Tests
  ## inject a synthetic runner; production (`runner.execute`) uses the
  ## default.
  ##
  ## Extraction (issue #16) now goes through `closure.extractCompileInputs`,
  ## not `closure.extractClosure` directly: it additionally derives, for
  ## every `{.compile.}`d single-path external this entrypoint names, the
  ## header set it `#include`s (folded into the closure) and the entry's
  ## `externals` list. `carried` is fed the CURRENT entry's `externals` (if
  ## one already exists for this `(path, flagHash)` key) so a warm recompile
  ## — where Nim serves an external's object from its own cache and the
  ## manifest carries no `cc` command to re-probe — carries the header set
  ## FORWARD instead of losing it (see `extractCompileInputs`'s doc comment).
  ##
  ## Policy: a compile whose closure cannot be recorded must not leave the
  ## previous entry in place — the stable binary already exists, so nothing
  ## would recompile and the stale record would be served as fresh.
  ## Invalidating instead makes decideCompile see `cdStale` and
  ## narrowByDiff force-include the entrypoint (unknown closure).
  ##
  ## On success: `updateEntry` + `saveDepGraph`, returns `(ok: true, "")` —
  ## UNLESS the save itself fails (issue #13.3), in which case this returns
  ## `(ok: false, "dependency graph could not be persisted")`. The in-memory
  ## graph already holds the new entry at that point (this run's own
  ## selection logic sees it correctly), but nothing describes it on disk;
  ## the caller (the runner) must treat this exactly like an extraction
  ## failure — see below — and discard the binary it just promoted to the stable path, so the NEXT run starts
  ## from `cdNeverBuilt` rather than trusting a stable binary the on-disk
  ## depgraph does not (yet, or ever) describe. Without that binary-discard
  ## step, a later revert of the source back to whatever the STALE on-disk
  ## entry's hash matches would make decideCompile find that stale entry
  ## AND the (wrongly-provenanced) stable binary, and serve the binary that
  ## was actually built from the edited sources — silently wrong output.
  ##
  ## On ANY `CatchableError` (missing/unparseable manifest, empty `link` —
  ## see `extractClosure` — or `updateEntry`'s NONEMPTY-CLOSURE refusal):
  ## `invalidateEntry` + `saveDepGraph`, returns `(ok: false, e.msg)`. If
  ## THAT save also fails, `e.msg` gains "; dependency graph could not be
  ## persisted" — the in-memory invalidation happened, but it did not reach
  ## disk either, so the caller's binary-discard step applies here too: the
  ## previous stable binary (if any) must not be trusted for the same
  ## reason as the success-path persist failure above.
  ##
  ## The caller only needs to warn on `not ok` and discard the stable
  ## binary; no further recovery step is needed on either path.
  let fHash = flagHash(ep.flags)
  let epAbs = if ep.path.isAbsolute: ep.path else: config.projectRoot / ep.path
  try:
    let key = (ep.path, fHash)
    let carried = if key in graph.entries: graph.entries[key].externals else: @[]
    let inputs = extractCompileInputs(nimcacheDir, binaryName, epAbs, config,
                                      index, carried, ccRun)
    var closureSeq = toSeq(inputs.files)
    closureSeq.sort()
    let contentHash = closureContentHash(closureSeq, config.projectRoot)
    graph.updateEntry(ep.path, fHash, inputs.files, contentHash, protocolMajor,
                      inputs.externals)
    if saveDepGraph(graph, config):
      result = (ok: true, error: "")
    else:
      result = (ok: false, error: "dependency graph could not be persisted")
  except CatchableError as e:
    graph.invalidateEntry(ep.path, fHash)
    if saveDepGraph(graph, config):
      result = (ok: false, error: e.msg)
    else:
      result = (ok: false, error: e.msg & "; dependency graph could not be persisted")

proc loadStoredDepGraph*(config: Config; discarded: var DepGraphDiscard): DepGraph =
  ## Load the graph from `<projectRoot>/<stateDir>/depgraph` exactly AS
  ## PERSISTED — the stored header's `nimVersion` is preserved verbatim, with
  ## NO comparison against "the current Nim version" (that freshness
  ## judgment is `loadDepGraph`, below, which layers it on top of this
  ## proc).
  ##
  ## This is the loader `crisol clean` must use (issue #12): a clean GCs the
  ## graph against the discovered entrypoint set and must never depend on,
  ## or silently stamp over, the fingerprint the pipeline compares on the
  ## next `run` — using the freshness view here loaded every real graph as
  ## empty (its header never equals the `""` a clean could pass), so a clean
  ## GC'd nothing and reported 0 dropped.
  ##
  ## discarded reports WHY a persisted graph was discarded at load (dgdNone
  ## when nothing was discarded):
  ## - Missing file → empty graph (not an error); dgdNone. Header nimVersion
  ##   is "" — there is no stored value to preserve.
  ## - Unreadable file → empty graph, header ""; dgdMalformed with the IO
  ##   error text. No direct stderr write here — the caller surfaces
  ##   `discarded` as a `ConfigWarning` (sanitized by `message`), the single
  ##   report channel; see the `except` clause below for why both `IOError`
  ##   and `OSError` are caught.
  ## - Malformed JSON, or valid JSON with an unexpected shape → empty graph,
  ##   header ""; dgdMalformed with the parse-error text or a short shape
  ##   reason. The caller's `ConfigWarning` (built from discarded) is now
  ##   the sole report for this — no separate stderr write here, to avoid
  ##   double-reporting the same discard.
  ## - Format-version mismatch → empty graph, header ""; dgdFormatVersion.
  ## - Otherwise → the graph as stored, header nimVersion == the value on
  ##   disk (whatever it is — no comparison performed here).
  let path = depgraphPath(config)
  discarded = DepGraphDiscard(kind: dgdNone)

  if not fileExists(path):
    # NOTE: `fileExists` (see std/private/oscommon) returns false for
    # anything that is not a regular file or symlink — a directory, device
    # file, named pipe, or socket at `path` all land here as dgdNone
    # ("missing"), never reach `readFile` below, and therefore can NEVER
    # exercise the dgdMalformed "unreadable" branch. Only a regular file
    # (or symlink to one) that exists but cannot be READ — e.g. permission
    # denied — reaches that branch.
    #
    # TOCTOU: a swap of `path` for a FIFO between this `fileExists` check and
    # the `readFile` below would block the read indefinitely (no reader has
    # attached to unblock `open()` on the FIFO's other end). Accepted: doing
    # so requires write access to crisol's own state dir, at which point an
    # attacker already has far more direct ways to disrupt this process.
    return initDepGraph("")

  var raw: string
  try:
    raw = readFile(path)
  except IOError, OSError:
    # `readFile` raises `IOError` (std/syncio), NOT `OSError` — the two are
    # unrelated CatchableError subtypes, so `except OSError` alone never
    # fires and an unreadable-but-present file (EACCES, or a race where the
    # file is removed between `fileExists` and `readFile`) would otherwise
    # propagate as an unhandled exception all the way to the CLI. Catch
    # both explicitly rather than relying on inheritance. (Nim's `except`
    # does not support an `as` binding on a multi-type list, hence
    # `getCurrentException` here instead of `except IOError, OSError as e`.)
    let e = getCurrentException()
    discarded = DepGraphDiscard(kind: dgdMalformed,
                                stored: "unreadable: " & e.msg)
    return initDepGraph("")

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: e.msg)
    return initDepGraph("")
  except Exception as e:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: e.msg)
    return initDepGraph("")

  result = fromJson(node, discarded)

  # M10 soundness: re-validate closure paths from the on-disk graph.
  #
  # Rule (issue #13.1): one rule for every closure path, absolute or
  # relative alike. Normalize each path to a candidate absolute location —
  # `p` itself if already absolute, else `projectRoot / p` — and keep the
  # path (stored VERBATIM, exactly as read from disk) iff that candidate is
  # projectRoot or a configured depRoot, or lives under one of them
  # (`cand == root or cand.startsWith(root & DirSep)`). Everything else is
  # dropped silently. `prNorm` and each depRoot are normalized ONCE per
  # load, not once per path.
  #
  # Threat model: a tampered or corrupt depgraph file could carry an
  # absolute path like "/etc/shadow", or — the #13.1 gap this closes — a
  # RELATIVE path such as "../../etc/passwd" that `closureContentHash`
  # would resolve via `projectRoot / relPath` to the very same place.
  # Relative paths are project-root-relative BY CONTRACT (see
  # closureContentHash, above, and DepGraphEntry.closure); admitting a
  # relative path without normalizing and bounds-checking it first let a
  # `..`-laden path escape the root exactly like an unchecked absolute one
  # would, and the guard existed to prevent only the latter. A legitimate
  # relative path that simply resolves inside the root (deleted deps
  # included — that staleness is handled by `isEntryStale`, not here) is
  # unaffected: it is still admitted, just via the same normalized
  # bounds-check every path now goes through.
  #
  # Deliberately NOT applied: symlink/realpath resolution. The closure
  # extractor's tracking policy (crisol/closure.underAnyRoot, and its
  # callers' doc comments) is deliberately LEXICAL — a source file reached
  # through a symlink inside a tracked root is recorded at its LEXICAL path
  # and hashed THROUGH the link, by design (see closure.nim's discussion of
  # `realEpDir`/`epDir` around the `@m`/`@p` resolution). Resolving
  # symlinks here, at load time, would silently disagree with that: every
  # legitimately symlinked-outside source would be dropped from the loaded
  # closure, the loaded set would then miss what `closureContentHash` hashed
  # at record time, the stored `closureHash` would never match again, and
  # such a project would recompile on every single run — for no added
  # defense, since a tampered depgraph only ever changes what gets HASHED
  # (a comparison outcome), never what gets DISCLOSED to the caller; there
  # is no channel here that reveals file contents. See
  # tests/unit/test_soundness_m10.nim's symlink-retention blocks (issue
  # #13.2) for the pin proving this stays lexical.
  let prNorm = config.projectRoot.absolutePath.normalizedPath
  var rootsNorm = @[prNorm]
  for dr in config.depRoots:
    rootsNorm.add dr.absolutePath.normalizedPath

  proc underRootNorm(p: string): bool =
    ## Shared M10 predicate: normalize `p` (relative -> projectRoot-relative)
    ## and test it against `rootsNorm` — the identical rule applied to
    ## `entry.closure` paths, below, and now (issue #16) to
    ## `entry.externals[].source`/`.headers[]` paths too.
    let cand = (if p.isAbsolute: p else: prNorm / p).normalizedPath
    for root in rootsNorm:
      if cand == root or cand.startsWith(root & $DirSep):
        return true
    false

  proc isPlainBasename(s: string): bool =
    ## M10 guard for `entry.externals[].obj` (issue #16): per
    ## `closure.ExternalSource.obj`'s contract, this field is documented as
    ## a bare object BASENAME, never a resolvable path — so the guard here
    ## is "contains no path separator and is not '..'", not a root-boundary
    ## check (there is no directory to resolve it against; it names an
    ## object inside a nimcache dir crisol never persists a rooted path
    ## for).
    if s.len == 0: return false
    if '/' in s or '\\' in s: return false
    if s == "..": return false
    true

  for key in toSeq(result.entries.keys):
    var entry = result.entries[key]
    var filtered = initHashSet[string]()
    for p in entry.closure:
      if underRootNorm(p):
        filtered.incl p   # kept VERBATIM — exactly as read from disk
      # else: drop the escaping path silently (absolute or relative alike)

    # M10, extended (issue #16): `entry.externals[].source` must resolve
    # under a tracked root (same rule/gate as a closure path — an
    # ExternalSource whose `source` escapes is fully untrustworthy, so the
    # WHOLE record is dropped, not just its `source` field) and `.obj` must
    # be a plain basename; `.headers[]` are filtered per-path, mirroring
    # `entry.closure`'s own per-path filtering above (an escaping header is
    # dropped, the rest of the record is kept).
    var filteredExternals: seq[ExternalSource] = @[]
    for ext in entry.externals:
      if not underRootNorm(ext.source): continue
      if not isPlainBasename(ext.obj): continue
      var keptHeaders: seq[string] = @[]
      for h in ext.headers:
        if underRootNorm(h):
          keptHeaders.add h    # kept VERBATIM — exactly as read from disk
      var kept = ext
      kept.headers = keptHeaders
      filteredExternals.add kept

    # Defense in depth — see DepGraphEntry.closure, invariant NONEMPTY-CLOSURE:
    # the writer refuses to record an empty closure, but if one reaches disk
    # anyway, treat it as absent so decideCompile/narrow re-derive it.
    if filtered.len == 0:
      result.entries.del(key)
      continue
    entry.closure = filtered
    entry.externals = filteredExternals
    result.entries[key] = entry

proc loadDepGraph*(config: Config; nimVersion: string; discarded: var DepGraphDiscard): DepGraph =
  ## Load the graph and apply the FRESHNESS view for `nimVersion` (the
  ## caller's notion of "the current Nim version" — normally
  ## `nimprobe.cachedNimFingerprint()`): loads the graph as persisted via
  ## `loadStoredDepGraph`, then, if its header nimVersion does not match
  ## `nimVersion`, discards it as stale and returns an empty graph stamped
  ## with `nimVersion` instead of the stored value.
  ##
  ## This is the loader every consumer OTHER than `clean` must use (the
  ## compile-avoidance/impact-analysis pipeline: `run`, `closure`, `list`,
  ## ...) — a graph recorded under a different Nim compiler cannot be
  ## trusted for staleness decisions, so it must be treated as absent.
  ## `clean` uses `loadStoredDepGraph` directly instead (see its doc):
  ## GCing the on-disk entry set must not depend on, or silently overwrite,
  ## the recorded fingerprint.
  ##
  ## discarded reports WHY a persisted graph was discarded at load (dgdNone
  ## when nothing was discarded); see `loadStoredDepGraph` for the
  ## dgdMalformed/dgdFormatVersion/missing-file cases, all unchanged here.
  ## On top of those, this proc adds:
  ## - Stored nimVersion present (non-"") and different from `nimVersion` →
  ##   empty graph stamped with `nimVersion`; dgdNimVersion(stored, current).
  ## - Stored nimVersion "" with a NON-empty entries table (the
  ##   loadStoredDepGraph missing-file/malformed/format-mismatch paths
  ##   already return "" with zero entries, so this only fires for a
  ##   genuinely-stored empty-string header — legacy/test data) and
  ##   `nimVersion` also differs from "" → same treatment: dgdNimVersion.
  ## - Otherwise (stored nimVersion == nimVersion, including "" == "") →
  ##   loaded cleanly; whatever `loadStoredDepGraph` reported stands.
  var stored = loadStoredDepGraph(config, discarded)
  if discarded.kind != dgdNone:
    # Already discarded by loadStoredDepGraph (missing file / malformed /
    # format mismatch) — re-stamp the header with the REQUESTED version so
    # the caller's "empty graph" carries the version it will compare
    # against on the next write, exactly as before this refactor.
    return initDepGraph(nimVersion)

  # A mismatch is flagged only when it is OBSERVABLE: an inert empty-string
  # header with zero entries is indistinguishable from "no file" (that is
  # exactly what a missing file loads as via loadStoredDepGraph) and must
  # stay dgdNone — otherwise a plain `--config` run with no depgraph yet
  # would spuriously report a nimVersion discard on its very first run.
  let mismatch = stored.header.nimVersion != nimVersion and
                 (stored.entries.len > 0 or stored.header.nimVersion != "")
  if mismatch:
    discarded = DepGraphDiscard(kind: dgdNimVersion,
                                stored: stored.header.nimVersion,
                                current: nimVersion)
    return initDepGraph(nimVersion)

  stored.header.nimVersion = nimVersion
  result = stored

proc loadDepGraph*(config: Config; nimVersion: string): DepGraph =
  ## Load the graph, discarding load provenance. See the 3-arg overload
  ## (with the `discard: var DepGraphDiscard` out-parameter) for the full
  ## behavior and for observing WHY a persisted graph was discarded.
  var d: DepGraphDiscard
  result = loadDepGraph(config, nimVersion, d)