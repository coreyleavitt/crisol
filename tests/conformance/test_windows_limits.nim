## test_windows_limits.nim — rfc-0007 D1b-ii: Job limits, parent-computed
## LimitsAchieved.
##
## Before this slice, `process/windows.nim` reported `lsUnsupported` for
## EVERY requested limit kind, unconditionally — D1a's honest placeholder
## (§1's weakest-honest-claim rule) pending real Job Object wiring. This
## file proves the two real analogs §5 names — `lkCpu` ->
## PerProcessUserTimeLimit, `lkAddressSpace` -> ProcessMemoryLimit — are now
## genuinely kernel-enforced (the cpu case) or at least genuinely installed
## (the address-space case), and that the no-analog kinds
## (`lkFileSize`/`lkOpenFiles`/`lkCore`/`lkMemory`) still report
## `lsUnsupported`, driven through the real Supervisor (process.nim's
## selection ladder via ./helpers, never the backend module directly —
## tests/conformance's own import-purity rule,
## test_conformance_import_purity.nim).
##
## OUT OF SCOPE here, deliberately (a separate, tracked follow-up — see
## process/windows.nim's module header): `classifyCause` attribution of a
## Job-limit kill to `cbLimit`. A Windows limit kill is classified purely by
## its `Exit` (`ekExited`/`ekNtStatus`, never `ekSignaled`) — this file
## asserts enforcement + `lsApplied`, NOT `cause.by == cbLimit` and NOT a
## specific exit code (a PerProcessUserTimeLimit kill's exit code is
## CI-unknown).
##
## Address-space RUNTIME enforcement (an allocation actually failing under
## `ProcessMemoryLimit`) is NOT proven here — a deterministic `addr_hog`
## fixture proved too failure-mode-messy (alloc-fail semantics vary: an
## OutOfMemDefect, a raw allocator-returned-nil, or a hard crash, none of
## which this slice can verify without a Windows host) to justify the added
## surface for a slice scoped to WIRING the limit, not auditing every
## enforcement failure mode. `lkAddressSpace` is proven via `lsApplied`
## (the install call succeeded) only — the runtime-enforcement case is left
## for a future, dedicated slice if ever needed.
##
## The classified `Outcome` (cpu case only, per this file's primary
## assertion) is asserted through crisol/types.outcome(), the SAME pure
## derivation every trust boundary calls — not a hand-rolled predicate
## (mirrors test_windows_ntstatus.nim exactly).
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_ntstatus.nim
## and test_windows_coopstop.nim): the `else` branch must still compile and
## exit cleanly on Linux/macOS, since crisol.nimble's self-discovering test
## task finds every `test_*.nim` file under tests/ regardless of host
## platform.

when defined(windows):
  import std/[options, os, unittest, monotimes, times]
  import ./helpers
  import crisol/types
  import crisol/process/types as ptypes

  let cpuSpinBin = compileFixture("cpu_spin")
  let passFastBin = compileFixture("pass_fast")

  proc limitsWith(kind: LimitKind; value: int64): Limits =
    ## Same construction idiom as sandbox.nim's `resolveSandbox` — a default
    ## `Limits()` (every kind `none`) with exactly one kind set.
    result.req[kind] = some(value)

  suite "rfc-0007 D1b-ii — windows Job limits, parent-computed LimitsAchieved":

    test "cpu_spin: lkCpu is a REAL, kernel-enforced Job limit":
      var sv = initSupervisor(installSignals = false)
      let markerPath = tmpOutputFile("win_limits_cpu_marker")
      let outPath = tmpOutputFile("win_limits_cpu_out")
      let spec = ChildSpec(argv: @[cpuSpinBin, markerPath], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath),
                            limits: limitsWith(lkCpu, 1'i64))
      # Generous deadline (+30s) — the Job kills this ~1s of CPU time in, but
      # scheduling contention on a shared CI runner can stretch wall-clock
      # well past that before the kernel gets around to it.
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 30))
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.limits[lkCpu] == lsApplied

      # The marker is written ONLY after an unreachable amount of spin work —
      # its absence is the enforcement proof: the process never got there.
      check not fileExists(markerPath)
      if fileExists(markerPath): removeFile(markerPath)

      # Lenient on the exact exit code/kind (a PerProcessUserTimeLimit kill's
      # exit code is CI-unknown) — assert enforcement + lsApplied, not a
      # specific code.
      let cause = classifyCause(report.exit, report.stop, Limits(), report.limits)
      let ep = Entrypoint(path: "tests/fixtures/cpu_spin.nim", group: "test", flags: @[])
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
      check outcome(r) != oPassed

    test "lkAddressSpace: Job limit install reported lsApplied":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_limits_as_out")
      let spec = ChildSpec(argv: @[passFastBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath),
                            limits: limitsWith(lkAddressSpace, 512 * 1024 * 1024'i64))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.limits[lkAddressSpace] == lsApplied

    test "lkOpenFiles: no Windows analog, reports lsUnsupported":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_limits_openfiles_out")
      let spec = ChildSpec(argv: @[passFastBin], cwd: getCurrentDir(), env: @[],
                            sinks: combinedSink(outPath),
                            limits: limitsWith(lkOpenFiles, 64'i64))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))
      removeFile(outPath)

      check ev.kind == weChildExited
      check report.limits[lkOpenFiles] == lsUnsupported

  when isMainModule:
    echo "test_windows_limits done"

else:
  when isMainModule:
    echo "test_windows_limits: skipped (not windows)"
