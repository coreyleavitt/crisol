## test_process_resultjson.nim — rfc-0007 A1a: resultjson.nim, the ONE owner
## of ProcessResult<->JSON both directions (§2).
##
## Reader posture: crisol's OWN reader (fromJson/fromJsonString here) must
## inhabit Nim enums to run the total derivation — an unparseable enum is a
## STRUCTURAL parse failure (-> future cache miss), never a default-valued
## lie. External readers tolerate unknown strings by construction (they are
## not typed Nim enums) — that asymmetry is this test's oracle: the SAME
## unknown-string input that an external jq/grep consumer would happily pass
## through must come back `none` from OUR reader.
import std/[json, options, unittest]
import crisol/process/types as ptypes
import crisol/process/resultjson

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc sampleResult(): ProcessResult =
  ProcessResult(
    exit: Exit(kind: ekSignaled, sig: 15, coreDumped: false),
    cause: Cause(by: cbRunner, reason: krTimeout, escalated: false),
    evidence: Evidence(
      killDomain: kdsProcessGroup,
      tree: toUnobservable,
      escapees: @[ProcSnapshot(pid: 42, ppid: 1, command: "nim_c", rssBytes: 123456)],
      limits: default(LimitsAchieved),
      hermetic: hlIsolated,
      killSnapshot: @[ProcSnapshot(pid: 41, ppid: 1, command: "hang_forever", rssBytes: 4096)],
      cooperativeUnavailable: false,
    ),
    rusage: some(Rusage(maxRssBytes: 1000, userCpuUs: 200, sysCpuUs: 50)),
    durationUs: 5_000_000,
  )

# ---------------------------------------------------------------------------
# Roundtrip
# ---------------------------------------------------------------------------

