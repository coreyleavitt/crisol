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
##      separator-normalized); every caller must route through it. Detected
##      two ways: (a) a `startsWith(` on the same line as `& DirSep` /
##      `& $DirSep` / `& "/"` / `& '/'`; (b) a per-file, whole-file-scoped
##      identifier tracker — any `let`/`var` binding whose right-hand side
##      appends one of those same separators is recorded, and any LATER
##      `startsWith(` use mentioning that identifier (as receiver or as
##      either argument) is flagged too. (b) exists because the idiom splits
##      across two lines just as often as it sits on one — `paths.underRoot`
##      itself is `let prefix = rootAbs & "/"` on one line, then
##      `candidate.startsWith(prefix)` on the next — so (a) alone is blind to
##      a copy-paste of that exact shape anywhere else. `underRoot` is the
##      ONE sanctioned two-line instance; it is exempted by a narrow
##      (file, enclosing-proc, identifier) allowlist entry below, not a
##      whole-file or whole-idiom exemption — a new two-line evasion
##      anywhere else, even elsewhere in `paths.nim`, still trips the gate.
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
## Tiers 2 and 3 are an AUDIT TRAIL, not soundness enforcement (F23): the
## gate checks only that a `# canon-ok:` marker is PRESENT on the line — it
## does not, and cannot, validate that the marker's stated `<reason>` is
## true. A misleading or lazy reason still satisfies the gate. The value
## these two tiers provide is documentation discipline enforced at review
## time (every canonicalization/`isAbsolute` site outside the seam is
## forced to say something, in the diff, for a human reviewer to read and
## judge) — not a machine-checked correctness property the way Tiers 1 and
## 4 are. The marker's reason text is trusted.
##
## TIER 4 — no string-typed key-surface overload reappears. A-final-ii
## declares the pre-`TrackedPath` string-typed overloads of
## `sidecarPath`/`readSidecar`/`writeSidecar`/`identityKey`/`soundnessKey`/
## `slug` DELETED (slice S3 deleted the last one, cachelocalfs's string
## `sidecarPath`/`readSidecar`/`writeSidecar`). Two layers:
##   (a) the closed name list (`keySurfaceProcs`, below): every such proc's
##       parameter list — balanced-paren extracted from the full file text,
##       so a signature that wraps across lines (`writeSidecar`'s does) is
##       still seen whole — is checked for a bare `: string` identity
##       parameter, after stripping the known-legitimate incidental string
##       params (a directory `root:string`, an already-string
##       `flagHash:string`).
##   (b) a concept-shaped pattern layer, independent of any name list: ANY
##       proc (anywhere in `src/crisol/**`) whose RETURN TYPE names a key
##       type (`CacheKeyPath`/`SoundnessKey`/`IdentityKey` — i.e. it
##       PRODUCES a key) is held to the same bare-`: string`-param check.
##       This is what actually stops a NEW key-deriving proc, added under a
##       name nobody anticipated when `keySurfaceProcs` was written, from
##       going uncovered. (a) stays as a second layer because it also
##       catches an overload whose return type is a plain `string`
##       (`sidecarPath`/`slug` both return `string`, not a key type) that a
##       return-type-based signal cannot see by construction.
##
## Comment lines (stripped line starts with `#`) are skipped for every
## line-based check — a doc comment that merely *mentions* an idiom is not a
## use of it.

import std/[os, strutils, tables, unittest]

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

# ---------------------------------------------------------------------------
# Tier 1 check #2, part (b) — the two-line raw-root-prefix evasion: a
# `let`/`var` binding builds `<expr> & <sep>` on one line, a LATER
# `startsWith(` mentions that identifier on another. Same-line-only
# `hasRawRootPrefixCheck` above is blind to this by construction.
# ---------------------------------------------------------------------------

proc topLevelDeclName(line: string): string =
  ## If `line` opens a column-0 `proc`/`func` declaration, returns its name
  ## (stops at `*`, `(`, or `[`); else "". Used only to scope the allowlist
  ## below to the enclosing proc — a lexical, not semantic, notion of
  ## "enclosing", which is all a column-0 heading gives us, but it is exact
  ## for this codebase's style (no top-level proc nests inside another).
  for kw in ["proc ", "func "]:
    if line.startsWith(kw):
      var i = kw.len
      let start = i
      while i < line.len and isIdentChar(line[i]): inc i
      if i > start: return line[start ..< i]
  ""

