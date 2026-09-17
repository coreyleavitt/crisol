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
## TIER 3 — `isAbsolute`-based root-check tripwire. `isAbsolute` is a
## legitimate join/branch primitive (e.g. "is this already rooted, or do I
## need to join it onto something") but it is ALSO the shape a hand-rolled,
## unsound root-membership check would take (`if p.isAbsolute and p.startsWith
## (root): ...`), so every use outside `paths.nim` itself carries the same
## `# canon-ok: <reason>` marker Tier 2 uses — reusing the identical
## mechanism rather than inventing a second one.
##
## TIER 4 — no string-typed key-surface overload reappears. A-final-ii
## declares the pre-`TrackedPath` string-typed overloads of
## `sidecarPath`/`readSidecar`/`writeSidecar`/`identityKey`/`soundnessKey`/
## `slug` DELETED (slice S3 deleted the last one, cachelocalfs's string
## `sidecarPath`/`readSidecar`/`writeSidecar`). This scans every such proc's
## parameter list — balanced-paren extracted from the full file text, so a
## signature that wraps across lines (`writeSidecar`'s does) is still seen
## whole — for a bare `: string` identity parameter, after stripping the
## known-legitimate incidental string params (a directory `root:string`, an
## already-string `flagHash:string`).
##
## Comment lines (stripped line starts with `#`) are skipped for every
## line-based check — a doc comment that merely *mentions* an idiom is not a
## use of it.

import std/[os, strutils, unittest]

const thisDir = currentSourcePath().parentDir()
const srcDir = thisDir.parentDir.parentDir / "src"
const srcCrisol = srcDir / "crisol"
const srcCrisolMain = srcDir / "crisol.nim"
  ## The library/CLI facade sibling to `src/crisol/` — every scan below
  ## walks it too (wiring-audit S4): omitting it left the facade's own
  ## path handling (e.g. `crisol init`'s target-path resolution) unaudited.

# Files where canonicalization (Tier 2) is sanctioned and needs no marker:
# the paths.nim seam itself, plus the canonicalizer-adjacent modules that
# legitimately resolve real filesystem paths. `closure.nim`/`config.nim` are
# deliberately NOT here — they carry real canon-primitive traffic (symlink/
# realpath duality; §2 projectRoot/stateDir cwd-resolution) but a whole-file
# exemption would hide drift at any NEW, illegitimate site just as easily as
# it hides none today; every site in them now carries its own marker instead.
const tier2Allowlist = [
  "paths.nim",          # the canonicalization seam
  "compilereport.nim",  # ccache path inspection
]

proc isCommentLine(line: string): bool =
  let s = line.strip()
  s.len == 0 or s.startsWith("#")

proc allSourceFiles(): seq[string] =
  ## Every `.nim` file crisol ships as production source: everything under
  ## `src/crisol/` plus the sibling `src/crisol.nim` entry point.
  for path in walkDirRec(srcCrisol):
    if path.endsWith(".nim"): result.add path
  result.add srcCrisolMain

proc relLabel(path: string): string =
  if path == srcCrisolMain: "crisol.nim"
  else: path.relativePath(srcCrisol)

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

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc containsWord(line, word: string): bool =
  ## `word` as a whole identifier, not merely as a substring — so `isAbsolute`
  ## does not also match inside `isAbsoluteNative`.
  var start = 0
  while true:
    let idx = line.find(word, start)
    if idx < 0: return false
    let beforeOk = idx == 0 or not isIdentChar(line[idx - 1])
    let afterIdx = idx + word.len
    let afterOk = afterIdx >= line.len or not isIdentChar(line[afterIdx])
    if beforeOk and afterOk: return true
    start = idx + 1

proc hasBareIsAbsolute(line: string): bool =
  ## `isAbsolute` (std/os's root-check predicate), called either as
  ## `isAbsolute(x)` or UFCS `x.isAbsolute`.
  containsWord(line, "isAbsolute")

# Key-surface procs whose pre-`TrackedPath` string-typed overloads
# A-final-ii declares deleted (slice S3 deleted the last one).
const keySurfaceProcs = [
  "sidecarPath", "readSidecar", "writeSidecar",
  "identityKey", "soundnessKey", "slug",
]

# Incidental string-typed params that are legitimate on a key-surface proc's
# signature today — a directory root to join under, or an already-string
# flag hash — as opposed to the identity/key/path input itself.
const legitStringParams = ["root: string", "flagHash: string"]

proc extractParamList(text: string; openParenIdx: int): string =
  ## Balanced-paren extraction of the parameter list starting at the `(` at
  ## `text[openParenIdx]` — correct even when a signature wraps lines (as
  ## `writeSidecar`'s does).
  var depth = 0
  for i in openParenIdx ..< text.len:
    if text[i] == '(': inc depth
    elif text[i] == ')':
      dec depth
      if depth == 0: return text[openParenIdx + 1 ..< i]
  text[openParenIdx + 1 .. ^1]

proc keySurfaceViolations(path: string): seq[string] =
  ## Every `proc <name>*(` header for a key-surface name, checked for a
  ## reintroduced string-typed identity parameter.
  let text = readFile(path)
  let rel = relLabel(path)
  for name in keySurfaceProcs:
    let needle = "proc " & name & "*("
    var searchFrom = 0
    while true:
      let idx = text.find(needle, searchFrom)
      if idx < 0: break
      let openParenIdx = idx + needle.len - 1
      var params = extractParamList(text, openParenIdx)
      for legit in legitStringParams: params = params.replace(legit, "")
      if ": string" in params:
        let lineNo = 1 + text[0 ..< idx].count('\n')
        result.add rel & ":" & $lineNo & "  " & name &
          " has a string-typed identity param — the deleted overload shape reappeared"
      searchFrom = openParenIdx + 1

suite "RFC-0009 A-final-ii-b — path-identity completion gate":

  test "Tier 1 — no relativePath(, no raw root-prefix check, no TrackedPath ordering":
    var offenders: seq[string]
    for path in allSourceFiles():
      let rel = relLabel(path)
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
    for path in allSourceFiles():
      if path.extractFilename in tier2Allowlist: continue
      let rel = relLabel(path)
      var n = 0
      for line in lines(path):
        inc n
        if isCommentLine(line): continue
        if hasCanonPrimitive(line) and "# canon-ok:" notin line:
          offenders.add rel & ":" & $n & "  unmarked canonicalization — add # canon-ok: <reason> or move to the paths seam"
    for o in offenders:
      echo "  TIER-2 VIOLATION: " & o
    check offenders.len == 0

  test "Tier 3 — isAbsolute outside paths.nim carries a # canon-ok: marker":
    var offenders: seq[string]
    for path in allSourceFiles():
      if path.extractFilename == "paths.nim": continue
      let rel = relLabel(path)
      var n = 0
      for line in lines(path):
        inc n
        if isCommentLine(line): continue
        if hasBareIsAbsolute(line) and "# canon-ok:" notin line:
          offenders.add rel & ":" & $n &
            "  unmarked isAbsolute — add # canon-ok: <reason> (join/branch decision) or route through paths.isUnderRoot if this is a root-membership check"
    for o in offenders:
      echo "  TIER-3 VIOLATION: " & o
    check offenders.len == 0

  test "Tier 4 — no string-typed key-surface overload reappears":
    var offenders: seq[string]
    for path in allSourceFiles():
      offenders.add keySurfaceViolations(path)
    for o in offenders:
      echo "  TIER-4 VIOLATION: " & o
    check offenders.len == 0

when isMainModule:
  echo "test_rfc9_path_identity_gate done"
