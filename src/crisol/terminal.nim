## terminal.nim — terminal / environment helpers for crisol.
##
## Separated from render.nim so that render.nim is a genuinely pure module
## (no I/O, no env reads).
##
## Public API:
##
##   shouldEnableColor*(isTty: bool): bool
##     Returns true iff isTty AND the NO_COLOR env var is unset (or empty).
##     The isTty argument is injected by the caller (from isatty(stdout)),
##     so the terminal-detection side-effect lives outside this function.
##     Only NO_COLOR is read here; pass isTty=false for a fully env-free call.

import std/os

proc shouldEnableColor*(isTty: bool): bool =
  ## Returns true iff isTty AND NO_COLOR is unset (or empty).
  ## The isTty argument is injected by the caller so the terminal-detection
  ## side-effect lives outside this function.  Only NO_COLOR is read here.
  if not isTty: return false
  let noColor = getEnv("NO_COLOR")
  noColor.len == 0