proc separatorAppendBinding(line: string): string =
  ## If the STRIPPED `line` is a `let`/`var` declaration whose right-hand
  ## side appends one of the four root-prefix separators
  ## (`& DirSep` / `& $DirSep` / `& "/"` / `& '/'`), returns the bound
  ## identifier; else "". This is exactly the shape `paths.nim:349`
  ## (`let prefix = if rootAbs.endsWith("/"): rootAbs else: rootAbs & "/"`)
  ## takes — the first half of the two-line idiom part (b) above exists to
  ## catch.
  let s = line.strip()
  var kwLen = 0
  for kw in ["let ", "var "]:
    if s.startsWith(kw): kwLen = kw.len
  if kwLen == 0: return ""
  let hasAppend = "& DirSep" in s or "& $DirSep" in s or "& \"/\"" in s or
    "& '/'" in s
  if not hasAppend: return ""
  var i = kwLen
  let start = i
  while i < s.len and isIdentChar(s[i]): inc i
  if i == start: return ""
  s[start ..< i]

# The ONE sanctioned two-line instance of the raw-root-prefix idiom:
# `paths.underRoot` builds `prefix = rootAbs & "/"` then compares via
# `candidate.startsWith(prefix)` — that IS `isUnderRoot`'s own
# implementation (the docstring on `isUnderRoot` names this file as the
# gate that must not flag it), not an evasion of it. Scoped to
# (file, enclosing proc, identifier) rather than the whole file or the
# whole idiom, so a NEW two-line evasion introduced anywhere else in
# `paths.nim` — even in a different proc — still trips the gate.
const tier1RawPrefixAllowlist = [
  ("paths.nim", "underRoot", "prefix"),
]

proc isTier1PrefixAllowlisted(file, procName, ident: string): bool =
  for (f, p, i) in tier1RawPrefixAllowlist:
    if f == file and p == procName and i == ident: return true
  false

proc rawRootPrefixViolations(fileLines: seq[string]; fileLabel: string): seq[string] =
  ## Tier 1 check #2 in full: same-line (`hasRawRootPrefixCheck`) plus the
  ## two-line evasion above. The identifier tracker is PROC-SCOPED, not
  ## whole-file: bindings recorded while inside a given top-level
  ## proc/func are cleared the moment the next column-0 `proc `/`func `
  ## heading is seen (`topLevelDeclName`), since this codebase's style has
  ## no top-level proc nesting inside another, so a column-0 heading is
  ## always a fresh lexical scope. Without this, an unrelated LATER proc
  ## that happens to reuse the same local/param name a tracked proc bound
  ## (e.g. `p`) would false-positive on its own, unrelated `startsWith(`
  ## use — the tracker had no way to know `p` from proc A was long out of
  ## scope by the time proc B used a same-named `p` of its own. A binding
  ## recorded OUTSIDE any proc (`currentProc == ""`, i.e. genuine top-level
  ## module scope) is tracked file-wide instead, since a module-level name
  ## really is visible for the rest of the file. See the self-test below
  ## for both the proc-scoped-clearing fixture and the still-caught
  ## same-shape-different-proc fixture.
  var currentProc = ""
  var moduleSepIdents: Table[string, bool]
  var procSepIdents: Table[string, bool]
  for i, line in fileLines:
    let lineNo = i + 1
    let declName = topLevelDeclName(line)
    if declName.len > 0:
      currentProc = declName
      procSepIdents.clear()
    if isCommentLine(line): continue
    if hasRawRootPrefixCheck(line):
      result.add fileLabel & ":" & $lineNo &
        "  raw root-prefix startsWith — use paths.isUnderRoot"
    let boundIdent = separatorAppendBinding(line)
    if boundIdent.len > 0:
      if currentProc.len == 0: moduleSepIdents[boundIdent] = true
      else: procSepIdents[boundIdent] = true
    if "startsWith(" in line:
      for ident in moduleSepIdents.keys:
        if containsWord(line, ident) and
           not isTier1PrefixAllowlisted(fileLabel, currentProc, ident):
          result.add fileLabel & ":" & $lineNo &
            "  raw root-prefix startsWith via two-line binding '" & ident &
            "' — use paths.isUnderRoot"
      for ident in procSepIdents.keys:
        if containsWord(line, ident) and
           not isTier1PrefixAllowlisted(fileLabel, currentProc, ident):
          result.add fileLabel & ":" & $lineNo &
            "  raw root-prefix startsWith via two-line binding '" & ident &
            "' — use paths.isUnderRoot"

