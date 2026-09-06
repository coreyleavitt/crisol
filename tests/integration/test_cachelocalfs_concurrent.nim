## test_cachelocalfs_concurrent.nim — RFC-0005 T20: real concurrent writers,
## two OS processes racing `put` of the SAME key into a shared file://
## (localfs) cache dir.
##
## Pins `cachelocalfs.localFsBackend`'s ACTUAL on-disk write mechanic
## (`ioutils.atomicPublish`, read directly before writing this test):
## every `put` writes to a PID-suffixed tmp file (`O_CREAT|O_EXCL`, so two
## processes never collide on the tmp path) and publishes it via
## `moveFile` (`rename(2)`) — atomic on the same filesystem. Two writers
## racing the SAME final path therefore never produce a torn/partial
## file: any reader of the entry, at any instant, either finds nothing yet
## (`cvMiss`) or a fully-written, cleanly-decodable entry (`cvOk`) — the
## in-place JSON bytes always belong to exactly one writer's one call,
## never a splice of two. And since a normal (non-crash) `put` renames its
## tmp file away, no `.tmp` file should survive once both writers have
## exited cleanly.
##
## Shape: `fork()` two real child OS processes directly from this already-
## compiled test binary (mirrors test_signal.nim/test_pgroup.nim's own
## fork-based child pattern in this same suite — no separate compiled
## fixture binary needed, since a forked child already carries the full
## image, `cachelocalfs` included). Each child loops `Iterations` times,
## `put`-ing the SAME `SoundnessKey` with a writer- and iteration-specific
## payload (`exitCode = writerId*1_000_000 + iter`) so a torn read would
## be DETECTABLE — a byte-level splice across two writers' JSON would
## either fail to decode (`cvCorrupt`, the checksum recomputed at decode
## time would not match) or, if it somehow still parsed, carry an exit
## code that traces to neither writer. The PARENT concurrently runs a
## reader loop against the SAME key for the whole race window.
##
## DETERMINISTIC-safe (per the task's own instruction): this asserts "no
## corruption observed over N iterations x 2 writers", never a specific
## interleaving — a failure here is a genuine atomicity bug, not a timing
## artifact, since `rename(2)` is unconditionally atomic on a real
## filesystem regardless of scheduling. Bounded: `Iterations` is kept
## small enough that the whole race finishes in well under 10s.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cachelocalfs_concurrent.nim

import std/[options, os, strutils, unittest]
import std/posix
import crisol/types
import crisol/cacheport
import crisol/cachewire      # storageFormatVersion
import crisol/cachelocalfs
import crisol/resultcache    # cacheVersionDirAt
import crisol/process/types as ptypes

# ---------------------------------------------------------------------------
# Helpers (mirrors test_cachetier.nim's/test_cachetrust.nim's sample*Result
# fixtures)
# ---------------------------------------------------------------------------

proc sampleProcessResult(exitCode: int): ptypes.ProcessResult =
  ptypes.ProcessResult(
    exit:  ptypes.Exit(kind: ptypes.ekExited, code: exitCode),
    cause: ptypes.Cause(by: ptypes.cbProcess),
    evidence: ptypes.Evidence(
      killDomain: ptypes.kdsProcessGroup,
      tree:       ptypes.toComplete,
      escapees:   @[],
      limits:     default(ptypes.LimitsAchieved),
      hermetic:   ptypes.hlIsolated,
      killSnapshot: @[],
      cooperativeUnavailable: false,
    ),
    rusage: none(ptypes.Rusage),
    durationUs: 1_000,
  )

const Iterations = 300
  ## Per writer (2 writers -> 600 total `put`s of the SAME key). Each `put`
  ## is a handful of syscalls (open/write/close/rename) on a local tmpfs-
  ## class filesystem — comfortably keeps the whole race well under 10s.

proc entryFor(key: SoundnessKey; writerId, iter: int): StoredEntry =
  ## `exitCode` encodes (writerId, iter) so a decoded entry's provenance is
  ## checkable — a torn read that still (implausibly) parsed as valid JSON
  ## would carry an exit code tracing to NEITHER writer.
  StoredEntry(
    key:            key,
    keyInputs:      none(KeyInputs),
    result: CachedResult(
      run:             sampleProcessResult(writerId * 1_000_000 + iter),
      records:         @[],
      cachedAt:        1_700_001_000'i64,
      payloadChecksum: "",
    ),
    storageVersion: storageFormatVersion,
    attestation:    none(Attestation),
  )

proc freshRoot(): string =
  result = getTempDir() / ("crisol_cachelocalfs_concurrent_" & $getpid())
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "cachelocalfs — real concurrent writers (T20)":

  test "two OS processes racing put() of the same key never produce a torn/corrupt entry; no stray .tmp survives":
    let root = freshRoot()
    defer: removeDir(root)
    let key = SoundnessKey("2020202020202020")
    let backend = localFsBackend(root, autoCreate = true, maxEntries = 0)

    proc writerLoop(writerId: int) =
      for i in 0 ..< Iterations:
        discard backend.put(entryFor(key, writerId, i))

    # -------------------------------------------------------------------
    # Spawn two real child processes, each hammering the SAME key.
    # -------------------------------------------------------------------
    let pid1 = fork()
    check pid1 >= 0
    if pid1 == 0:
      writerLoop(1)
      exitnow(0)

    let pid2 = fork()
    check pid2 >= 0
    if pid2 == 0:
      writerLoop(2)
      exitnow(0)

    # -------------------------------------------------------------------
    # PARENT: read the SAME key continuously for the whole race window,
    # reaping each child (WNOHANG) as it exits.
    # -------------------------------------------------------------------
    var child1Done = false
    var child2Done = false
    var reads = 0
    var hits = 0

    while not (child1Done and child2Done):
      let fetched = backend.get(key)
      case fetched.verdict
      of cvOk:
        inc hits
        let code = fetched.value.result.run.exit.code
        let writerId = code div 1_000_000
        let iter = code mod 1_000_000
        check writerId in [1, 2]
        check iter >= 0 and iter < Iterations
        check fetched.value.storageVersion == storageFormatVersion
      of cvMiss:
        discard  # nothing written yet -- fine, not a race window at all
      else:
        checkpoint("unexpected verdict mid-race: " & $fetched.verdict)
        fail()
      inc reads

      if not child1Done:
        var ws: cint = 0
        if waitpid(pid1, ws, WNOHANG) == pid1: child1Done = true
      if not child2Done:
        var ws: cint = 0
        if waitpid(pid2, ws, WNOHANG) == pid2: child2Done = true

    checkpoint("reader loop performed " & $reads & " reads, " & $hits & " of them cvOk, during the race")
    check reads > 0

    # -------------------------------------------------------------------
    # Final state: a clean, decodable entry from one of the two writers.
    # -------------------------------------------------------------------
    let final = backend.get(key)
    check final.verdict == cvOk
    check final.value.storageVersion == storageFormatVersion
    let finalWriterId = final.value.result.run.exit.code div 1_000_000
    check finalWriterId in [1, 2]

    # -------------------------------------------------------------------
    # No stray .tmp file survives a clean (non-crash) exit of both writers
    # -- atomicPublish's rename(2) always removes the PID-suffixed tmp file
    # it created, on every successful put.
    # -------------------------------------------------------------------
    let verDir = cacheVersionDirAt(root)
    var strayTmp: seq[string] = @[]
    for kind, path in walkDir(verDir):
      if kind == pcFile and path.endsWith(".tmp"):
        strayTmp.add path
    check strayTmp.len == 0
