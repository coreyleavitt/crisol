## test_r14_slot_tmpdir_leak.nim — code-review r14 (Medium): per-slot temp
## dir leaked on every NORMAL completion.
##
## `cleanupSlotTmp` (runner.nim) removed only the FILES inside
## `slot.tmpDir`; its doc comment falsely claimed the directory itself "is
## cleaned up by the execute main loop" — the only `removeDir(slots[idx].
## tmpDir)` lived in the shuttingDown-teardown branch of `execute`. Every
## OTHER slot-release path — a normal RUN-phase completion (`fkDone` from
## `spRunning`), a compile-own-failure (`fkDone` from `spCompiling`), and a
## post-compile cache hit (`fkCacheHit`, RFC-0005 A2c-ii) — left the
## `mkdtemp`'d `crisol_slot_*`/`crisol_run_*` directory behind: one leaked
## directory per entrypoint per run.
##
## Drives the real API (`crisol/api.runTests`) against an isolated TMPDIR
## so leaked directories are trivially enumerable, with two runs that
## together hit all three leak sites:
##
##   Run 1: `pass_always.nim` (normal RUN-phase completion) and
##          `fail_compile.nim` (compile-own-failure), both fresh.
##   Run 2: after deleting run 1's promoted stable binaries (forcing
##          `decideCompile` to report `cdNeverBuilt` instead of
##          `cdSkipFresh`), `pass_always.nim` recompiles and its
##          post-compile cache consult (RFC-0005 A2c-ii) finds run 1's
##          still-valid stored pass under the SAME (unchanged) closure —
##          served as `fkCacheHit` without ever spawning a run child.
##          `fail_compile.nim` fails compile again.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r14_slot_tmpdir_leak.nim

import std/[os, strutils, tempfiles, unittest]
import crisol/api
import crisol/paths  # TrackedPath.display() -- not re-exported through crisol/api

import "../support/helpers"

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  thisFile.parentDir.parentDir / "fixtures"

proc leakedSlotDirs(dir: string): seq[string] =
  ## Any child of `dir` whose name starts with one of the runner's own
  ## `makeTmpDir` prefixes — `crisol_slot_` (`spawnCompileStable`) or
  ## `crisol_run_` (`spawnRunDirect`, the cdSkipFresh direct-run path).
  result = @[]
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind == pcDir:
      let name = path.extractFilename
      if name.startsWith("crisol_slot_") or name.startsWith("crisol_run_"):
        result.add path

proc baseOpts(projectRoot: string): RunOptions =
  RunOptions(
    configPath:     projectRoot / "crisol.kdl",
    manageLock:     true,
    installSignals: false,
    persist:        true,
    showProgress:   false,
    noCache:        false,
  )

suite "r14 — per-slot tmpDir does not leak on any normal completion path":

  test "pass + compile-fail + post-compile cache-hit: no crisol_slot_*/crisol_run_* dirs remain":
    withTempProject:
      # Isolated TMPDIR: `makeTmpDir` (runner.nim) creates its per-slot
      # dirs under `std/os.getTempDir()`, which resolves TMPDIR dynamically
      # at call time — redirecting it here makes every dir this run
      # creates trivially enumerable, and isolates the assertion from any
      # OTHER process's own /tmp traffic in this checkout (which may be
      # shared with a concurrent agent's own test runs).
      let isoTmp = createTempDir("crisol_r14_isotmp_", "")
      defer: removeDir(isoTmp)
      let hadTmpdir = existsEnv("TMPDIR")
      let oldTmpdir = getEnv("TMPDIR")
      putEnv("TMPDIR", isoTmp)
      defer:
        if hadTmpdir: putEnv("TMPDIR", oldTmpdir)
        else: delEnv("TMPDIR")

      writeFile(projectRoot / "tests" / "unit" / "test_pass.nim",
               readFile(fixtureDir() / "pass_always.nim"))
      writeFile(projectRoot / "tests" / "unit" / "test_failcompile.nim",
               readFile(fixtureDir() / "fail_compile.nim"))

      # --- Run 1: fresh compile+run of both fixtures. Hits the RUN-phase
      # fkDone (pass_always) and the COMPILE-phase fkDone (fail_compile)
      # leak sites in the same pass. ---
      let rr1 = runTests(baseOpts(projectRoot))
      check rr1.results.len == 2

      let leaked1 = leakedSlotDirs(isoTmp)
      check leaked1.len == 0

      var rr1PassStored = false
      for r in rr1.results:
        if string(r.ep.tp.display()).endsWith("test_pass.nim"):
          rr1PassStored = r.cacheDecision == cdmStored
      check rr1PassStored  # sanity: run 1's pass really did get stored

      # --- Force a real recompile of the PASSING entrypoint while its
      # cache store entry (from run 1) is still intact: delete the
      # promoted stable binaries so decideCompile reports cdNeverBuilt ->
      # edNeverBuilt (RFC-0005 A2c-ii territory) instead of cdSkipFresh.
      # The nimcache itself (".crisol/cache") and the result-cache store
      # are left untouched — only the "bin" dir (the stable-binary output,
      # a separate subtree) is removed. ---
      removeDir(projectRoot / ".crisol" / "bin")

      # --- Run 2: pass_always recompiles, then its post-compile consult
      # hits run 1's still-valid stored pass (fkCacheHit — the third leak
      # site) — served without ever spawning a run child. fail_compile
      # fails compile again (exercises the SAME compile-own-failure site
      # a second time). ---
      let rr2 = runTests(baseOpts(projectRoot))
      check rr2.results.len == 2

      var rr2PassCached = false
      var rr2PassCacheDecision: CacheDecision
      for r in rr2.results:
        if string(r.ep.tp.display()).endsWith("test_pass.nim"):
          rr2PassCached         = r.cached
          rr2PassCacheDecision  = r.cacheDecision
      # Sanity: run 2 actually exercised the fkCacheHit path this test
      # means to cover, not just a second plain live run.
      check rr2PassCached
      check rr2PassCacheDecision == cdmHit

      let leaked2 = leakedSlotDirs(isoTmp)
      check leaked2.len == 0
