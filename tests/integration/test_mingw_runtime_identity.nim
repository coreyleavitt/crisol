## test_mingw_runtime_identity.nim — R10-L9: the mingw runtime identity,
## produced by a real run on Windows.
##
## THE FINDING. `ccidentity`'s runtime half has a mingw arm (`__MINGW32__`:
## the content of `libucrt.a` and `libmsvcrt.a` as the driver resolves them,
## and the system DLL each binds, `ucrtbase.dll` / `msvcrt.dll`). It was
## written from documented output and had no producer on any CI leg: the
## windows leg is the MSVC leg, and the Linux and macOS legs never define
## `__MINGW32__`.
##
## WHAT THIS FILE PINS, on Windows with a MinGW-w64 `gcc` on PATH
## (windows-latest ships one in `C:\mingw64\bin`):
##   1. a project `nim.cfg` saying `cc = gcc` identifies BOTH halves through
##      the real probe, and the runtime half is the mingw arm's answer (it
##      names `ucrtbase.dll`, the DLL a UCRT MinGW program loads);
##   2. a real `crisol run` of that project compiles with gcc and runs, and a
##      second run is served from the result cache -- which it can only be if
##      the toolchain was identified (an unidentified one disables the cache).
##
## A Windows host without `gcc` on PATH prints the CRISOL-SKIP-TEST marker
## below; ci/assert-subset-honesty.sh forbids it on the windows leg. On any
## other platform the file compiles to a one-line notice.
##
## Run with (Windows):
##   nim r --hints:off --warnings:off --path:src tests/integration/test_mingw_runtime_identity.nim

when defined(windows):
  import std/[os, strutils, unittest]
  import crisol/api
  import crisol/runcore        # runTestsWith/productionRunDeps (uncontracted)
  import crisol/types          # CacheDecision
  import crisol/ccidentity     # CcProbeContext/toolchainVerdict
  import "../support/ccprobes" # ccFingerprint
  import "../support/helpers"  # withTempProject

  const ThisFile = "tests/integration/test_mingw_runtime_identity.nim"

  proc useGcc(projectRoot: string) =
    writeFile(projectRoot / "nim.cfg", "cc = gcc\n")

  let haveGcc = findExe("gcc").len > 0
  if haveGcc:
    echo "R10-L9 MINGW REAL: gcc = " & findExe("gcc")

  suite "R10-L9 — mingw runtime identity on Windows":

    test "a project `cc = gcc` is identified, and the runtime half is the mingw arm's":
      if not haveGcc:
        echo "CRISOL-SKIP-TEST: " & ThisFile & "#mingw_identified_no_gcc"
        skip()
      else:
        withTempProject:
          useGcc(projectRoot)
          let fp = ccFingerprint(CcProbeContext(projectRoot: projectRoot,
                                                stateDir: projectRoot / ".crisol",
                                                flags: @[]))
          checkpoint "fingerprint: " & $fp
          checkpoint "compiler why: " & fp.compiler.why
          checkpoint "runtime why: " & fp.runtime.why
          echo "R10-L9 MINGW FINGERPRINT: " & $fp
          check toolchainVerdict(fp).kind == tvIdentified
          check fp.compiler.state == cfsKnown
          check fp.runtime.state == cfsKnown
          check "ucrtbase.dll" in fp.runtime.text or "msvcrt.dll" in fp.runtime.text

    test "a real run under `cc = gcc` compiles, runs, and is served from the cache the second time":
      if not haveGcc:
        echo "CRISOL-SKIP-TEST: " & ThisFile & "#mingw_run_no_gcc"
        skip()
      else:
        withTempProject:
          useGcc(projectRoot)
          writeFile(projectRoot / "tests" / "unit" / "test_a.nim", "quit(0)\n")
          let opts = RunOptions(configPath: projectRoot / "crisol.kdl",
                                installSignals: false, showProgress: false,
                                persist: false)
          let rr1 = runTestsWith(opts, productionRunDeps())
          checkpoint "run 1: " & $rr1.status & " " & rr1.error
          require rr1.status == rsOk
          require rr1.results.len == 1
          check rr1.results[0].outcome == oPassed
          check rr1.results[0].cacheDecision == cdmStored
          let rr2 = runTestsWith(opts, productionRunDeps())
          checkpoint "run 2: " & $rr2.status & " " & rr2.error
          require rr2.status == rsOk
          require rr2.results.len == 1
          check rr2.results[0].cacheDecision == cdmHit
          check rr2.results[0].cached

  when isMainModule:
    echo "test_mingw_runtime_identity done"
else:
  when isMainModule:
    echo "test_mingw_runtime_identity: skipped (not windows)"
