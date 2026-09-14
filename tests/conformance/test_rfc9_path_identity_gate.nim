## test_rfc9_path_identity_gate.nim — RFC-0009 A-final-ii-b.
##
## A textual completion gate over `src/crisol/**.nim` that keeps path handling
## SOUND after the TrackedPath migration. Two tiers, mirroring the style of
## test_conformance_import_purity.nim: read the source text, assert, print any
## offender with file:line. These are properties the Nim type checker cannot
## see — a raw string-prefix root check compiles perfectly — so only a scan of
## the source catches the mistake.
##
## TIER 1 — soundness hazards (enforced across ALL of src/crisol/, no
## file allowlist). Any occurrence is a failure:
##   1. `relativePath(` — recomputing a relative path by hand instead of using
##      TrackedPath/`classify`. None today.
##   2. A raw root-membership prefix check: `startsWith(<root> & <sep>)`. This
##      is the classic bug where `/proj-old` matches under `/proj`. The ONE
##      sanctioned implementation is `paths.isUnderRoot` (component-boundary,
##      separator-normalized); every caller must route through it. Detected as
##      a `startsWith(` on the same line as `& DirSep` / `& $DirSep` / `& "/"`.
##      `paths.underRoot`'s own `candidate.startsWith(prefix)` (prefix is a
##      precomputed local, no inline `& sep`) is deliberately NOT matched.
##   3. Defining an ordering operator (`<` `<=` `>` `>=`) over `TrackedPath`.
##      TrackedPath has NO such operator by design — ordering MUST go through
##      `cmpKeyBytes` (portability, never folds). Any hand-rolled comparator
##      would let a fold-order sneak into a persisted/serialized sequence.
##
## TIER 2 — canonicalization primitives (`absolutePath(`, `normalizedPath`,
## `expandFilename(`). Canonicalization belongs in the `paths.nim` seam and a
## handful of sanctioned canonicalizer-adjacent modules; ANYWHERE else it must
## be a conscious, documented choice carrying an inline `# canon-ok: <reason>`
## marker on the same line, or the gate fails. This catches silent drift in
## the pure-logic modules (planner/keys/narrow/order/...) which must never
## canonicalize.
##
## Comment lines (stripped line starts with `#`) are skipped for every check —
## a doc comment that merely *mentions* an idiom is not a use of it.

import std/[os, strutils, unittest]

const thisDir = currentSourcePath().parentDir()
const srcCrisol = thisDir.parentDir.parentDir / "src" / "crisol"

# Files where canonicalization (Tier 2) is sanctioned and needs no marker:
# the paths.nim seam itself, plus the canonicalizer-adjacent / Non-goals
# modules that legitimately resolve real filesystem paths.
const tier2Allowlist = [
  "paths.nim",          # the canonicalization seam
  "closure.nim",        # §5 symlink/realpath duality (lexical vs real)
  "config.nim",         # §2 projectRoot/stateDir cwd-resolution
  "compilereport.nim",  # ccache path inspection
  "ccprobe.nim",
  "artifactid.nim",
  "report.nim",
]

proc isCommentLine(line: string): bool =
  let s = line.strip()
  s.len == 0 or s.startsWith("#")

proc hasRawRootPrefixCheck(line: string): bool =
  ## `startsWith(` on the same code line as an appended separator — the
  ## raw root-membership idiom. `paths.isUnderRoot` is the one sanctioned
  ## implementation; it does not use this idiom, so it is not matched.
  if "startsWith(" notin line: return false
  "& DirSep" in line or "& $DirSep" in line or "& \"/\"" in line or
    "& '/'" in line

proc definesTrackedPathOrdering(line: string): bool =
  ## A `<` / `<=` / `>` / `>=` operator defined with a TrackedPath parameter.
  if "TrackedPath" notin line: return false
  if not ("proc " in line or "func " in line or "template " in line): return false
  "`<`" in line or "`<=`" in line or "`>`" in line or "`>=`" in line

proc hasCanonPrimitive(line: string): bool =
  "absolutePath(" in line or "normalizedPath" in line or "expandFilename(" in line

suite "RFC-0009 A-final-ii-b — path-identity completion gate":

  test "Tier 1 — no relativePath(, no raw root-prefix check, no TrackedPath ordering":
    var offenders: seq[string]
    for path in walkDirRec(srcCrisol):
      if not path.endsWith(".nim"): continue
      let rel = path.relativePath(srcCrisol)
      var n = 0
      for line in lines(path):
        inc n
        if isCommentLine(line): continue
        if "relativePath(" in line:
          offenders.add rel & ":" & $n & "  relativePath( — use TrackedPath/classify"
        if hasRawRootPrefixCheck(line):
          offenders.add rel & ":" & $n & "  raw root-prefix startsWith — use paths.isUnderRoot"
        if definesTrackedPathOrdering(line):
          offenders.add rel & ":" & $n & "  ordering operator over TrackedPath — use cmpKeyBytes"
    for o in offenders:
      echo "  TIER-1 VIOLATION: " & o
    check offenders.len == 0

  test "Tier 2 — canonicalization outside the seam carries a # canon-ok: marker":
    var offenders: seq[string]
    for path in walkDirRec(srcCrisol):
      if not path.endsWith(".nim"): continue
      if path.extractFilename in tier2Allowlist: continue
      let rel = path.relativePath(srcCrisol)
      var n = 0
      for line in lines(path):
        inc n
        if isCommentLine(line): continue
        if hasCanonPrimitive(line) and "# canon-ok:" notin line:
          offenders.add rel & ":" & $n & "  unmarked canonicalization — add # canon-ok: <reason> or move to the paths seam"
    for o in offenders:
      echo "  TIER-2 VIOLATION: " & o
    check offenders.len == 0

when isMainModule:
  echo "test_rfc9_path_identity_gate done"
