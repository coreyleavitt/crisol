## test_rfc0007_a1b_kill_path.nim — rfc-0007 A1b E2E: the honest kill-path
## producer, proven through the real entry point (`crisol run --json`).
##
## This is the slice's load-bearing proof (RFC-0007 "Load-bearing property"):
## a runner-authored kill is reported as such, end-to-end, with the ACTUAL
## observed wstatus — not the synthesized SIGKILL `pollSlot` fabricated
## before this slice. Three cases, all asserted through the CLI's `--json`
## output (crisol/run/v2, real per-phase `run.exit`/`run.cause` nodes):
##
##   hang_forever  (default signal dispositions) — dies on SIGTERM inside the
##     grace window: the primary `outcome` string is now "killed" (rfc-0007
##     A1d-i's wire cutover — deriveOutcome, not the legacy stored field) AND
##     run.cause {by:"runner", reason:"timeout", escalated:false},
##     run.exit.kind "signaled", symbol SIGTERM.
##   term_ignores  (traps/ignores SIGTERM, keeps running) — forces escalation:
##     run.cause.escalated == true, symbol SIGKILL.
##   pass_always — run.exit.code == 0.
##
## Generous timeouts (--timeout 2, i.e. 2s) so this is load-robust; the
## grace window itself (spawn.GracePeriodMs, 400 ms) is a fixed runner
## constant, not something this test races against — it only asserts the
## OUTCOME, never a latency threshold.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a1b_kill_path.nim

import std/[json, os, unittest]
import ../support/capture
import crisol         # imports runMain

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fixtureDir(): string =
  let thisFile = currentSourcePath()
  let testsDir = thisFile.parentDir.parentDir
  testsDir / "fixtures"

proc firstEntrypoint(jsonText: string): JsonNode =
  let doc = parseJson(jsonText)
  check doc["entrypoints"].len == 1
  doc["entrypoints"][0]

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "rfc-0007 A1b — honest kill-path producer (crisol run --json)":

  test "hang_forever: outcome killed + honest run.cause/run.exit (SIGTERM, not escalated)":
    let fd = fixtureDir()
    var code = 0
    let output = captureStdout(proc() =
      code = runMain(@["run", fd / "hang_forever.nim",
                        "--timeout", "2", "--jobs", "1", "--json",
                        "--no-cache"]))
    discard code
    let ep = firstEntrypoint(output)

    # rfc-0007 A1d-i: the wire cutover — `outcome` is now deriveOutcome(r),
    # not the legacy stored field.  A runner-authored kill finally reads
    # "killed" as the PRIMARY verdict, not just an advisory side-channel.
    check ep["outcome"].getStr == "killed"

    # The honest observation: the runner authored this kill (not fabricated).
    # Wire strings are resultjson's own Nim-identifier convention (A1a,
    # locked) — cbRunner/krTimeout, not a paraphrase.
    check ep.hasKey("run")
    check ep["run"]["kind"].getStr == "ran"
    check ep["run"]["cause"]["by"].getStr == "runner"
    check ep["run"]["cause"]["reason"].getStr == "timeout"
    check ep["run"]["cause"]["escalated"].getBool == false

    # hang_forever has default signal dispositions — it dies on the FIRST
    # signal sent (SIGTERM), inside the grace window. Before this slice,
    # pollSlot synthesized SIGKILL unconditionally regardless of what
    # actually happened — this is the fabrication being fixed.
    check ep["run"]["exit"]["kind"].getStr == "signaled"
    check ep["run"]["exit"]["sig"].getInt == 15  # SIGTERM (POSIX-standard number; the runner reports these)
    # rfc-0007 A1d-i: evidence is now a real node too (not just exit/cause).
    check ep["run"].hasKey("evidence")
    check ep["run"]["evidence"]["killDomain"].kind == JString

  test "term_ignores: SIGTERM-ignoring child forces escalation to SIGKILL":
    let fd = fixtureDir()
    var code = 0
    let output = captureStdout(proc() =
      code = runMain(@["run", fd / "term_ignores.nim",
                        "--timeout", "2", "--jobs", "1", "--json",
                        "--no-cache"]))
    discard code
    let ep = firstEntrypoint(output)

    check ep["outcome"].getStr == "killed"
    check ep["run"]["cause"]["by"].getStr == "runner"
    check ep["run"]["cause"]["reason"].getStr == "timeout"
    check ep["run"]["cause"]["escalated"].getBool == true

    check ep["run"]["exit"]["kind"].getStr == "signaled"
    check ep["run"]["exit"]["sig"].getInt == 9  # SIGKILL (POSIX-standard number; the runner reports these)

  test "pass_always: run.exit.code == 0":
    let fd = fixtureDir()
    var code = 0
    let output = captureStdout(proc() =
      code = runMain(@["run", fd / "pass_always.nim",
                        "--timeout", "2", "--jobs", "1", "--json",
                        "--no-cache"]))
    check code == 0
    let ep = firstEntrypoint(output)
    check ep["outcome"].getStr == "passed"
    check ep.hasKey("run")
    check ep["run"]["kind"].getStr == "ran"
    check ep["run"]["exit"]["kind"].getStr == "exited"
    check ep["run"]["exit"]["code"].getInt == 0
    check ep["run"]["cause"]["by"].getStr == "process"
    # rfc-0007 A1d-i: the compile phase is now its own real Phase node too.
    check ep.hasKey("compile")
    check ep["compile"]["kind"].getStr in ["ran", "skipped"]
