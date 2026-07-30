## test_compiledriver.nim — unit tests for compiledriver.nim (RFC-0006 M-driver).
##
## Two tiers:
##  - Suite A ("runMeasured — orchestration"): FULLY synthetic compileOnly/
##    runCc/link closures (instant-return, no subprocess at all) drive the
##    phase-sequencing / abort-on-failure logic in `runMeasured`.
##  - Suite B ("defaultRunCc — overlap-aware concurrency"): the REAL
##    `defaultRunCc` (which calls std/osproc.execProcesses, the same
##    primitive Nim's own compiler uses) driven with trivial, FAST shell
##    commands (`sleep 0.1`, `true`, `false`) — real but cheap subprocesses,
##    never a slow real `nim`/`cc` invocation, to prove the span-accounting
##    is genuinely overlap-aware (not summed durations).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_compiledriver.nim

import std/[options, os, osproc, strutils, tables, unittest]
import crisol/compiledriver
import crisol/objcache

# ---------------------------------------------------------------------------
# Suite A helpers — synthetic seam + a manifest fixture on disk (runMeasured
# reads the manifest for real via closure.parseCompileManifest; only the
# compileOnly/runCc/link EFFECTS are faked).
# ---------------------------------------------------------------------------

proc writeSyntheticManifest(nimcacheDir, binName: string) =
  createDir(nimcacheDir)
  let json = """
  {
    "compile": [
      ["/proj/nimcache/@pfoo.nim.c", "true"],
      ["/proj/nimcache/@mmain.nim.c", "true"]
    ],
    "linkcmd": "true"
  }
  """
  writeFile(nimcacheDir / binName & ".json", json)

let tmpRoot = getTempDir() / "crisol_test_compiledriver_" & $getCurrentProcessId()

# ---------------------------------------------------------------------------
# Suite A: runMeasured orchestration (fully synthetic seam)
# ---------------------------------------------------------------------------

suite "runMeasured — orchestration with injected synthetic procs":

  test "happy path: all three phases run, spans + per-unit cc times recorded":
    let nimcacheDir = tmpRoot / "happy"
    writeSyntheticManifest(nimcacheDir, "ep")

    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      check units.len == 2
      check units[0].basename == "@pfoo.nim.c"
      check units[1].basename == "@mmain.nim.c"
      RunCcResult(
        ok: true,
        ccSpanUs: 12345,
        units: @[
          CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 5000),
          CcUnitResult(basename: "@mmain.nim.c", ok: true, ccTimeUs: 9000),
        ])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      check linkCmd == "true"
      (ok: true, output: "")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check spans.ok
    check spans.errorMsg == ""
    check spans.codegenSpanUs >= 0
    check spans.ccSpanUs == 12345
    check spans.linkSpanUs >= 0
    check spans.ccUnitTimesUs["@pfoo.nim.c"] == 5000
    check spans.ccUnitTimesUs["@mmain.nim.c"] == 9000

  test "compileOnly failure aborts immediately: ok=false, no cc/link phase reached":
    var ccCalled, linkCalled = false
    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: false, output: "boom: syntax error")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      ccCalled = true
      RunCcResult(ok: true)
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      linkCalled = true
      (ok: true, output: "")

    # No manifest file written — compileOnly fails before it would ever be read.
    let spans = runMeasured(driver, "/proj/ep.nim", @[], tmpRoot / "co_fail", tmpRoot / "co_fail" / "ep")

    check not spans.ok
    check "compileOnly failed" in spans.errorMsg
    check "boom: syntax error" in spans.errorMsg
    check not ccCalled
    check not linkCalled
    check spans.ccUnitTimesUs.len == 0

  test "cc-phase failure aborts before link: ok=false, link never called, partial spans kept":
    let nimcacheDir = tmpRoot / "cc_fail"
    writeSyntheticManifest(nimcacheDir, "ep")

    var linkCalled = false
    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(
        ok: false,
        ccSpanUs: 777,
        units: @[
          CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 100),
          CcUnitResult(basename: "@mmain.nim.c", ok: false, ccTimeUs: 200),
        ])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      linkCalled = true
      (ok: true, output: "")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check not spans.ok
    check "cc phase failed" in spans.errorMsg
    check not linkCalled
    # Partial spans from the phases that DID complete are preserved, not fabricated for link.
    check spans.ccSpanUs == 777
    check spans.linkSpanUs == 0
    check spans.ccUnitTimesUs["@mmain.nim.c"] == 200

  test "link failure aborts: ok=false, but codegen+cc spans from completed phases are kept":
    let nimcacheDir = tmpRoot / "link_fail"
    writeSyntheticManifest(nimcacheDir, "ep")

    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(ok: true, ccSpanUs: 42,
                  units: @[CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 42)])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      (ok: false, output: "undefined reference to `main`")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check not spans.ok
    check "link failed" in spans.errorMsg
    check "undefined reference" in spans.errorMsg
    check spans.ccSpanUs == 42
    check spans.linkSpanUs == 0   # link never completed — no fabricated span

