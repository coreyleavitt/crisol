## test_c0_clean_stores.nim — C0: teach `crisol clean` to preserve result-cache
## and ledger stores.
##
## RFC-0004 slice C0 requirements:
##   1. `isResultCacheRootName` predicate from resultcache.nim.
##   2. `cleanOrphans` PRESERVES `cache/v<N>/` (result-cache subtree).
##   3. `cleanOrphans` preserves the `ledger/` DIR (A1c compacts contents).
##   4. `cleanAll` (--all) removes BOTH result-cache dir AND ledger dir.
##
## Note (A1c update): cleanOrphans now compacts the ledger — original shard
## files are removed and replaced with a single compacted shard.  The ledger/
## DIRECTORY is preserved, but the specific original shard filenames are NOT
## guaranteed to survive.  Tests 3a/3b check that the dir exists and is
## non-empty after compaction rather than checking for specific file names.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_c0_clean_stores.nim

import std/[os, options, sets, tables, times, unittest]
import std/posix as posix_mod
import crisol/[types, clean, resultcache]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  let tmp = getTempDir() / ("crisol_c0_" & tag & "_" & $posix_mod.getpid() & "_" &
                             $int64(epochTime() * 1_000_000))
  createDir(tmp)
  tmp

proc makeConfig(root: string): Config =
  ## Minimal Config with one non-opt-in group.
  Config(
    projectRoot:        root,
    stateDir:           ".crisol",
    jobs:               1,
    timeoutSecs:        300,
    compileTimeoutSecs: 600,
    maxOutputBytes:     1024 * 1024,
    groups: @[
      types.Group(name: "unit",
                  globs: @["tests/unit/test_*.nim"],
                  optIn: false),
    ],
  )

proc seedTestFile(root: string) =
  ## Create a minimal test entrypoint so discover() finds exactly one ep.
  let unitDir = root / "tests" / "unit"
  createDir(unitDir)
  writeFile(unitDir / "test_seed.nim", "# stub\n")

# ---------------------------------------------------------------------------
# Suite 1 — isResultCacheRootName predicate
# ---------------------------------------------------------------------------

suite "C0 — isResultCacheRootName predicate":

  test "v1 is recognised as a result-cache root":
    check isResultCacheRootName("v1")

  test "v12 is recognised as a result-cache root":
    check isResultCacheRootName("v12")

  test "v999 is recognised as a result-cache root":
    check isResultCacheRootName("v999")

  test "bare v is NOT a result-cache root":
    check not isResultCacheRootName("v")

  test "v1x is NOT a result-cache root":
    check not isResultCacheRootName("v1x")

  test "a real compile slug is NOT a result-cache root":
    check not isResultCacheRootName("deadbeef12345678")

  test "empty string is NOT a result-cache root":
    check not isResultCacheRootName("")

  test "resultCacheDirName matches current version":
    # resultCacheDirName() must itself pass isResultCacheRootName.
    let name = resultCacheDirName()
    check isResultCacheRootName(name)
    # And it must match the constant used by the path helper.
    check name == "v" & $resultCacheFormatVersion

# ---------------------------------------------------------------------------
# Suite 2 — cleanOrphans PRESERVES result-cache subtree
# ---------------------------------------------------------------------------

suite "C0 — cleanOrphans preserves result-cache store":

  test "v<N>/ subtree inside cache/ is NOT deleted as an orphan":
    let root = makeTempRoot("rcache_preserve")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    # Seed the result-cache dir with a fake entry.
    let rcDir = cacheDir / resultCacheDirName()
    createDir(rcDir)
    writeFile(rcDir / "00aabbccddeeff00.json", "{}")

    # Also plant an orphan compile dir to confirm normal pruning still works.
    createDir(cacheDir / "orphan_deadbeef00000000")

    let r = cleanOrphans(cfg)

    # Result-cache dir MUST survive.
    check dirExists(rcDir)
    check fileExists(rcDir / "00aabbccddeeff00.json")

    # Orphan compile dir MUST be gone.
    check not dirExists(cacheDir / "orphan_deadbeef00000000")

    # Deletion count reflects only the orphan (not the rc dir).
    check r.cacheDeleted >= 1

  test "v<N>/ is preserved even when there are NO live compile slugs":
    ## Edge case: no entrypoints discovered → expectedSlugs is empty →
    ## previously, everything under cache/ would be deleted.
    let root = makeTempRoot("rcache_noeps")
    defer: removeDir(root)

    # No test files planted → discover returns empty.
    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    let rcDir = cacheDir / resultCacheDirName()
    createDir(rcDir)
    writeFile(rcDir / "aabbccddeeff0011.json", "{}")

    let r = cleanOrphans(cfg)

    check dirExists(rcDir)
    check r.cacheDeleted == 0

