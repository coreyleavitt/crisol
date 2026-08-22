## test_cli_closure.nim — issue #9 slice A integration tests for `crisol closure`.
##
## Proves the new read-only CLI subcommand surfaces the SAME depgraph data
## crisol itself uses for --changed selection, so a downstream consumer
## (amoxtli) never has to re-implement the depgraph loader or group/flag
## resolution.
##
##   crisol closure <entrypoint> [--json]    — entries for one entrypoint path.
##   crisol closure --all [--json]           — every discovered entrypoint.
##
## Coverage:
##   1. Before any run: `closure <path> --json` → recorded == false, closure == [].
##   2. After `run <path>`: `closure <path> --json` → recorded == true, closure
##      contains the entrypoint AND its dependency, closureHash is 16 hex chars,
##      group/flagHash are populated.
##   3. `closure --all --json` → one entry per discovered entrypoint, in one doc.
##   4. Usage errors: no args, or positional + --all together → exit 3.
##   5. Non-JSON `closure --all` → exit 0, human listing mentions both paths.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_closure.nim

import std/[json, monotimes, os, strutils, unittest]
import std/posix as posix_mod
import crisol  # runMain
import crisol/render  # pathFlagsWarnings — reuse run/list's exact wording
import crisol/jsonout  # ClosureV1Schema/ClosureV1Revision — schema/revision pin

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  result = getTempDir() / ("crisol_closure_" & tag & "_" & $mono.ticks)
  createDir(result)

proc captureStdoutToFile(path: string; body: proc()): void =
  ## Redirect fd 1 (stdout) to `path`, call body(), then restore.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(1) failed")
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stdout)
    discard posix_mod.dup2(savedFd, 1.cint)
    discard posix_mod.close(savedFd)

proc captureStderrToFile(path: string; body: proc()): void =
  ## Redirect fd 2 (stderr) to `path`, call body(), then restore.
  let f = open(path, fmWrite)
  let fileFd: cint = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(2.cint)
  if savedFd < 0:
    f.close()
    raise newException(OSError, "dup(2) failed")
  discard posix_mod.dup2(fileFd, 2.cint)
  f.close()
  try:
    body()
  finally:
    flushFile(stderr)
    discard posix_mod.dup2(savedFd, 2.cint)
    discard posix_mod.close(savedFd)

proc writeF(root, rel, content: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc setUpProject(): string =
  ## Build a temp project root with a dep.nim + two test entrypoints, laid
  ## out under the default "unit" group convention glob
  ## (tests/unit/test_*.nim — see config.nim's DefaultGroups) so no
  ## crisol.kdl is needed.
  let root = uniqueTmpDir("proj")
  writeF(root, "tests/unit/dep.nim", "proc v*(): int = 1\n")
  writeF(root, "tests/unit/test_a.nim", "import dep\ndoAssert v() == 1\n")
  writeF(root, "tests/unit/test_b.nim", "doAssert true\n")
  root

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "crisol closure — issue #9 slice A":

  test "closure <path> --json BEFORE any run: recorded == false, closure == []":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_before.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["schema"].getStr == "crisol/closure/v1"
    check j["entries"].len == 1
    let e = j["entries"][0]
    check e["path"].getStr == "tests/unit/test_a.nim"
    check e["recorded"].getBool == false
    check e["closure"].len == 0
    check e["closureHash"].getStr == ""

  test "run then closure <path> --json: recorded == true, closure has both files":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the captureStdoutToFile block below
    check runCode == 0

    let outPath = getTempDir() / "crisol_closure_after.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len == 1
    let e = j["entries"][0]
    check e["recorded"].getBool == true
    check e["group"].getStr.len > 0
    check e["flagHash"].getStr.len == 16
    check e["closureHash"].getStr.len == 16
    var closureSet: seq[string]
    for c in e["closure"]:
      closureSet.add c.getStr
    check "tests/unit/test_a.nim" in closureSet
    check "tests/unit/dep.nim" in closureSet

  test "closure --all --json: entries for BOTH test_a (recorded) and test_b (not)":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)  # avoid leaking this uncaptured run's buffered stdout
                       # into the captureStdoutToFile block below
    check runCode == 0

    let outPath = getTempDir() / "crisol_closure_all.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    var byPath: seq[(string, bool)]
    for e in j["entries"]:
      byPath.add (e["path"].getStr, e["recorded"].getBool)
    check ("tests/unit/test_a.nim", true) in byPath
    check ("tests/unit/test_b.nim", false) in byPath

  test "closure with no args → exit 3":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)
    let code = runMain(@["closure"])
    check code == 3

  test "closure --all <path> together → exit 3":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)
    let code = runMain(@["closure", "--all", "tests/unit/test_a.nim"])
    check code == 3

  test "non-json closure --all → exit 0, stdout mentions both paths":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_all_human.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all"]))
    check code == 0
    let txt = readFile(outPath)
    check "tests/unit/test_a.nim" in txt
    check "tests/unit/test_b.nim" in txt

