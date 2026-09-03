## test_sandbox.nim — A3 unit tests for SandboxSpec resolution
##
## Covers:
##   1. hlIsolated → envScrub=true, tmpdir=true, rlimits=true, netIso=false
##   2. hlNone → all false, empty allowlist
##   3. hlNetwork → superset of isolated, netIso=true
##   4. Default allowlist contains expected vars (PATH, HOME, USER, LOGNAME, LANG,
##      TERM, TZ, TMPDIR, NIMBLE_DIR, NIM_CONFIG_DIR)
##   5. LC_* prefix matches LC_ALL, LC_CTYPE but not GOPATH
##   6. Passthroughs deduplicated and in deterministic order
##   7. chdirIntoScratch defaults false; enabled when requested
##   8. RLIMIT_AS and RLIMIT_CPU default to none(int64)

import std/[sequtils, unittest, options]
import crisol/[types, sandbox]
import crisol/api
import crisol/process/types  ## unqualified Limits/LimitKind (rfc-0007 A2a-iii)

# ---------------------------------------------------------------------------
# 1. hlIsolated sets envScrub=true, tmpdir=true, rlimits=true, netIso=false
# ---------------------------------------------------------------------------

suite "sandbox — hlIsolated baseline":

  test "hlIsolated sets envScrub=true, tmpdir=true, rlimits=true, netIso=false":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.envScrub == true
    check spec.tmpdir   == true
    check spec.rlimits  == true
    check spec.netIso   == false

# ---------------------------------------------------------------------------
# 2. hlNone → all false, empty allowlist
# ---------------------------------------------------------------------------

suite "sandbox — hlNone":

  test "hlNone produces all-false flags and empty allowlist":
    let spec = resolveSandbox(level = hlNone)
    check spec.envScrub == false
    check spec.tmpdir   == false
    check spec.rlimits  == false
    check spec.netIso   == false
    check spec.envAllowlist         == newSeq[string]()
    check spec.envAllowlistPrefixes == newSeq[string]()

# ---------------------------------------------------------------------------
# 3. hlNetwork → superset of isolated, netIso=true
# ---------------------------------------------------------------------------

suite "sandbox — hlNetwork":

  test "hlNetwork is superset of isolated with netIso=true":
    let spec = resolveSandbox(level = hlNetwork)
    check spec.envScrub == true
    check spec.tmpdir   == true
    check spec.rlimits  == true
    check spec.netIso   == true

# ---------------------------------------------------------------------------
# 4. Default allowlist contains expected vars
# ---------------------------------------------------------------------------

suite "sandbox — default allowlist":

  test "default allowlist contains PATH, HOME, USER, LOGNAME, LANG, TERM, TZ, TMPDIR":
    let spec = resolveSandbox(level = hlIsolated)
    for v in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TZ", "TMPDIR"]:
      check v in spec.envAllowlist

  test "default allowlist contains NIMBLE_DIR, NIM_CONFIG_DIR":
    let spec = resolveSandbox(level = hlIsolated)
    check "NIMBLE_DIR"      in spec.envAllowlist
    check "NIM_CONFIG_DIR"  in spec.envAllowlist

  test "DefaultEnvAllowlist constant contains the same base vars":
    for v in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TERM", "TZ",
              "TMPDIR", "NIMBLE_DIR", "NIM_CONFIG_DIR"]:
      check v in DefaultEnvAllowlist

# ---------------------------------------------------------------------------
# 5. LC_* prefix matches LC_ALL, LC_CTYPE but not GOPATH
# ---------------------------------------------------------------------------

suite "sandbox — LC_* prefix matching":

  test "LC_* prefix matches LC_ALL and LC_CTYPE":
    let spec = resolveSandbox(level = hlIsolated)
    check "LC_" in spec.envAllowlistPrefixes

  test "default allowlist does not contain GOPATH (non-LC_ var)":
    let spec = resolveSandbox(level = hlIsolated)
    check "GOPATH" notin spec.envAllowlist
    check "GOPATH" notin spec.envAllowlistPrefixes

