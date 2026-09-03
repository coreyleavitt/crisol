## test_conformance_import_purity.nim — rfc-0007 A2a-ii: the suite enforces
## its own backend-agnostic guarantee.
##
## Every tests/conformance/*.nim file may import `crisol/process` (the §1
## selection ladder) but must NEVER import a backend module directly
## (`crisol/process/posix`, `crisol/process/posixcore`, `crisol/process/linux`)
## — doing so would let one conformance case quietly depend on posix-only
## behavior, defeating the whole point of the suite: "every later backend
## lands under the same suite automatically" (§1 module-layout comment). This
## is a textual grep-assert, not a compiler check: process.nim's `when
## defined(...)` ladder means an accidental direct backend import would still
## compile cleanly on this host (Linux selects process/linux, which itself
## is a thin `import posix; export posix` shell over process/posix) — only a
## scan of the SOURCE TEXT catches the mistake the type checker cannot see.

import std/[os, strutils, unittest]

const thisDir = currentSourcePath().parentDir()

const forbiddenImports = [
  "crisol/process/posix",
  "crisol/process/posixcore",
  "crisol/process/linux",
  "crisol/process/windows",
]

suite "rfc-0007 A2a-ii — conformance suite import purity":

  test "no tests/conformance/*.nim file imports a process backend module directly":
    var offenders: seq[string]
    for kind, path in walkDir(thisDir):
      if kind != pcFile or not path.endsWith(".nim"): continue
      if path == currentSourcePath(): continue  # this file's own literals below
      let content = readFile(path)
      for forbidden in forbiddenImports:
        if content.contains(forbidden):
          offenders.add(path.extractFilename & " references \"" & forbidden & "\"")
    check offenders.len == 0
    for o in offenders:
      echo "  IMPORT PURITY VIOLATION: " & o

when isMainModule:
  echo "test_conformance_import_purity done"
