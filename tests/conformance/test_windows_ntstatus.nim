## test_windows_ntstatus.nim — rfc-0007 D1a: the `ekNtStatus` producer proof.
##
## The RFC's own words for why this file exists (Stage D's D1a bullet): "The
## access-violation fixture lands HERE — it is ekNtStatus's producer proof,
## not serde-only coverage." `decodeExitCode`'s `>= 0xC0000000` partition
## (process/windows.nim, real since the A2d spike) is proven here against a
## REAL Win32 access violation, driven through the real entry point:
## Supervisor spawn -> next -> reap (process.nim's selection ladder via
## ./helpers, never the backend module directly — tests/conformance's own
## import-purity rule, test_conformance_import_purity.nim). The classified
## `Outcome` is asserted through crisol/types.outcome(), the SAME pure
## derivation every trust boundary calls — not a hand-rolled predicate.
##
## `crisol run --json` (the CLI, like the POSIX A1b/A1f tests use) is NOT
## reachable yet at D1a: crisol/runner pulls in crisol/lock and
## crisol/ioutils, both of which `import std/posix` unconditionally today
## (D2's job per the RFC's Stage D bullet — "lock (LockFileEx), ioutils
## (MoveFileEx, CREATE_NEW)") — so the full CLI does not even
## `nim check --os:windows` until D2 lands. The Supervisor-level proof below
## is D1a's real entry point, not a narrowed stand-in for a CLI check that
## does not yet compile on this platform.
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[options, os, unittest, monotimes, times]
  import ./helpers
  import crisol/types
  import crisol/process/types as ptypes

  let avBin = compileFixture("access_violation")

  suite "rfc-0007 D1a — ekNtStatus producer proof (access violation)":

    test "access_violation: reaped Exit is ekNtStatus 0xC0000005, classified oCrashed":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_ntstatus_av")
      let spec = ChildSpec(argv: @[avBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.exit.kind == ekNtStatus
      check report.exit.status == 0xC0000005'u32

      # The runner never sent this fault — no stop act was ever recorded.
      check report.stop.isNone

      let cause = classifyCause(report.exit, report.stop, Limits(), report.limits)
      check cause.by == cbProcess

      # Drive the REAL production outcome() derivation (crisol/types) over a
      # minimal, honestly-populated EntrypointResult, exactly the shape the
      # runner itself builds — not a hand-rolled equivalent.
      let ep = Entrypoint(path: "tests/fixtures/access_violation.nim", group: "test", flags: @[])
      let evidence = Evidence(
        killDomain: report.killDomain,
        tree: treeObservationFor(report.killDomain),
        escapees: report.escapees,
        limits: report.limits,
        hermetic: hlNone,
        killSnapshot: report.killSnapshot,
        cooperativeUnavailable: report.cooperativeUnavailable,
      )
      let res = ProcessResult(exit: report.exit, cause: cause, evidence: evidence,
                               rusage: report.rusage, durationUs: 0)
      let r = EntrypointResult(ep: ep, compile: Phase(kind: pkSkipped),
                               run: Phase(kind: pkRan, res: res))
      check outcome(r) == oCrashed

  when isMainModule:
    echo "test_windows_ntstatus done"

else:
  when isMainModule:
    echo "test_windows_ntstatus: skipped (not windows)"
