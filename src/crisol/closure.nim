## closure.nim — source-dependency closure extractor for one entrypoint (D1).
##
## Reads the per-build nimcache JSON produced by `nim c` and extracts the
## transitive set of `.nim` source files the entrypoint depends on, filtered
## to files that live under a *tracked root* (projectRoot or a configured
## depRoot).  Stdlib, nimble-package paths, and anything that cannot be
## resolved to a tracked root are silently excluded.
##
## ## Algorithm (RFC-0001 §Dependency Source, verified decode algorithm)
##
## The nimcache JSON at `<nimcacheDir>/<binaryName>.json` contains a `compile`
## array of `[cFilePath, gccCmd]` pairs.  For each pair, element 0 is the path
## to the generated `.c` file whose **basename** encodes the source location:
##
##   basename: strip `.c` → strip leading prefix → decode body (@s→/, @@→@)
##
## Two prefixes matter:
##
## - `@m<body>` — body is a path relative to the *entrypoint's source
##   directory* (not the CWD).  Candidate = normalize(entrypointDir / body).
##
## - `@p<body>` — body is a path relative to whichever search-path root
##   resolved it (stdlib dir, nimble pkg dir, or a project `--path` root
##   such as `src/`).  crisol cannot know which root from the mangled name,
##   so it tries each tracked root in order: `projectRoot`, `projectRoot/src`,
##   then each `depRoot` and `depRoot/src`.  The first that names an existing
##   file wins.  If none matches → stdlib/nimble → excluded.
##
## The under-tracked-root filter (step 5) is path-location based, NOT
## prefix based.  A project module imported via `--path:src` is `@p`-mangled
## but must be tracked because excluding it breaks both `narrowByDiff` and
## compile-avoidance.  This is the D1a soundness fix.
##
## ## Return value
##
## A `HashSet[string]` of paths relative to `projectRoot`, using forward
## slashes, matching the scheme used by `Entrypoint.path` and future
## dep-graph keys.  The entrypoint's own file is included (it appears in
## `compile`).
##
## ## Error handling
##
## A missing or unparse­able JSON raises `CrisolError(kind: cekEnvironment)`.
## The caller (D2/D6) decides recovery policy; the conservative fallback
## (run the entrypoint regardless) is a later-slice concern.

import std/[json, os, sets, strutils]
import crisol/types

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc trackedRoots(config: Config): seq[string] =
  ## Ordered list of directories to try when resolving `@p` bodies.
  ## For each root R we include R itself and R/src (the universal src layout).
  result = @[]
  let pr = config.projectRoot.absolutePath.normalizedPath
  result.add pr
  result.add pr / "src"
  for dr in config.depRoots:
    let d = dr.absolutePath.normalizedPath
    result.add d
    result.add d / "src"

proc isUnderRoot(path: string; root: string): bool =
  ## True iff `path` (normalised absolute) starts with `root` followed by a
  ## path separator (or equals root exactly).  Both arguments must be absolute
  ## and already normalised.
  if path == root: return true
  path.startsWith(root & $DirSep)

proc toProjectRelative(absPath: string; projectRoot: string): string =
  ## Convert an absolute path to a projectRoot-relative forward-slash path.
  let root = projectRoot.absolutePath.normalizedPath
  let norm  = absPath.normalizedPath
  if norm.startsWith(root & $DirSep):
    result = norm[root.len + 1 .. ^1]
  elif norm == root:
    result = ""
  else:
    result = norm          # fallback: return as-is (shouldn't happen post-filter)
  # Normalise to forward slashes on all platforms.
  result = result.replace($DirSep, "/")

proc decodeBody(raw: string): string =
  ## Decode @s → /, @@ → @ in the post-prefix mangled body string.
  raw
    .replace("@@", "\x00")   # protect literal @ temporarily
    .replace("@s", $DirSep)  # @s → path separator
    .replace("\x00", "@")    # restore literal @

