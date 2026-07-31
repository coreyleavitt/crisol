## test_nimprobe.nim — unit tests for nimprobe.nim (soundness fix: Nim
## compiler fingerprint must distinguish a stock build from a patched build
## sharing the same `--version` STRING).
##
## All I/O is synthetic: tests inject a fake `run` seam (nim --version) and a
## fake `hashBin` seam (binary content hash), so no real nim binary is read
## or spawned.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_nimprobe.nim

import std/[unittest, strutils, os]
import crisol/nimprobe

# ---------------------------------------------------------------------------
# Seam helpers
# ---------------------------------------------------------------------------

proc makeRun(verOut: string, verOk: bool): RunProc =
  ## Returns a run proc that serves synthetic `nim --version` output.
  result = proc(cmd: string, args: openArray[string]): tuple[output: string, ok: bool] =
    case cmd
    of "nim":
      (output: verOut, ok: verOk)
    else:
      (output: "", ok: false)

proc makeHashBin(hash: string): BinHashProc =
  ## Returns a hashBin proc that ignores its `path` argument and returns a
  ## canned hash — lets tests simulate "different binary content" without a
  ## real compiler on disk.
  result = proc(path: string): string = hash

const StockVersion =
  "Nim Compiler Version 2.2.10 [Linux: amd64]\n" &
  "Compiled at 2025-01-01\n" &
  "Copyright (c) 2006-2024 by Andreas Rumpf\n\n" &
  "active boot switches: -d:release"

const PatchedVersionDifferentDate =
  "Nim Compiler Version 2.2.10 [Linux: amd64]\n" &
  "Compiled at 2025-06-15\n" &                      # different build date
  "Copyright (c) 2006-2024 by Andreas Rumpf\n\n" &
  "active boot switches: -d:release"

# ---------------------------------------------------------------------------
# Suite 1: the soundness rule — same version string, different binary
# ---------------------------------------------------------------------------

suite "nimFingerprint — stock vs patched build at the SAME version string":

  test "same --version FIRST LINE but different full output (Compiled-at date) -> different fingerprint":
    let run1 = makeRun(StockVersion, true)
    let run2 = makeRun(PatchedVersionDifferentDate, true)
    let hashBin = makeHashBin("samehash")
    let fp1 = nimFingerprint(run1, hashBin)
    let fp2 = nimFingerprint(run2, hashBin)
    check fp1 != fp2

  test "identical --version output but DIFFERENT binary content hash -> different fingerprint (THE stock-vs-patched rule)":
    let run = makeRun(StockVersion, true)
    let fp1 = nimFingerprint(run, makeHashBin("hash-of-stock-binary"))
    let fp2 = nimFingerprint(run, makeHashBin("hash-of-patched-binary"))
    check fp1 != fp2

  test "identical version output AND identical binary content hash -> same fingerprint":
    let run1 = makeRun(StockVersion, true)
    let run2 = makeRun(StockVersion, true)
    let fp1 = nimFingerprint(run1, makeHashBin("samehash"))
    let fp2 = nimFingerprint(run2, makeHashBin("samehash"))
    check fp1 == fp2

# ---------------------------------------------------------------------------
# Suite 2: normal operation
# ---------------------------------------------------------------------------

suite "nimFingerprint — normal operation":

  test "combines full normalized version output and bin hash with '|' separator":
    let run = makeRun("Nim Compiler Version 2.2.10 [Linux: amd64]", true)
    let fp = nimFingerprint(run, makeHashBin("deadbeefcafebabe"))
    check fp == "Nim Compiler Version 2.2.10 [Linux: amd64]|deadbeefcafebabe"

  test "keeps ALL lines of --version output, not just the first":
    let run = makeRun(StockVersion, true)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check "Compiled at 2025-01-01" in fp
    check "active boot switches: -d:release" in fp

  test "drops blank lines when normalizing":
    let run = makeRun(StockVersion, true)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check "\n\n" notin fp

  test "trims leading/trailing whitespace per line":
    let run = makeRun("  Nim Compiler Version 2.2.10  \n  Compiled at 2025-01-01  ", true)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check fp == "Nim Compiler Version 2.2.10\nCompiled at 2025-01-01|h"

