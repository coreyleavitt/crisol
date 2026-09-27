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
import crisol/[types, paths, clean, resultcache, depgraph, planner]
import crisol/process/tooltrees

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTempRoot(tag: string): string =
  let tmp = getTempDir() / ("crisol_c0_" & tag & "_" & $getCurrentProcessId() & "_" &
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

proc slugFor(relPath: string; roots: TrackedRoots; flags: seq[string] = @[]): string =
  ## Compute the slug for a path+flags pair the same way discover would.
  slug(fromCanonical(relPath, roots).get, roots, flags)

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

    let r = cleanOrphans(cfg, knownToolchain("", ""))

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

    let r = cleanOrphans(cfg, knownToolchain("", ""))

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

    let r = cleanOrphans(cfg, knownToolchain("", ""))

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

    let r = cleanOrphans(cfg, knownToolchain("", ""))

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

# ---------------------------------------------------------------------------
# Suite 5 — R15-D5 / R15-L2: an interrupted clean stops at the next phase
# boundary and reports the interruption truthfully.
# ---------------------------------------------------------------------------

suite "R15-D5 / R15-L2 — interrupted cleanOrphans performs no further destructive phase":

  test "a signal observed before cleanOrphans starts: cache/, bin/, the depgraph and the ledger are all left untouched, and the result says interrupted":
    ## Before the fix, cleanOrphans had no interrupt check at all: cache/bin
    ## pruning, the depgraph GC, and every ledger compaction ran to
    ## completion regardless of a pending signal. `deliverInterrupt` runs the
    ## real handler body (the same one a SIGINT/SIGTERM would) without a real
    ## signal reaching this process (see tests/unit/test_tooltrees.nim) --
    ## `shutdownRequested()` then reads `some` for the rest of the open scope,
    ## exactly as it would after a real Ctrl-C landed while the toolchain was
    ## being probed, just before `cleanOrphans` was ever called.
    let root = makeTempRoot("interrupt_boundary")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    let binDir   = stateDir / "bin"
    let ledgerDir = stateDir / "ledger"
    createDir(cacheDir)
    createDir(binDir)
    createDir(ledgerDir)

    # An orphan in cache/ and bin/ -- pruned on an uninterrupted clean.
    createDir(cacheDir / "orphan_deadbeef00000000")
    createDir(binDir / "orphan_deadbeef00000000")

    # A ledger shard -- compacted on an uninterrupted clean.
    let shardPath = ledgerDir / "12345-abcdef-1.ndjson"
    writeFile(shardPath, "{\"historyFormatVersion\":1}\n")

    # A stale depgraph entry -- dropped on an uninterrupted clean.
    var graph = initDepGraph("")
    let stalePath = "tests/unit/test_deleted_long_ago.nim"
    let fHash     = flagHash(@[])
    graph.updateEntry(stalePath, fHash,
      [fromCanonical(stalePath, default(TrackedRoots)).get].toHashSet, @[], "", 1)
    doAssert saveDepGraph(graph, cfg)

    enterInterruptScope()
    deliverInterrupt(2)  # SIGINT, played without a real signal (R14-D5)
    let r = cleanOrphans(cfg, knownToolchain("", ""))
    discard leaveInterruptScope()

    check r.interrupted

    # No destructive phase ran: every orphan and every stale record survives.
    check dirExists(cacheDir / "orphan_deadbeef00000000")
    check dirExists(binDir / "orphan_deadbeef00000000")
    check fileExists(shardPath)
    let g2 = loadDepGraph(cfg, "")
    check g2.entries.hasKey((stalePath, fHash))

    check r.cacheDeleted == 0
    check r.binDeleted == 0
    check r.graphEntriesDropped == 0
    check r.shardsRemoved == 0
    check r.cacheEvicted == 0

# ---------------------------------------------------------------------------
# Suite 6 — R15-D4: CleanToolchain's zero value is safe
# ---------------------------------------------------------------------------

suite "R15-D4 — CleanToolchain zero value":

  test "the zero value is an unknown toolchain, not known(\"\")":
    # R15-D4: `CleanToolchain()`'s zero value used to read as known(""), a
    # real (if empty) toolchain identity `cleanOrphans` would prune cache/
    # dirs by — unsafe, the same shape of bug as R14-L1. A default-
    # constructed value must instead land on the branch that prunes nothing
    # by the toolchain, mirroring `Registration()`'s own R15-D4 fix
    # (tests/unit/test_tooltrees.nim).
    check CleanToolchain().kind == ctkUnknown

# ---------------------------------------------------------------------------
# Suite 7 — R16-D2: stale `.promoting` files in bin/ are pruned
# ---------------------------------------------------------------------------

suite "R16-D2 — stale *.promoting files in bin/ are pruned":

  test "a stale .promoting file inside a LIVE entrypoint's bin dir is removed":
    ## `runner.promoteCompiledBinary` stages a copy at `<stableBin>.promoting`
    ## beside the stable binary, then renames it into place; a kill between
    ## the copy and the rename leaves the staged file behind. `pruneDir`
    ## only decides whether to keep or remove a whole `<slug>` directory —
    ## it never looks inside one it keeps — so this litter used to survive
    ## forever once left next to a LIVE entrypoint's binary.
    let root = makeTempRoot("promoting_live")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let binDir   = stateDir / "bin"
    createDir(binDir)

    let relPath      = "tests/unit/test_seed.nim"
    let expectedSlug = slugFor(relPath, cfg.trackedRoots, @[])
    let liveBinDir   = binDir / expectedSlug
    createDir(liveBinDir)

    # The real stable binary, and the stale staged copy a kill left behind.
    writeFile(liveBinDir / "test_seed", "#!/bin/sh\n")
    let stalePromoting = liveBinDir / "test_seed.promoting"
    writeFile(stalePromoting, "partial\n")

    let r = cleanOrphans(cfg, knownToolchain("", ""))

    # The live dir, and the real stable binary inside it, survive.
    check dirExists(liveBinDir)
    check fileExists(liveBinDir / "test_seed")
    # The stale `.promoting` file does NOT.
    check not fileExists(stalePromoting)
    check r.binDeleted >= 1

  test "a stale .promoting file inside an ORPHAN entrypoint's bin dir is removed with the whole dir":
    let root = makeTempRoot("promoting_orphan")
    defer: removeDir(root)
    seedTestFile(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let binDir   = stateDir / "bin"
    createDir(binDir)

    # No entrypoint maps to this slug — clean must drop the whole directory.
    let orphanBinDir = binDir / "orphan_deadbeef00000000"
    createDir(orphanBinDir)
    writeFile(orphanBinDir / "gone.promoting", "partial\n")

    discard cleanOrphans(cfg, knownToolchain("", ""))

    check not dirExists(orphanBinDir)
