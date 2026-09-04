## test_a0_env_pin.nim — RFC-0005 A0: env-pin's two load-bearing properties.
##
##   1. filterEnv's tail: a pin reaches the child env regardless of the
##      host's own value for that name, and CRISOL_CACHE_* is stripped
##      unconditionally (envScrub true OR false, even if allowlisted).
##   2. Key-portability invariance (the RFC's named load-bearing property):
##      realSeams' keyOf is invariant under {stateDir, projectRoot/cwd
##      context, TMPDIR value, a pinned variable's host value} and VARIES
##      when an unpinned allowlisted env variable's value changes.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/test_a0_env_pin.nim

import std/[os, strutils, unittest]
import crisol/[types, sandbox, cachedispatch, depgraph]

# ---------------------------------------------------------------------------
# 1a — filterEnv injects a pin, overriding the host's own value.
# ---------------------------------------------------------------------------

suite "A0 — filterEnv: envPins reach the child env":

  test "a pin overrides the host's own value for that name":
    let spec = resolveSandbox(hlIsolated, envPins = @[("USER", "ci-pinned-user")])
    let parentEnv = @[("HOME", "/root"), ("USER", "alice"), ("PATH", "/usr/bin")]
    let result = filterEnv(parentEnv, spec, @[])
    var seen = ""
    var found = false
    for (k, v) in result:
      if k == "USER":
        seen = v
        found = true
    check found
    check seen == "ci-pinned-user"

  test "a pin reaches the child even when NOT on the allowlist":
    let spec = resolveSandbox(hlIsolated, envPins = @[("MY_CUSTOM_PIN", "pinned")])
    let parentEnv = @[("HOME", "/root")]
    let result = filterEnv(parentEnv, spec, @[])
    var found = false
    for (k, v) in result:
      if k == "MY_CUSTOM_PIN":
        check v == "pinned"
        found = true
    check found

  test "a pin applies even under hlNone (envScrub == false)":
    let spec = resolveSandbox(hlNone, envPins = @[("USER", "ci-pinned-user")])
    let parentEnv = @[("HOME", "/root"), ("USER", "alice")]
    let result = filterEnv(parentEnv, spec, @[])
    var seen = ""
    for (k, v) in result:
      if k == "USER": seen = v
    check seen == "ci-pinned-user"

  test "runner-internal injected pairs win over a same-named pin":
    ## Protects the runner's own control vars (CRISOL_SINK/CRISOL_ATTEMPT/
    ## TMPDIR) from being clobbered by a misconfigured --env-pin.
    let spec = resolveSandbox(hlIsolated, envPins = @[("TMPDIR", "user-pinned-tmp")])
    let parentEnv = @[("HOME", "/root")]
    let result = filterEnv(parentEnv, spec, @[("TMPDIR", "runner-scratch-dir")])
    var seen = ""
    for (k, v) in result:
      if k == "TMPDIR": seen = v
    check seen == "runner-scratch-dir"

# ---------------------------------------------------------------------------
# 1b — CRISOL_CACHE_* is stripped unconditionally.
# ---------------------------------------------------------------------------

suite "A0 — filterEnv: CRISOL_CACHE_* stripped unconditionally":

  test "stripped under envScrub == true, even when explicitly allowlisted":
    var spec = resolveSandbox(hlIsolated)
    spec.envAllowlist.add "CRISOL_CACHE_TOKEN"
    let parentEnv = @[("CRISOL_CACHE_TOKEN", "secret123"), ("HOME", "/root")]
    let result = filterEnv(parentEnv, spec, @[])
    for (k, _) in result:
      check not k.startsWith("CRISOL_CACHE_")

  test "stripped under envScrub == false (hlNone pass-through)":
    let spec = resolveSandbox(hlNone)
    let parentEnv = @[("CRISOL_CACHE_TOKEN", "secret123"), ("HOME", "/root")]
    let result = filterEnv(parentEnv, spec, @[])
    for (k, _) in result:
      check not k.startsWith("CRISOL_CACHE_")

  test "stripped even if pinned directly (an operator cannot un-strip it)":
    let spec = resolveSandbox(hlIsolated, envPins = @[("CRISOL_CACHE_TOKEN", "leaked")])
    let result = filterEnv(@[], spec, @[])
    for (k, _) in result:
      check not k.startsWith("CRISOL_CACHE_")

