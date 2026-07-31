## test_clean.nim — C4 integration tests for `crisol clean` and the advisory lock.
##
## Tests:
##   1. clean prunes orphan cache/bin dirs; keeps current slugs.
##   2. clean ignores gates — gated-group caches are NOT deleted by clean.
##   3. clean --all removes the entire .crisol/ dir.
##   4. clean drops stale depgraph entries; keeps current entries.
##   5. Lock contention: second acquireLock fails with cekEnvironment.
##   6. Lock auto-releases when the holding process exits.
##   7. list / --dry-run succeed while the lock is held (they don't acquire it).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_clean.nim

import std/[options, os, sets, strutils, tables, times, unittest]
import std/posix
import crisol
import crisol/[types, runner, depgraph, lock, clean]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc makeTempRoot(): string =
  ## Create a unique temp directory to serve as a fake projectRoot.
  let tmp = getTempDir() / ("crisol_test_clean_" & $getpid() & "_" & $epochTime().int)
  createDir(tmp)
  tmp

proc makeConfig(root: string): Config =
  ## Build a minimal Config rooted at `root` with two groups:
  ##   unit        — globs tests/unit/test_*.nim  (non-opt-in)
  ##   integration — globs tests/integration/test_*.nim (opt-in + gated)
  let gate = Gate(env: "CRISOL_TEST_GATE_NOTSET_XYZ")
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
      types.Group(name: "integration",
                  globs: @["tests/integration/test_*.nim"],
                  optIn: true,
                  gate:  some(gate)),
    ],
  )

proc slugFor(relPath: string; flags: seq[string] = @[]): string =
  ## Compute the slug for a path+flags pair (wraps the library proc).
  slug(relPath, flags)

# ---------------------------------------------------------------------------
# Suite 1 — clean prunes orphans / keeps current slugs
# ---------------------------------------------------------------------------

suite "crisol clean — orphan pruning":

  test "clean removes orphan dirs and keeps current slugs":
    let root = makeTempRoot()
    defer: removeDir(root)

    # Create a fake discovery root with a single test file.
    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    writeFile(unitDir / "test_foo.nim", "# stub\n")

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    let binDir   = stateDir / "bin"
    createDir(cacheDir)
    createDir(binDir)

    # Compute the expected slug for the discovered entrypoint.
    let relPath      = "tests/unit/test_foo.nim"
    let expectedSlug = slugFor(relPath, @[])

    # Create the expected (current) dirs.
    createDir(cacheDir / expectedSlug)
    createDir(binDir   / expectedSlug)

    # Create orphan dirs that should be pruned.
    createDir(cacheDir / "orphan_deadbeef0000dead")
    createDir(binDir   / "orphan_cafebabe0000cafe")

    let r = cleanOrphans(cfg)

    # Current dirs must remain.
    check dirExists(cacheDir / expectedSlug)
    check dirExists(binDir   / expectedSlug)

    # Orphan dirs must be gone.
    check not dirExists(cacheDir / "orphan_deadbeef0000dead")
    check not dirExists(binDir   / "orphan_cafebabe0000cafe")

    # Counts.
    check r.cacheDeleted >= 1
    check r.binDeleted   >= 1

  test "clean also prunes per-slot temp dirs (_<N> suffix) not matching any current slug":
    let root = makeTempRoot()
    defer: removeDir(root)

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    writeFile(unitDir / "test_bar.nim", "# stub\n")

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    let relPath      = "tests/unit/test_bar.nim"
    let expectedSlug = slugFor(relPath, @[])

    # Per-slot dir for the current entrypoint → should be retained.
    createDir(cacheDir / (expectedSlug & "_0"))
    # Per-slot dir for a non-existent (orphan) entrypoint → should be pruned.
    createDir(cacheDir / "orphan_aabbccdd1234abcd_3")

    let r = cleanOrphans(cfg)

    check dirExists(cacheDir / (expectedSlug & "_0"))
    check not dirExists(cacheDir / "orphan_aabbccdd1234abcd_3")
    check r.cacheDeleted >= 1

# ---------------------------------------------------------------------------
# Suite 1b — RFC-0006 nimcache-persistence GC: toolchain-fingerprinted dirs
# ---------------------------------------------------------------------------