# ---------------------------------------------------------------------------
# Suite B: defaultRunCc — real (cheap) subprocesses prove overlap-awareness
# ---------------------------------------------------------------------------

suite "defaultRunCc — overlap-aware concurrency (real cheap subprocesses)":

  test "4 units of ~100ms each at concurrency 4 overlap: span << sum of durations":
    let units = @[
      (basename: "a.c", ccCmd: "sleep 0.1"),
      (basename: "b.c", ccCmd: "sleep 0.1"),
      (basename: "c.c", ccCmd: "sleep 0.1"),
      (basename: "d.c", ccCmd: "sleep 0.1"),
    ]
    let r = defaultRunCc(units, concurrency = 4)

    check r.ok
    check r.units.len == 4
    for u in r.units:
      check u.ok
      # Each unit's OWN wall time should be roughly one sleep, not 4.
      check u.ccTimeUs < 350_000    # generous ceiling well under 400ms (4x)

    # Overlap-aware: span should be close to ONE sleep (~100ms), never close
    # to the sequential sum (~400ms). Generous bound to absorb container jitter.
    check r.ccSpanUs < 300_000
    check r.ccSpanUs >= 90_000     # sanity: not suspiciously near-zero

  test "same 4 units at concurrency 1 run sequentially: span ~= sum of durations":
    let units = @[
      (basename: "a.c", ccCmd: "sleep 0.1"),
      (basename: "b.c", ccCmd: "sleep 0.1"),
      (basename: "c.c", ccCmd: "sleep 0.1"),
      (basename: "d.c", ccCmd: "sleep 0.1"),
    ]
    let r = defaultRunCc(units, concurrency = 1)

    check r.ok
    # Sequential: span should be close to the SUM (~400ms), clearly more than
    # the concurrency=4 case's ceiling above — proves concurrency is honored.
    check r.ccSpanUs >= 350_000

  test "a failing unit is reported per-unit and fails the overall phase":
    let units = @[
      (basename: "ok.c", ccCmd: "true"),
      (basename: "bad.c", ccCmd: "false"),
    ]
    let r = defaultRunCc(units, concurrency = 2)

    check not r.ok
    check r.units.len == 2
    var sawOk, sawBad = false
    for u in r.units:
      if u.basename == "ok.c":
        check u.ok
        sawOk = true
      elif u.basename == "bad.c":
        check not u.ok
        sawBad = true
    check sawOk and sawBad

  test "empty unit list: ok=true, zero span, no subprocess spawned":
    let r = defaultRunCc(@[])
    check r.ok
    check r.units.len == 0
    check r.ccSpanUs == 0

  test "default concurrency (unspecified) matches Nim's own default (countProcessors)":
    if countProcessors() < 2:
      skip()   # single-core CI runner: sequential IS the honest default here too
    else:
      let units = @[
        (basename: "a.c", ccCmd: "sleep 0.08"),
        (basename: "b.c", ccCmd: "sleep 0.08"),
      ]
      let r = defaultRunCc(units)   # concurrency NOT passed — uses the default
      check r.ok
      # If the default silently meant "concurrency=1" this would be >= 160ms.
      check r.ccSpanUs < 150_000

