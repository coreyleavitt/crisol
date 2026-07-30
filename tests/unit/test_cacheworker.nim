## test_cacheworker.nim — unit tests for crisol/cacheworker.nim (RFC-0006
## R2b1/R1/R1b/review Finding 2): the compile-cache worker's key-material
## capture and per-unit cache-key derivation.
##
## No real `nim`/`cc` invocation anywhere in this file — that is the single
## deliberately-budgeted real-compile check in
## tests/integration/test_compileworker_real.nim. This file covers:
##
##   1. captureToolchainCcVersion — sources ccprobe.ccVersion (cc AND ldd
##      folded), not a hand-rolled cc-only probe.
##   2. buildCacheKeyOf — a failed cc -M probe degrades a reusable unit to
##      non-cacheable (empty keyHash), never a normal key computed from an
##      empty include-closure component; the entry unit is always
##      non-cacheable.
##   3. buildCacheKeyOf — the .c-path derivation is shell-aware, not a naive
##      splitWhitespace(), so a whitespace-containing path doesn't silently
##      degrade every reusable unit to non-cacheable.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_cacheworker.nim

import std/[strutils, tables, unittest]
import crisol/cacheworker
import crisol/ccprobe
import crisol/artifactid

# ===========================================================================
# Behavior 1 — R2: the compile-cache worker's ccVersion key-material capture
# must source BOTH cc AND ldd (the libc fingerprint), like RFC-0004's
# ccprobe.ccVersion — not a hand-rolled cc-only probe.
# ===========================================================================

suite "captureToolchainCcVersion — R2: sources ccprobe.ccVersion (cc AND ldd folded)":

  test "a libc-only change (ldd --version differs, cc --version identical) changes the captured component":
    ## Before the fix, the worker's ccVersion key-material component came
    ## from a hand-rolled `cc --version`-only probe — a libc-only upgrade
    ## (base-image glibc bump, same cc) would NOT change it, so a stale-ABI
    ## `.o` would confirm-hit under the object cache's key. This proves the
    ## worker's capture proc genuinely folds the ldd output, not just cc's.
    let runV1: ccprobe.RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      if cmd == "cc": (output: "gcc-13.2.0", ok: true)
      elif cmd == "ldd": (output: "ldd (GNU libc) 2.39", ok: true)
      else: (output: "", ok: false)
    let runV2: ccprobe.RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      if cmd == "cc": (output: "gcc-13.2.0", ok: true)          # cc UNCHANGED
      elif cmd == "ldd": (output: "ldd (GNU libc) 2.40", ok: true)  # libc-only bump
      else: (output: "", ok: false)
    let v1 = captureToolchainCcVersion(runV1)
    let v2 = captureToolchainCcVersion(runV2)
    check v1 != v2
    check "2.39" in v1
    check "2.40" in v2

  test "matches ccprobe.ccVersion exactly (not a parallel reimplementation)":
    let run: ccprobe.RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      if cmd == "cc": (output: "gcc-13.2.0", ok: true)
      elif cmd == "ldd": (output: "ldd (GNU libc) 2.39", ok: true)
      else: (output: "", ok: false)
    check captureToolchainCcVersion(run) == ccprobe.ccVersion(run)

# ===========================================================================
# Behavior 2 — R1/R1b: buildCacheKeyOf — a failed cc -M probe degrades the
# unit to non-cacheable (empty keyHash), never a normal key computed from an
# empty include-closure component.
# ===========================================================================