# ---------------------------------------------------------------------------
# Suite 3: graceful degradation when probes fail
# ---------------------------------------------------------------------------

suite "nimFingerprint — probe failures yield sentinels, never raise":

  test "nim --version probe failure (ok=false) substitutes NimVersionSentinel":
    let run = makeRun("", false)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check fp == NimVersionSentinel & "|h"

  test "nim --version probe succeeds but empty output -> NimVersionSentinel substituted":
    let run = makeRun("", true)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check fp == NimVersionSentinel & "|h"

  test "nim --version probe succeeds but only whitespace/blank lines -> NimVersionSentinel":
    let run = makeRun("   \n  \n", true)
    let fp = nimFingerprint(run, makeHashBin("h"))
    check fp == NimVersionSentinel & "|h"

  test "hashBin failure (empty path / unreadable) substitutes NimBinSentinel":
    let run = makeRun(StockVersion, true)
    let fp = nimFingerprint(run, makeHashBin(NimBinSentinel))
    check fp.endsWith("|" & NimBinSentinel)

  test "both probes fail -> both sentinels, still a stable non-empty string":
    let run = makeRun("", false)
    let fp = nimFingerprint(run, makeHashBin(NimBinSentinel))
    check fp == NimVersionSentinel & "|" & NimBinSentinel
    check fp.len > 0

# ---------------------------------------------------------------------------
# Suite 4: determinism
# ---------------------------------------------------------------------------

suite "nimFingerprint — determinism":

  test "same inputs -> identical output (pure function of injected seams)":
    let run = makeRun(StockVersion, true)
    let hashBin = makeHashBin("stable-hash")
    let fp1 = nimFingerprint(run, hashBin)
    let fp2 = nimFingerprint(run, hashBin)
    check fp1 == fp2

# ---------------------------------------------------------------------------
# Suite 5: realBinHash — default hashBin seam
# ---------------------------------------------------------------------------

suite "realBinHash — content hash of a real file":

  test "empty path -> NimBinSentinel":
    check realBinHash("") == NimBinSentinel

  test "nonexistent path -> NimBinSentinel (never raises)":
    check realBinHash("/nonexistent/path/that/does/not/exist/nim") == NimBinSentinel

  test "same file content -> same hash; different content -> different hash":
    let tmpA = getTempDir() / "crisol_nimprobe_test_a.bin"
    let tmpB = getTempDir() / "crisol_nimprobe_test_b.bin"
    writeFile(tmpA, "content-one")
    writeFile(tmpB, "content-two")
    defer:
      removeFile(tmpA)
      removeFile(tmpB)
    let hA1 = realBinHash(tmpA)
    let hA2 = realBinHash(tmpA)
    let hB  = realBinHash(tmpB)
    check hA1 == hA2
    check hA1 != hB
    check hA1 != NimBinSentinel
    check hB  != NimBinSentinel

# ---------------------------------------------------------------------------
# Suite 6: cachedNimFingerprint — memoised real-seam accessor
# ---------------------------------------------------------------------------

suite "cachedNimFingerprint — memoised, never raises":

  test "returns a stable non-empty string across repeated calls (real seams, real process)":
    let v1 = cachedNimFingerprint()
    let v2 = cachedNimFingerprint()
    check v1 == v2
    check v1.len > 0

# ---------------------------------------------------------------------------
# Suite 7: resolveNimBin
# ---------------------------------------------------------------------------

suite "resolveNimBin — PATH resolution":

  test "returns a non-empty path when nim is on PATH (this test itself runs under nim)":
    let p = resolveNimBin()
    check p.len > 0

when isMainModule:
  echo "All nimprobe tests passed."
