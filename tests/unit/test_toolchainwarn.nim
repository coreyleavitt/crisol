## test_toolchainwarn.nim -- the toolchain verdict a user reads, one case per
## `ToolchainVerdict` arm.
##
## `toolchainWarning(fp)` returns `none` exactly when the toolchain can key the
## result cache, and otherwise the one line runcore.nim prints (and runs with the
## cache off). Each arm is pinned by a marker phrase only its message carries,
## plus what every message owes a reader: what happened (nothing cached this
## run), the cause when the probe recorded one, the remedy, and no internal
## identifier.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_toolchainwarn.nim

import std/[options, strutils, tables, unittest]
import crisol/[ccidentity, toolchainwarn, toolrun, types]
import "../support/ccfake"

const
  MarkCompiler  = "C compiler Nim is configured to use could not be identified"
  MarkRuntime   = "C runtime library the configured compiler links"
  MarkBlind     = "could not be identified at all"
  AllMarks      = [MarkCompiler, MarkRuntime, MarkBlind]
  MarkNotCached = "nothing is cached for this run: no result is stored or looked up"
  MarkRemedy    = "Caching resumes once"

let sound = fpOf(SoundFp)

proc warningFor(fp: CcFingerprint): string =
  let w = toolchainWarning(fp)
  doAssert w.isSome, "expected a warning for " & $toolchainVerdict(fp)
  w.get

template checkOnly(line: string; mark: string) =
  checkpoint("line = " & line)
  for m in AllMarks:
    if m == mark: check m in line
    else:         check m notin line
  check line.startsWith("warning: ")
  check MarkNotCached in line
  check MarkRemedy in line
  check "ccidentity" notin line
  check "CcFingerprint" notin line
  check "\n" notin line

suite "toolchainWarning -- one verdict per reason":

  test "sound: no warning (the cache stays on)":
    check toolchainVerdict(sound).kind == tvIdentified
    check toolchainWarning(sound).isNone

  test "upCompiler names the probe's cause":
    let f = msvcHost()
    f.macroReply = ran(2, "", "D8021")
    let fp = probe(f)
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upCompiler)
    let line = warningFor(fp)
    checkOnly(line, MarkCompiler)
    check "exited 2" in line

  test "upCompiler from a parsed sentinel: no empty cause":
    let line = warningFor(CcFingerprint(runtime: sound.runtime))
    checkOnly(line, MarkCompiler)
    check "()" notin line

  test "upRuntime names the probe's cause":
    let f = msvcHost()
    f.fileHex.del "C:\\msvc\\vc\\lib\\LIBCMT.lib"
    let fp = probe(f)
    check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upRuntime)
    let line = warningFor(fp)
    checkOnly(line, MarkRuntime)
    check "LIBCMT.lib" in line

  test "upBoth: discovery failed, the cause is named once":
    let f = msvcHost()
    f.discovery = Discovery(kind: dkNotFound, why: "nim exited 1")
    let line = warningFor(probe(f))
    checkOnly(line, MarkBlind)
    check line.count("nim exited 1") == 1

  test "upBoth: the zero-value fingerprint (never probed) fails closed":
    check toolchainVerdict(CcFingerprint()) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)
    checkOnly(warningFor(CcFingerprint()), MarkBlind)

  test "a warning is returned exactly when the toolchain is unsound":
    for fp in [sound, CcFingerprint(), CcFingerprint(compiler: sound.compiler),
               CcFingerprint(runtime: sound.runtime)]:
      check toolchainWarning(fp).isSome == (toolchainVerdict(fp).kind == tvUnidentified)

proc nonces(values: varargs[string]): (NonceProc, ref int) =
  ## A drawer handing out `values` in order, and how many it handed out.
  let drawn = new int
  let vs = @values
  let f = proc(): string =
    result = vs[drawn[]]
    inc drawn[]
  (f, drawn)

