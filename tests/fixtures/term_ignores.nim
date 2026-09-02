## term_ignores.nim — fixture that ignores SIGTERM and keeps running.
## Used by rfc-0007 A1b's E2E: the runner's SIGTERM grace window elapses with
## the child still alive, forcing escalation to SIGKILL — proves
## `cause.escalated == true` and the observed exit symbol is SIGKILL (not the
## SIGTERM `hang_forever` dies on under default dispositions).
import std/[os, posix]

signal(SIGTERM, SIG_IGN)
while true:
  os.sleep(1000)
