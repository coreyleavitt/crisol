## tests/conformance/helpers.nim — rfc-0007 A2a-ii shared plumbing for the
## backend-agnostic conformance suite.
##
## Imports `crisol/process` (the §1 ladder) ONLY, plus stdlib — no
## `crisol/sandbox`, `crisol/types`, or `crisol/runner` dependency. That is
## deliberate, not an oversight: this suite proves the CONTRACT (`process.nim`
## and whichever backend `when defined(...)` selects), not the product
## runner's use of it — until A2b the runner does not drive the Supervisor at
## all (see each suite file's header). A file in this directory that reached
## for `crisol/runner` would silently smuggle runner behavior into what is
## supposed to be a pure contract pin.
##
## Not itself a `test_*.nim` file, so crisol.nimble's self-discovering test
## task never tries to run it directly.

import std/[os, osproc, monotimes, times]
import crisol/process

export process

const fixtureDir* = currentSourcePath().parentDir().parentDir() / "fixtures"
const binDir* = fixtureDir / "bin"
const nimcacheDir* = fixtureDir / "nimcache"

proc compileFixture*(name: string): string =
  ## Compiles tests/fixtures/<name>.nim the same way the rest of the suite
  ## does (test_rfc0007_a2a_supervisor.nim, test_pgroup.nim) — unconditional
  ## per-load recompile, no staleness tracking; fixtures are small.
  createDir(binDir)
  let src = fixtureDir / (name & ".nim")
  let bin = binDir / name
  let cache = nimcacheDir / name
  let (o, rc) = execCmdEx("nim c --mm:orc --nimcache:" & cache & " -o:" & bin & " " & src)
  doAssert rc == 0, name & " compile failed:\n" & o
  bin

proc tmpOutputFile*(tag: string): string =
  ## A fresh sink path per case — pid + wall-clock keeps parallel `./dev test`
  ## invocations (and repeated runs) from colliding on the same file.
  getTempDir() / "crisol_conformance_" & tag & "_" & $getCurrentProcessId() &
    "_" & $epochTime().int64 & ".txt"

proc spawnAndWait*(sv: var Supervisor; spec: ChildSpec; deadline: MonoTime):
    tuple[ev: WaitEvent; report: ReapReport] =
  ## Spawn and drive `next` to completion within `deadline`, WITHOUT ever
  ## sending a stop act. `ev.kind != weChildExited` on a spawn error or a
  ## deadline miss — callers that need the raw SpawnResult (item 7) or the
  ## intermediate weDeadline event (items 2/3) call `sv.spawn`/`sv.next`
  ## directly instead of this helper.
  let sr = sv.spawn(spec)
  doAssert sr.ok, "spawnAndWait: spawn failed unexpectedly: " &
    (if sr.ok: "" else: sr.error)
  let ev = sv.next(deadline)
  if ev.kind != weChildExited:
    return (ev, ReapReport())
  (ev, sv.reap(ev.id))