# ---------------------------------------------------------------------------
# 6. Passthroughs deduplicated, deterministic order
# ---------------------------------------------------------------------------

suite "sandbox — passthrough deduplication":

  test "duplicate passthroughs are deduplicated":
    let spec = resolveSandbox(
      level       = hlIsolated,
      passthroughs = @["FOO", "BAR", "FOO", "BAR"],
    )
    let fooCount = spec.envAllowlist.filterIt(it == "FOO").len
    let barCount = spec.envAllowlist.filterIt(it == "BAR").len
    check fooCount == 1
    check barCount == 1

  test "allowlist order is deterministic (sorted)":
    let spec1 = resolveSandbox(
      level        = hlIsolated,
      passthroughs = @["ZEBRA", "ALPHA"],
    )
    let spec2 = resolveSandbox(
      level        = hlIsolated,
      passthroughs = @["ALPHA", "ZEBRA"],
    )
    check spec1.envAllowlist == spec2.envAllowlist

# ---------------------------------------------------------------------------
# 7. chdirIntoScratch defaults false, enabled when requested
# ---------------------------------------------------------------------------

suite "sandbox — chdirIntoScratch":

  test "chdirIntoScratch defaults to false":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.chdirIntoScratch == false

  test "chdirIntoScratch=true when requested":
    let spec = resolveSandbox(level = hlIsolated, chdirIntoScratch = true)
    check spec.chdirIntoScratch == true

# ---------------------------------------------------------------------------
# 8. RLIMIT_AS and RLIMIT_CPU default to none(int64)
# ---------------------------------------------------------------------------