suite "crisol clean — nimcache-persistence toolchain-fingerprint GC":

  test "current-toolchain cache dir is KEPT; stale-toolchain cache dir is PRUNED":
    let root = makeTempRoot()
    defer: removeDir(root)

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    writeFile(unitDir / "test_tc.nim", "# stub\n")

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    let relPath   = "tests/unit/test_tc.nim"
    let baseSlug  = slugFor(relPath, @[])
    let currentFp = toolchainFingerprint("2.2.10", "gcc-current|ldd-current")
    let staleFp   = toolchainFingerprint("2.2.10", "gcc-OLD|ldd-OLD")
    check currentFp != staleFp  ## precondition

    let currentDir = cacheDir / (baseSlug & "-" & currentFp)
    let staleDir   = cacheDir / (baseSlug & "-" & staleFp)
    createDir(currentDir)
    createDir(staleDir)

    let r = cleanOrphans(cfg, nimVersion = "2.2.10", ccVersion = "gcc-current|ldd-current")

    # The dir matching the CURRENT toolchain fingerprint survives.
    check dirExists(currentDir)
    # The dir left over from an OLD (stale) toolchain fingerprint is an
    # orphan and gets pruned — this is the GC half of nimcache-persistence:
    # a cc/nim upgrade must not accumulate cache dirs forever.
    check not dirExists(staleDir)
    check r.cacheDeleted >= 1

  test "no toolchain probe supplied (defaults) ⇒ falls back to bare-slug expected set":
    ## Back-compat: cleanOrphans(cfg) with no nimVersion/ccVersion (as called
    ## by every OTHER test in this file, and by any pre-fingerprint caller)
    ## must behave exactly as before — retaining the bare `<slug>` dir with
    ## no toolchain suffix.
    let root = makeTempRoot()
    defer: removeDir(root)

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    writeFile(unitDir / "test_bare.nim", "# stub\n")

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    let relPath  = "tests/unit/test_bare.nim"
    let baseSlug = slugFor(relPath, @[])
    createDir(cacheDir / baseSlug)  ## bare, no toolchain suffix

    let r = cleanOrphans(cfg)  ## no nimVersion/ccVersion — the "" default

    check dirExists(cacheDir / baseSlug)
    check r.cacheDeleted == 0

# ---------------------------------------------------------------------------
# Suite 2 — clean ignores gates (gated-group caches are KEPT)
# ---------------------------------------------------------------------------

suite "crisol clean — gates ignored":

  test "gated-group cache is NOT deleted even when gate is closed":
    let root = makeTempRoot()
    defer: removeDir(root)

    # Create an integration test file (gated group, opt-in).
    let intDir = root / "tests" / "integration"
    createDir(intDir)
    writeFile(intDir / "test_gated.nim", "# stub\n")

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    let cacheDir = stateDir / "cache"
    createDir(cacheDir)

    # The gate env var CRISOL_TEST_GATE_NOTSET_XYZ is NOT set,
    # so applyGates would exclude this group.  clean must NOT call applyGates.
    let relPath   = "tests/integration/test_gated.nim"
    let gatedSlug = slugFor(relPath, @[])

    createDir(cacheDir / gatedSlug)

    let r = cleanOrphans(cfg)

    # Gate is closed but clean discovers all groups → slug is in expected set.
    check dirExists(cacheDir / gatedSlug)
    check r.cacheDeleted == 0

# ---------------------------------------------------------------------------
# Suite 3 — clean --all
# ---------------------------------------------------------------------------

suite "crisol clean --all":

  test "cleanAll removes the entire .crisol/ directory":
    let root = makeTempRoot()
    defer: removeDir(root)

    let cfg      = makeConfig(root)
    let stateDir = root / ".crisol"
    createDir(stateDir / "cache" / "someslug")
    createDir(stateDir / "bin"   / "someslug")
    writeFile(stateDir / "depgraph", "{}")
    writeFile(stateDir / "lastrun.json", "{}")
    writeFile(stateDir / "lock", "")

    check dirExists(stateDir)
    cleanAll(cfg)
    check not dirExists(stateDir)

  test "cleanAll on absent state dir is a no-op (no error)":
    let root = makeTempRoot()
    defer: removeDir(root)

    let cfg = makeConfig(root)
    # .crisol/ does not exist — should not raise.
    check not dirExists(root / ".crisol")
    cleanAll(cfg)
    check not dirExists(root / ".crisol")

# ---------------------------------------------------------------------------
# Suite 4 — clean GCs stale depgraph entries
# ---------------------------------------------------------------------------

suite "crisol clean — depgraph GC":

  test "stale depgraph entry is dropped; current entry survives":
    let root = makeTempRoot()
    defer: removeDir(root)

    let unitDir = root / "tests" / "unit"
    createDir(unitDir)
    writeFile(unitDir / "test_kept.nim", "# stub\n")

    let cfg = makeConfig(root)

    # Seed depgraph with one current entry and one stale entry.
    var graph = initDepGraph("")
    let keptPath  = "tests/unit/test_kept.nim"
    let stalePath = "tests/unit/test_deleted_long_ago.nim"  # no file on disk
    let emptySet  = initHashSet[string]()
    let fHash     = flagHash(@[])

    graph.updateEntry(keptPath,  fHash, emptySet, "", 1)
    graph.updateEntry(stalePath, fHash, emptySet, "", 1)
    saveDepGraph(graph, cfg)

    discard cleanOrphans(cfg)

    # Reload and verify.
    let g2 = loadDepGraph(cfg, "")
    # The stale entry (path not matching any current entrypoint glob) must be gone.
    check not g2.entries.hasKey((stalePath, fHash))
    # The kept entry must survive.
    check g2.entries.hasKey((keptPath, fHash))

