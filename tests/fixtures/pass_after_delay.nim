## pass_after_delay.nim — rfc-0007 B1b support fixture: sleeps briefly then
## exits 0. Used as a SECOND entrypoint (after spawn_late_orphan.nim, jobs=1)
## purely to keep the executor's event loop alive — and therefore still
## calling `sv.next()`, the only place the async orphan sweep runs — long
## enough for a late-dying, already-reparented orphan from the FIRST
## entrypoint to actually be observed and reaped. Without a second live
## slot, `execute()` would return the instant the first entrypoint's result
## is emitted, and nothing would ever call `next()` again to catch it.
import std/os

sleep(3000)
quit(0)
