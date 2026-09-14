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

  test "no tests/support/*.nim file imports std/posix (RFC-0009 B-inventory)":
    # The de-POSIX sweep's SHARED helpers must themselves be portable, or a
    # single posix import in tests/support/ would re-POSIX every test that
    # uses it — defeating the windows-green goal from one place. The sweep
    # regex is RFC-0009's pinned `^\s*(import|from).*\bposix\b`.
    let supportDir = thisDir.parentDir / "support"
    var offenders: seq[string]
    if dirExists(supportDir):
      for kind, path in walkDir(supportDir):
        if kind != pcFile or not path.endsWith(".nim"): continue
        for line in lines(path):
          let s = line.strip()
          if (s.startsWith("import") or s.startsWith("from")) and
             (" posix" in s or "/posix" in s or "[posix" in s or
              ",posix" in s or "\tposix" in s):
            offenders.add(path.extractFilename & ": " & s)
            break
    check offenders.len == 0
    for o in offenders:
      echo "  tests/support POSIX IMPORT: " & o

when isMainModule:
  echo "test_conformance_import_purity done"