# ---------------------------------------------------------------------------
# 2 — key-portability invariance (RFC-0005 A0, load-bearing).
# ---------------------------------------------------------------------------
#
# keyOf (realSeams' returned KeyOfProc) must be INVARIANT under:
#   - stateDir            (realSeams param; keyOf's closure never reads it —
#                          only load/store do)
#   - projectRoot / cwd    (realSeams takes neither as a parameter at all;
#                          slug()/binName() — planner.nim — are pure functions
#                          of ep.path/ep.flags with no getCurrentDir() call,
#                          so the process's cwd cannot reach the key. Proven
#                          below by actually calling keyOf from two different
#                          working directories.)
#   - TMPDIR's value       (hermeticEnvHash hashes TMPDIR's NAME only)
#   - a pinned variable's  (its PINNED value is hashed, never the host's —
#     host value            this is the property env-pin exists to add)
#
# and must VARY when an unpinned allowlisted variable's value changes.

suite "A0 — key-portability invariance (keyOf, through realSeams)":

  test "keyOf is invariant under stateDir + cwd + TMPDIR value + pinned host value; varies on an unpinned value":
    var g = initDepGraph("2.2.10")
    let pinnedSpec = resolveSandbox(hlIsolated, envPins = @[("USER", "ci-pinned-user")])
    let pep = PlannedEntrypoint(
      ep: Entrypoint(path: "tests/unit/test_x.nim", group: "unit", flags: @[]),
      edecision: edRunFresh)

    let envA: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/bin"), ("USER", "alice"),
      ("TMPDIR", "/tmp/run-aaa"),
    ]
    let seamsA = realSeams(
      stateDir = "/tmp/crisol_state_A", graph = addr g,
      nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
      spec = pinnedSpec, parentEnv = envA, protocolMajor = 1)
    let keyA = seamsA.keyOf(pep)

    # Different stateDir, different host TMPDIR value, different host USER
    # value (the pinned name) -- everything the RFC calls out as host-
    # variable -- PLUS a different process cwd at call time.
    let envB: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/bin"), ("USER", "bob"),
      ("TMPDIR", "/tmp/run-bbb-totally-different-suffix"),
    ]
    let seamsB = realSeams(
      stateDir = "/tmp/crisol_state_B_a_completely_different_path", graph = addr g,
      nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
      spec = pinnedSpec, parentEnv = envB, protocolMajor = 1)

    let originalCwd = getCurrentDir()
    var keyB: SoundnessKey
    setCurrentDir(getTempDir())
    try:
      keyB = seamsB.keyOf(pep)
    finally:
      setCurrentDir(originalCwd)

    check keyA == keyB   # invariant: stateDir, cwd, TMPDIR value, pinned host value

    # Now vary an UNPINNED allowlisted value (PATH) -- must change the key.
    let envC: seq[(string, string)] = @[
      ("HOME", "/root"), ("PATH", "/usr/local/bin"), ("USER", "alice"),
      ("TMPDIR", "/tmp/run-aaa"),
    ]
    let seamsC = realSeams(
      stateDir = "/tmp/crisol_state_A", graph = addr g,
      nimVersion = "2.2.10", ccVersion = "gcc 13.2.0",
      spec = pinnedSpec, parentEnv = envC, protocolMajor = 1)
    let keyC = seamsC.keyOf(pep)

    check keyC != keyA   # variance: an unpinned allowlisted value must move the key

when isMainModule:
  echo "test_a0_env_pin: done"
