## depparse.nim — LEGACY / TEST-SUPPORT decode helper from the D1a spike.
##
## ⚠️  NOT USED BY THE IMPACT-ANALYSIS PIPELINE.  The canonical, SOUND decoder is
##     `closure.nim` (`resolveMangled` + `extractClosure`).  This module survives
##     only as the `@p` soundness CANARY: `tests/fixtures/pathimport_main.nim`
##     imports it via `--path:src` precisely so `tests/integration/test_closure.nim`
##     can prove that project source reached through `@p` lands in the closure.
##     `tests/unit/test_depdecode.nim` pins its decode vectors.  Do not delete it
##     without repointing those tests at another project module.
##
## ⚠️  DO NOT re-wire `decodeMangledPath`/`classifyMangled` into the extractor.
##     They implement the ORIGINAL `@p → always EXCLUDE` heuristic, which is
##     UNSOUND: project source imported via `--path:src` (the standard src-layout
##     used by crisol's own dogfood and amoxtli) mangles as `@p` and would be
##     silently dropped from every closure → under-selection (the exact failure
##     crisol exists to prevent).  `closure.nim` deliberately replaced this with
##     path-location filtering (decode @m AND @p, keep iff the resolved path is
##     under a tracked root).  The `mkLibrary`/`""`-for-`@p` behavior below is
##     retained ONLY so the pinned legacy vectors keep passing — it is the wrong
##     policy for the live closure.
##
## Empirically-verified mangling facts (spike D1a, Nim 2.2.10) — still accurate,
## shared with closure.nim's sound decoder:
##   - The nimcache JSON lives at <nimcache>/<output-binary-name>.json (NOT
##     <projectname>.json); crisol uses the -o: binary name to locate it.
##   - compile[][0] = full path to the generated .c file.
##   - @m… = strip @m, replace @s with /, resolve relative to the ENTRYPOINT'S
##     SOURCE DIRECTORY (not currentDir).  @@ → literal @.
##   - currentDir (CWD of the nim c invocation, == project root) is stored in the
##     JSON but is NOT the base for @m resolution.
##   - nimexe is empty on Nim 2.2.10; use nim --version for version info.
##   - Entries differ by compile flag, confirming (path, flag-hash) keying.

import std/[os, strutils]

type
  MangledKind* = enum
    mkProject  ## @m prefix — project module
    mkLibrary  ## @p prefix — search-path module. NOTE: legacy label "library";
               ## this is NOT "always exclude" — closure.nim resolves @p against
               ## tracked roots (project src reached via --path:src is @p too).
    mkUnknown  ## unrecognised prefix

proc classifyMangled*(cFilePath: string): MangledKind =
  ## Classify a .c path from the compile array by its mangle prefix.
  let base = cFilePath.extractFilename
  if base.startsWith("@p"):
    mkLibrary
  elif base.startsWith("@m"):
    mkProject
  else:
    mkUnknown

proc decodeMangledPath*(cFilePath: string; entrypointPath: string): string =
  ## Decode one compile-array .c path to its `.nim` source path.
  ##
  ## `cFilePath`     — element[0] of a `compile` pair (full path to .c file).
  ## `entrypointPath` — absolute path to the entrypoint .nim source file.
  ##
  ## Returns the absolute path to the `.nim` source, or `""` for @p entries
  ## (which must be excluded from the project closure).
  ##
  ## The returned path is NOT yet validated to lie under the project root;
  ## the caller applies that filter to distinguish project modules from
  ## unrecognised modules outside the tree.
  let base = cFilePath.extractFilename   # e.g. "@mdeptest_dep.nim.c"
  if base.startsWith("@p"):
    return ""                            # library / stdlib — exclude
  if not base.startsWith("@m"):
    return ""                            # unknown — conservatively exclude
  # Strip trailing .c then the @m prefix.
  let noExt   = base[0 .. ^3]           # strip ".c"  e.g. "@mdeptest_dep.nim"
  let noPrefix = noExt[2 .. ^1]         # strip "@m"  e.g. "deptest_dep.nim"
                                        # or "@s"-encoded: "..@ssrc@smylib.nim"
  # Decode @s → path separator, @@ → @ (Nim escapes @ as @@).
  let decoded = noPrefix
    .replace("@@", "\x00")              # protect literal @ temporarily
    .replace("@s", $DirSep)             # @s → /
    .replace("\x00", "@")               # restore literal @
  # Resolve relative to the entrypoint's source directory.
  let epDir  = entrypointPath.parentDir
  result = (epDir / decoded).normalizedPath