# ---------------------------------------------------------------------------
# Suite C: parseCcOutputObj — extract the -o object path from a cc command
# ---------------------------------------------------------------------------

suite "parseCcOutputObj — extracts the cc -o object-output path":

  test "space-separated '-o <path>' form":
    let ccCmd = "gcc -c -w -I/opt/nim/2.2.10/lib -o /cache/@pfoo.nim.c.o /cache/@pfoo.nim.c"
    check parseCcOutputObj(ccCmd) == "/cache/@pfoo.nim.c.o"

  test "concatenated '-o<path>' form":
    let ccCmd = "gcc -c -w -I/opt/nim/2.2.10/lib -o/cache/@pfoo.nim.c.o /cache/@pfoo.nim.c"
    check parseCcOutputObj(ccCmd) == "/cache/@pfoo.nim.c.o"

  test "no -o flag present: returns empty string":
    let ccCmd = "gcc -c -w /cache/@pfoo.nim.c"
    check parseCcOutputObj(ccCmd) == ""

  test "trailing '-o' with nothing after it: returns empty string, does not crash":
    let ccCmd = "gcc -c -w -o"
    check parseCcOutputObj(ccCmd) == ""

  test "review Finding 2: a shell-quoted '-o <path>' whose path contains a space returns the FULL path, not truncated at the space":
    ## Realistic under WSL2 / a mounted toolchain with a space in its path
    ## (e.g. `/mnt/c/Users/John Doe/proj`) -- nimcacheDir/outputBinPath
    ## inherit the space, so Nim shell-quotes the `-o` argument
    ## (`quoteShellPosix`) before this ccCmd string is ever generated. A
    ## naive `splitWhitespace()` corrupts this into "-o", "'/cache/John",
    ## losing everything after the space -- silently truncating the object
    ## path. `parseCcOutputObj` must tokenize shell-AWARE (via
    ## `artifactid.shellSplit`, same as `deriveCcMInvocation`) and return the
    ## complete path.
    let ccCmd = "gcc -c -w -I/opt/nim/lib -o '/cache/John Doe/@pfoo.nim.c.o' " &
                "'/cache/John Doe/@pfoo.nim.c'"
    check parseCcOutputObj(ccCmd) == "/cache/John Doe/@pfoo.nim.c.o"

  test "review Finding 2: an unterminated shell quote degrades to empty string, never crashes and never mis-tokenizes":
    let ccCmd = "gcc -c -w -o '/cache/unterminated /@pfoo.nim.c.o /cache/x.c"
    check parseCcOutputObj(ccCmd) == ""

# ---------------------------------------------------------------------------
# Suite D: newCacheDriver — cache-mode runCc (synthetic ObjCacheSeams +
# injected ccRunner; no real compiles).
# ---------------------------------------------------------------------------

let cacheTmpRoot = getTempDir() / "crisol_test_cachedriver_" & $getCurrentProcessId()

suite "newCacheDriver — cache-mode runCc: HIT path":

  test "a lookup HIT copies the cached object to objOut, records ocdHit, never invokes the ccRunner":
    let dir = cacheTmpRoot / "hit"
    createDir(dir)
    let cachedPath = dir / "cached.o"
    let objOut     = dir / "out.o"
    writeFile(cachedPath, "fake cached object bytes")

    var ccCalled = false
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      ccCalled = true
      RunCcResult(ok: true, units: @[])

    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] =
        check keyHash == "hhh"
        check keyPreimage == "ppp"
        some(cachedPath),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        fail() # must never be called on a HIT
        false,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "hhh", preimage: "ppp", objOutPath: objOut)

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "mod.nim.c", ccCmd: "gcc -c -o " & objOut & " mod.nim.c")]
    let res = driver.runCc(units)

    check res.ok
    check not ccCalled
    check readFile(objOut) == "fake cached object bytes"
    check res.units.len == 1
    check res.units[0].ok
    check res.units[0].ccTimeUs == 0
    check res.decisions.len == 1
    check res.decisions[0].basename == "mod.nim.c"
    check res.decisions[0].decision == ocdHit

