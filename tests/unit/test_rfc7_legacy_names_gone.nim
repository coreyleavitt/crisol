## test_rfc7_legacy_names_gone.nim — rfc-0007 A1e-i: the removal-sweep
## grep-test the bullet requires.
##
## Asserts the deleted legacy names never reappear in src/:
##   - the legacy EntrypointResult fields (outcome, exitCode, signal,
##     achieved, peakRssBytes, cached, flaky) — checked precisely against
##     the EntrypointResult object body in types.nim, not a blanket scan,
##     because several of these names are legitimately reused elsewhere for
##     UNRELATED fields (Slot.achieved, Slot.peakRssBytes, the
##     appendAttemptRow ledger parameter, LedgerRow.outcome, Summary.flaky) —
##     a blanket scan for the bare word would false-positive on all of them.
##   - the legacy Outcome enum values oTimeout/oSignal, the pre-rename
##     `deriveOutcome` name, and the deleted dual-write coherence check
##     (checkRfc7Coherence/rfc7Check) — these four ARE blanket-safe: after
##     this slice landed, none of them has any legitimate remaining use
##     anywhere in src/, so a plain whole-word scan is the precise check.
##   - `.outcome` FIELD-ACCESS syntax outside its one legitimate remaining
##     owner: `ledger.LedgerRow.outcome` (a persisted wire STRING, never
##     touched by this slice) and the `types.outcome`/`api.outcome` module-
##     qualifier spellings that name the (now unshadowed) derivation proc.
##
## No std/re: this repo has no PCRE dependency anywhere, so matching here is
## plain substring scanning with a hand-rolled identifier-boundary check
## (`wordAt`) instead of pulling in a regex engine for one test file.
##
## Grep-test allowance (encoded precisely, rfc-0007 A1e-i bullet):
##   `outcomestrings.nim`'s `LegacyTimedOutOutcomeString`/
##   `LegacySignaledOutcomeString` hold the persisted-string-domain literals
##   "timedOut"/"signaled" so ledger history classifies correctly (§2's
##   persisted-string vs enum-value distinction) — those are STRING
##   LITERALS, not the `oTimeout`/`oSignal` enum identifiers, so they never
##   trip the whole-word scan below; no separate carve-out is coded for them
##   because there is nothing for them to be exempted FROM.
import std/[os, strutils, unittest]

const CrisolRoot = currentSourcePath().parentDir.parentDir.parentDir
const SrcDir = CrisolRoot / "src"

proc isIdentChar(c: char): bool =
  c.isAlphaNumeric or c == '_'

proc wordAt(line: string; word: string; start: int): bool =
  ## True iff `word` occurs at byte offset `start` in `line` as a whole
  ## identifier — the char before and after (if any) are not identifier
  ## characters (a hand-rolled `\b...\b`, since this repo has no regex dep).
  let e = start + word.len
  if start > 0 and isIdentChar(line[start - 1]): return false
  if e < line.len and isIdentChar(line[e]): return false
  true

proc containsWord(line: string; word: string): bool =
  var searchFrom = 0
  while true:
    let idx = line.find(word, searchFrom)
    if idx < 0: return false
    if wordAt(line, word, idx): return true
    searchFrom = idx + 1

proc allNimFiles(): seq[string] =
  for f in walkDirRec(SrcDir):
    if f.endsWith(".nim"):
      result.add f

type Hit = tuple[file: string, line: int, text: string]

proc grepWord(word: string): seq[Hit] =
  ## Every (file, 1-based line, text) whose line contains `word` as a whole
  ## identifier, across every .nim file under src/.
  for path in allNimFiles():
    var lineNo = 1
    for line in readFile(path).splitLines:
      if containsWord(line, word):
        result.add (file: path, line: lineNo, text: line.strip)
      inc lineNo