# Key-surface procs whose pre-`TrackedPath` string-typed overloads
# A-final-ii declares deleted (slice S3 deleted the last one).
#
# MAINTENANCE RULE: this list is a closed enumeration by NAME — it cannot
# see a newly-added key-deriving proc under a name it doesn't already know.
# `keyProducingPatternViolations` below is the concept-shaped second layer:
# it catches any proc whose RETURN TYPE names a key type (CacheKeyPath /
# SoundnessKey / IdentityKey) regardless of its name. A new key-deriving
# proc is covered automatically IFF it returns one of those key types; if
# it instead returns a plain `string` (as `sidecarPath`/`slug` do), it is
# NOT visible to the pattern layer and MUST be added to this list by hand.
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

# ---------------------------------------------------------------------------
# Tier 4, layer (b) — concept-shaped: ANY proc whose return type names a key
# type, regardless of its name, checked for the same reintroduced
# string-typed identity parameter `keySurfaceViolations` above checks by
# name. See the MAINTENANCE RULE comment on `keySurfaceProcs` above.
# ---------------------------------------------------------------------------

proc findMatchingClose(text: string; openIdx: int; open, close: char): int =
  ## Index of the `close` that balances the `open` at `text[openIdx]`.
  ## Falls back to the last index if unbalanced (should not happen on
  ## syntactically valid Nim source) — never raises, never loops forever.
  var depth = 0
  for i in openIdx ..< text.len:
    if text[i] == open: inc depth
    elif text[i] == close:
      dec depth
      if depth == 0: return i
  text.len - 1

type ProcDecl = tuple[name: string, paramsText: string, returnText: string, lineNo: int]

const returnTextMaxWrapLines = 5
  ## Bound on how many newlines `scanProcDecls` will cross while hunting
  ## for the `=` that ends a declaration's return-type clause. A return
  ## type never legitimately wraps more than a line or two in this
  ## codebase's style; the bound exists purely so a signature with no `=`
  ## at all (a body-less forward declaration) can't walk the scan off into
  ## unrelated, unbounded amounts of later source — keeps the scan fast
  ## and its blast radius small, per F34.

proc scanProcDecls(text: string): seq[ProcDecl] =
  ## Every column-0 `proc `/`func ` declaration in `text` — an anonymous
  ## `proc(...)` type or value literal (no space before the `(`, e.g.
  ## `BackendGetProc* = proc(key: SoundnessKey): ...`) is skipped by
  ## construction, since the search needle itself requires the space.
  ## `paramsText` is balanced-paren extracted (a wrapped signature is seen
  ## whole, same as `extractParamList` above); `returnText` runs from the
  ## closing `)` to the terminating `=`, covering both `): T =` and
  ## `): T {.pragma.} =` (the pragma text itself is swept into
  ## `returnText` too, harmlessly: it is only ever tested for key-type
  ## NAMES, never parsed further) — AND a return type that wraps onto its
  ## own line (`proc foo(...):\n  CacheKeyPath =`), a shape real
  ## signatures in this codebase use (F34). Newlines are crossed freely
  ## while hunting for the `=`, bounded by `returnTextMaxWrapLines` so an
  ## `=`-less body-less declaration can't run the scan away unbounded.
  var searchFrom = 0
  while true:
    let idx = text.find("proc ", searchFrom)
    let idxF = text.find("func ", searchFrom)
    let declIdx =
      if idx < 0: idxF
      elif idxF < 0: idx
      else: min(idx, idxF)
    if declIdx < 0: break
    var i = declIdx + 5
    let nameStart = i
    while i < text.len and isIdentChar(text[i]): inc i
    let name = text[nameStart ..< i]
    if i < text.len and text[i] == '*': inc i
    if i < text.len and text[i] == '[':
      i = findMatchingClose(text, i, '[', ']') + 1
    while i < text.len and text[i] == ' ': inc i
    if i >= text.len or text[i] != '(':
      searchFrom = declIdx + 5
      continue
    let openParen = i
    let closeParen = findMatchingClose(text, openParen, '(', ')')
    let paramsText = text[openParen + 1 ..< closeParen]
    var retEnd = closeParen + 1
    var wrapLines = 0
    while retEnd < text.len and text[retEnd] != '=':
      if text[retEnd] == '\n':
        inc wrapLines
        if wrapLines > returnTextMaxWrapLines: break
      inc retEnd
    let returnText = text[closeParen + 1 ..< retEnd]
    let lineNo = 1 + text[0 ..< declIdx].count('\n')
    result.add (name, paramsText, returnText, lineNo)
    searchFrom = closeParen + 1

proc mentionsKeyType(s: string): bool =
  containsWord(s, "CacheKeyPath") or containsWord(s, "SoundnessKey") or
    containsWord(s, "IdentityKey")