# ---------------------------------------------------------------------------
# `closure` accepts --config <path> / --config=<path>, mirroring
# clean's parsing (same error text + exit 3 when the value is missing).
# ---------------------------------------------------------------------------

suite "crisol closure — --config <path>":

  test "closure --all --json --config <path> targets a non-default config file":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # Write a second, non-default config file naming the same convention glob.
    let cfgPath = root / "crisol_alt.kdl"
    writeFile(cfgPath, "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")

    let outPath = getTempDir() / "crisol_closure_config.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--json", "--config", cfgPath]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len == 2

  test "closure --config= (inline form) with an empty value → exit 3":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_config_empty_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--config="]))
    check code == 3
    check "crisol: --config requires a file path" in readFile(outPath)

  test "closure --config with no following value → exit 3":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_config_missing_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--config"]))
    check code == 3
    check "crisol: --config requires a file path" in readFile(outPath)

# ---------------------------------------------------------------------------
# `closure` prints the same ad-hoc / ambiguous path diagnostics that
# `run`/`list` print via render.pathFlagsWarnings.
# ---------------------------------------------------------------------------

suite "crisol closure — ad-hoc / ambiguous path warnings":

  test "closure <path not in any group glob> prints the same ad-hoc warning run/list print":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # A .nim file that exists but is outside the "unit" group's convention
    # glob (tests/unit/test_*.nim) — matches no configured group, so
    # discover() records it as an ad-hoc path.
    writeF(root, "scripts/adhoc.nim", "doAssert true\n")

    let expected = pathFlagsWarnings(@["scripts/adhoc.nim"], @[], @[])
    check expected.len == 1

    let outPath = getTempDir() / "crisol_closure_adhoc_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "scripts/adhoc.nim"]))
    check code == 0
    check "crisol: " & expected[0] in readFile(outPath)

# ---------------------------------------------------------------------------
# ConfigWarning.message can carry untrusted-origin text verbatim (e.g. the
# raw KDL node name of an unrecognized config key) — it must reach stderr
# control-byte-sanitized, same as depgraph.nim's own discard diagnostics.
# ---------------------------------------------------------------------------

