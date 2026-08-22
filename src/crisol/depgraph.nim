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
## - **Missing file** in closure: `isEntryStale` returns true.
## - **Absent entry**: `isEntryStale` returns true.
## - **Deleted-entrypoint GC**: `gcDeletedEntrypoints` drops keys absent from the
##   provided current-entrypoint set.
##
## ## Atomic writes
##
## `saveDepGraph` writes to `<depgraph>.tmp` in the same directory, then calls
## `moveFile` (rename(2)) for an atomic replacement.  Readers always see either
## the old or the new file, never a torn write.

import std/[algorithm, json, os, sequtils, sets, strutils, tables]
import std/posix as posix_mod
import crisol/types
import crisol/config  # for stateDirOf

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const DepGraphFormatVersion* = 3
  ## Increment this when the JSON schema changes in an incompatible way.
  ## A loaded file with a different formatVersion is treated as absent.
  ##
  ## History:
  ##   3 — issue #5: closures are derived from the nimcache `link` array.
  ##       Every v2 entry is suspect (any entry rewritten after a warm
  ##       recompile is truncated or empty and hash-matches itself forever,
  ##       so upgrading alone cannot heal it); the bump discards the whole
  ##       graph once — a one-time full recompile — rather than serve it.
  ## v2: added closureHash and protocolMajor fields.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DepGraphHeader* = object
    nimVersion*:    string  ## Nim version string (e.g. "2.2.10")
    formatVersion*: int     ## DepGraphFormatVersion

  DepGraphEntry* = object
    closure*:       HashSet[string]  ## project-root-relative closure paths
    closureHash*:   string           ## 64-bit chained FNV-1a over sorted closure file CONTENTS (16 hex)
    protocolMajor*: int              ## crisol protocol major at build time

  DepGraph* = object
    header*:  DepGraphHeader
    entries*: Table[(string, string), DepGraphEntry]
      ## Key: (entrypoint path, flagHash)
      ## Value: DepGraphEntry with closure, content hash, and protocol major

# ---------------------------------------------------------------------------
# FNV-1a 64-bit hash (stable across Nim versions; never std/hashes)
# ---------------------------------------------------------------------------

const fnvOffset64* = 0xcbf29ce484222325'u64
  ## FNV-1a 64-bit offset basis.  Exported so ``keys.nim`` can seed its chain
  ## from the same basis without re-declaring the constant.
const fnvPrime64  = 0x00000100000001b3'u64

proc fnv1a64*(data: string): uint64 =
  ## 64-bit FNV-1a hash over `data`.
  result = fnvOffset64
  for c in data:
    result = result xor uint64(ord(c))
    result = result * fnvPrime64

proc toHex16*(v: uint64): string =
  ## Render a uint64 as 16 lower-case hex chars.
  const hexChars = "0123456789abcdef"
  result = newString(16)
  var x = v
  for i in countdown(15, 0):
    result[i] = hexChars[x and 0xf]
    x = x shr 4

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
  var sorted = files
  sorted.sort()
  var running: uint64 = fnvOffset64  # start from FNV offset (not 0) for non-trivial empty case
  for relPath in sorted:
    let absPath =
      if relPath.isAbsolute: relPath
      else: projectRoot / relPath
    let content = readFile(absPath)
    # Chain: mix running hash value, path, and content together.
    # This makes the result sensitive to both WHICH file changed AND WHAT its content is.
    running = fnv1a64(toHex16(running) & "\x00" & relPath & "\x00" & content)
  result = toHex16(running)

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
                  protocolMajor: int = 0) =
  ## Insert or replace the entry for (path, fHash).
  ##
  ## Refuses an EMPTY closure (issue #5): a compiled entrypoint's closure
  ## always contains at least the entrypoint itself, so an empty set is a
  ## crisol defect (manifest misread, demangle regression, entrypoint outside
  ## every tracked root), never a real scan result.  Recording it would make
  ## the entry permanently fresh — the content hash over nothing matches
  ## forever — so decideCompile, the result-cache key and --changed selection
  ## could never observe a change.  Raises `CrisolError(cekInternal)` and
  ## leaves any existing entry untouched; the caller decides whether to
  ## `invalidateEntry` (the runner does).
  if closure.len == 0:
    raise newCrisolError(cekInternal,
      "refusing to record an empty source closure (it could never go stale)")
  graph.entries[(path, fHash)] = DepGraphEntry(
    closure:       closure,
    closureHash:   closureHash,
    protocolMajor: protocolMajor,
  )

proc invalidateEntry*(graph: var DepGraph; path: string; fHash: string) =
  ## Drop the entry for (path, fHash) so the next plan sees "no closure
  ## record": decideCompile → cdStale (recompile) and narrowByDiff → unknown
  ## closure (force-included).  Idempotent; absent key is a no-op.
  ##
  ## Used by the runner when a compile SUCCEEDED but the closure could not be
  ## recorded: the stable binary is already in place, so without this the
  ## PREVIOUS entry (arbitrarily stale) would keep being served as fresh.
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
    let entryNode = newJObject()
    entryNode["path"]          = newJString(path)
    entryNode["flagHash"]      = newJString(fHash)
    entryNode["closure"]       = closureArr
    entryNode["closureHash"]   = newJString(entry.closureHash)
    entryNode["protocolMajor"] = newJInt(entry.protocolMajor)
    entriesArr.add entryNode

  result = newJObject()
  result["header"]  = headerNode
  result["entries"] = entriesArr