suite "newCacheDriver — cache-mode runCc: MISS path":

  test "a lookup MISS runs the ccRunner, then stores the produced object; decision ocdStored on success":
    let dir = cacheTmpRoot / "miss_store"
    createDir(dir)
    let objOut = dir / "out.o"

    var lookupCalled = false
    var storeArgs: tuple[keyHash, preimage, objPath: string]
    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] =
        lookupCalled = true
        none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        storeArgs = (keyHash: keyHash, preimage: keyPreimage, objPath: objPath)
        true,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "hhh2", preimage: "ppp2", objOutPath: objOut)

    # Synthetic ccRunner: simulates a successful compile by writing objOut's
    # bytes itself (a real cc invocation would do this as a side effect).
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      check units.len == 1
      check units[0].basename == "mod.nim.c"
      writeFile(objOut, "freshly compiled object bytes")
      RunCcResult(ok: true, ccSpanUs: 999,
                  units: @[CcUnitResult(basename: "mod.nim.c", ok: true, ccTimeUs: 999)])

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "mod.nim.c", ccCmd: "gcc -c -o " & objOut & " mod.nim.c")]
    let res = driver.runCc(units)

    check lookupCalled
    check res.ok
    check res.ccSpanUs == 999
    check storeArgs.keyHash == "hhh2"
    check storeArgs.preimage == "ppp2"
    check storeArgs.objPath == objOut
    check res.decisions.len == 1
    check res.decisions[0].basename == "mod.nim.c"
    check res.decisions[0].decision == ocdStored

  test "a lookup MISS whose store is skipped (soft cap) records ocdMissCompiled, not ocdStored":
    let dir = cacheTmpRoot / "miss_nostore"
    createDir(dir)
    let objOut = dir / "out.o"

    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] = none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool = false,  # e.g. soft-cap skip
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "hhh3", preimage: "ppp3", objOutPath: objOut)
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      writeFile(objOut, "object bytes")
      RunCcResult(ok: true, ccSpanUs: 10,
                  units: @[CcUnitResult(basename: "mod.nim.c", ok: true, ccTimeUs: 10)])

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "mod.nim.c", ccCmd: "gcc -c -o " & objOut & " mod.nim.c")]
    let res = driver.runCc(units)

    check res.ok
    check res.decisions.len == 1
    check res.decisions[0].decision == ocdMissCompiled

suite "newCacheDriver — cache-mode runCc: MISS with failing cc":

  test "a nonzero-exit compile: unit ok=false, store NOT called, no decision recorded for it":
    let dir = cacheTmpRoot / "miss_fail"
    createDir(dir)
    let objOut = dir / "out.o"

    var storeCalled = false
    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] = none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        storeCalled = true
        true,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "hhh4", preimage: "ppp4", objOutPath: objOut)
    # Synthetic ccRunner: simulates a FAILED compile — no objOut bytes written,
    # unit reported ok=false (mirrors a nonzero/killed real cc exit).
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(ok: false, ccSpanUs: 50,
                  units: @[CcUnitResult(basename: "mod.nim.c", ok: false, ccTimeUs: 50)])

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "mod.nim.c", ccCmd: "gcc -c -o " & objOut & " mod.nim.c")]
    let res = driver.runCc(units)

    check not res.ok
    check not storeCalled
    check res.decisions.len == 0
    check res.units.len == 1
    check not res.units[0].ok
    check not fileExists(objOut)   # no truncated .o was ever produced/cached

