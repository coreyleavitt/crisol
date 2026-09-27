## test_real_cl_identity.nim -- the real MSVC probe under `CL` (R9-D1c).
##
## cl reads `CL` (prepended) and `_CL_` (appended) on every compile. With a
## banner probe, any non-empty `CL` made cl exit 2 and the host could not
## cache at all; and a `CL=/DFOO`, which changes object code, moved nothing in
## the key. The preprocessor probe answers under any `CL`, and the values are
## folded into the compiler digest.
##
## Drives the real `ccFingerprint` (not the memoised accessor, which would
## pin whichever `CL` the first caller saw) against the host's configured
## compiler, in a scratch project with no `nim.cfg` of its own, so the
## compiler is the one the global Nim configuration selects: `vcc` on the
## Windows CI leg and in the MSVC image. Windows only; elsewhere each test
## self-skips with a CRISOL-SKIP-TEST marker, and
## ci/assert-subset-honesty.sh pins that skip on macOS and REQUIRES the real
## body on Windows.
##
## Run with (MSVC container):
##   nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_real_cl_identity.nim

import std/[os, strutils, unittest]
import crisol/ccidentity
import "../support/ccprobes"

const ThisFile = "tests/integration/test_real_cl_identity.nim"

let clAtStart = (had: existsEnv("CL"), value: getEnv("CL"))

proc withEnv(name: string; value: string; unset: bool; body: proc()) =
  ## Run `body` with `name` set to `value` (or removed when `unset`), then
  ## restore it exactly. The probes inherit this process's environment.
  let had = existsEnv(name)
  let prior = getEnv(name)
  if unset: delEnv(name) else: putEnv(name, value)
  try:
    body()
  finally:
    if had: putEnv(name, prior) else: delEnv(name)

let root = getTempDir() / ("crisol_real_cl_identity_" & $getCurrentProcessId())
createDir(root)
let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])

proc probeUnder(value: string; unset: bool): CcFingerprint =
  var fp: CcFingerprint
  withEnv("CL", value, unset, proc() = fp = ccFingerprint(ctx))
  fp

when defined(windows):
  echo "R9-REAL-CL REAL: probing the configured compiler"

suite "R9-D1c on a real cl: CL is identified, and keys the compiler":

  test "CL=/W4: the configured cl is identified":
    when not defined(windows):
      echo "CRISOL-SKIP-TEST: " & ThisFile & "#real_cl_identified_under_cl_env"
      skip()
    else:
      let fp = probeUnder("/W4", false)
      checkpoint $fp & " / " & fp.compiler.why & " / " & fp.runtime.why
      check toolchainVerdict(fp).kind == tvIdentified
      check fp.compiler.text.startsWith("msvc ") or
            fp.compiler.text.startsWith("clang-cl ")
      check existsEnv("CL") == clAtStart.had
      check getEnv("CL") == clAtStart.value

  test "a CL value moves the compiler half, not the runtime half":
    when not defined(windows):
      echo "CRISOL-SKIP-TEST: " & ThisFile & "#real_cl_value_moves_key"
      skip()
    else:
      let clean = probeUnder("", true)
      let withDefine = probeUnder("/DCRISOL_R9_CL", false)
      checkpoint "clean   = " & $clean
      checkpoint "defined = " & $withDefine
      check toolchainVerdict(clean).kind == tvIdentified
      check toolchainVerdict(withDefine).kind == tvIdentified
      check clean.compiler.text == withDefine.compiler.text
      check clean.compiler != withDefine.compiler
      check clean.runtime == withDefine.runtime

suite "R11-S1 on a real cl: a CL set by config.nims is nim's, not crisol's":

  test "a config.nims putEnv(CL) is refused, not probed without it":
    when not defined(windows):
      echo "CRISOL-SKIP-TEST: " & ThisFile & "#real_cl_config_nims_putenv"
      skip()
    else:
      # cl reads CL from the environment nim spawns it with; the identity
      # probes run with this process's. Probed with CL unset here, so the
      # difference is the config's alone.
      let proj = root / "putenv"
      createDir(proj)
      let pctx = CcProbeContext(projectRoot: proj, stateDir: proj / ".crisol", flags: @[])
      var plain, refused: CcFingerprint
      withEnv("CL", "", true, proc() = plain = ccFingerprint(pctx))
      writeFile(proj / "config.nims", "putEnv(\"CL\", \"/DCRISOL_R11_S1\")\n")
      withEnv("CL", "", true, proc() = refused = ccFingerprint(pctx))
      checkpoint "plain   = " & $plain & " / " & plain.compiler.why
      checkpoint "refused = " & $refused & " / " & refused.compiler.why
      check toolchainVerdict(plain).kind == tvIdentified
      check toolchainVerdict(refused) ==
            ToolchainVerdict(kind: tvUnidentified, part: upBoth)
      check "CL" in refused.compiler.why
      check "/DCRISOL_R11_S1" in refused.compiler.why

removeDir(root)

when isMainModule:
  echo "test_real_cl_identity done"
