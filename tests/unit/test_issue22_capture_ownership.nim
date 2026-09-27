## tests/unit/test_issue22_capture_ownership.nim — issue #22.
##
## `toolexec` is the sole owner of subprocess output capture. This pins that:
## no module may read a child's stdout or stderr with `streams.readAll`, which
## silently truncates at the child's first flush on Windows (see
## `crisol/toolexec`'s module doc), and no module may read one pipe of a
## separate-stream child without the other, which deadlocks (see
## `crisol/toolexec.runTool`).
##
## Only the `readAll` rule is pinned mechanically. "A separate-stderr spawn
## must be drained concurrently" is stated in `toolexec`'s own doc instead of being
## scanned for: every text heuristic tried for it keyed on the shape of an
## `options = {...}` line, which a harmless reformat would break. There are
## five spawn sites in `src/` in total and all five route through `toolexec`.
##
## A source-level pin, not a behavioural one: the behaviour is proven by
## `tests/integration/test_issue22_capture.nim` and
## `tests/integration/test_issue22_changed_completeness.nim`. This exists so a
## SIXTH hand-rolled capture site cannot quietly reintroduce the bug at a call
## site those tests do not reach — which is exactly how five of them
## accumulated. Same shape and rationale as
## `test_rfc7_a3_ioutils_ownership.nim`.

import std/[os, strutils, unittest]

const srcRoot = currentSourcePath().parentDir().parentDir().parentDir() / "src"

iterator allNimFiles(): string =
  for path in walkDirRec(srcRoot):
    if path.endsWith(".nim"): yield path

proc relSlash(path: string): string =
  path[srcRoot.len + 1 .. ^1].replace('\\', '/')

proc readsAChildStreamWithReadAll(line: string): bool =
  ## True iff `line` calls `readAll` on a `Process`'s stdout or stderr stream.
  ## Deliberately narrow: `readAll` on a FILE (runner.nim's `f.readAll()`) is
  ## unrelated and stays allowed.
  let s = line.strip
  if s.startsWith("#"): return false
  ("outputStream" in s or "errorStream" in s) and "readAll" in s

suite "issue #22 — toolexec owns subprocess output capture":

  test "no module reads a child's stdout or stderr with readAll":
    var offenders: seq[string]
    for path in allNimFiles():
      var lineNo = 1
      for line in readFile(path).splitLines:
        if readsAChildStreamWithReadAll(line):
          offenders.add(relSlash(path) & ":" & $lineNo & ": " & line.strip)
        inc lineNo
    checkpoint("child-stream readAll sites (use toolexec.runTool; " &
               "it drains to genuine EOF):\n" & offenders.join("\n"))
    check offenders.len == 0

when isMainModule:
  echo "test_issue22_capture_ownership done"
