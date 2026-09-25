## test_r8_real_cl_refusal.nim — R8-L1 (round-8 review): R7-S1's REAL trigger,
## driven through the production identity path against a real `cl`.
##
## R7-S1 fixed `ccidentity.ccIdentity` so that a candidate driver which was
## spawned and exited non-zero is REFUSED (the compiler half degrades to
## `cfsUnavailable`, naming it in `refusedDrivers`) instead of being read as
## absent. The trigger it exists for is measured, not hypothetical: with any
## non-empty `CL` in the environment a real `cl` prints D8003 and exits 2. Until
## this file, that was proven only with SYNTHETIC captures on Linux
## (tests/unit/test_ccprobe.nim) -- no CI step ever set `CL`, so nothing showed
## that the real `cl`, the real `toolrun.realRunMerged` seam and the real
## `WindowsCcProfile` still combine into a refusal.
##
## What it drives: `ccIdentity(realRunMerged, WindowsCcProfile, realFileHash)`
## -- the exact call the unexported `ccFingerprint` makes on a Windows host --
## called directly rather than through `cachedCcFingerprint`, whose memo would
## pin whichever `CL` the first caller saw. The memoised accessor is read once,
## BEFORE `CL` is touched, only to supply a real runtime half for the
## `toolchainUnsoundReason` verdict and for the control.
##
## Both tests need a real `cl` resolvable on PATH, which on windows-latest
## means a Developer Command Prompt environment: the ci.yml step that runs this
## file imports vcvars64.bat's environment first. Anywhere `cl` does not
## resolve (Linux, macOS, a plain Windows shell) each test self-skips with a
## CRISOL-SKIP-TEST marker; ci/assert-subset-honesty.sh pins that skip as
## expected on macos and REQUIRES the real body on windows.
##
## Run with (MSVC container, where `cl` is on PATH):
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_r8_real_cl_refusal.nim

import std/[os, strutils, unittest]
import crisol/[ccidentity, toolrun]

const ThisFile = "tests/integration/test_r8_real_cl_refusal.nim"

let clAtStart = (had: existsEnv("CL"), value: getEnv("CL"))

let clPath =
  when defined(windows): resolveDriver("cl")
  else: ""

proc withEnv(name: string; value: string; unset: bool; body: proc()) =
  ## Run `body` with `name` set to `value` (or removed when `unset`), then
  ## restore the variable exactly -- present-with-value or absent -- whatever
  ## `body` raised. The probes inherit this process's environment, so a leaked
  ## `CL` would poison every later probe in the process.
  let had = existsEnv(name)
  let prior = getEnv(name)
  if unset: delEnv(name) else: putEnv(name, value)
  try:
    body()
  finally:
    if had: putEnv(name, prior) else: delEnv(name)

# The memoised real fingerprint, taken with `CL` removed so the memo can only
# ever hold the clean-environment answer.
var baseline: CcFingerprint
if clPath.len > 0:
  echo "R8-REAL-CL REAL: cl resolves to " & clPath
  withEnv("CL", "", unset = true, proc() = baseline = cachedCcFingerprint())

suite "R7-S1 on a real cl: a present driver that exits non-zero is refused":

  test "CL=/W4: real cl exits non-zero and the compiler half is refused":
    if clPath.len == 0:
      echo "CRISOL-SKIP-TEST: " & ThisFile & "#real_cl_refused_under_cl_env"
      skip()
    else:
      var raw: tuple[output: string, ok: bool]
      var half: CcHalf
      withEnv("CL", "/W4", unset = false, proc() =
        raw = realRunMerged("cl", [])
        half = ccIdentity(realRunMerged, WindowsCcProfile, realFileHash))
      checkpoint("cl output under CL=/W4:\n" & raw.output)
      # The measured premise R7-S1 rests on: it RAN (non-empty output) and
      # did not exit 0. If a toolset update ever made cl exit 0 here, this
      # line -- not the refusal below -- is the one that should go red.
      check not raw.ok
      check raw.output.strip.len > 0
      check half.state == cfsUnavailable
      if half.state == cfsUnavailable:
        checkpoint("refusedDrivers = " & $half.refusedDrivers)
        check "cl" in half.refusedDrivers
      let fp = CcFingerprint(compiler: half, runtime: baseline.runtime)
      check toolchainUnsoundReason(fp) == turCompilerRefused
      # The environment is restored exactly as the process started with it.
      check existsEnv("CL") == clAtStart.had
      check getEnv("CL") == clAtStart.value

  test "CONTROL CL unset: the same real cl identifies itself":
    if clPath.len == 0:
      echo "CRISOL-SKIP-TEST: " & ThisFile & "#real_cl_known_without_cl_env"
      skip()
    else:
      var half: CcHalf
      withEnv("CL", "", unset = true, proc() =
        half = ccIdentity(realRunMerged, WindowsCcProfile, realFileHash))
      check half.state == cfsKnown
      if half.state == cfsKnown:
        checkpoint("compiler half = " & half.text)
        check "Microsoft" in half.text
      else:
        checkpoint("refusedDrivers = " & $half.refusedDrivers)
      # The memoised production value, taken with CL removed, is sound.
      check toolchainUnsoundReason(baseline) == turSound

when isMainModule:
  echo "test_r8_real_cl_refusal done"
