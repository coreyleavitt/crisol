## test_timeout_resolution.nim — S2a unit tests for effectiveRunTimeoutMs
##
## Covers:
##   1. Returns the group/entrypoint value (converted to ms) when runTimeoutSecs > 0.
##   2. Returns the global config.timeoutSecs (in ms) when ep.runTimeoutSecs == 0.
##   3. Returns the built-in default (in ms) when both are 0.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_timeout_resolution.nim

import std/unittest
import crisol/types
import crisol/scheduler

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeEp(runTimeoutSecs: int = 0): Entrypoint =
  Entrypoint(path: "tests/unit/test_a.nim", group: "unit", flags: @[],
             runTimeoutSecs: runTimeoutSecs)

proc makeCfg(timeoutSecs: int = 0): Config =
  Config(groups: @[], jobs: 1, timeoutSecs: timeoutSecs,
         compileTimeoutSecs: 600, maxOutputBytes: 10 * 1024 * 1024,
         stateDir: ".crisol", projectRoot: "/tmp")

# ---------------------------------------------------------------------------
# Suite: effectiveRunTimeoutMs
# ---------------------------------------------------------------------------

suite "effectiveRunTimeoutMs":

  test "returns ep.runTimeoutSecs * 1000 when ep.runTimeoutSecs > 0":
    let ep  = makeEp(runTimeoutSecs = 42)
    let cfg = makeCfg(timeoutSecs = 300)
    check effectiveRunTimeoutMs(ep, cfg) == 42_000

  test "returns global config.timeoutSecs * 1000 when ep.runTimeoutSecs == 0 and config > 0":
    let ep  = makeEp(runTimeoutSecs = 0)
    let cfg = makeCfg(timeoutSecs = 120)
    check effectiveRunTimeoutMs(ep, cfg) == 120_000

  test "returns built-in default (300_000 ms) when both ep and config are 0":
    let ep  = makeEp(runTimeoutSecs = 0)
    let cfg = makeCfg(timeoutSecs = 0)
    # DefaultTimeoutSecs == 300; built-in fallback should be 300_000 ms
    check effectiveRunTimeoutMs(ep, cfg) == 300_000

  test "ep.runTimeoutSecs takes priority over global config":
    ## Even if the global is larger, the ep-level value wins when > 0.
    let ep  = makeEp(runTimeoutSecs = 5)
    let cfg = makeCfg(timeoutSecs = 300)
    check effectiveRunTimeoutMs(ep, cfg) == 5_000

  test "global config takes priority over built-in default":
    ## When ep is 0 but config is set, config wins over the 300s default.
    let ep  = makeEp(runTimeoutSecs = 0)
    let cfg = makeCfg(timeoutSecs = 600)
    check effectiveRunTimeoutMs(ep, cfg) == 600_000