suite "buildCacheKeyOf — R1: a failed cc -M probe makes the unit non-cacheable":

  proc syntheticReader(mapping: Table[string, string]): FileReaderProc =
    result = proc(path: string): tuple[content: string; ok: bool] =
      if mapping.hasKey(path):
        (content: mapping[path], ok: true)
      else:
        (content: "", ok: false)

  test "a reusable unit whose cc -M probe fails gets an EMPTY keyHash (non-cacheable), not a normal key":
    let entryBasename = "@mep.nim.c"
    let cPath = "/cache/other.nim.c"
    let ccCmd = "gcc -c -I/inc -o /cache/other.nim.c.o " & cPath
    let reader = syntheticReader({cPath: "int x;"}.toTable)
    let failingCcMRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "", ok: false)   # cc -M probe fails
    let keyOf = buildCacheKeyOf(entryBasename, @[], "2.2.10", "gcc-13|glibc-2.39",
                               failingCcMRun, reader)
    let key = keyOf((basename: "other.nim.c", ccCmd: ccCmd))
    check key.keyHash == ""
    check key.preimage == ""
    # objOutPath is still derived (shape-completeness — compiledriver's
    # non-cacheable branch never reads it, but keyOf must not crash deriving it).
    check key.objOutPath == "/cache/other.nim.c.o"

  test "a reusable unit whose cc -M probe SUCCEEDS gets a real, non-empty keyHash (sanity: the degrade doesn't leak into the happy path)":
    let entryBasename = "@mep.nim.c"
    let cPath = "/cache/other.nim.c"
    let ccCmd = "gcc -c -I/inc -o /cache/other.nim.c.o " & cPath
    let reader = syntheticReader({cPath: "int x;", "/inc/foo.h": "int y;"}.toTable)
    let okCcMRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "/cache/other.nim.c.o: " & cPath & " /inc/foo.h\n", ok: true)
    let keyOf = buildCacheKeyOf(entryBasename, @[], "2.2.10", "gcc-13|glibc-2.39",
                               okCcMRun, reader)
    let key = keyOf((basename: "other.nim.c", ccCmd: ccCmd))
    check key.keyHash.len > 0
    check key.preimage.len > 0

  test "the entry unit is ALWAYS non-cacheable, independent of the cc -M probe outcome":
    let entryBasename = "@mep.nim.c"
    let ccCmd = "gcc -c -o /cache/@mep.nim.c.o /cache/@mep.nim.c"
    let okCcMRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "/cache/@mep.nim.c.o: /cache/@mep.nim.c\n", ok: true)
    let keyOf = buildCacheKeyOf(entryBasename, @[], "2.2.10", "gcc-13|glibc-2.39", okCcMRun)
    let key = keyOf((basename: entryBasename, ccCmd: ccCmd))
    check key.keyHash == ""

# ===========================================================================
# Behavior 3 — review Finding 2: buildCacheKeyOf's .c-path derivation is
# shell-aware, not a naive splitWhitespace(). A whitespace-containing path
# (e.g. a WSL2 stateDir/project root such as "/mnt/c/Users/John Doe/proj")
# previously truncated the derived cPath at the embedded space, so readFile
# always failed and EVERY reusable unit silently degraded to non-cacheable —
# a permanent, silent objcache no-op under such a path, with no diagnostic.
# ===========================================================================

suite "buildCacheKeyOf — review Finding 2: shell-aware .c-path derivation under a whitespace path":

  test "a reusable unit whose .c source path contains a space derives the correct cPath and produces a real, non-empty (cacheable) key":
    let entryBasename = "@mep.nim.c"
    let cPath = "/cache/John Doe/other.nim.c"
    let ccCmd = "gcc -c -I/inc -o '/cache/John Doe/other.nim.c.o' '" & cPath & "'"
    let okCcMRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "'/cache/John Doe/other.nim.c.o': '" & cPath & "'\n", ok: true)
    let readFile: FileReaderProc = proc(path: string): tuple[content: string; ok: bool] =
      if path == cPath: (content: "int x;", ok: true)
      else: (content: "", ok: false)

    let keyOf = buildCacheKeyOf(entryBasename, @[], "2.2.10", "gcc-13|glibc-2.39",
                               okCcMRun, readFile)
    let key = keyOf((basename: "other.nim.c", ccCmd: ccCmd))

    # Before the fix, a naive splitWhitespace() truncated cPath to
    # "/cache/John" (stopping at the embedded space), readFile("/cache/John")
    # missed, and the unit silently degraded to non-cacheable (empty
    # keyHash) — indistinguishable from a genuine per-unit oddity. The fix
    # must resolve the FULL path and produce a real key.
    check key.keyHash.len > 0
    check key.preimage.len > 0
    check key.objOutPath == "/cache/John Doe/other.nim.c.o"

  test "an unterminated shell quote in the ccCmd still degrades to non-cacheable (fail-safe unchanged)":
    let entryBasename = "@mep.nim.c"
    let ccCmd = "gcc -c -I/inc -o '/cache/unterminated other.nim.c.o /cache/other.nim.c"
    let okCcMRun: RunProc = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
      (output: "should never matter\n", ok: true)
    let keyOf = buildCacheKeyOf(entryBasename, @[], "2.2.10", "gcc-13|glibc-2.39", okCcMRun)
    let key = keyOf((basename: "other.nim.c", ccCmd: ccCmd))
    check key.keyHash == ""
    check key.preimage == ""

when isMainModule:
  echo "All cacheworker unit tests passed."