proc hasBareStringIdentityParam(params: string): bool =
  var stripped = params
  for legit in legitStringParams: stripped = stripped.replace(legit, "")
  ": string" in stripped

proc keyProducingPatternViolations(path: string): seq[string] =
  ## Every proc declaration in `path` whose RETURN TYPE names a key type —
  ## i.e. it PRODUCES a key — checked for a bare string-typed identity
  ## parameter, independent of the proc's name.
  let text = readFile(path)
  let rel = relLabel(path)
  for decl in scanProcDecls(text):
    if mentionsKeyType(decl.returnText) and hasBareStringIdentityParam(decl.paramsText):
      result.add rel & ":" & $decl.lineNo & "  " & decl.name &
        " returns a key type but takes a bare string identity param — the deleted overload shape reappeared"

suite "RFC-0009 A-final-ii-b — path-identity completion gate":

  test "Tier 1 — no relativePath(, no raw root-prefix check, no TrackedPath ordering":
    var offenders: seq[string]
    for path in allSourceFiles():
      let rel = relLabel(path)
      var fileLines: seq[string]
      for line in lines(path): fileLines.add line
      for i, line in fileLines:
        if isCommentLine(line): continue
        if "relativePath(" in line:
          offenders.add rel & ":" & $(i + 1) & "  relativePath( — use TrackedPath/classify"
        if definesTrackedPathOrdering(line):
          offenders.add rel & ":" & $(i + 1) & "  ordering operator over TrackedPath — use cmpKeyBytes"
      offenders.add rawRootPrefixViolations(fileLines, rel)
    for o in offenders:
      echo "  TIER-1 VIOLATION: " & o
    check offenders.len == 0

  test "Tier 1 detector self-test — two-line raw root-prefix evasion vs. the sanctioned underRoot shape":
    # POSITIVE: a fresh copy-paste of the exact two-line idiom, under a name
    # and file the allowlist does not mention, must be caught even though
    # `hasRawRootPrefixCheck` (same-line-only) is blind to it.
    let evasion = @[
      "proc sneaky(candidate, rootAbs: string): bool =",
      "  let prefix = rootAbs & \"/\"",
      "  candidate.startsWith(prefix)",
    ]
    let evasionHits = rawRootPrefixViolations(evasion, "fixture.nim")
    check evasionHits.len == 1
    check "two-line binding 'prefix'" in evasionHits[0]

    # A second identifier name, and the ident-as-argument (not receiver)
    # call shape, are both still caught.
    let evasionArgForm = @[
      "proc alsoSneaky(candidate, rootAbs: string): bool =",
      "  let rootPrefix = rootAbs & DirSep",
      "  startsWith(candidate, rootPrefix)",
    ]
    check rawRootPrefixViolations(evasionArgForm, "fixture2.nim").len == 1

    # NEGATIVE: the literal sanctioned shape, under (paths.nim, underRoot,
    # prefix) exactly, is allowlisted and produces zero violations.
    let sanctioned = @[
      "proc underRoot(candidate, rootAbs: string): Option[string] =",
      "  let prefix = if rootAbs.endsWith(\"/\"): rootAbs else: rootAbs & \"/\"",
      "  if candidate.len > prefix.len and candidate.startsWith(prefix):",
    ]
    check rawRootPrefixViolations(sanctioned, "paths.nim").len == 0

    # The allowlist is scoped to (file, proc, ident) — the identical binding
    # shape under ANY other name, file, or enclosing proc still trips.
    let sameShapeWrongProc = @[
      "proc notUnderRoot(candidate, rootAbs: string): Option[string] =",
      "  let prefix = if rootAbs.endsWith(\"/\"): rootAbs else: rootAbs & \"/\"",
      "  if candidate.len > prefix.len and candidate.startsWith(prefix):",
    ]
    check rawRootPrefixViolations(sameShapeWrongProc, "paths.nim").len == 1
    let sameShapeWrongFile = @[
      "proc underRoot(candidate, rootAbs: string): Option[string] =",
      "  let prefix = if rootAbs.endsWith(\"/\"): rootAbs else: rootAbs & \"/\"",
      "  if candidate.len > prefix.len and candidate.startsWith(prefix):",
    ]
    check rawRootPrefixViolations(sameShapeWrongFile, "notpaths.nim").len == 1

    # NEGATIVE (F33): the tracker is proc-scoped, not whole-file. Proc `a`
    # binds `p` for a legitimate root-prefix purpose; proc `b`, later in
    # the same file, has its OWN unrelated `p` (here a parameter) and
    # merely happens to call `startsWith` mentioning it. This must NOT
    # trip — `b`'s `p` is not `a`'s tracked binding, and a whole-file
    # tracker (pre-fix) could not tell the difference.
    let crossProcUnrelatedReuse = @[
      "proc a(root: string): string =",
      "  let p = root & \"/\"",
      "  p",
      "",
      "proc b(p, q: string): bool =",
      "  q.startsWith(p)",
    ]
    check rawRootPrefixViolations(crossProcUnrelatedReuse, "fixture3.nim").len == 0

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
      offenders.add keyProducingPatternViolations(path)
    for o in offenders:
      echo "  TIER-4 VIOLATION: " & o
    check offenders.len == 0

  test "Tier 4 detector self-test — pattern layer catches an unnamed key-deriving proc":
    # POSITIVE: a proc under a name NOT in `keySurfaceProcs`, returning a
    # key type, with a bare string identity param — the name-list layer
    # (`keySurfaceViolations`) cannot see this; the pattern layer must.
    let fixture = """
proc newIdentityFromPath*(path: string; roots: TrackedRoots): IdentityKey =
  discard
"""
    writeFile(getTempDir() / "fixture_tier4_positive.nim.tmp", fixture)
    defer: removeFile(getTempDir() / "fixture_tier4_positive.nim.tmp")
    let hits = keyProducingPatternViolations(getTempDir() / "fixture_tier4_positive.nim.tmp")
    check hits.len == 1
    check "newIdentityFromPath" in hits[0]

    # NEGATIVE: the same shape but with the legitimate incidental `root:
    # string` param only (no OTHER bare string) does not trip.
    let legitFixture = """
proc keyBytesForRoot*(root: string; tp: TrackedPath; roots: TrackedRoots): CacheKeyPath =
  discard
"""
    writeFile(getTempDir() / "fixture_tier4_negative.nim.tmp", legitFixture)
    defer: removeFile(getTempDir() / "fixture_tier4_negative.nim.tmp")
    check keyProducingPatternViolations(getTempDir() / "fixture_tier4_negative.nim.tmp").len == 0

    # NEGATIVE: a proc mentioning a key type only as a PARAMETER (a
    # key-CONSUMING proc, not a key-producing one) is not a return-type
    # match, so an incidental string param alongside it is not flagged.
    let consumerFixture = """
proc lookupSidecar*(shardPath: string; key: SoundnessKey): string =
  discard
"""
    writeFile(getTempDir() / "fixture_tier4_consumer.nim.tmp", consumerFixture)
    defer: removeFile(getTempDir() / "fixture_tier4_consumer.nim.tmp")
    check keyProducingPatternViolations(getTempDir() / "fixture_tier4_consumer.nim.tmp").len == 0

  test "Tier 4 detector self-test — wrapped return type is not defeated (F34)":
    # POSITIVE: the return type wraps onto its own line
    # (`proc foo(...):\n  KeyType =`), same as F34 describes. Pre-fix,
    # `scanProcDecls` stopped at the first newline after the closing paren
    # and captured only the bare `:`, so `mentionsKeyType` never saw
    # `IdentityKey` — the concept layer silently missed this shape.
    let wrappedPositive = """
proc wrappedKeyProc*(path: string; roots: TrackedRoots):
    IdentityKey =
  discard
"""
    writeFile(getTempDir() / "fixture_tier4_wrapped_positive.nim.tmp", wrappedPositive)
    defer: removeFile(getTempDir() / "fixture_tier4_wrapped_positive.nim.tmp")
    let wrappedHits = keyProducingPatternViolations(getTempDir() / "fixture_tier4_wrapped_positive.nim.tmp")
    check wrappedHits.len == 1
    check "wrappedKeyProc" in wrappedHits[0]

    # NEGATIVE: same wrapped-return shape, but every string-typed param is
    # one of the legitimate incidental ones (`root: string`) — must not be
    # flagged, proving the wrap-handling fix introduces no new false
    # positive of its own.
    let wrappedNegative = """
proc wrappedLegitProc*(root: string; tp: TrackedPath):
    CacheKeyPath =
  discard
"""
    writeFile(getTempDir() / "fixture_tier4_wrapped_negative.nim.tmp", wrappedNegative)
    defer: removeFile(getTempDir() / "fixture_tier4_wrapped_negative.nim.tmp")
    check keyProducingPatternViolations(getTempDir() / "fixture_tier4_wrapped_negative.nim.tmp").len == 0

when isMainModule:
  echo "test_rfc9_path_identity_gate done"