proc fromJson(node: JsonNode; nimVersion: string): DepGraph =
  ## Deserialize a DepGraph from a JsonNode.
  ## Returns empty graph if the format is wrong, the nimVersion mismatches,
  ## or formatVersion differs.
  result = initDepGraph(nimVersion)

  if node.kind != JObject: return

  # Validate header
  let headerNode = node{"header"}
  if headerNode == nil or headerNode.kind != JObject: return

  let storedNimVer    = headerNode{"nimVersion"}
  let storedFmtVer    = headerNode{"formatVersion"}
  if storedNimVer == nil or storedFmtVer == nil: return
  if storedNimVer.getStr("") != nimVersion: return
  if storedFmtVer.getInt(-1) != DepGraphFormatVersion: return

  # Update header (matches current nim version)
  result.header.nimVersion    = nimVersion
  result.header.formatVersion = DepGraphFormatVersion

  # Parse entries
  let entriesArr = node{"entries"}
  if entriesArr == nil or entriesArr.kind != JArray: return

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

    result.entries[(path, fHash)] = DepGraphEntry(
      closure:       closure,
      closureHash:   closureHash,
      protocolMajor: protocolMajor,
    )

# ---------------------------------------------------------------------------
# Public: persistence
# ---------------------------------------------------------------------------

proc depgraphPath(config: Config): string =
  ## Absolute path to the depgraph file.
  stateDirOf(config) / "depgraph"

proc saveDepGraph*(graph: DepGraph; config: Config) =
  ## Write the graph to `<projectRoot>/<stateDir>/depgraph` atomically.
  ## Creates the state directory if absent.
  ## On any write failure: warns to stderr and returns — never raises.
  ##
  ## Uses O_CREAT|O_EXCL|O_WRONLY so the temp-file open fails if any file or
  ## symlink already exists at the .tmp path — prevents a pre-planted symlink
  ## from redirecting the write to an attacker-chosen target (P5).
  ## A stale .tmp from a previous crashed run is removed first.
  let stateDir  = stateDirOf(config)
  let finalPath = depgraphPath(config)
  let tmpPath   = finalPath & ".tmp"

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return

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
      return
    let written = posix_mod.write(tmpFd, jsonStr.cstring, jsonStr.len)
    discard posix_mod.close(tmpFd)
    tmpFd = -1
    if written < 0 or written != jsonStr.len:
      stderr.write("crisol: warning: short write to depgraph temp file\n")
      try: removeFile(tmpPath) except: discard
      return
    moveFile(tmpPath, finalPath)
  except OSError as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: could not write depgraph: " & e.msg & "\n")
    try: removeFile(tmpPath) except: discard
  except Exception as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: unexpected error writing depgraph: " &
                 e.msg & "\n")
    try: removeFile(tmpPath) except: discard

proc loadDepGraph*(config: Config; nimVersion: string): DepGraph =
  ## Load the graph from `<projectRoot>/<stateDir>/depgraph`.
  ##
  ## - Missing file → empty graph (not an error).
  ## - Malformed JSON → empty graph (safer fallback; log to stderr).
  ## - Nim-version mismatch → empty graph.
  ## - Format-version mismatch → empty graph.
  let path = depgraphPath(config)

  if not fileExists(path):
    return initDepGraph(nimVersion)

  var raw: string
  try:
    raw = readFile(path)
  except OSError as e:
    stderr.write("crisol: warning: could not read depgraph '" & path &
                 "': " & e.msg & " — starting with empty graph\n")
    return initDepGraph(nimVersion)

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    stderr.write("crisol: warning: depgraph is malformed JSON: " & e.msg &
                 " — starting with empty graph\n")
    return initDepGraph(nimVersion)
  except Exception as e:
    stderr.write("crisol: warning: could not parse depgraph: " & e.msg &
                 " — starting with empty graph\n")
    return initDepGraph(nimVersion)

  result = fromJson(node, nimVersion)

  # M10 soundness: re-validate closure paths from the on-disk graph.
  # Drop any absolute path that does NOT resolve under the projectRoot.
  # A tampered or corrupt depgraph could carry paths like "/etc/shadow",
  # which would then be read by closureContentHash.  Relative paths are
  # project-root-relative and are legitimate (they may not exist yet if a
  # dep was deleted — that is handled by isEntryStale).
  let prNorm = config.projectRoot.absolutePath.normalizedPath
  for key in toSeq(result.entries.keys):
    var entry = result.entries[key]
    var filtered = initHashSet[string]()
    for p in entry.closure:
      if p.isAbsolute:
        # Keep only if it is under projectRoot (or a depRoot if configured).
        var underRoot = p.startsWith(prNorm & $DirSep) or p == prNorm
        if not underRoot:
          for dr in config.depRoots:
            let drNorm = dr.absolutePath.normalizedPath
            if p.startsWith(drNorm & $DirSep) or p == drNorm:
              underRoot = true
              break
        if underRoot:
          filtered.incl p
        # else: drop the suspicious absolute path silently
      else:
        filtered.incl p   # relative path: kept as-is (project-root-relative)
    # issue #5 defense-in-depth: an entry with NO closure can never go stale
    # (the writer refuses to record one — see updateEntry); if one reaches
    # disk anyway, treat it as absent so decideCompile/narrow re-derive it.
    if filtered.len == 0:
      result.entries.del(key)
      continue
    entry.closure = filtered
    result.entries[key] = entry