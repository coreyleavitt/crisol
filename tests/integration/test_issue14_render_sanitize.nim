## test_issue14_render_sanitize.nim — issue #14: report BODIES (not just
## diagnostics) must not carry raw control bytes from config-origin text.
##
## A config can legally carry control characters in quoted strings (nkdl
## accepts `\u{1b}` escapes, and a literal TAB anywhere).  Group names, flags
## and paths flow from there into the human plan/run/closure listings on
## stdout.  Every such field must be sanitized at the render layer so stdout
## carries no byte < 0x20 other than '\n' and no DEL — while crisol's own
## ANSI color codes (off here: captured, non-TTY) are unaffected.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue14_render_sanitize.nim

import std/[json, os, strutils, unittest]
import crisol
import ../support/capture

proc rawControlBytes(s: string): seq[int] =
  ## Every offending byte position: < 0x20 other than '\n', or DEL.
  for i, c in s:
    if (c.ord < 0x20 and c != '\n') or c.ord == 0x7f: result.add i

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_i14_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / ".crisol")
  writeFile(result / "tests" / "unit" / "test_a.nim", "quit(0)\n")

## Group name carries ESC (via nkdl's \u{} escape) and a literal TAB; a flag
## carries ESC too.  Both reach the plan listing's [group] and flags columns.
const HostileKdl = "group \"unit\\u{1b}[2J\tx\" {\n" &
                   "    globs \"tests/unit/test_*.nim\"\n" &
                   "    flags \"-d:a\\u{1b}[31mb\"\n" &
                   "}\n"

suite "issue #14 — report bodies carry no raw control bytes":

  test "crisol list: hostile group name and flag are sanitized in the human plan rows":
    let root = newProject("list")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", HostileKdl)

    var code = 0
    let output = captureStdout(proc() = code = runMain(@["list", "--config", root / "crisol.kdl"]))
    check code == 0
    check rawControlBytes(output).len == 0
    # The row is still there, with the control bytes replaced, not dropped.
    check "[unit?[2J?x]" in output
    check "-d:a?[31mb" in output

  test "crisol list --json: the same fields are JSON-escaped, never raw":
    let root = newProject("json")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", HostileKdl)

    var code = 0
    let output = captureStdout(proc() = code = runMain(@["list", "--config", root / "crisol.kdl", "--json"]))
    check code == 0
    check rawControlBytes(output).len == 0
    let j = parseJson(output.strip())
    # Round-trips to the ORIGINAL bytes: JSON is data, not terminal output.
    check j["entrypoints"][0]["group"].getStr == "unit\x1b[2J\tx"
