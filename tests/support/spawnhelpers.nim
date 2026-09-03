## tests/support/spawnhelpers.nim — rfc-0007 A2a-i shared helper for the
## migrated spawn-integration tests: builds a ChildSpec the way a real
## runner resolves one (env scrub + TMPDIR injection into an EXPLICIT env
## list — §1 ChildSpec.env doc — and an opt-in chdir into the scratch dir),
## then drives process.nim's Supervisor to completion. Replaces the old
## spawn.forkExecEnvScratch + spawn.supervise flow these five test files
## used before this slice; no new PRODUCTION logic exists only for tests —
## the env/limits resolution below is exactly sandbox.nim's existing pure
## `filterEnv`/`resolveSandbox` output reshaped into the §1 ChildSpec shape.

import std/[os, envvars, sequtils, options, monotimes, times, tempfiles]
import crisol/[types, sandbox]
import crisol/process

proc buildChildSpec*(bin: string; extraEnv: openArray[(string, string)];
                     spec: SandboxSpec; outPath: string;
                     scratchDir: var string): ChildSpec =
  ## Resolves a full ChildSpec the way a real runner would before calling
  ## `Supervisor.spawn` — env scrub + TMPDIR injection happen HERE, not in
  ## the backend (§1: "achieved by construction"). `scratchDir` is an out
  ## param so the caller can assert on / clean up the path, mirroring the
  ## old `forkExecEnvScratch(..., outScratchDir)` signature these tests used.
  ##
  ## rfc-0007 A2a-iii: `SandboxSpec.limits` IS the §1 `Limits` shape now
  ## (the old `rlimitConfig`-to-`Limits` mapping this helper used to do —
  ## `limitsFromSpec` — is gone; there is nothing left to map).
  scratchDir = ""
  var cwd = ""
  var allExtra: seq[(string, string)] = @[]
  for pair in extraEnv: allExtra.add(pair)
  if spec.tmpdir:
    scratchDir = createTempDir("crisol_scratch_", "")
    allExtra.add(("TMPDIR", scratchDir))
    if spec.chdirIntoScratch:
      cwd = scratchDir
  let envList = filterEnv(toSeq(envPairs()), spec, allExtra)
  ChildSpec(argv: @[bin], cwd: cwd, env: envList,
            sinks: combinedSink(outPath), limits: spec.limits)

proc spawnAndWait*(sv: var Supervisor; spec: ChildSpec; timeoutMs: int):
    tuple[ok: bool; report: ReapReport] =
  ## Spawn and drive `next` to completion within `timeoutMs`. Never sends a
  ## stop act — a plain run-to-completion wait for the migrated tests, none
  ## of which exercise the kill path (that is test_rfc0007_a2a_supervisor's
  ## job). `ok == false` on a spawn error or a timeout (child never exited).
  let sr = sv.spawn(spec)
  if not sr.ok:
    return (false, ReapReport())
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  let ev = sv.next(deadline)
  if ev.kind != weChildExited:
    return (false, ReapReport())
  (true, sv.reap(ev.id))

proc cleanupScratch*(scratchDir: string) =
  if scratchDir.len > 0:
    try: removeDir(scratchDir)
    except CatchableError: discard
