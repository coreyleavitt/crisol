## test_windows_sinks.nim — rfc-0007 D1a: "inherited handles to sinks" —
## proven, not merely present in spawnChild's STARTUPINFO wiring. The
## `noisy_output` fixture (shared with the cross-platform conformance suite's
## output-cap coverage) writes a deterministic, byte-checkable pattern to
## stdout; this proves that output lands in the sink FILE crisol hands the
## child at spawn, via CreateProcessW's inherited `hStdOutput`/`hStdError`
## (bInheritHandle + STARTF_USESTDHANDLES) — not merely that the child ran.
##
## Driven through the real Supervisor (`process.nim`'s selection ladder via
## ./helpers), never the backend module directly — tests/conformance's own
## import-purity rule (test_conformance_import_purity.nim).
##
## Compile-time gated to `defined(windows)` (mirrors test_windows_smoke.nim):
## the `else` branch must still compile and exit cleanly on Linux/macOS,
## since crisol.nimble's self-discovering test task finds every
## `test_*.nim` file under tests/ regardless of host platform.

when defined(windows):
  import std/[os, unittest, monotimes, times]
  import ./helpers

  let noisyBin = compileFixture("noisy_output")

  proc expectedPattern(n: int): string =
    result = newString(n)
    for i in 0 ..< n:
      result[i] = char(ord('a') + (i mod 26))

  suite "rfc-0007 D1a — inherited handles to sinks":

    test "noisy_output: child stdout is inherited into the sink file, byte-for-byte":
      var sv = initSupervisor(installSignals = false)
      let outPath = tmpOutputFile("win_sink_inherit")
      const n = 2000
      let spec = ChildSpec(argv: @[noisyBin], cwd: getCurrentDir(),
                            env: @[("CRISOL_NOISY_BYTES", $n)],
                            sinks: combinedSink(outPath))
      let (ev, report) = spawnAndWait(sv, spec, getMonoTime() + initDuration(seconds = 10))

      check ev.kind == weChildExited
      check report.exit.kind == ekExited
      check report.exit.code == 0

      let content = readFile(outPath)
      removeFile(outPath)
      check content.len == n
      check content == expectedPattern(n)

  when isMainModule:
    echo "test_windows_sinks done"

else:
  when isMainModule:
    echo "test_windows_sinks: skipped (not windows)"