suite "newCacheDriver — cache-mode runCc: non-cacheable unit (empty keyHash, R2b1)":

  test "a unit whose keyOf returns an empty keyHash is compiled via ccRunner, never looked up or stored; decision ocdDisabled":
    ## The entry .c must stay PRIVATE (RFC: "the entry .c + link stay
    ## private") — keyOf signals this by returning an empty keyHash for it.
    let dir = cacheTmpRoot / "noncacheable"
    createDir(dir)
    let objOut = dir / "out.o"

    var lookupCalled = false
    var storeCalled = false
    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] =
        lookupCalled = true
        none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        storeCalled = true
        true,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "", preimage: "", objOutPath: objOut)   # non-cacheable (e.g. the entry unit)

    var ccCalled = false
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      ccCalled = true
      check units.len == 1
      check units[0].basename == "@mentry.nim.c"
      writeFile(objOut, "entry object bytes")
      RunCcResult(ok: true, ccSpanUs: 5,
                  units: @[CcUnitResult(basename: "@mentry.nim.c", ok: true, ccTimeUs: 5)])

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "@mentry.nim.c", ccCmd: "gcc -c -o " & objOut & " @mentry.nim.c")]
    let res = driver.runCc(units)

    check res.ok
    check ccCalled
    check not lookupCalled
    check not storeCalled
    check res.units.len == 1
    check res.units[0].ok
    check res.decisions.len == 1
    check res.decisions[0].basename == "@mentry.nim.c"
    check res.decisions[0].decision == ocdDisabled

  test "a nonzero-exit compile of a non-cacheable unit: unit ok=false, no decision recorded, store never called":
    let dir = cacheTmpRoot / "noncacheable_fail"
    createDir(dir)
    let objOut = dir / "out.o"

    var storeCalled = false
    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] = none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        storeCalled = true
        true,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      (keyHash: "", preimage: "", objOutPath: objOut)
    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(ok: false, ccSpanUs: 3,
                  units: @[CcUnitResult(basename: "@mentry.nim.c", ok: false, ccTimeUs: 3)])

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[(basename: "@mentry.nim.c", ccCmd: "gcc -c -o " & objOut & " @mentry.nim.c")]
    let res = driver.runCc(units)

    check not res.ok
    check not storeCalled
    check res.decisions.len == 0
    check res.units.len == 1
    check not res.units[0].ok

  test "a mix of one cacheable-miss unit and one non-cacheable unit: only the cacheable one is looked up/stored":
    let dir = cacheTmpRoot / "mixed"
    createDir(dir)
    let objOutCacheable    = dir / "cacheable.o"
    let objOutNonCacheable = dir / "noncacheable.o"

    var lookupCalls: seq[string]
    var storeCalls: seq[string]
    let seams = ObjCacheSeams(
      lookup: proc(keyHash, keyPreimage: string): Option[string] =
        lookupCalls.add keyHash
        none(string),
      store: proc(keyHash, keyPreimage, objPath: string): bool =
        storeCalls.add keyHash
        true,
    )
    let keyOf = proc(unit: CompileUnit): tuple[keyHash, preimage, objOutPath: string] =
      if unit.basename == "@mentry.nim.c":
        (keyHash: "", preimage: "", objOutPath: objOutNonCacheable)
      else:
        (keyHash: "hhh5", preimage: "ppp5", objOutPath: objOutCacheable)

    let ccRunner = proc(units: seq[CompileUnit]): RunCcResult =
      var unitResults: seq[CcUnitResult]
      for u in units:
        if u.basename == "@mentry.nim.c":
          writeFile(objOutNonCacheable, "entry bytes")
        else:
          writeFile(objOutCacheable, "reusable bytes")
        unitResults.add CcUnitResult(basename: u.basename, ok: true, ccTimeUs: 1)
      RunCcResult(ok: true, ccSpanUs: 2, units: unitResults)

    let driver = newCacheDriver(seams, keyOf, ccRunner = ccRunner)
    let units = @[
      (basename: "@preusable.nim.c", ccCmd: "gcc -c -o " & objOutCacheable & " @preusable.nim.c"),
      (basename: "@mentry.nim.c", ccCmd: "gcc -c -o " & objOutNonCacheable & " @mentry.nim.c"),
    ]
    let res = driver.runCc(units)

    check res.ok
    check lookupCalls == @["hhh5"]   # never consulted for the non-cacheable unit
    check storeCalls == @["hhh5"]    # never stored for the non-cacheable unit
    check res.decisions.len == 2
    var decisionByBasename: Table[string, ObjCacheDecision]
    for d in res.decisions:
      decisionByBasename[d.basename] = d.decision
    check decisionByBasename["@preusable.nim.c"] == ocdStored
    check decisionByBasename["@mentry.nim.c"] == ocdDisabled

