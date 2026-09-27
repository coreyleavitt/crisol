## tests/integration/test_issue23_cc_identity.nim -- issue #23.
##
## The soundness key's C-toolchain component must IDENTIFY the toolchain that
## compiles this host's tests. This drives the real production accessor
## (`ccidentity.cachedCcVersion`, the memoised probe `productionRunDeps`
## installs as `RunDeps.ccProbe` and that crisol.nim's `clean` handler calls
## directly) with no seam injected, in a scratch project with no `nim.cfg` of
## its own, so the compiler is the one the global Nim configuration selects.
##
## Its RED is on Windows: there the pre-#23 probe found no `cc` and no `ldd`
## and every host folded to one constant. A green run proves nothing unless it
## also ran in the MSVC image (see `docs/handoff/msvc-selection-layer.md`).

import std/[os, strutils, unittest]
import crisol/ccidentity
import "../support/ccprobes"

let root = getTempDir() / ("crisol_issue23_" & $getCurrentProcessId())
createDir(root)
let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])

proc carriesContentDigest(s: string): bool =
  ## True iff `s` ends with ` #` and sixteen hex digits -- the shape of every
  ## identified half. A sentinel does not.
  const digestLen = 16
  if s.len < digestLen + 2: return false
  if s[s.len - digestLen - 2 .. s.len - digestLen - 1] != " #": return false
  for c in s[s.len - digestLen .. ^1]:
    if c notin HexDigits: return false
  true

suite "issue #23 -- the soundness key identifies this host's C toolchain":

  test "the compiler half names the configured compiler, by content":
    let fp = cachedCcFingerprint(ctx)
    checkpoint($fp & " / " & fp.compiler.why)
    check fp.compiler.state == cfsKnown
    check serializeCompilerHalf(fp.compiler).carriesContentDigest
    # The legible part names a compiler family and a version.
    check fp.compiler.text.startsWith("gcc ") or
          fp.compiler.text.startsWith("clang ") or
          fp.compiler.text.startsWith("msvc ") or
          fp.compiler.text.startsWith("clang-cl ")

  test "the runtime half identifies the C runtime by content":
    ## Not a version string alone: a distro glibc backport moves no version,
    ## and Nim+vcc links the CRT statically, so on Windows the runtime is a
    ## set of .lib files that only their content identifies.
    let fp = cachedCcFingerprint(ctx)
    checkpoint($fp & " / " & fp.runtime.why)
    check fp.runtime.state == cfsKnown
    check serializeRuntimeHalf(fp.runtime).carriesContentDigest

  test "the accessor is memoised and serializes the same value":
    check cachedCcVersion(ctx) == $cachedCcFingerprint(ctx)
    check toolchainVerdict(cachedCcFingerprint(ctx)).kind == tvIdentified

removeDir(root)

when isMainModule:
  echo "test_issue23_cc_identity done"