# ---------------------------------------------------------------------------
# Suite 5 — advisory lock
# ---------------------------------------------------------------------------

suite "crisol advisory lock":

  test "acquireLock succeeds when no one holds it":
    let root = makeTempRoot()
    defer: removeDir(root)

    let stateDir = root / ".crisol"
    var h = acquireLock(stateDir)
    check h.fd >= 0
    releaseLock(h)

  test "second acquireLock on same stateDir (from forked child) raises contention error":
    ## Parent holds the lock; forked child tries to acquire → must fail with
    ## cekEnvironment (contention).  Child writes '1' (contention) or '0' to a file.
    let root = makeTempRoot()
    defer: removeDir(root)

    let stateDir   = root / ".crisol"
    let resultFile = root / "lock_result.txt"

    # Parent acquires first.
    var h = acquireLock(stateDir)
    check h.fd >= 0

    let childPid = fork()
    if childPid == 0:
      # Child process: attempt second acquire — must fail.
      var gotContention = false
      try:
        var h2 = acquireLock(stateDir)
        releaseLock(h2)
      except CrisolError as e:
        if e.kind == cekEnvironment:
          gotContention = true
      except:
        discard
      writeFile(resultFile, if gotContention: "1" else: "0")
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      releaseLock(h)

      check fileExists(resultFile)
      check readFile(resultFile).strip() == "1"

  test "lock auto-releases when holding process exits (parent acquires after child dies)":
    let root = makeTempRoot()
    defer: removeDir(root)

    let stateDir = root / ".crisol"

    let childPid = fork()
    if childPid == 0:
      # Child: acquire lock, then exit WITHOUT calling releaseLock.
      # The kernel must release the lock on process exit.
      let h = acquireLock(stateDir)
      discard h
      quit(0)
    else:
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)
      # Child is dead → lock must have been auto-released.
      var acquired = false
      try:
        var h = acquireLock(stateDir)
        acquired = h.fd >= 0
        releaseLock(h)
      except:
        discard
      check acquired

# ---------------------------------------------------------------------------
# Suite 6 — read-only commands do not acquire the lock
# ---------------------------------------------------------------------------

suite "crisol clean — read-only commands skip lock":

  test "list runs successfully while lock is held by another process":
    ## Fork a child that holds the lock; parent verifies list exits 0.
    let root = makeTempRoot()
    defer: removeDir(root)

    let stateDir = root / ".crisol"

    # Signal pipe: child writes byte when lock is held.
    var pipeFds: array[2, cint]
    discard posix.pipe(pipeFds)

    let childPid = fork()
    if childPid == 0:
      discard posix.close(pipeFds[0])
      let h = acquireLock(stateDir)
      discard h
      var b: char = 'x'
      discard posix.write(pipeFds[1], addr b, 1)
      discard posix.close(pipeFds[1])
      os.sleep(30_000)
      quit(0)
    else:
      discard posix.close(pipeFds[1])
      var b: char
      discard posix.read(pipeFds[0], addr b, 1)
      discard posix.close(pipeFds[0])

      # list with a fixture file — does not acquire the lock.
      let fixDir = fixtureDir()
      let code = runMain(@["list", fixDir / "pass_always.nim"])

      discard posix.kill(childPid, SIGKILL)
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)

      check code == 0

  test "run --dry-run succeeds while lock is held":
    let root = makeTempRoot()
    defer: removeDir(root)

    let stateDir = root / ".crisol"

    var pipeFds: array[2, cint]
    discard posix.pipe(pipeFds)

    let childPid = fork()
    if childPid == 0:
      discard posix.close(pipeFds[0])
      let h = acquireLock(stateDir)
      discard h
      var b: char = 'y'
      discard posix.write(pipeFds[1], addr b, 1)
      discard posix.close(pipeFds[1])
      os.sleep(30_000)
      quit(0)
    else:
      discard posix.close(pipeFds[1])
      var b: char
      discard posix.read(pipeFds[0], addr b, 1)
      discard posix.close(pipeFds[0])

      let fixDir = fixtureDir()
      let code = runMain(@["run", "--dry-run", fixDir / "pass_always.nim"])

      discard posix.kill(childPid, SIGKILL)
      var ws: cint = 0
      discard waitpid(childPid, ws, 0)

      check code == 0