suite "resultjson — roundtrip":

  test "full ProcessResult (killed, escapees, killSnapshot, rusage) roundtrips byte-equal":
    let r = sampleResult()
    let parsed = fromJson(toJson(r))
    check parsed.isSome
    check parsed.get == r

  test "ekExited / cbProcess / no rusage / no escapees roundtrips":
    let r = ProcessResult(
      exit: Exit(kind: ekExited, code: 0),
      cause: Cause(by: cbProcess),
      evidence: Evidence(killDomain: kdsProcessGroup, tree: toComplete, escapees: @[],
                          limits: default(LimitsAchieved), hermetic: hlNone,
                          killSnapshot: @[], cooperativeUnavailable: false),
      rusage: none(Rusage),
      durationUs: 42,
    )
    let parsed = fromJson(toJson(r))
    check parsed.isSome
    check parsed.get == r

  test "cbLimit(lkFileSize) roundtrips its LimitKind payload":
    let r = ProcessResult(
      exit: Exit(kind: ekSignaled, sig: 25, coreDumped: false),
      cause: Cause(by: cbLimit, limit: lkFileSize),
      evidence: Evidence(killDomain: kdsCgroup, tree: toComplete, escapees: @[],
                          limits: default(LimitsAchieved), hermetic: hlNetwork,
                          killSnapshot: @[], cooperativeUnavailable: true),
      rusage: none(Rusage),
      durationUs: 1,
    )
    let parsed = fromJson(toJson(r))
    check parsed.isSome
    check parsed.get == r

  test "ekNtStatus roundtrips the raw uint32":
    let r = ProcessResult(
      exit: Exit(kind: ekNtStatus, status: 0xC0000005'u32),
      cause: Cause(by: cbExternal),
      evidence: Evidence(killDomain: kdsJobObject, tree: toUnobservable, escapees: @[],
                          limits: default(LimitsAchieved), hermetic: hlIsolated,
                          killSnapshot: @[], cooperativeUnavailable: false),
      rusage: none(Rusage),
      durationUs: 1,
    )
    let parsed = fromJson(toJson(r))
    check parsed.isSome
    check parsed.get == r

  test "toJsonString / fromJsonString round trip through text":
    let r = sampleResult()
    let parsed = fromJsonString(toJsonString(r))
    check parsed.isSome
    check parsed.get == r

  test "enums serialize as strings on the wire":
    let node = toJson(sampleResult())
    check node["exit"]["kind"].kind == JString
    check node["exit"]["kind"].getStr == "signaled"
    check node["cause"]["by"].getStr == "runner"
    check node["evidence"]["tree"].getStr == "unobservable"
    check node["evidence"]["hermetic"].getStr == "isolated"

# ---------------------------------------------------------------------------
# Structural failure (crisol's own reader) — the fuzz test's oracle.
# ---------------------------------------------------------------------------

suite "resultjson — own-reader structural failure (fuzz oracle)":

  test "malformed JSON text -> none, never raises":
    check fromJsonString("{not json") == none(ProcessResult)
    check fromJsonString("") == none(ProcessResult)
    check fromJsonString("null") == none(ProcessResult)
    check fromJsonString("42") == none(ProcessResult)
    check fromJsonString("[]") == none(ProcessResult)

  test "missing required top-level key -> none":
    let good = toJson(sampleResult())
    for key in ["exit", "cause", "evidence", "durationUs"]:
      var n = copy(good)
      n.delete(key)
      check fromJson(n) == none(ProcessResult)

  test "unknown exit.kind string -> STRUCTURAL failure (none), not a default-valued lie":
    var n = copy(toJson(sampleResult()))
    n["exit"]["kind"] = newJString("ekBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown cause.by string -> none":
    var n = copy(toJson(sampleResult()))
    n["cause"]["by"] = newJString("cbBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown cause.reason string -> none":
    var n = copy(toJson(sampleResult()))
    n["cause"]["reason"] = newJString("krBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown evidence.killDomain string -> none":
    var n = copy(toJson(sampleResult()))
    n["evidence"]["killDomain"] = newJString("kdsBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown evidence.tree string -> none":
    var n = copy(toJson(sampleResult()))
    n["evidence"]["tree"] = newJString("toBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown evidence.hermetic string -> none":
    var n = copy(toJson(sampleResult()))
    n["evidence"]["hermetic"] = newJString("hlBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown cause.limit string (cbLimit variant) -> none":
    let r = ProcessResult(
      exit: Exit(kind: ekSignaled, sig: 24, coreDumped: false),
      cause: Cause(by: cbLimit, limit: lkCpu),
      evidence: Evidence(killDomain: kdsProcessGroup, tree: toUnobservable, escapees: @[],
                          limits: default(LimitsAchieved), hermetic: hlIsolated,
                          killSnapshot: @[], cooperativeUnavailable: false),
      rusage: none(Rusage),
      durationUs: 1,
    )
    var n = copy(toJson(r))
    n["cause"]["limit"] = newJString("lkBogus")
    check fromJson(n) == none(ProcessResult)

  test "unknown limits[] key in evidence.limits object -> none":
    var n = copy(toJson(sampleResult()))
    n["evidence"]["limits"] = newJObject()
    n["evidence"]["limits"]["addressSpace"] = newJString("lsBogus")
    check fromJson(n) == none(ProcessResult)

  test "wrong-typed field (exit.kind as int, not string) -> none":
    var n = copy(toJson(sampleResult()))
    n["exit"]["kind"] = newJInt(1)
    check fromJson(n) == none(ProcessResult)

  test "wrong-typed top level (exit as a string, not object) -> none":
    var n = copy(toJson(sampleResult()))
    n["exit"] = newJString("nope")
    check fromJson(n) == none(ProcessResult)

  test "escapees array with a malformed element -> none (never fabricates a partial seq)":
    var n = copy(toJson(sampleResult()))
    var badEscapee = newJObject()
    badEscapee["pid"] = newJString("not-an-int")
    n["evidence"]["escapees"] = newJArray()
    n["evidence"]["escapees"].add badEscapee
    check fromJson(n) == none(ProcessResult)

  test "property: every enum field, replaced with an unrecognized string in isolation, structurally fails":
    ## A small property sweep, not a sampled spot-check: for every enum-typed
    ## JSON leaf resultjson owns, substituting garbage fails closed.
    let paths = @[
      @["exit", "kind"],
      @["cause", "by"],
      @["evidence", "killDomain"],
      @["evidence", "tree"],
      @["evidence", "hermetic"],
    ]
    for path in paths:
      var n = copy(toJson(sampleResult()))
      var cursor = n
      for i in 0 ..< path.len - 1:
        cursor = cursor[path[i]]
      cursor[path[^1]] = newJString("__not_a_real_enum_value__")
      check fromJson(n) == none(ProcessResult)