proc resolveMangledAll(cFilePath: string;
                       entrypointPath: string;
                       roots: seq[string]): seq[string] =
  ## Decode one `.c` path to zero or more absolute `.nim` candidate paths.
  ##
  ## For `@m`: exactly one candidate (entrypointDir/body), existence not checked
  ##           (R5: record deleted deps too).
  ## For `@p`: ALL tracked roots that produce a valid candidate path are returned,
  ##           regardless of whether the file currently exists on disk (R5+R7 fix):
  ##           - R5: a dep that was deleted still appears as a candidate from its
  ##             original root → the closure records it → narrowByDiff detects the
  ##             deletion in git diff.
  ##           - R7: when multiple roots could have provided the file (ambiguous),
  ##             ALL are recorded (over-selection) so a change to any copy triggers
  ##             re-selection.
  ## For anything else: empty list (conservative).
  let base = cFilePath.extractFilename        # e.g. "@mdeptest_dep.nim.c"
  if not (base.startsWith("@m") or base.startsWith("@p")):
    return @[]                               # unknown prefix — exclude

  let noExt    = base[0 .. ^3]               # strip ".c"
  let noPrefix = noExt[2 .. ^1]              # strip "@m" or "@p"
  let body     = decodeBody(noPrefix)        # decode @s/@@ escapes

  if base.startsWith("@m"):
    # Relative to the entrypoint's source directory.
    # Single candidate; do NOT check existence (R5: record deleted deps).
    let epDir = entrypointPath.absolutePath.parentDir
    result = @[(epDir / body).normalizedPath]

  else: # "@p"
    # R7 fix: generate candidates from ALL tracked roots where the file EXISTS.
    # When multiple roots have the file (ambiguous), record all of them so a
    # change to any copy triggers re-selection (over-selection, safe).
    # When no root has the file: the file is from stdlib/nimble/was deleted;
    # return empty so the under-root filter excludes it.  For deleted @p deps,
    # the previous closure still holds the path and isEntryStale (R4 fix) will
    # detect the missing file and force a re-run, so soundness is maintained
    # via the stale-entry path rather than the closure-rebuild path.
    result = @[]
    for root in roots:
      let candidate = (root / body).normalizedPath
      if fileExists(candidate):
        result.add candidate

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc extractClosure*(nimcacheDir: string;
                     binaryName: string;
                     entrypoint: string;
                     config: Config): HashSet[string] =
  ## Extract the source-dependency closure for one compiled entrypoint.
  ##
  ## Parameters:
  ##   `nimcacheDir`  — the `--nimcache` directory used to compile `entrypoint`.
  ##   `binaryName`   — the basename of the `-o:` binary (used to locate the
  ##                    JSON: `<nimcacheDir>/<binaryName>.json`).
  ##   `entrypoint`   — absolute (or project-root-relative) path to the `.nim`
  ##                    source file.
  ##   `config`       — must have `projectRoot` set; may have `depRoots`.
  ##
  ## Returns a `HashSet[string]` of projectRoot-relative, forward-slash paths.
  ##
  ## Raises `CrisolError(cekEnvironment)` if the JSON is missing or unparseable.

  let jsonPath = nimcacheDir / binaryName & ".json"
  if not fileExists(jsonPath):
    raise newCrisolError(cekEnvironment,
      "nimcache JSON not found: " & jsonPath &
      " — was the entrypoint compiled with the expected -o: and --nimcache?")

  let jstr = readFile(jsonPath)
  var jnode: JsonNode
  try:
    jnode = parseJson(jstr)
  except JsonParsingError as e:
    raise newCrisolError(cekEnvironment,
      "failed to parse nimcache JSON at " & jsonPath & ": " & e.msg)

  let compileArr = jnode{"compile"}
  if compileArr == nil or compileArr.kind != JArray:
    raise newCrisolError(cekEnvironment,
      "nimcache JSON at " & jsonPath & " has no 'compile' array")

  let roots      = trackedRoots(config)
  let epAbs      = entrypoint.absolutePath.normalizedPath
  let prAbs      = config.projectRoot.absolutePath.normalizedPath

  # Collect all tracked roots for the under-root filter.
  # A candidate is kept iff it lives under projectRoot OR any depRoot.
  var trackedDirs: seq[string] = @[prAbs]
  for dr in config.depRoots:
    trackedDirs.add dr.absolutePath.normalizedPath

  result = initHashSet[string]()

  for pair in compileArr:
    if pair.kind != JArray or pair.len < 1: continue
    let cPath = pair[0].getStr("")
    if cPath == "": continue

    # R5+R7 fix: resolveMangledAll returns ALL candidate paths (possibly multiple
    # for ambiguous @p entries, possibly non-existent for deleted deps).
    let candidates = resolveMangledAll(cPath, epAbs, roots)
    for resolved in candidates:
      if resolved == "": continue            # (shouldn't occur, but be defensive)

      # Under-tracked-root filter: the SOUNDNESS gate. Keeps only what lives under
      # projectRoot or a depRoot. Stdlib/nimble paths are excluded here.
      # Existence is NOT checked (R5): deleted deps remain in the closure.
      var underTracked = false
      for dir in trackedDirs:
        if isUnderRoot(resolved, dir):
          underTracked = true
          break
      if not underTracked: continue

      # Convert to projectRoot-relative, forward slashes.
      result.incl toProjectRelative(resolved, prAbs)