# ---------------------------------------------------------------------------
# Suite E: runMeasured surfaces RunCcResult.decisions onto CompileSpans
# (RFC-0006 Stage R, R5a) — ADDITIVE: measure-mode callers (defaultRunCc/
# newMeasureDriver never populate decisions) see an empty seq, unaffected.
# ---------------------------------------------------------------------------

suite "runMeasured — surfaces cache decisions onto CompileSpans (R5a)":

  test "success path: a cache-mode driver's decisions are copied onto CompileSpans.decisions":
    let nimcacheDir = tmpRoot / "decisions_success"
    writeSyntheticManifest(nimcacheDir, "ep")

    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(
        ok: true,
        ccSpanUs: 100,
        units: @[
          CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 10),
          CcUnitResult(basename: "@mmain.nim.c", ok: true, ccTimeUs: 20),
        ],
        decisions: @[
          (basename: "@pfoo.nim.c", decision: ocdHit),
          (basename: "@mmain.nim.c", decision: ocdDisabled),
        ])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      (ok: true, output: "")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check spans.ok
    check spans.decisions.len == 2
    var byBasename: Table[string, ObjCacheDecision]
    for d in spans.decisions:
      byBasename[d.basename] = d.decision
    check byBasename["@pfoo.nim.c"] == ocdHit
    check byBasename["@mmain.nim.c"] == ocdDisabled

  test "cc-phase failure early-return: decisions collected so far are still surfaced":
    let nimcacheDir = tmpRoot / "decisions_cc_fail"
    writeSyntheticManifest(nimcacheDir, "ep")

    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      RunCcResult(
        ok: false,
        ccSpanUs: 50,
        units: @[
          CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 10),
          CcUnitResult(basename: "@mmain.nim.c", ok: false, ccTimeUs: 40),
        ],
        decisions: @[(basename: "@pfoo.nim.c", decision: ocdStored)])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      fail() # must never be reached — cc phase already failed
      (ok: true, output: "")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check not spans.ok
    check spans.decisions.len == 1
    check spans.decisions[0].basename == "@pfoo.nim.c"
    check spans.decisions[0].decision == ocdStored

  test "measure-mode driver (RunCcResult with no decisions set) leaves CompileSpans.decisions empty":
    let nimcacheDir = tmpRoot / "decisions_measure_mode"
    writeSyntheticManifest(nimcacheDir, "ep")

    var driver: CompileDriver
    driver.compileOnly = proc(entrypoint: string; flags: seq[string];
                              nimcacheDir, outputBinPath: string):
                                tuple[ok: bool; output: string] =
      (ok: true, output: "")
    driver.runCc = proc(units: seq[CompileUnit]): RunCcResult =
      # A measure-mode-shaped result: no `decisions` field populated at all.
      RunCcResult(
        ok: true,
        ccSpanUs: 30,
        units: @[
          CcUnitResult(basename: "@pfoo.nim.c", ok: true, ccTimeUs: 15),
          CcUnitResult(basename: "@mmain.nim.c", ok: true, ccTimeUs: 15),
        ])
    driver.link = proc(linkCmd: string): tuple[ok: bool; output: string] =
      (ok: true, output: "")

    let spans = runMeasured(driver, "/proj/ep.nim", @[], nimcacheDir, nimcacheDir / "ep")

    check spans.ok
    check spans.decisions.len == 0

when isMainModule:
  echo "All compiledriver tests passed."