suite "sandbox — rlimit defaults":

  test "RLIMIT_AS defaults to none(int64)":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkAddressSpace].isNone

  test "RLIMIT_CPU defaults to none(int64)":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkCpu].isNone

  test "RLIMIT_FSIZE has a safe non-none default":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkFileSize].isSome

  test "RLIMIT_NOFILE has a safe non-none default":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkOpenFiles].isSome

  test "RLIMIT_CORE defaults to some(0) (disable core dumps)":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkCore] == some(0'i64)

  test "hlNone limits.req fields are all none":
    let spec = resolveSandbox(level = hlNone)
    check spec.limits == Limits()

# ---------------------------------------------------------------------------
# 9. RlimitOverrides bundle (L13): named-field override → limits.req
# ---------------------------------------------------------------------------

suite "sandbox — RlimitOverrides bundle":

  test "default RlimitOverrides() leaves RFC defaults intact":
    let spec = resolveSandbox(level = hlIsolated, rlimits = RlimitOverrides())
    check spec.limits.req[lkAddressSpace].isNone
    check spec.limits.req[lkCpu].isNone
    check spec.limits.req[lkFileSize].isSome
    check spec.limits.req[lkOpenFiles].isSome
    check spec.limits.req[lkCore] == some(0'i64)

  test "each named override lands in the matching limits.req field":
    let spec = resolveSandbox(
      level   = hlIsolated,
      rlimits = RlimitOverrides(
        limitAs:     some(7'i64),
        limitCpu:    some(8'i64),
        limitFsize:  some(9'i64),
        limitNofile: some(10'i64),
        limitCore:   some(11'i64),
      ),
    )
    check spec.limits.req[lkAddressSpace] == some(7'i64)
    check spec.limits.req[lkCpu]          == some(8'i64)
    check spec.limits.req[lkFileSize]     == some(9'i64)
    check spec.limits.req[lkOpenFiles]    == some(10'i64)
    check spec.limits.req[lkCore]         == some(11'i64)

# ---------------------------------------------------------------------------
# 10. RunOptions.hermeticLevel → resolved SandboxSpec.level (L14)
# ---------------------------------------------------------------------------

suite "sandbox — RunOptions.hermeticLevel wiring":

  test "RunOptions default hermeticLevel is hlIsolated":
    check RunOptions().hermeticLevel == hlIsolated

  test "each RunOptions.hermeticLevel resolves to the matching spec level":
    for lvl in [hlNone, hlIsolated, hlNetwork]:
      let opts = RunOptions(hermeticLevel: lvl)
      let spec = resolveSandbox(level = opts.hermeticLevel)
      check spec.level == lvl

  test "hlNone via RunOptions disables scrub + rlimits":
    let opts = RunOptions(hermeticLevel: hlNone)
    let spec = resolveSandbox(level = opts.hermeticLevel)
    check spec.envScrub == false
    check spec.rlimits  == false

# ---------------------------------------------------------------------------
# 11. Fix 1 — RLIMIT_NOFILE default raised to 1024; Config override honored
# ---------------------------------------------------------------------------

suite "sandbox — Fix 1: RLIMIT_NOFILE default + Config override":

  test "DefaultRlimitNofile is 1024 (raised from the old 256, which starved real workloads)":
    check DefaultRlimitNofile == 1024'i64

  test "resolveSandbox with no override applies the new 1024 default":
    let spec = resolveSandbox(level = hlIsolated)
    check spec.limits.req[lkOpenFiles] == some(1024'i64)

  test "Config.rlimitNofile override is honored by the sandbox spec":
    ## Proves the Config -> RlimitOverrides -> SandboxSpec wiring end to end
    ## via the same rlimitOverridesFrom() helper production code (api.runTests)
    ## uses at its resolveSandbox call site.
    let cfg  = Config(rlimitNofile: some(4096'i64))
    let spec = resolveSandbox(level = hlIsolated, rlimits = rlimitOverridesFrom(cfg))
    check spec.limits.req[lkOpenFiles] == some(4096'i64)

  test "Config.rlimitNofile unset (none) falls back to the built-in 1024 default":
    let cfg  = Config()   # rlimitNofile defaults to none(int64)
    let spec = resolveSandbox(level = hlIsolated, rlimits = rlimitOverridesFrom(cfg))
    check spec.limits.req[lkOpenFiles] == some(1024'i64)

# ---------------------------------------------------------------------------
# 12. isFullyAchieved (rfc-0007 A2a-iii): per-limit gate, netIso always false
# ---------------------------------------------------------------------------

suite "sandbox — isFullyAchieved":

  proc allApplied(): LimitsAchieved =
    for k in LimitKind: result[k] = lsApplied

  test "every requested limit applied, netIso unrequested → true":
    let spec = resolveSandbox(level = hlIsolated)  # requests fsize/nofile/core
    check isFullyAchieved(spec, allApplied())

  test "a requested limit that read back lsFailed → false":
    let spec = resolveSandbox(level = hlIsolated)
    var achieved = allApplied()
    achieved[lkCore] = lsFailed
    check not isFullyAchieved(spec, achieved)

  test "an unrequested limit's status never matters":
    let spec = resolveSandbox(level = hlIsolated)  # lkAddressSpace/lkCpu unrequested
    var achieved = allApplied()
    achieved[lkAddressSpace] = lsFailed  # never requested — must not fail the gate
    achieved[lkCpu]          = lsNotRequested
    check isFullyAchieved(spec, achieved)

  test "netIso requested (hlNetwork) → always false, even with every limit applied":
    ## netIso is NEVER wired (never-goal, §5) — hlNetwork stays uncacheable
    ## until RFC-0008's observer exists (§6), matching the pre-A2a-iii
    ## behavior where SandboxAchieved.netIso was likewise never set.
    let spec = resolveSandbox(level = hlNetwork)
    check not isFullyAchieved(spec, allApplied())

  test "hlNone: nothing requested → true regardless of the achieved array":
    let spec = resolveSandbox(level = hlNone)
    check isFullyAchieved(spec, default(LimitsAchieved))
    check isFullyAchieved(spec, allApplied())

when isMainModule:
  echo "All sandbox tests passed."
