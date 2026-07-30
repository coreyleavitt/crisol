## test_objcache_gate.nim — RFC-0006 Stage R, R2b2: integration tests wiring
## the cache-mode compile worker into runner.nim's compile slot, gated by
## Config.objCache / RunOptions.objCache / RunOptions.noObjCache.
##
## Mirrors tests/integration/test_measure_compile_gate.nim's structure and
## rationale exactly (same fixture, same self-reexec soundness constraint —
## see that file's module doc for the full explanation of why the ON-path
## tests spawn the REAL `crisol` binary rather than making a library call).
##
## The observable proof that the cache worker (not the monolithic `nim c`
## path) ran is `<stateDir>/objcache/v1/` gaining at least one `*.o` entry —
## the monolithic path and the measurement worker never touch that
## directory at all.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_objcache_gate.nim

import std/[json, os, osproc, streams, strtabs, strutils, times, unittest]
import crisol/types
import crisol/depgraph
import crisol/runner
import crisol/objcache
import crisol/compilecost

# ---------------------------------------------------------------------------
# Helpers — library-call path (OFF / no-worker; never needs the real binary)
# ---------------------------------------------------------------------------

proc projectRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

const epRelPath = "tests" / "fixtures" / "pass_always.nim"

proc mkEp(): Entrypoint =
  Entrypoint(path: epRelPath, group: "test", flags: @[])

proc freshStateDir(tag: string): string =
  result = getTempDir() / "crisol_test_objcache_gate_" & tag & "_" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc makeConfig(stateDir: string; objCache: bool; workerBinary: string = ""): Config =
  Config(
    projectRoot:        projectRoot(),
    stateDir:           stateDir,
    timeoutSecs:        60,
    compileTimeoutSecs: 300,
    maxOutputBytes:     65_536,
    jobs:               1,
    objCache:           objCache,
    workerBinary:       workerBinary,
  )

proc objCacheDirPopulated(stateDir: string): bool =
  ## True iff <stateDir>/objcache/v1/ exists and holds >=1 *.o entry — the
  ## observable proof the cache worker (not `nim c` / the measure worker)
  ## actually ran as the slot's compile child.
  let dir = stateDir / "objcache" / objCacheDirName()
  if not dirExists(dir): return false
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".o"):
      return true
  false

# ---------------------------------------------------------------------------
# Helpers — real-binary path (ON behaviors; self-reexec must be sound)
# ---------------------------------------------------------------------------

proc buildCrisolBinary(): string =
  ## Compile the REAL src/crisol.nim CLI binary once, into an isolated temp
  ## path — the only sound host for --objcache's self-reexec (mirrors
  ## test_measure_compile_gate.nim's buildCrisolBinary exactly).
  result = getTempDir() / "crisol_test_objcache_gate_bin" / "crisol"
  createDir(result.parentDir)
  let cmd = "nim c --hints:off --warnings:off -d:release --mm:orc -o:" &
            result.quoteShell & " " & (projectRoot() / "src" / "crisol.nim").quoteShell
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "failed to build crisol binary for objcache gate tests: " & output
  doAssert fileExists(result), "crisol binary not produced at " & result

let crisolBin = buildCrisolBinary()

