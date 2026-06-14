## test_s7_guards.nim — S7 automated drift guards (RFC-0003 §S7)
##
## Guard 1 — canonical-config zero-warnings:
##   loadConfig applied to InitTemplate (the string that `crisol init` writes)
##   must produce ZERO config warnings.  This is the single-source-of-truth guard:
##   if InitTemplate grows an unknown key, or a known key is renamed in the parser
##   without updating the template, this test fails.
##
## Guard 2 — schema-version pin:
##   The emitted run JSON's schema field must equal RunV1Schema (not a duplicated
##   string literal).  The emitted plan JSON's schema field must equal PlanV1Schema.
##   Asserting the EXPORTED CONSTANTS (not copied strings) makes the test drift-proof:
##   if either schema string changes, both the emitter and this test see the same value.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_s7_guards.nim

import std/[json, options, os, tempfiles, unittest]
import crisol/types
import crisol/config
import crisol/jsonout   # RunV1Schema
import crisol/planview  # PlanV1Schema
import crisol           # InitTemplate

# ---------------------------------------------------------------------------
# Guard 1 — InitTemplate parses with zero warnings
# ---------------------------------------------------------------------------

suite "S7 guard — canonical InitTemplate parses with zero warnings":

  test "loadConfig(InitTemplate) produces no ConfigWarnings":
    ## Write InitTemplate to a temp file and parse it.
    ## Any unknown/misspelled key in InitTemplate would produce a ConfigWarning
    ## and fail this test, catching drift between the init output and the parser.
    let tmp = createTempDir("crisol_s7_", "")
    defer: removeDir(tmp)
    let cfgPath = tmp / "crisol.kdl"
    writeFile(cfgPath, InitTemplate)
    let (_, warns) = loadConfig(configPath = cfgPath)
    check warns.len == 0

# ---------------------------------------------------------------------------
# Guard 2 — schema-version pin using exported constants
# ---------------------------------------------------------------------------

suite "S7 guard — schema-version pin via exported constants":

  test "toJson emits RunV1Schema in the schema field":
    ## The run JSON document's schema field must equal the exported RunV1Schema
    ## constant.  This is drift-proof: if the emitter string changes, either
    ## the constant or the assertion fails — there is no hidden duplication.
    let results: seq[EntrypointResult] = @[]
    let summary = Summary()
    let node = toJson(results, summary)
    check node.hasKey("schema")
    check node["schema"].getStr == RunV1Schema

  test "planToJson emits PlanV1Schema in the schema field":
    ## The plan JSON document's schema field must equal the exported PlanV1Schema
    ## constant.  Same single-source-of-truth guarantee as the run guard above.
    let plan = RunPlan(jobs: 1, entrypoints: @[])
    let gatedOut: seq[GatedEntry] = @[]
    let node = planToJson(plan, gatedOut)
    check node.hasKey("schema")
    check node["schema"].getStr == PlanV1Schema
