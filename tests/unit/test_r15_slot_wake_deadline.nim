## test_r15_slot_wake_deadline.nim — code-review r15: nextDeadline must not
## busy-spin on a forceKilled slot.
##
## `slotWakeDeadline` (runner.nim) is the extracted pure per-slot selection
## logic behind `nextDeadline` -- given one slot's wake-relevant fields and
## the current running minimum (`floor`, normally now+sampleTickMs), it
## returns the new minimum. A slot already forceKilled has a stopDeadline
## fixed in the past (that is what triggered the forceKill) and nothing
## re-arms it -- so it must be EXCLUDED from the min: its next legitimate
## wakeup is the eventual weChildExited, not another deadline sweep. Without
## the exclusion, `nextDeadline` keeps returning that past instant forever,
## and the event loop's `next(deadline)` returns weDeadline immediately on
## every call -- a busy-spin (full fill-pass + sweep per iteration) that
## pegs a core for as long as the child takes to actually die.
##
## Pure decision test: no subprocess, no Supervisor, no real Slot (Slot
## itself is private to runner.nim) -- SlotWakeInfo is the minimal exported
## data view built exactly for this.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_r15_slot_wake_deadline.nim

import std/[monotimes, options, times, unittest]
import crisol/runner

suite "r15: slotWakeDeadline excludes forceKilled slots from the min":

  test "a live, forceKilled slot with a past stopDeadline does not win the min":
    let now = getMonoTime()
    let floor = now + initDuration(milliseconds = 25)  # the sample-tick ceiling
    let pastStop = now - initDuration(milliseconds = 500)  # escalated long ago
    let info = SlotWakeInfo(live: true, forceKilled: true,
                            stopDeadline: some(pastStop),
                            deadline: now + initDuration(milliseconds = 10000))
    let got = slotWakeDeadline(info, floor)
    check got == floor  # NOT pastStop -- the bug pre-fix returned pastStop here

  test "a live, NOT forceKilled slot with a past stopDeadline (still escalating) DOES win the min":
    # Sanity: the exclusion is specific to forceKilled, not to a past
    # stopDeadline in general -- a slot mid-grace-window (stopDeadline
    # already armed but escalateExpired has not yet forceKilled it this
    # tick) must still surface its deadline so the loop wakes promptly to
    # escalate it.
    let now = getMonoTime()
    let floor = now + initDuration(milliseconds = 25)
    let pastStop = now - initDuration(milliseconds = 500)
    let info = SlotWakeInfo(live: true, forceKilled: false,
                            stopDeadline: some(pastStop),
                            deadline: now + initDuration(milliseconds = 10000))
    let got = slotWakeDeadline(info, floor)
    check got == pastStop

  test "an idle slot never contributes, regardless of forceKilled/deadline values":
    let now = getMonoTime()
    let floor = now + initDuration(milliseconds = 25)
    let info = SlotWakeInfo(live: false, forceKilled: false,
                            stopDeadline: none(MonoTime),
                            deadline: now - initDuration(milliseconds = 999999))
    let got = slotWakeDeadline(info, floor)
    check got == floor

  test "a live slot with only a future run deadline (no stopDeadline) reports it when earlier than floor":
    let now = getMonoTime()
    let floor = now + initDuration(milliseconds = 25)
    let nearerDeadline = now + initDuration(milliseconds = 5)
    let info = SlotWakeInfo(live: true, forceKilled: false,
                            stopDeadline: none(MonoTime),
                            deadline: nearerDeadline)
    let got = slotWakeDeadline(info, floor)
    check got == nearerDeadline