suite "toolchainIdentity -- an unidentified toolchain never compares equal":

  test "an identified toolchain is its serialized fingerprint, and draws no nonce":
    let (draw, drawn) = nonces("n1", "n2")
    check toolchainIdentity(sound, draw) == $sound
    check toolchainIdentity(sound, draw) == $sound
    check drawn[] == 0

  test "an unidentified toolchain differs run to run, and from its serialized form":
    for fp in [CcFingerprint(), CcFingerprint(compiler: sound.compiler),
               CcFingerprint(runtime: sound.runtime)]:
      checkpoint($toolchainVerdict(fp))
      let (draw, drawn) = nonces("n1", "n2")
      let a = toolchainIdentity(fp, draw)
      let b = toolchainIdentity(fp, draw)
      check drawn[] == 2
      check a != b
      check a != $fp
      check b != $fp
      check a.startsWith($fp)

  test "an unidentified toolchain whose drawer returns no nonce is refused":
    let (draw, _) = nonces("")
    expect AssertionDefect:
      discard toolchainIdentity(CcFingerprint(), draw)

suite "RunToolchain -- one run's probe and the identity keyed on it (R12-D4)":

  let site = DriverSite(known: false, why: "no discovery in this test")

  test "runToolchain keys an identified probe on its fingerprint":
    let (draw, drawn) = nonces("n1")
    let t = runToolchain(ToolchainProbe(fp: sound, site: site), draw)
    check t.identity == $sound
    check t.probe.fp == sound
    check not t.site.known
    check drawn[] == 0

  test "runToolchain draws one nonce for an unidentified probe":
    let (draw, drawn) = nonces("n1", "n2")
    let t = runToolchain(ToolchainProbe(fp: CcFingerprint(), site: site), draw)
    check drawn[] == 1
    check t.identity == toolchainIdentity(CcFingerprint(), nonces("n1")[0])
    check t.identity != $CcFingerprint()

  test "unkeyed keys nothing and keeps the site":
    let t = unkeyed(site)
    check t.identity == ""
    check toolchainVerdict(t.probe.fp).kind == tvUnidentified
    check t.site.why == "no discovery in this test"

  test "the zero value keys nothing: every reading of it refuses (R15-D4)":
    # R15-D4: `RunToolchain()` compiles outside this module. Read as a
    # value it was `unkeyed` with an unknown site, a key no caller chose.
    let zero = RunToolchain()
    expect AssertionDefect: discard zero.identity
    expect AssertionDefect: discard zero.probe
    expect AssertionDefect: discard zero.site
    var declared: RunToolchain
    expect AssertionDefect: discard declared.identity

suite "cacheGate -- the run's cache decision, one row per input combination":

  let blind = CcFingerprint()
  let noCompiler = CcFingerprint(runtime: sound.runtime)
  let noRuntime = CcFingerprint(compiler: sound.compiler)

  type Row = tuple[noCache, degraded: bool; fp: CcFingerprint;
                   on: bool; reason: CacheDecision; warns: bool]
  let rows: seq[Row] = @[
    (false, false, sound,      true,  cdmNotEligible,           false),
    (true,  false, sound,      false, cdmPolicyDisabled,        false),
    (false, true,  sound,      false, cdmRootsDegraded,         false),
    (true,  true,  sound,      false, cdmPolicyDisabled,        false),
    (false, false, blind,      false, cdmToolchainUnidentified, true),
    (false, false, noCompiler, false, cdmToolchainUnidentified, true),
    (false, false, noRuntime,  false, cdmToolchainUnidentified, true),
    (true,  false, blind,      false, cdmPolicyDisabled,        true),
    (false, true,  blind,      false, cdmToolchainUnidentified, true),
    (true,  true,  noRuntime,  false, cdmPolicyDisabled,        true),
  ]

  test "every row":
    for r in rows:
      checkpoint("noCache=" & $r.noCache & " degraded=" & $r.degraded &
                 " toolchain=" & $toolchainVerdict(r.fp))
      let g = cacheGate(r.noCache, r.degraded, r.fp)
      check (g.kind == cgOn) == r.on
      if g.kind == cgOff:
        check g.reason == r.reason
      check g.warning.isSome == r.warns
      check g.warning == toolchainWarning(r.fp)

  test "degraded roots never read as the --no-cache flag":
    let g = cacheGate(false, true, sound)
    check g.kind == cgOff
    check g.reason != cdmPolicyDisabled
