## scheduler.nim — pure scheduling helpers for crisol
##
## This module contains small, unit-testable pure helpers that support
## the executor's scheduling decisions without touching any I/O or process
## state.
##
## Public API:
##
##   effectiveRunTimeoutMs*(ep: Entrypoint; config: Config): int
##     Returns the effective run-phase timeout in **milliseconds** for `ep`.
##     Resolution order (first non-zero wins):
##       1. ep.runTimeoutSecs  (group-level, copied by discover())
##       2. config.timeoutSecs (global)
##       3. 300_000 ms         (built-in default, matching DefaultTimeoutSecs)
##
##     The result is always positive.  The built-in default (300_000 ms) is
##     intentionally consistent with config.DefaultTimeoutSecs so that there
##     is never a magic number that diverges between the two.

import crisol/types

# ---------------------------------------------------------------------------
# Built-in run-timeout default (milliseconds)
# ---------------------------------------------------------------------------

const BuiltinRunTimeoutMs* = 300_000
  ## Built-in run-phase timeout (300 s), used when neither the entrypoint nor
  ## the global config specifies a timeout.  Consistent with DefaultTimeoutSecs
  ## in config.nim — do not change one without changing the other.

# ---------------------------------------------------------------------------
# effectiveRunTimeoutMs — pure, unit-testable
# ---------------------------------------------------------------------------

proc effectiveRunTimeoutMs*(ep: Entrypoint; config: Config): int =
  ## Returns the effective run-phase timeout in milliseconds for `ep`.
  ##
  ## Resolution order (first non-zero wins):
  ##   1. ep.runTimeoutSecs  > 0 → use that value (converted to ms)
  ##   2. config.timeoutSecs > 0 → use the global value (converted to ms)
  ##   3. BuiltinRunTimeoutMs    → built-in default (300_000 ms)
  ##
  ## Feature A (RFC-0002): the group-level timeout is copied into
  ## ep.runTimeoutSecs by discover().  This proc computes the final resolved
  ## value that the executor should use when setting the run-phase deadline.
  if ep.runTimeoutSecs > 0:
    ep.runTimeoutSecs * 1000
  elif config.timeoutSecs > 0:
    config.timeoutSecs * 1000
  else:
    BuiltinRunTimeoutMs
