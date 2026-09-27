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
import crisol/toolrun      # RunResult
import ../support/fakerun  # fakeReply

# ---------------------------------------------------------------------------
# Seam helpers
# ---------------------------------------------------------------------------

proc makeRun(verOut: string, verOk: bool): RunProc =
  ## Returns a run proc that serves synthetic `nim --version` output.
  result = proc(cmd: string, args: openArray[string]): RunResult =
    case cmd
    of "nim":
      fakeReply(verOut, verOk)
    else:
      fakeReply("", false)

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
# Suite 6b: NimMemo — the one memo rule, through the fakes (R14-D3)
# ---------------------------------------------------------------------------

suite "NimMemo — never keeps an answer an interrupted run decided (R14-D3)":

  proc countingRun(replies: seq[RunResult]; calls: ref int): RunProc =
    ## Serves `replies` in order (the last one repeats), counting calls.
    result = proc(cmd: string, args: openArray[string]): RunResult =
      let i = min(calls[], replies.high)
      inc calls[]
      replies[i]

  test "a reInterrupted nim --version is returned but not kept; the next lookup probes again":
    var m: NimMemo
    let calls = new int
    let run = countingRun(@[notRun(reInterrupted, "was interrupted"),
                            ran(0, StockVersion, "")], calls)
    let first = m.lookup(run, makeHashBin("h"))
    check first == NimVersionSentinel & "|h"
    let second = m.lookup(run, makeHashBin("h"))
    check calls[] == 2
    check second == nimFingerprint(makeRun(StockVersion, true), makeHashBin("h"))
    check second != first
    discard m.lookup(run, makeHashBin("h"))
    check calls[] == 2   # the real answer is kept

  test "an ordinary failure's placeholder is kept":
    for failed in [ran(1, "", "boom"), notRun(reTimedOut, "did not answer"),
                   notRun(reIoError, "held open"), notRun(reNotStarted, "no nim")]:
      var m: NimMemo
      let calls = new int
      let run = countingRun(@[failed, ran(0, StockVersion, "")], calls)
      checkpoint $failed.ending
      check m.lookup(run, makeHashBin("h")) == NimVersionSentinel & "|h"
      check m.lookup(run, makeHashBin("h")) == NimVersionSentinel & "|h"
      check calls[] == 1

  test "probeNim.known: a placeholder in either part is an unknown identity (R14-D4)":
    check probeNim(makeRun(StockVersion, true), makeHashBin("h")).known
    check not probeNim(makeRun("", false), makeHashBin("h")).known
    check not probeNim(makeRun("  \n", true), makeHashBin("h")).known
    check not probeNim(makeRun(StockVersion, true), makeHashBin(NimBinSentinel)).known
    let interrupted = proc(cmd: string, args: openArray[string]): RunResult =
      notRun(reInterrupted, "was interrupted")
    check not probeNim(interrupted, makeHashBin("h")).known

  test "lookupProbe carries the kept answer's known flag with its fingerprint":
    var ok: NimMemo
    let good = ok.lookupProbe(makeRun(StockVersion, true), makeHashBin("h"))
    check good.known
    check ok.lookupProbe(makeRun("", false), makeHashBin("h")) == good   # kept
    var bad: NimMemo
    let placeholder = bad.lookupProbe(makeRun("", false), makeHashBin("h"))
    check not placeholder.known
    check placeholder.fingerprint == NimVersionSentinel & "|h"
    check bad.lookup(makeRun(StockVersion, true), makeHashBin("h")) == placeholder.fingerprint

  test "probeNim.interrupted is exactly `nim --version` ending reInterrupted":
    check probeNim(makeRun(StockVersion, true), makeHashBin("h")).interrupted == false
    check probeNim(makeRun("", false), makeHashBin("h")).interrupted == false
    let interrupted = proc(cmd: string, args: openArray[string]): RunResult =
      notRun(reInterrupted, "was interrupted")
    check probeNim(interrupted, makeHashBin("h")).interrupted

# ---------------------------------------------------------------------------
# Suite 7: resolveNimBin
# ---------------------------------------------------------------------------

suite "resolveNimBin — PATH resolution":

  test "returns a non-empty path when nim is on PATH (this test itself runs under nim)":
    let p = resolveNimBin()
    check p.len > 0

when isMainModule:
  echo "All nimprobe tests passed."
