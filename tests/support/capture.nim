## tests/support/capture.nim — RFC-0009 Stage B (B3a).
##
## Portable in-process capture of the C-level stdout/stderr file descriptors,
## for CLI tests that call `runMain(...)` directly and then assert on what it
## printed. The pattern is the classic dup/dup2 redirect: save fd 1 (or 2),
## point it at a temp file for the duration of `body`, then restore.
##
## Why not `std/posix`: this is a SHARED test helper, and the de-POSIX sweep
## forbids `std/posix` in tests/support/ (test_conformance_import_purity.nim)
## — one posix import here would re-POSIX every test that captures output.
## So the three CRT calls are bound directly with `importc`, split by platform:
## POSIX `dup`/`dup2`/`close` (`<unistd.h>`) and Windows `_dup`/`_dup2`/
## `_close` (`<io.h>`), plus `fileno`/`_fileno` to get the CRT fd of the temp
## file. fd 1 = stdout and fd 2 = stderr under both the POSIX and the MSVCRT
## conventions, so the redirect target numbers are identical on both.
##
## This replaces the per-file `captureStdoutToFile`/`captureStderrToFile`
## helpers that ~28 CLI tests hand-rolled against `std/posix` — those files now
## `import ../support/capture` and drop their own copy plus the posix import,
## so they compile AND run on Windows.

import std/[os, syncio]

when defined(windows):
  proc cDup(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc cDup2(src, dst: cint): cint {.importc: "_dup2", header: "<io.h>".}
  proc cClose(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  proc cFileno(f: File): cint {.importc: "_fileno", header: "<stdio.h>".}
else:
  proc cDup(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
  proc cDup2(src, dst: cint): cint {.importc: "dup2", header: "<unistd.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  proc cFileno(f: File): cint {.importc: "fileno", header: "<stdio.h>".}

proc captureFdToFile(targetFd: cint; stream: File; path: string;
                     body: proc()) =
  ## Redirect `targetFd` (1=stdout, 2=stderr) to `path` for the duration of
  ## `body`, flushing `stream` on both sides so nothing leaks or is lost, then
  ## restore the original fd. Raises OSError if the initial dup fails.
  let f = open(path, fmWrite)
  let fileFd = cFileno(f)
  flushFile(stream)
  let saved = cDup(targetFd)
  if saved < 0:
    close(f)
    raise newException(OSError, "dup(" & $targetFd & ") failed")
  discard cDup2(fileFd, targetFd)
  try:
    body()
    flushFile(stream)
  finally:
    discard cDup2(saved, targetFd)
    discard cClose(saved)
    close(f)

proc captureStdoutToFile*(path: string; body: proc()) =
  ## Run `body`, capturing everything it writes to stdout (fd 1) into `path`.
  captureFdToFile(1.cint, stdout, path, body)

proc captureStderrToFile*(path: string; body: proc()) =
  ## Run `body`, capturing everything it writes to stderr (fd 2) into `path`.
  captureFdToFile(2.cint, stderr, path, body)

# --- string-returning convenience wrappers ---------------------------------
# These cover the ~28 CLI tests' hand-rolled variants. A private temp path is
# used and removed; the captured text is returned.


proc uniqueTmp(tag: string): string =
  getTempDir() / ("crisol_cap_" & tag & "_" & $getCurrentProcessId() & ".txt")

proc captureStdout*(body: proc()): string =
  ## Run `body`, return everything it wrote to stdout.
  let p = uniqueTmp("out")
  captureStdoutToFile(p, body)
  result = readFile(p)
  try: removeFile(p) except CatchableError: discard

proc captureStderr*(body: proc()): string =
  ## Run `body`, return everything it wrote to stderr.
  let p = uniqueTmp("err")
  captureStderrToFile(p, body)
  result = readFile(p)
  try: removeFile(p) except CatchableError: discard

proc captureBoth*(body: proc()): tuple[stdout, stderr: string] =
  ## Run `body` ONCE, capturing stdout and stderr simultaneously (both fds are
  ## redirected for the duration). Replaces the per-file `captureBoth(args)`
  ## helpers: a caller that needs runMain's exit code captures it via a closure
  ## variable, e.g.
  ##   var code = 0
  ##   let (outT, errT) = captureBoth(proc() = code = runMain(args))
  let outP = uniqueTmp("bothout")
  let errP = uniqueTmp("botherr")
  let outF = open(outP, fmWrite)
  let errF = open(errP, fmWrite)
  let outFd = cFileno(outF)
  let errFd = cFileno(errF)
  flushFile(stdout)
  flushFile(stderr)
  let savedOut = cDup(1.cint)
  let savedErr = cDup(2.cint)
  discard cDup2(outFd, 1.cint)
  discard cDup2(errFd, 2.cint)
  outF.close()
  errF.close()
  try:
    body()
    flushFile(stdout)
    flushFile(stderr)
  finally:
    discard cDup2(savedOut, 1.cint)
    discard cDup2(savedErr, 2.cint)
    discard cClose(savedOut)
    discard cClose(savedErr)
  result = (readFile(outP), readFile(errP))
  try: removeFile(outP) except CatchableError: discard
  try: removeFile(errP) except CatchableError: discard