suite "crisol closure — control-byte sanitization of config warnings":

  test "unknown config key containing a raw TAB byte reaches stderr sanitized (no control bytes but '\\n')":
    ## nkdl (KDL v2) rejects the ESC byte (0x1b) literally ANYWHERE in a
    ## document, including inside quoted strings — U+000E-U+001F is in its
    ## disallowed-control-codepoint set, so a config key name can never
    ## smuggle ESC through the parser.  TAB (0x09) IS accepted inside a
    ## quoted node name, so it's the vehicle here for a control byte that
    ## reaches ConfigWarning.message raw and must be sanitized before stderr.
    let root = setUpProject()
    defer: removeDir(root)

    writeFile(root / "crisol.kdl",
      "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n    \"unk\tkey\"\n}\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_ctrlbyte_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "--all"]))
    check code == 0

    let errText = readFile(outPath)
    check "unknown config key" in errText
    check "unk?key" in errText   # raw TAB sanitized to '?'
    check '\t' notin errText
    for c in errText:
      check (c == '\n') or (ord(c) >= 0x20 and ord(c) != 0x7f)

# ---------------------------------------------------------------------------
# `closure <path>` matching no entrypoint exits 3 with the same
# "no entrypoints matched" message `run` uses; `--all` with zero discovered
# entrypoints stays exit 0 with an empty entries report.
# ---------------------------------------------------------------------------

suite "crisol closure — no-match exit code":

  test "closure <nonexistent path> --json → exit 3, stderr mentions no entrypoints matched":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_nomatch_err.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "does/not/exist.nim", "--json"]))
    check code == 3
    check "no entrypoints matched" in readFile(outPath)

  test "closure <path> whose only match is gated out → exit 0, empty report (matches run's contract)":
    ## A positional path whose group is gated out IS a discovered
    ## entrypoint — it lands in the plan's gatedOut, not in entries.  That
    ## is different from a path matching no discovered entrypoint at all
    ## (the exit-3 case above): `run` for the same selection exits 0
    ## (zrkAllGated), and `closure` must match that contract rather than
    ## treating "gated out" as "no match".
    let root = setUpProject()
    defer: removeDir(root)

    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
    gate "CRISOL_CLOSURE_GATED_TEST_UNSET_XYZ_12345"
}
""")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_gatedout.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "tests/unit/test_a.nim", "--json"]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len == 0
    # plan/v1 serializes gatedOut, so closure/v1 must mirror it (revision bump).
    check j["schemaRevision"].getInt == ClosureV1Revision
    check j.hasKey("gatedOut")
    check j["gatedOut"].len == 1
    check j["gatedOut"][0]["path"].getStr == "tests/unit/test_a.nim"
    check j["gatedOut"][0]["group"].getStr == "unit"
    check j["gatedOut"][0]["reason"].getStr.len > 0

  test "closure <path> whose only match is gated out, non-JSON → exit 0, gate-skip line on stdout (not stderr)":
    ## renderClosure ignores ClosureReport.gatedOut (it only walks .entries),
    ## so the all-gated case previously printed NOTHING at all in human mode
    ## — a silent, empty-looking success.  `run` mirrors the identical
    ## zrkAllGated case with gateSkipMessages(...) lines on STDOUT; `closure`'s
    ## non-JSON branch used to put the same lines on stderr — a parity gap
    ## with `run` — and now matches: gate-skip lines go to stdout, before
    ## the (possibly empty) report, and stderr carries none of them.
    let root = setUpProject()
    defer: removeDir(root)

    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
    gate "CRISOL_CLOSURE_GATED_TEST_UNSET_XYZ_12345"
}
""")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_gatedout_human_out.txt"
    let errPath = getTempDir() / "crisol_closure_gatedout_human_err.txt"
    defer:
      (try: removeFile(outPath) except: discard)
      (try: removeFile(errPath) except: discard)
    var code = 0
    captureStderrToFile(errPath, proc () =
      captureStdoutToFile(outPath, proc () =
        code = runMain(@["closure", "tests/unit/test_a.nim"])))
    check code == 0

    let outText = readFile(outPath)
    # Stable substring: gateSkipMessages' own wording is
    # `skipped group "<group>" — <reason>` — assert on the group-naming
    # prefix rather than the (environment-dependent) reason text.
    check "skipped group \"unit\"" in outText
    check "skipped group \"unit\"" notin readFile(errPath)

  test "closure gate-skip line for a group name containing a TAB byte renders sanitized on stdout":
    ## Same gated-group shape as above, but the group's own NAME (config-file
    ## text, not the reason) carries a raw TAB byte — via KDL's own `\t`
    ## escape — proving gateSkipMessages lines are sanitized end-to-end on
    ## the (now-stdout) path, not just the report body.
    let root = setUpProject()
    defer: removeDir(root)

    writeFile(root / "crisol.kdl", "group \"un\\tit\" {\n" &
      "    globs \"tests/unit/test_*.nim\"\n" &
      "    gate \"CRISOL_CLOSURE_GATED_TEST_UNSET_XYZ_12345\"\n" &
      "}\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_gatedout_tab_out.txt"
    let errPath = getTempDir() / "crisol_closure_gatedout_tab_err.txt"
    defer:
      (try: removeFile(outPath) except: discard)
      (try: removeFile(errPath) except: discard)
    var code = 0
    captureStderrToFile(errPath, proc () =
      captureStdoutToFile(outPath, proc () =
        code = runMain(@["closure", "tests/unit/test_a.nim"])))
    check code == 0

    let outText = readFile(outPath)
    check "skipped group \"un?it\"" in outText   # TAB sanitized to '?'
    for c in outText:
      check (c == '\n') or (ord(c) >= 0x20 and ord(c) != 0x7f)
    check readFile(errPath).len == 0   # nothing at all leaked to stderr

  test "usage text: closure path whose only match is gated out matches run's exit-0 contract, not the exit-3 no-match case":
    let outPath = getTempDir() / "crisol_closure_usage_gated.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["--help"]))
    check code == 0
    let txt = readFile(outPath)
    check "gated out" in txt

# ---------------------------------------------------------------------------
# Usage text reflects N-positional-path grammar for `closure`.
# ---------------------------------------------------------------------------

suite "crisol closure — usage grammar":

  test "--help usage text documents closure <entrypoint>... (N paths, not just one)":
    let outPath = getTempDir() / "crisol_closure_usage.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["--help"]))
    check code == 0
    check "crisol closure <entrypoint>..." in readFile(outPath)


# ---------------------------------------------------------------------------
# A discarded depgraph (Nim-version mismatch) surfaces as a visible,
# structured diagnostic, not a silent empty-graph fallback.
# ---------------------------------------------------------------------------

suite "crisol closure — stale depgraph diagnostic":

  test "stale depgraph nimVersion → closure --all --json reports recorded==false " &
       "for every entry AND a structured 'depgraph discarded' warning":
    ## Simulates a Nim upgrade: after a real `run` records entries, the
    ## depgraph file's header.nimVersion is rewritten to a value that will
    ## never match the running compiler's fingerprint. `closure --all --json`
    ## must still exit 0, but every entry must show recorded==false AND the
    ## discard must be a VISIBLE, STRUCTURED diagnostic — both in the JSON
    ## `warnings` array and on stderr (crisol.nim's closure handler: `for w
    ## in cr.warnings: stderr.write("warning: " & w.message & "\n")`) — not
    ## silently indistinguishable from "never ran".
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let runCode = runMain(@["run", "tests/unit/test_a.nim"])
    flushFile(stdout)
    check runCode == 0

    # Rewrite the persisted depgraph's header.nimVersion so it can never
    # match the current compiler fingerprint (see depgraph.nim's top doc
    # comment: `<projectRoot>/<stateDir>/depgraph`, stateDir defaults to
    # ".crisol").
    let depgraphPath = root / ".crisol" / "depgraph"
    check fileExists(depgraphPath)
    var doc = parseJson(readFile(depgraphPath))
    doc["header"]["nimVersion"] = newJString("0.0.0-stale")
    writeFile(depgraphPath, $doc)

    let outPath = getTempDir() / "crisol_closure_stale_depgraph.json"
    let errPath = getTempDir() / "crisol_closure_stale_depgraph.err"
    defer:
      (try: removeFile(outPath) except: discard)
      (try: removeFile(errPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      captureStderrToFile(errPath, proc () =
        code = runMain(@["closure", "--all", "--json"])))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len > 0
    for e in j["entries"]:
      check e["recorded"].getBool == false

    var foundDiscardWarning = false
    for w in j["warnings"]:
      if "depgraph discarded" in w["message"].getStr:
        foundDiscardWarning = true
    check foundDiscardWarning

    check "depgraph discarded" in readFile(errPath)

# ---------------------------------------------------------------------------
# Code-review test-gap closures.
# ---------------------------------------------------------------------------

suite "crisol closure — schema/warnings completeness":

  test "closure --all --json: schemaRevision == ClosureV1Revision; warnings is a present array; an unknown config key surfaces as a warning":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # An unknown top-level config key becomes a ConfigWarning (config.nim's
    # "top-level" makeConfigWarning branch) that must reach BOTH the
    # closure/v1 JSON `warnings` array and closureReport's plan-phase
    # warnings — not merely be swallowed by the parser.
    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n" &
                       "bogus-top-level-key \"nope\"\n")

    let outPath = getTempDir() / "crisol_closure_t2_schema.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--json", "--config", cfgPath]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["schema"].getStr == ClosureV1Schema
    check j["schemaRevision"].getInt == ClosureV1Revision
    check j.hasKey("warnings")
    check j["warnings"].kind == JArray
    var foundBogusWarning = false
    for w in j["warnings"]:
      if "bogus-top-level-key" in w["message"].getStr:
        foundBogusWarning = true
    check foundBogusWarning