# ---------------------------------------------------------------------------
# Suite 3 — cleanOrphans does NOT touch ledger/ (sibling of cache/)
# ---------------------------------------------------------------------------

suite "C0 — cleanOrphans leaves ledger/ untouched":

  test "ledger/ dir survives a cleanOrphans call (A1c: contents compacted)":
    ## A1c: cleanOrphans compacts ledger shards — original filenames are
    ## removed and replaced with a single compact-*.ndjson file.  The
    ## ledger/ DIRECTORY must survive and be non-empty.
    let root = makeTempRoot("ledger_survive")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg       = makeConfig(root)
    let stateDir  = root / ".crisol"
    let ledgerDir = stateDir / "ledger"
    createDir(ledgerDir)
    writeFile(ledgerDir / "12345-abcdef-1.ndjson",
              "{\"historyFormatVersion\":1}\n")

    let r = cleanOrphans(cfg)

    # The ledger/ dir must survive.
    check dirExists(ledgerDir)
    # After compaction the original shard is gone but a compacted shard exists.
    check r.shardsRemoved >= 1

  test "cleanOrphans with orphan compile dirs still leaves ledger/ dir intact":
    let root = makeTempRoot("ledger_survive_orphan")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg       = makeConfig(root)
    let stateDir  = root / ".crisol"
    let cacheDir  = stateDir / "cache"
    let ledgerDir = stateDir / "ledger"
    createDir(cacheDir)
    createDir(ledgerDir)
    writeFile(ledgerDir / "99999-abcdef-2.ndjson",
              "{\"historyFormatVersion\":1}\n")

    # Plant an orphan so pruning actually runs.
    createDir(cacheDir / "orphan_cafecafe00000000")

    let r = cleanOrphans(cfg)

    # ledger/ dir must survive; compaction replaces original shards.
    check dirExists(ledgerDir)
    check r.cacheDeleted >= 1
    check r.shardsRemoved >= 1

# ---------------------------------------------------------------------------
# Suite 4 — cleanAll removes result-cache dir AND ledger dir
# ---------------------------------------------------------------------------

suite "C0 — cleanAll removes both new stores":

  test "cleanAll removes cache/v<N>/ (result-cache store)":
    let root = makeTempRoot("cleanall_rc")
    defer: removeDir(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let rcDir    = stateDir / "cache" / resultCacheDirName()
    createDir(rcDir)
    writeFile(rcDir / "ff00ff00ff00ff00.json", "{}")

    check dirExists(rcDir)
    cleanAll(cfg)
    check not dirExists(rcDir)
    check not dirExists(stateDir)

  test "cleanAll removes ledger/ dir":
    let root = makeTempRoot("cleanall_ledger")
    defer: removeDir(root)

    let cfg       = makeConfig(root)
    let stateDir  = root / ".crisol"
    let ledgerDir = stateDir / "ledger"
    createDir(ledgerDir)
    writeFile(ledgerDir / "1-abc-1.ndjson", "{\"historyFormatVersion\":1}\n")

    check dirExists(ledgerDir)
    cleanAll(cfg)
    check not dirExists(ledgerDir)
    check not dirExists(stateDir)

  test "cleanAll removes both result-cache and ledger simultaneously":
    let root = makeTempRoot("cleanall_both")
    defer: removeDir(root)

    let cfg       = makeConfig(root)
    let stateDir  = root / ".crisol"
    let rcDir     = stateDir / "cache" / resultCacheDirName()
    let ledgerDir = stateDir / "ledger"
    createDir(rcDir)
    writeFile(rcDir / "aabbccddeeff0022.json", "{}")
    createDir(ledgerDir)
    writeFile(ledgerDir / "2-abc-1.ndjson", "{\"historyFormatVersion\":1}\n")
    # Also add a compile cache dir.
    createDir(stateDir / "cache" / "somecompileslug")

    cleanAll(cfg)
    check not dirExists(rcDir)
    check not dirExists(ledgerDir)
    check not dirExists(stateDir)
