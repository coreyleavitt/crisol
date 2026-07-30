## test_objkey.nim — unit tests for objkey.nim (RFC-0006 Stage R, R2a: the
## FULL Stage-R soundness key).
##
## All seams injected (synthetic `ccMRun`/`readFile`): NO real `cc`/`nim`
## invocation anywhere in this file.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_objkey.nim

import std/[strutils, tables, unittest]
import crisol/objkey
import crisol/artifactid   # FileReaderProc, RunProc — the seam types stageRKey takes

# ---------------------------------------------------------------------------
# Helpers — synthetic seams (mirrors test_artifactid.nim's idiom)
# ---------------------------------------------------------------------------

proc syntheticReader(mapping: Table[string, string]): FileReaderProc =
  result = proc(path: string): tuple[content: string; ok: bool] =
    if mapping.hasKey(path):
      (content: mapping[path], ok: true)
    else:
      (content: "", ok: false)

proc syntheticCcMRun(output: string; ok = true): RunProc =
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    (output: output, ok: ok)

const baseCContent = "int foo(void) { return 1; }\n"
const baseCcCmd     = "gcc -c -I/inc -o /cache/mod.nim.c.o /cache/mod.nim.c"
const baseCcMOutput = "/cache/mod.nim.c.o: /cache/mod.nim.c /inc/foo.h\n"
const baseNimVersion = "2.2.10"
const baseCcVersion  = "gcc-13|glibc-2.39"

proc baseKey(cContent = baseCContent; ccCmd = baseCcCmd; ccMOutput = baseCcMOutput;
            nimVersion = baseNimVersion; ccVersion = baseCcVersion;
            headerContent = "int x;"):
    tuple[keyHash: string; preimage: string; ok: bool] =
  let run = syntheticCcMRun(ccMOutput)
  let reader = syntheticReader({"/inc/foo.h": headerContent}.toTable)
  stageRKey(cContent, ccCmd, @[], nimVersion, ccVersion, run, reader)

# ===========================================================================
# Behavior 1 — determinism + sensitivity to each of the five components
# ===========================================================================

suite "stageRKey — determinism + per-component sensitivity":

  test "identical five components produce identical keyHash and preimage":
    let a = baseKey()
    let b = baseKey()
    check a.keyHash == b.keyHash
    check a.preimage == b.preimage

  test "changing ccCmd changes both keyHash and preimage":
    let a = baseKey()
    let b = baseKey(ccCmd = "gcc -c -I/inc -DFOO=1 -o /cache/mod.nim.c.o /cache/mod.nim.c")
    check a.keyHash != b.keyHash
    check a.preimage != b.preimage

  test "changing cContent changes both keyHash and preimage":
    let a = baseKey()
    let b = baseKey(cContent = "int foo(void) { return 2; }\n")
    check a.keyHash != b.keyHash
    check a.preimage != b.preimage

  test "changing the include-closure (header content, same path) changes both keyHash and preimage":
    let a = baseKey()
    let b = baseKey(headerContent = "int x; int y;")
    check a.keyHash != b.keyHash
    check a.preimage != b.preimage

  test "changing nimVersion changes both keyHash and preimage":
    let a = baseKey()
    let b = baseKey(nimVersion = "2.2.11")
    check a.keyHash != b.keyHash
    check a.preimage != b.preimage

  test "changing ccVersion changes both keyHash and preimage":
    let a = baseKey()
    let b = baseKey(ccVersion = "gcc-14|glibc-2.39")
    check a.keyHash != b.keyHash
    check a.preimage != b.preimage

# ===========================================================================
# Behavior 2 — R1: a failed cc -M include-closure probe must NEVER fold into
# a normal, non-empty key. `ccIncludeClosure.ok=false` (the probe itself
# failed) must propagate all the way out of `stageRKey` as a non-cacheable
# signal — never silently fold an empty `inc` component into an otherwise-
# ordinary key that could collide with (or be confused for) a genuinely
# different unit's key.
# ===========================================================================

suite "stageRKey — R1: cc -M probe failure degrades to non-cacheable, never a normal key":

  test "a failed cc -M probe (ccMRun ok=false) makes stageRKey signal non-cacheable (ok=false, empty keyHash/preimage)":
    let run = syntheticCcMRun("", ok = false)
    let reader = syntheticReader(initTable[string, string]())
    let key = stageRKey(baseCContent, baseCcCmd, @[], baseNimVersion, baseCcVersion, run, reader)
    check not key.ok
    check key.keyHash == ""
    check key.preimage == ""

  test "two DIFFERENT units both hitting a failed cc -M probe do NOT collapse to the same non-empty key (both degrade to empty, not to some shared 'normal' hash)":
    let run = syntheticCcMRun("", ok = false)
    let reader = syntheticReader(initTable[string, string]())
    let keyX = stageRKey("content X", "gcc -c -o x.o x.c", @[], baseNimVersion, baseCcVersion, run, reader)
    let keyY = stageRKey("content Y", "gcc -c -o y.o y.c", @[], baseNimVersion, baseCcVersion, run, reader)
    check not keyX.ok
    check not keyY.ok
    check keyX.keyHash == ""
    check keyY.keyHash == ""
    # Neither degraded key is a "normal" non-empty key that could be
    # mistaken for (or collide with) a real successful-probe key.
    let successKey = baseKey()
    check keyX.keyHash != successKey.keyHash
    check keyY.keyHash != successKey.keyHash

  test "a SUCCESSFUL probe still yields ok=true with a non-empty key (sanity: the ok field doesn't degrade the happy path)":
    let key = baseKey()
    check key.ok
    check key.keyHash.len > 0
    check key.preimage.len > 0

when isMainModule:
  echo "All objkey tests passed."