# ---------------------------------------------------------------------------
# An entrypoint belonging to two groups (same glob, different flags)
# yields one ClosureEntry PER group — discover()'s documented cross-group
# fan-out (discover.nim: "the same file in two groups yields one entry PER
# group"), surfaced end-to-end through `closure --all --json`.
# ---------------------------------------------------------------------------

suite "crisol closure — multi-group entrypoint":

  test "an entrypoint matching TWO groups' globs yields TWO ClosureEntry rows (same path, different group/flagHash)":
    let root = uniqueTmpDir("multigroup")
    defer: removeDir(root)
    writeF(root, "tests/unit/test_a.nim", "doAssert true\n")
    let cfgPath = root / "crisol.kdl"
    writeFile(cfgPath, """
group "alpha" {
    globs "tests/unit/test_*.nim"
    flags "-d:alphamarker"
}
group "beta" {
    globs "tests/unit/test_*.nim"
    flags "-d:betamarker"
}
""")
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_t2_multigroup.json"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStdoutToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--json", "--config", cfgPath]))
    check code == 0

    let j = parseJson(readFile(outPath).strip())
    check j["entries"].len == 2
    var groups: seq[string]
    var flagHashes: seq[string]
    for e in j["entries"]:
      check e["path"].getStr == "tests/unit/test_a.nim"
      groups.add e["group"].getStr
      flagHashes.add e["flagHash"].getStr
    check "alpha" in groups
    check "beta" in groups
    check groups[0] != groups[1]
    check flagHashes[0] != flagHashes[1]

# ---------------------------------------------------------------------------
# CLI-level flag/config error branches.
# ---------------------------------------------------------------------------

suite "crisol closure — unknown flag":

  test "closure --bogus → exit 3, stderr mentions unknown flag for closure":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_t2_bogusflag.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "--bogus"]))
    check code == 3
    check "unknown flag for closure" in readFile(outPath)

suite "crisol closure — --config error path":

  test "closure --all --config <nonexistent path> → exit 3, stderr mentions the error":
    let root = setUpProject()
    defer: removeDir(root)
    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let outPath = getTempDir() / "crisol_closure_t2_badconfig.txt"
    defer: (try: removeFile(outPath) except: discard)
    var code = 0
    captureStderrToFile(outPath, proc () =
      code = runMain(@["closure", "--all", "--config", "/nonexistent/crisol.kdl"]))
    check code == 3
    let err = readFile(outPath)
    check "environment error" in err
    check "/nonexistent/crisol.kdl" in err
