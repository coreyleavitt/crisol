## test_rfc7_a3_ioutils_ownership.nim — rfc-0007 A3: `ioutils` becomes the
## sole owner of raw file I/O.
##
## Two textual (not type-checker) assertions over every `.nim` file under
## `src/` — same rationale as `test_conformance_import_purity.nim`: the
## boundary this slice draws is a SOURCE-TEXT convention (which module is
## "allowed" to touch `std/posix`/`std/osproc` directly), invisible to the
## compiler, so only a scan of the text itself can catch a violation:
##
##   1. `std/posix` import count outside `crisol/process/*`, `ioutils.nim`,
##      `lock.nim`, `signals.nim` is zero — the A3 bullet's own acceptance
##      test. `crisol.nim`, `depgraph.nim`, `jsonout.nim`, `ledger.nim`, and
##      `shardedledger.nim` are the five modules this slice migrates off
##      hand-rolled `posix.open`/`write`/`close`/`getpid` onto the four named
##      `ioutils` primitives (`exclusiveCreate`, `appendOpen`,
##      `atomicPublish`, `writeAllFd`) plus whatever well-named additions
##      their actual usage required (`createOverwrite`, `closeFd`,
##      `readRandomBytes`, `lastErrorString`, `writeGuardedFile`) — see
##      ioutils.nim's module doc for the full primitive set and why each
##      exists.
##   2. Every `std/osproc` import site carries the `# process-contract-exempt`
##      marker on the SAME line — RFC-0007 §"Scope": short-lived tool
##      invocations (git, the ccprobe/nimprobe probes, compiledriver's
##      measure-mode cc/link, gitdiff, icbaseline, measureworker,
##      workerplan) carry no `Evidence` claims and join no kill domain, so
##      they sit outside the process contract by design — the marker makes
##      that boundary visible in the source instead of accidental.
##
## `memprobe.nim` reads `/proc` as plain files via `std/os`/`readFile` and
## imports neither `std/posix` nor `std/osproc` — nothing to allow-list for it.

import std/[os, strutils, unittest]

const CrisolRoot = currentSourcePath().parentDir.parentDir.parentDir
const SrcDir = CrisolRoot / "src"

## Files (by path relative to SrcDir, forward-slash form) allowed to import
## `std/posix` directly. `crisol/process/*` is a directory allowance handled
## separately below (an open-ended set of backend files, not enumerated here).
const AllowedPosixFiles = [
  "crisol/ioutils.nim",
  "crisol/lock.nim",
  "crisol/signals.nim",
]

proc allNimFiles(): seq[string] =
  for f in walkDirRec(SrcDir):
    if f.endsWith(".nim"):
      result.add f

proc relSlash(path: string): string =
  path.relativePath(SrcDir).replace('\\', '/')

proc isAllowedPosixSite(rel: string): bool =
  rel.startsWith("crisol/process/") or rel in AllowedPosixFiles

proc importsStdPosixLine(line: string): bool =
  ## True iff `line` is (ignoring leading whitespace) an `import std/posix`
  ## statement — as a bare import or via `as`/`except` — but NOT a doc
  ## comment or prose line merely mentioning the module (those start with
  ## `#`/`##`, which this check excludes by requiring the line to start
  ## with the literal keyword `import`).
  let s = line.strip
  s == "import std/posix" or s.startsWith("import std/posix ") or
    s.startsWith("import std/posix\t")

proc importsStdOsprocLine(line: string): bool =
  ## True iff `line` is an import statement (bare `import`, a `std/[...]`
  ## bracketed list, or `from ... import`) that pulls in `std/osproc`.
  let s = line.strip
  if not (s.startsWith("import") or s.startsWith("from")): return false
  s.contains("std/osproc") or s.contains("std/[") and
    (block:
      # bracketed form: `import std/[a, osproc, b]` — match "osproc" as a
      # whole list element, not a substring of some other module name.
      var found = false
      for part in s.split({'[', ']', ',', ' '}):
        if part == "osproc": found = true
      found)

suite "rfc-0007 A3 — ioutils sole owner of raw file I/O":

  test "std/posix import count outside process/, ioutils, lock, signals is zero":
    var offenders: seq[string]
    for path in allNimFiles():
      let rel = relSlash(path)
      if isAllowedPosixSite(rel): continue
      var lineNo = 1
      for line in readFile(path).splitLines:
        if importsStdPosixLine(line):
          offenders.add(rel & ":" & $lineNo & ": " & line.strip)
        inc lineNo
    checkpoint("unexpected std/posix imports:\n" & offenders.join("\n"))
    check offenders.len == 0

  test "every std/osproc import site carries the process-contract-exempt marker":
    var offenders: seq[string]
    for path in allNimFiles():
      let rel = relSlash(path)
      var lineNo = 1
      for line in readFile(path).splitLines:
        if importsStdOsprocLine(line):
          if "process-contract-exempt" notin line:
            offenders.add(rel & ":" & $lineNo & ": " & line.strip)
        inc lineNo
    checkpoint("std/osproc import sites missing the exempt marker:\n" &
               offenders.join("\n"))
    check offenders.len == 0

when isMainModule:
  echo "test_rfc7_a3_ioutils_ownership done"