proc entrypointResultBody(): string =
  ## The EntrypointResult object's own field block in types.nim — from its
  ## `EntrypointResult* = object` header to the next line at the SAME
  ## indentation that opens a different type (i.e. the next 2-space-indented
  ## `<Name>* = ` line), so a forbidden field name mentioned in a comment
  ## belonging to some OTHER type never leaks into this check.
  let lines = readFile(SrcDir / "crisol" / "types.nim").splitLines
  var startIdx = -1
  for i, line in lines:
    if line.strip.startsWith("EntrypointResult* = object"):
      startIdx = i
      break
  doAssert startIdx >= 0, "types.nim: EntrypointResult* = object not found"
  proc opensNextType(line: string): bool =
    ## Exactly two leading spaces, then a letter — the sibling-type
    ## indentation level inside the enclosing `type` block.
    line.len > 2 and line[0] == ' ' and line[1] == ' ' and
    line[2] != ' ' and line[2].isAlphaAscii
  var endIdx = lines.len
  for i in (startIdx + 1) ..< lines.len:
    if opensNextType(lines[i]):
      endIdx = i
      break
  lines[startIdx ..< endIdx].join("\n")

proc declaresField(body: string; fieldName: string): bool =
  ## True iff `body` has a line declaring `fieldName` as an object field:
  ## optional leading whitespace, the exact name, optional `*`, optional
  ## whitespace, then `:` — anchored to line start so prose mentioning the
  ## name inside a doc comment (which always starts with whitespace + `##`)
  ## never matches.
  for line in body.splitLines:
    var i = 0
    while i < line.len and line[i] == ' ': inc i
    if line.continuesWith(fieldName, i):
      var j = i + fieldName.len
      if j < line.len and line[j] == '*': inc j
      while j < line.len and line[j] == ' ': inc j
      if j < line.len and line[j] == ':':
        return true
  false

suite "rfc-0007 A1e-i — legacy names gone from src/":

  test "EntrypointResult carries none of the seven deleted fields":
    let body = entrypointResultBody()
    for fieldName in ["outcome", "exitCode", "signal", "achieved",
                      "peakRssBytes", "cached", "flaky"]:
      check not declaresField(body, fieldName)

  test "oTimeout / oSignal are gone (the legacy Outcome values)":
    check grepWord("oTimeout").len == 0
    check grepWord("oSignal").len == 0

  test "deriveOutcome is gone (A1e-i renamed it to outcome)":
    check grepWord("deriveOutcome").len == 0

  test "the dual-write coherence check is gone":
    check grepWord("checkRfc7Coherence").len == 0
    check grepWord("rfc7Check").len == 0

  test "no .outcome field access outside the allowed LedgerRow/module sites":
    ## Allowed:
    ##   - ledger.nim / order.nim / shard.nim / api.nim: `row.outcome` /
    ##     `r.outcome` on a LedgerRow — a persisted wire STRING field that
    ##     this slice never touched (it was never part of EntrypointResult).
    ##   - `types.outcome` / `api.outcome`: the module-qualifier spelling of
    ##     the derivation PROC, not field access — textually indistinguishable
    ##     from field access by a bare scan, so allowed by construction
    ##     rather than by filename.
    let allowedBasenames = ["ledger.nim", "order.nim", "shard.nim", "api.nim"]
    var violations: seq[string]
    for path in allNimFiles():
      let base = path.extractFilename
      var lineNo = 1
      for line in readFile(path).splitLines:
        let idx = line.find(".outcome")
        if idx >= 0 and wordAt(line, "outcome", idx + 1):
          if base notin allowedBasenames and
             not line.contains("types.outcome") and
             not line.contains("api.outcome"):
            violations.add path & ":" & $lineNo & ": " & line.strip
        inc lineNo
    checkpoint("unexpected .outcome field access:\n" & violations.join("\n"))
    check violations.len == 0

  test "outcomestrings carries the ONE sanctioned legacy-string exception":
    ## Encodes the allowance precisely: the persisted-string literals live
    ## ONLY in outcomestrings.nim, as the two named constants — not as bare
    ## `oTimeout`/`oSignal` identifiers anywhere (already proven above).
    let content = readFile(SrcDir / "crisol" / "outcomestrings.nim")
    check "LegacyTimedOutOutcomeString* = \"timedOut\"" in content
    check "LegacySignaledOutcomeString* = \"signaled\"" in content