proc runCrisolObjCache(stateDir: string; extraArgs: seq[string] = @[];
                       epPath: string = epRelPath):
                       tuple[exitCode: int; output: string] =
  let p = startProcess(
    crisolBin,
    workingDir = projectRoot(),
    args = @["run", epPath, "--objcache", "--jobs", "1"] & extraArgs,
    env = {"CRISOL_STATE_DIR": stateDir, "PATH": getEnv("PATH"), "HOME": getEnv("HOME")}.newStringTable,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  close(p)
  (exitCode: code, output: output)

proc runCrisolNoExplicitFlag(stateDir: string; extraArgs: seq[string] = @[];
                             epPath: string = epRelPath):
                             tuple[exitCode: int; output: string] =
  ## RFC-0006 Stage R, R2b2 default-on flip: unlike runCrisolObjCache above,
  ## this omits --objcache entirely -- proving the CLI's OWN default (no
  ## `objcache` KDL node in the discovered config, no --objcache/--no-objcache
  ## flag) now dispatches the cache worker, not just an explicit request. The
  ## CLI always sets RunOptions.workerBinary to its own getAppFilename()
  ## (crisol.nim's runMain), so this is the true CLI-style default path.
  let p = startProcess(
    crisolBin,
    workingDir = projectRoot(),
    args = @["run", epPath, "--jobs", "1"] & extraArgs,
    env = {"CRISOL_STATE_DIR": stateDir, "PATH": getEnv("PATH"), "HOME": getEnv("HOME")}.newStringTable,
    options = {poUsePath, poStdErrToStdOut},
  )
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  close(p)
  (exitCode: code, output: output)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "objcache gate — runner wiring (RFC-0006 Stage R R2b2)":

  test "explicit OFF (Config-struct level, RFC-0006 default-on flip: objCache is no longer false by default -- this test proves the explicit-off path, not the default): normal execute() run passes AND objcache/ dir is never created":
    ## NOTE: makeConfig() builds a Config struct directly, bypassing
    ## config.loadConfig's KDL-absent default (which now resolves objCache
    ## to true -- see test_config.nim / the CLI-default test below for that).
    ## This test only proves that an EXPLICITLY objCache=false Config still
    ## takes the byte-identical monolithic path.
    let stateDir = freshStateDir("off")
    defer: removeDir(stateDir)

    let ep  = mkEp()
    let cfg = makeConfig(stateDir, objCache = false)
    check cfg.objCache == false   # confirms the explicit-off Config field

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    # The monolithic `nim c` path never invokes the cache worker, so
    # <stateDir>/objcache/ is never created at all — the cleanest observable
    # proof (through the public API) that the default-off path takes the
    # EXACT existing (unchanged) monolithic route.
    check not dirExists(stateDir / "objcache")

  test "library-path safety: objCache=true with workerBinary UNSET never fork-bombs; falls back to monolithic compile":
    ## Same defect class the measure-compile-reuse gate guards against:
    ## getAppFilename() would point at THIS unittest binary, not crisol, so
    ## objCache must never call it directly. With no workerBinary configured,
    ## spawnCompileStable must degrade to the monolithic `nim c` path.
    let stateDir = freshStateDir("lib_no_worker")
    defer: removeDir(stateDir)

    let ep = mkEp()
    let cfg = makeConfig(stateDir, objCache = true)
    check cfg.workerBinary.len == 0   # unset by default — the unsafe case

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let t0 = epochTime()
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)
    let elapsed = epochTime() - t0

    check results.len == 1
    check results[0].outcome == oPassed
    check elapsed < 30.0   # a real single-file compile; a fork bomb would hang
                           # until the (300s) compile watchdog fires instead

    check not dirExists(stateDir / "objcache")

  test "library-path: workerBinary injected -> cache worker dispatches; objcache/v1/ populated":
    ## Proves the seam itself (Config.objCache + Config.workerBinary),
    ## independent of the CLI: a plain library call with an explicitly
    ## injected worker binary path gets the SAME cache-worker dispatch as
    ## the CLI's --objcache.
    let stateDir = freshStateDir("lib_worker")
    defer: removeDir(stateDir)

    let ep = mkEp()
    var cfg = makeConfig(stateDir, objCache = true)
    cfg.workerBinary = crisolBin

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed
    check objCacheDirPopulated(stateDir)

  test "review Finding 3: a CONFIGURED tight objcacheMaxEntries is what the write-time soft cap enforces, not the hardcoded 10000 default":
    ## Before the fix, cacheworker.runCompileCacheWorker called
    ## `realObjCacheSeams(plan.stateDir)` with NO cap arguments, so the
    ## write-time soft cap always used the hardcoded DefaultMaxObjCacheEntries
    ## (10 000) regardless of `Config.objcacheMaxEntries` -- a suite whose
    ## reusable-unit count is far below 10 000 (as here) could never observe
    ## the configured cap being enforced on the default `crisol run` path.
    ## pass_always.nim compiles to several reusable units (>1, per
    ## test_compileworker_real.nim's own "4 reusable units processed"
    ## observation) -- with objcacheMaxEntries=1, only the FIRST NEW key may
    ## be stored; every subsequent NEW key for this SAME compile must be
    ## soft-cap-skipped, so objcache/v1/ ends up with far FEWER `.o` entries
    ## than the full reusable set.
    let stateDir = freshStateDir("configured_entries_cap")
    defer: removeDir(stateDir)

    let ep = mkEp()
    var cfg = makeConfig(stateDir, objCache = true, workerBinary = crisolBin)
    cfg.objcacheMaxEntries = 1

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    let verDir = stateDir / "objcache" / objCacheDirName()
    check dirExists(verDir)
    var objCount = 0
    for kind, path in walkDir(verDir):
      if kind == pcFile and path.endsWith(".o"): inc objCount
    check objCount >= 1
    check objCount <= 1   # the CONFIGURED cap (1), not the hardcoded default

  test "ON: real crisol binary run succeeds AND populates objcache/v1/":
    let stateDir = freshStateDir("on")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolObjCache(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check objCacheDirPopulated(stateDir)

  test "DEFAULT-ON (RFC-0006 Stage R flip): real crisol binary run with NO --objcache flag at all still succeeds AND populates objcache/v1/":
    ## The flip's headline behavior: a plain `crisol run <ep>` (CLI-style,
    ## no --objcache, no --no-objcache, no `objcache` KDL node in the
    ## discovered config) now dispatches the cache worker by default -- this
    ## is the byte-for-byte inversion of what this file's "OFF (default)"
    ## test proved before the flip.
    let stateDir = freshStateDir("default_on")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolNoExplicitFlag(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check objCacheDirPopulated(stateDir)

  test "review Finding 2 (integration proof): ON with a WHITESPACE-containing stateDir still populates objcache/v1/, not a silent no-op":
    ## `cachePath`/`binPath` (planner.nim) are both rooted at `stateDirOf`, so
    ## a space anywhere in the stateDir path (realistic under WSL2, e.g.
    ## `/mnt/c/Users/John Doe/proj`) propagates into the per-slot nimcacheDir/
    ## outputBinPath crisol constructs — and therefore into the manifest's
    ## `-o <path>` and trailing `.c` source arguments the objcache worker's
    ## `parseCcOutputObj`/`buildCacheKeyOf` must parse. Before the Finding-2
    ## fix, a plain `splitWhitespace()` in both silently truncated those
    ## paths at the embedded space, so `readFile`/copy always missed and
    ## EVERY reusable unit degraded to non-cacheable — objcache/v1/ would
    ## exist but never actually gain a real `.o` entry populated via the
    ## whitespace-poisoned path. This test proves real storage happens end to
    ## end under such a path, not just that the process exits 0.
    let stateDir = getTempDir() / "crisol test objcache gate space" &
                   "_" & $getCurrentProcessId()
    removeDir(stateDir)
    createDir(stateDir)
    defer: removeDir(stateDir)
    check ' ' in stateDir   # sanity: the fixture genuinely exercises a space

    let (exitCode, output) = runCrisolObjCache(stateDir)
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check objCacheDirPopulated(stateDir)

  test "ON, run twice against the same stateDir: both runs succeed; objcache/v1/ stays populated":
    let stateDir = freshStateDir("on_twice")
    defer: removeDir(stateDir)

    let (exitCode1, output1) = runCrisolObjCache(stateDir)
    check exitCode1 == 0
    if exitCode1 != 0: echo "crisol run 1 output:\n", output1

    let (exitCode2, output2) = runCrisolObjCache(stateDir)
    check exitCode2 == 0
    if exitCode2 != 0: echo "crisol run 2 output:\n", output2

    check objCacheDirPopulated(stateDir)

  test "ON, run twice against the same stateDir with two DIFFERENT fixtures sharing runtime units: persisted lastrun.json's compile.objcache shows realized hits/hitRate/reusedBytes/cacheSizeBytes on the second run (RFC-0006 Stage R R5b)":
    ## End-to-end proof of R5b's report aggregation: a real --objcache run
    ## (no --measure-compile-reuse) still surfaces its own realized
    ## hit/miss telemetry in the report, not just on disk under objcache/v1/.
    ##
    ## Empirically confirmed (diagnostic, not asserted here): recompiling
    ## the IDENTICAL single entrypoint across two SEPARATE crisol process
    ## invocations does NOT reliably reuse objcache entries in this
    ## environment/toolchain -- a property of the objkey/objcache key
    ## derivation (out of this slice's scope; the RFC's own doc calls out a
    ## "known first-wave dedup gap"). Two DIFFERENT entrypoints that share
    ## compiled runtime units (system.nim/exceptions.nim/etc.), on the other
    ## hand, DO reliably hit -- this is the exact mechanism
    ## test_compileworker_real.nim's "real cross-entrypoint HIT" suite
    ## already proves at the worker level; this test drives the SAME
    ## mechanism through the real CLI's --objcache flag, mirroring
    ## test_objcache_gate.nim's own "run twice" pattern with pass_always.nim
    ## then fail_always.nim (both trivial fixtures, no extra compile flags
    ## needed): run 1 is a cold cache (all misses/stores); run 2's DIFFERENT
    ## entrypoint hits the runtime units run 1 already stored.
    let stateDir = freshStateDir("r5b_report")
    defer: removeDir(stateDir)

    let (exitCode1, output1) = runCrisolObjCache(stateDir)
    check exitCode1 == 0
    if exitCode1 != 0: echo "crisol run 1 output:\n", output1

    let (exitCode2, output2) = runCrisolObjCache(stateDir,
      epPath = "tests" / "fixtures" / "fail_always.nim")
    # fail_always.nim genuinely fails at runtime (exit 1) -- unrelated to
    # compile/objcache correctness; the compile itself still succeeds.
    check exitCode2 == 1
    if exitCode2 != 1: echo "crisol run 2 output:\n", output2

    let lastRunPath = stateDir / "lastrun.json"
    check fileExists(lastRunPath)
    let doc = parseJson(readFile(lastRunPath))
    check doc["schemaRevision"].getInt == 11

    check doc.hasKey("compile")
    check doc["compile"].hasKey("objcache")
    let oc = doc["compile"]["objcache"]

    check oc["hits"].getInt > 0
    check oc["hitRate"].getFloat > 0.0
    check oc["reusedBytes"].getBiggestInt > 0
    check oc["cacheSizeBytes"].getBiggestInt > 0
    check oc.hasKey("note")
    check oc["note"].getStr.len > 0
    check oc["segments"].kind == JArray
    check oc["segments"].len >= 1
    for seg in oc["segments"]:
      check seg["groupId"].getStr.len > 0
      check seg["hitRate"].getFloat >= 0.0
      check seg["hitRate"].getFloat <= 1.0

    echo "R5b sample compile.objcache node:\n", $oc

  test "RAW Config-level (bypasses api.planImpl): objCache AND measureCompileReuse BOTH true, workerBinary set -> the CACHE worker STILL dispatches at this low level (runner.nim's own literal branch order is unchanged by the Issue-1 fix)":
    ## Renamed from the original "R14-T1" title (see the CLI-driven test
    ## below, which keeps that name and now asserts the OPPOSITE outcome).
    ##
    ## Issue-1 fix (measurement starved by default-on objcache): the actual
    ## precedence inversion (measure now wins over objcache) is implemented
    ## at the RESOLUTION layer -- api.planImpl suppresses cfg.objCache to
    ## false whenever cfg.measureCompileReuse is true, BEFORE Config ever
    ## reaches runner.spawnCompileStable -- deliberately WITHOUT touching
    ## spawnCompileStable's own branch order (still objCache-checked first;
    ## see runner.nim). THIS test builds `cfg` directly and calls
    ## plan()/execute() -- it bypasses api.planImpl entirely, so it never
    ## goes through that suppression. It is intentionally exercising
    ## runner.nim's literal, unsuppressed Config-level contract in
    ## isolation (as its own original comment said: "proves the seam
    ## itself... independent of the CLI") -- a contract that is simply
    ## undefined/unspecified for a caller who hands it a contradictory
    ## Config directly, bypassing the one place (api.planImpl) that resolves
    ## the contradiction. Real callers (the CLI, api.runTests/planTests)
    ## NEVER construct Config this way -- see the CLI-driven R14-T1 test
    ## immediately below for the precedence that actually reaches users.
    ##
    ## Observable proof strategy unchanged from the original: a populated
    ## objcache/v1/ dir PLUS a completely empty COMPILE-COST ledger is the
    ## observable proof that the cache worker (not the measure worker) was
    ## the slot's compile child at this raw level.
    let stateDir = freshStateDir("both_flags")
    defer: removeDir(stateDir)

    let ep = mkEp()
    var cfg = makeConfig(stateDir, objCache = true)
    cfg.measureCompileReuse = true
    cfg.workerBinary = crisolBin

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, "", false)
    let results = execute(p, config = cfg, graph = graph, nimVersion = "", showProgress = false)

    check results.len == 1
    check results[0].outcome == oPassed

    check objCacheDirPopulated(stateDir)             # cache worker ran
    check scanCompileCostLedger(stateDir).len == 0    # measure worker did NOT run

  test "R14-T1 (code review, INVERTED by the Issue-1 fix): --objcache --measure-compile-reuse together via the real CLI -> the MEASURE worker now wins; objcache/v1/ stays empty, compile-cost ledger is populated":
    ## Was: "objCache precedence ... objcache/v1/ populated, compile-cost
    ## ledger stays empty" -- that was PRECISELY the Issue-1 regression
    ## (default-on objCache starving --measure-compile-reuse of its own
    ## worker). This is the realistic, USER-FACING path (real CLI ->
    ## crisol.nim's runMain -> api.runTests -> planImpl), where the Issue-1
    ## fix's suppression (`cfg.objCache = resolveObjCache(...) and not
    ## cfg.measureCompileReuse`, api.nim planImpl) actually applies: measurement
    ## is an explicit diagnostic that REPLACES caching for the run it's
    ## requested on, so it must win when both are requested together.
    ## Contrast with the RAW Config-level test above, which bypasses
    ## planImpl entirely and therefore still observes runner.nim's
    ## unsuppressed, objCache-first literal branch order.
    let stateDir = freshStateDir("both_flags_cli")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolObjCache(stateDir, @["--measure-compile-reuse"])
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check not objCacheDirPopulated(stateDir)      # cache worker never ran
    check scanCompileCostLedger(stateDir).len > 0  # measure worker did run

    # Both flags were EXPLICITLY passed on the CLI -> the contradictory-
    # flags ConfigWarning (api.planImpl, Issue-1 fix) should be visible on
    # stderr (captured into `output` via poStdErrToStdOut).
    check "measure-compile-reuse" in output and "objcache" in output.toLowerAscii

  test "--no-objcache overrides --objcache: monolithic path taken, objcache/ never created":
    let stateDir = freshStateDir("no_objcache_wins")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolObjCache(stateDir, @["--no-objcache"])
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check not dirExists(stateDir / "objcache")

  test "--no-objcache ALONE (RFC-0006 default-on flip: no --objcache flag to 'override' -- --no-objcache must win against the now-implicit default-on, not just against an explicit --objcache) -> monolithic path taken, objcache/ never created":
    let stateDir = freshStateDir("no_objcache_alone")
    defer: removeDir(stateDir)

    let (exitCode, output) = runCrisolNoExplicitFlag(stateDir, @["--no-objcache"])
    check exitCode == 0
    if exitCode != 0: echo "crisol run output:\n", output

    check not dirExists(stateDir / "objcache")

when isMainModule:
  echo "All objcache gate tests passed."
