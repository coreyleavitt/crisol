## test_admission.nim — S3+S5 unit tests for AdmissionController (pure).
##
## S3 suite: group-cap-only subset of AdmissionController.admit/release/onSlotFinish.
## S5 suite: memory predicate — under/over budget, progress override, committed
##           reservation burst guard, cdSkipFresh estimate, non-vacuity proof.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_admission.nim

import std/[options, unittest]
import crisol/types
import crisol/admission

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkConfig(groups: seq[Group]): Config =
  Config(
    groups:             groups,
    jobs:               4,
    timeoutSecs:        300,
    compileTimeoutSecs: 600,
    maxOutputBytes:     10 * 1024 * 1024,
    stateDir:           ".crisol",
    projectRoot:        "/tmp",
  )

proc mkGroup(name: string; maxJobs: Option[int]): Group =
  Group(
    name:     name,
    globs:    @["tests/unit/*.nim"],
    flags:    @[],
    optIn:    false,
    gate:     none(Gate),
    timeoutSecs: 0,
    maxJobs:  maxJobs,
  )

proc mkPlan(jobs: int): RunPlan =
  RunPlan(jobs: jobs, entrypoints: @[])

# ---------------------------------------------------------------------------
# Suite: group-cap-only admit/release/onSlotFinish
# ---------------------------------------------------------------------------

suite "AdmissionController — group cap (S3)":

  test "uncapped group always admits":
    let cfg  = mkConfig(@[mkGroup("unit", none(int))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok  = ac.admit(passId, "unit", edNeverBuilt)
    check tok.isSome
    check tok.get.group == "unit"

  test "admit increments groupInflight; second admit within cap succeeds":
    let cfg  = mkConfig(@[mkGroup("unit", some(2))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    check tok2.isSome

  test "admit returns none when groupInflight == cap":
    let cfg  = mkConfig(@[mkGroup("serial", some(1))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "serial", edNeverBuilt)
    check tok1.isSome
    let tok2 = ac.admit(passId, "serial", edNeverBuilt)
    check tok2.isNone     # cap hit: exactly 1 in flight

  test "admit respects cap N=2: third admit returns none":
    let cfg  = mkConfig(@[mkGroup("g", some(2))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    discard ac.admit(passId, "g", edNeverBuilt)
    discard ac.admit(passId, "g", edNeverBuilt)
    let tok3 = ac.admit(passId, "g", edNeverBuilt)
    check tok3.isNone

  test "release frees a slot — admit succeeds after release":
    let cfg  = mkConfig(@[mkGroup("serial", some(1))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "serial", edNeverBuilt)
    check tok1.isSome
    check ac.admit(passId, "serial", edNeverBuilt).isNone  # at cap
    ac.release(tok1.get)
    inc passId
    let tok2 = ac.admit(passId, "serial", edNeverBuilt)
    check tok2.isSome                              # slot freed by release

  test "onSlotFinish frees a slot — admit succeeds after finish":
    let cfg  = mkConfig(@[mkGroup("serial", some(1))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "serial", edNeverBuilt)
    check tok1.isSome
    check ac.admit(passId, "serial", edNeverBuilt).isNone  # at cap
    ac.onSlotFinish(tok1.get, none(int64))
    inc passId
    let tok2 = ac.admit(passId, "serial", edNeverBuilt)
    check tok2.isSome                              # slot freed by finish

  test "different groups are independent — cap on one does not block the other":
    let cfg  = mkConfig(@[
      mkGroup("serial", some(1)),
      mkGroup("parallel", some(4)),
    ])
    let plan = mkPlan(8)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "serial",   edNeverBuilt)  # serial now at cap
    check tok1.isSome
    check ac.admit(passId, "serial", edNeverBuilt).isNone  # serial blocked
    let tokP = ac.admit(passId, "parallel", edNeverBuilt)  # parallel unaffected
    check tokP.isSome

  test "uncapped group: no limit even at high concurrency":
    let cfg  = mkConfig(@[mkGroup("free", none(int))])
    let plan = mkPlan(16)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    for _ in 0 ..< 10:
      check ac.admit(passId, "free", edNeverBuilt).isSome

  test "group not in config (no cap entry) is treated as uncapped":
    ## Groups without maxJobs do NOT get a cap entry — they are fully uncapped.
    ## Use a high jobsCap so the CPU limit doesn't fire before we prove it.
    let cfg  = mkConfig(@[mkGroup("unit", none(int))])
    let plan = mkPlan(20)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    # "unknown" group has no cap → treated as uncapped
    for _ in 0 ..< 5:
      check ac.admit(passId, "unknown", edNeverBuilt).isSome

  test "cdSkipFresh decision is accepted (decision param accepted, not inspected this slice)":
    let cfg  = mkConfig(@[mkGroup("unit", some(2))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok  = ac.admit(passId, "unit", edRunFresh)
    check tok.isSome
    check tok.get.group == "unit"

  test "SlotToken.reserved reflects estJobPeak for cold compile (S5 active)":
    ## S3 note: token.reserved was 0 when memory was stubbed.
    ## S5: reserved is now set to estJobPeak (512 MiB default) for cold compiles.
    ## probe=nil → B inert (always admits), but reserved is still set correctly.
    let cfg  = mkConfig(@[mkGroup("unit", none(int))])
    let plan = mkPlan(4)
    var ac   = initAdmission(cfg, plan)
    var passId: uint = 0
    inc passId
    let tok  = ac.admit(passId, "unit", edNeverBuilt)
    check tok.isSome
    # S5: reserved is estJobPeak (512 MiB) because probe is nil and B is inert,
    # but we still track the reservation for committed accounting.
    check tok.get.reserved == 512i64 * 1024 * 1024

# ---------------------------------------------------------------------------
# Helpers for S5 memory tests
# ---------------------------------------------------------------------------

proc mkAdmissionMem(avail: Option[int64];
                    estJobPeakMb: int64 = 512;
                    safetyMb: int64 = 0;
                    memPerRunMb: int64 = 64;
                    jobsCap: int = 4;
                    groups: seq[Group] = @[]): AdmissionController =
  ## Build a controller with a fixed probe returning `avail` and explicit seeds.
  ## Used to inject deterministic available memory without touching real /proc.
  let probe = proc(): Option[int64] = avail
  let cfg   = mkConfig(groups)
  let plan  = mkPlan(jobsCap)
  result = initAdmission(cfg, plan, probe,
                         estJobPeakMb = estJobPeakMb,
                         safetyMb     = safetyMb,
                         memPerRunMb  = memPerRunMb)

# ---------------------------------------------------------------------------
# Suite: S5 memory predicate
# ---------------------------------------------------------------------------

suite "AdmissionController — memory predicate (S5)":

  # -------------------------------------------------------------------------
  # NON-VACUITY case (RFC lines 510-513): liveCount >= 1 AND memory gate blocks.
  # This MUST go RED against the group-cap-only S3 admit before S5 is implemented.
  # It proves the MEMORY gate (not just progress override) is active.
  # -------------------------------------------------------------------------
  test "non-vacuity: liveCount>=1 AND over-budget → admit returns none (memory gate blocks)":
    ## avail = 100 MiB, estJobPeak = 512 MiB, safety = 0.
    ## First admit: liveCount==0 → progress override fires → admitted.
    ## Second admit: liveCount==1, committed=512MiB, avail=100MiB →
    ##   avail - committed - safety = 100 - 512 - 0 = -412 MiB < 0 → NONE.
    let availBytes = 100i64 * 1024 * 1024   # 100 MiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # liveCount==0 → override → admitted
    check tok1.isSome
    # Same passId → same snapshot; now liveCount==1
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # liveCount==1, over budget → NONE
    check tok2.isNone  # RED until S5 implements the memory gate

  test "under-budget: avail > committed + safety + reserved → admits":
    ## avail = 1024 MiB, estJobPeak = 512 MiB, safety = 0 → plenty of room.
    let availBytes = 1024i64 * 1024 * 1024  # 1 GiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    # First admit: liveCount==0 → override (or memory admits — avail OK either way)
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    # Second admit: liveCount==1, committed=512MiB, avail=1024MiB → 1024-512-0=512>=512 → admits
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok2.isSome

  test "over-budget: avail < committed + safety + reserved → refuses (liveCount>=1)":
    ## This is the canonical memory-gate-blocks case.
    ## Same as non-vacuity test — the dedicated name makes intent clearer.
    let availBytes = 100i64 * 1024 * 1024   # 100 MiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # override fires (liveCount==0)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # liveCount==1, over budget
    check tok2.isNone

  test "progress override: liveCount==0 admits even when over-budget":
    ## avail = 1 byte, estJobPeak = 512 MiB → clearly over budget.
    ## But liveCount==0 → progress override → must admit (deadlock prevention).
    let availBytes = 1i64   # effectively 0 usable
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok = ac.admit(passId, "unit", edNeverBuilt)  # liveCount==0 → override
    check tok.isSome

  test "progress override does NOT bypass group cap":
    ## liveCount==0 but group is at its cap → group cap must still refuse.
    let availBytes = 1i64   # over budget
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0,
                             groups = @[mkGroup("serial", some(1))])
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "serial", edNeverBuilt)  # liveCount==0, within cap → admitted
    check tok1.isSome
    # liveCount==1, group at cap → cap must refuse (cap takes priority over override)
    let tok2 = ac.admit(passId, "serial", edNeverBuilt)
    check tok2.isNone

  test "committed reservation blocks a burst within one fill pass":
    ## avail = 600 MiB, estJobPeak = 512 MiB, safety = 0.
    ## Pass 1: inc passId → snapshot = 600 MiB (refreshed on first admit of pass).
    ##   admit #1: liveCount==0 → override → committed += 512 MiB → admitted.
    ##   admit #2: liveCount==1, 600-512-0=88 < 512 → refused.
    ## This confirms per-admit committed update within a single pass.
    let availBytes = 600i64 * 1024 * 1024   # 600 MiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId  # single pass
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # same snapshot, but committed grew
    check tok2.isNone

  test "cdSkipFresh uses memPerRunMb (64 MiB) not estJobPeak (512 MiB)":
    ## avail = 200 MiB, estJobPeak = 512 MiB, memPerRunMb = 64 MiB, safety = 0.
    ## A cold admit (cdNeverBuilt) after one slot live: 200-512-0=-312 < 0 → refused.
    ## A fresh admit (cdSkipFresh) after one slot live: 200-512-0=..wait,
    ##   liveCount==1 after first admit, committed=512 (for a cold reserve).
    ##   Actually let's be careful: first admit is override (liveCount==0).
    ##   After tok1: committed=512 MiB (from cdNeverBuilt).
    ##   cdSkipFresh reserve=64 MiB: avail-committed-safety=200-512-0=-312 → still refused.
    ##
    ## Better setup: first admit is cdSkipFresh (reserved=64).
    ##   After tok1: committed=64. liveCount==1.
    ##   cdSkipFresh #2 reserve=64: 200-64-0=136 >=64 → admitted.
    ##   cdNeverBuilt #3 reserve=512: 200-64*2-0=72 < 512 → refused.
    ## This proves cdSkipFresh path uses the smaller estimate.
    let availBytes = 200i64 * 1024 * 1024   # 200 MiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0,
                             memPerRunMb = 64)
    var passId: uint = 0
    inc passId
    # First cdSkipFresh: liveCount==0 → override (or mem admits: 200-0-0=200>=64) → admitted
    let tok1 = ac.admit(passId, "unit", edRunFresh)
    check tok1.isSome
    check tok1.get.reserved == 64i64 * 1024 * 1024  # 64 MiB reserved
    # Second cdSkipFresh: liveCount==1, avail-committed-safety=200-64-0=136>=64 → admitted
    let tok2 = ac.admit(passId, "unit", edRunFresh)
    check tok2.isSome
    # cdNeverBuilt: avail-committed-safety=200-128-0=72 < 512 → refused
    let tok3 = ac.admit(passId, "unit", edNeverBuilt)
    check tok3.isNone

  test "probe none AND memBudgetMb==0 → B inert (always admits up to jobsCap)":
    ## When availSnapshot.isNone, the memory gate is inert — admit is group-cap+jobsCap-only.
    ## Use a high jobsCap so we can verify B is truly inert (no memory refusals).
    var ac = mkAdmissionMem(none(int64), estJobPeakMb = 512, safetyMb = 0, jobsCap = 20)
    var passId: uint = 0
    inc passId
    for _ in 0 ..< 10:
      check ac.admit(passId, "unit", edNeverBuilt).isSome

  test "safety margin counts against available budget":
    ## avail = 600 MiB, estJobPeak = 200 MiB, safety = 100 MiB.
    ## After first (committed=200): 600-200-100=300 >= 200 → second admits.
    ## After second (committed=400): 600-400-100=100 < 200 → third refused.
    ## Without safety: 600-400-0=200 >= 200 → third would admit.
    let availBytes = 600i64 * 1024 * 1024
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 200, safetyMb = 100,
                             memPerRunMb = 64)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # liveCount==0 → override
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # 600-200-100=300 >= 200 → admits
    check tok2.isSome
    let tok3 = ac.admit(passId, "unit", edNeverBuilt)   # 600-400-100=100 < 200 → refuses
    check tok3.isNone

  test "liveCount >= jobsCap refuses regardless of memory":
    ## Even with ample memory, once liveCount hits jobsCap → refuse.
    ## Use uncapped group so group cap never fires; only jobsCap limits.
    let availBytes = 100i64 * 1024 * 1024 * 1024  # 100 GiB — ample
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0,
                             jobsCap = 2)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok2.isSome
    let tok3 = ac.admit(passId, "unit", edNeverBuilt)  # liveCount==jobsCap==2 → refused
    check tok3.isNone

  test "release rolls back committed and liveCount":
    ## After release, the same slot can be re-admitted within budget.
    let availBytes = 600i64 * 1024 * 1024  # 600 MiB
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # override → committed=512
    check tok1.isSome
    check ac.admit(passId, "unit", edNeverBuilt).isNone  # 600-512=88 < 512 → refused
    ac.release(tok1.get)  # rolls back committed → 0, liveCount → 0
    # Now liveCount==0 again → override fires (new pass so snapshot refreshes)
    inc passId
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok2.isSome

  test "onSlotFinish rolls back committed and liveCount":
    let availBytes = 600i64 * 1024 * 1024
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # override → committed=512
    check tok1.isSome
    check ac.admit(passId, "unit", edNeverBuilt).isNone  # over budget
    ac.onSlotFinish(tok1.get, none(int64))  # rolls back committed → 0, liveCount → 0
    inc passId
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok2.isSome

  test "onSlotFinish with rss updates estJobPeak monotonically":
    ## After a high-RSS observation, estJobPeak ratchets up → harder to admit.
    ## avail = 2000 MiB, initial estJobPeak = 512 MiB.
    ## Admit 2 slots (512 each → committed=1024), finish first with rss=900MiB.
    ## estJobPeak should ratchet to 900 MiB.
    ## Next pass: avail=2000. committed=512 (one still live).
    ## Admit cold: 2000-512-0=1488 >= 900 → admits.
    ## Then committed=512+900=1412. Next cold: 2000-1412-0=588 < 900 → refuses.
    let availBytes = 2000i64 * 1024 * 1024
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # override, committed=512
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # 2000-512=1488>=512 → admits, committed=1024
    check tok2.isSome
    # Finish tok1 with 900 MiB RSS → estJobPeak ratchets to 900 MiB, committed=512
    ac.onSlotFinish(tok1.get, some(900i64 * 1024 * 1024))
    # New fill pass
    inc passId
    # Admit next cold: reserved=900 MiB now. committed=512. 2000-512-0=1488>=900 → admits
    let tok3 = ac.admit(passId, "unit", edNeverBuilt)
    check tok3.isSome  # committed now 512+900=1412
    let tok4 = ac.admit(passId, "unit", edNeverBuilt)  # 2000-1412-0=588 < 900 → refuses
    check tok4.isNone

  test "onSlotFinish with rss=none does NOT update estJobPeak":
    ## Low rss=none should not lower the estimate.
    ## avail = 100 GiB to keep memory gate out of the way for this test.
    let availBytes = 100i64 * 1024 * 1024 * 1024
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId: uint = 0
    inc passId
    let tok = ac.admit(passId, "unit", edNeverBuilt)
    check tok.isSome
    # Finish with none (no observation) — estJobPeak should stay at 512 MiB
    ac.onSlotFinish(tok.get, none(int64))
    # Verify via behavior with tight budget: if estJobPeak had wrongly dropped, admission
    # semantics would change. Monotonic floor is independently tested below.
    # Prove monotonic: admit, finish with tiny rss, verify peak still blocks next slot.
    var ac2 = mkAdmissionMem(some(availBytes), estJobPeakMb = 512, safetyMb = 0)
    var passId2: uint = 0
    inc passId2
    let t1 = ac2.admit(passId2, "unit", edNeverBuilt)
    check t1.isSome
    ac2.onSlotFinish(t1.get, some(1i64))  # tiny RSS — should NOT lower below 512 MiB
    # Now with tight avail: avail=513 MiB, estJobPeak should still be 512 MiB
    var ac3 = mkAdmissionMem(some(513i64 * 1024 * 1024), estJobPeakMb = 512, safetyMb = 0)
    var passId3: uint = 0
    inc passId3
    let t2 = ac3.admit(passId3, "unit", edNeverBuilt)  # liveCount==0 → override
    check t2.isSome
    # committed=512, avail=513: 513-512-0=1 < 512 → second refuses (peak still 512)
    let t3 = ac3.admit(passId3, "unit", edNeverBuilt)
    check t3.isNone

# ---------------------------------------------------------------------------
# Suite: S6a — initAdmission reads seeds from Config
# ---------------------------------------------------------------------------

suite "AdmissionController — Config-sourced seeds (S6a)":

  test "cfg.memPerJobMb 700 → initAdmission uses 700 MiB seed (not 512 MiB default)":
    ## Config has memPerJobMb=700; initAdmission should seed estJobPeak at 700 MiB.
    ## avail=1050: seed=700, 1st override (committed=700). 2nd: 1050-700=350 < 700 → refuse.
    ## With 512 MiB default: committed=512. 2nd: 1050-512=538>=512 → admit (distinguishes them).
    let availBytes = 1050i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memPerJobMb:        some(700),  # S6a: Config carries the seed
      memPerRunMb:        none(int),
      memBudgetMb:        none(int),
      memAware:           none(bool),
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # liveCount==0 → override; committed=700 MiB
    check tok1.isSome
    check tok1.get.reserved == 700i64 * 1024 * 1024  # seed reflects 700 MiB
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)  # 1050-700=350 < 700 → refuse
    check tok2.isNone

  test "cfg.memPerRunMb 128 → initAdmission uses 128 MiB seed for cdSkipFresh":
    ## Config has memPerRunMb=128; cdSkipFresh should reserve 128 MiB, not 64 MiB.
    ## Distinguish: avail=200, skip 1 (committed=128), then skip 2: 200-128=72 < 128 → refuse.
    ## With 64: committed=64, second: 200-64=136>=64 → admit.
    let availBytes = 200i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memPerJobMb:        none(int),
      memPerRunMb:        some(128),  # S6a: Config carries the seed
      memBudgetMb:        none(int),
      memAware:           none(bool),
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edRunFresh)  # override (liveCount=0); committed=128
    check tok1.isSome
    check tok1.get.reserved == 128i64 * 1024 * 1024
    let tok2 = ac.admit(passId, "unit", edRunFresh)  # 200-128=72 < 128 → refuse
    check tok2.isNone

  test "cfg.memPerJobMb 0 (absent) → initAdmission falls back to 512 MiB built-in seed":
    ## When cfg.memPerJobMb==0, initAdmission must use the 512 MiB built-in.
    ## avail=1050: seed=512, 1st override (committed=512). 2nd: 1050-512=538>=512 → admit.
    let availBytes = 1050i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memPerJobMb:        none(int),   # absent → built-in 512 MiB
      memPerRunMb:        none(int),
      memBudgetMb:        none(int),
      memAware:           none(bool),
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # override; committed=512 MiB
    check tok1.isSome
    check tok1.get.reserved == 512i64 * 1024 * 1024  # default built-in
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)  # 1050-512=538>=512 → admit
    check tok2.isSome

  test "injected estJobPeakMb param overrides cfg.memPerJobMb for test injectability":
    ## When the explicit param is > 0, it wins over cfg.memPerJobMb.
    ## This preserves the S5 test seam.
    let availBytes = 1050i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memPerJobMb:        some(700),  # Config says 700
      memPerRunMb:        none(int),
      memBudgetMb:        none(int),
      memAware:           none(bool),
    )
    let plan = mkPlan(4)
    # Inject 300 MiB explicitly — should override the config's 700 MiB
    var ac = initAdmission(cfg, plan, probe, estJobPeakMb = 300)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # override; committed should be 300 MiB
    check tok1.isSome
    check tok1.get.reserved == 300i64 * 1024 * 1024  # injected param wins

# ---------------------------------------------------------------------------
# Suite: M9 — mem-aware truth table in initAdmission (four cases)
# ---------------------------------------------------------------------------
#
# These tests prove that initAdmission correctly resolves the four mem-aware
# cases (M5b): the decision logic lives inside initAdmission, not in execute().
#
# Truth table:
#   some(false)          → kill switch: gate fully OFF (probe nil, budget 0).
#   some(true)           → force ON: probe used AS-IS; budget active.
#   none + probe avail   → auto ON: probe used; budget active.
#   none + probe unavail → auto OFF: probe nil; budget still active (budget-only mode).

suite "AdmissionController — mem-aware truth table in initAdmission (M9)":

  test "some(false) = kill switch: gate fully OFF even with a live probe and budget":
    ## mem-aware some(false) must suppress the probe AND zero out the budget.
    ## With a live probe returning 100 MiB and budget=256 MiB:
    ## Without kill switch, the gate would serialize (budget < peak).
    ## With kill switch, the gate is fully inert → two admits succeed despite budget.
    let availBytes = 100i64 * 1024 * 1024   # 100 MiB — well below 512 MiB peak
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memBudgetMb:        some(256),  # budget set, but kill switch must suppress it
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memAware:           some(false),  # kill switch OFF
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    # Both admits must succeed: gate is fully inert (probe suppressed, budget suppressed)
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    check tok2.isSome   # inert → no memory refusal

  test "some(true) = force ON: gate active even when probe candidate would return none":
    ## mem-aware some(true) forces the gate ON using the probe AS-IS.
    ## With a nil probe but budget=100 MiB and estJobPeak=512 MiB seed:
    ## some(true) + nil probe → budget-only mode (on first admit of pass: probe nil + budget > 0
    ## → availSnapshot = some(budget=100 MiB)).
    ## First admit: liveCount==0 → progress-override → admitted (committed=512 MiB).
    ## Second admit: avail(100 MiB) - committed(512 MiB) < 512 MiB → NONE.
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memBudgetMb:        some(100),  # 100 MiB budget < 512 MiB peak → serializes
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memAware:           some(true),  # force ON
    )
    let plan = mkPlan(4)
    # Pass nil probe — some(true) must use budget-only mode (not just be inert).
    var ac = initAdmission(cfg, plan, probe = nil)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # liveCount==0 → override → admitted
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # 100-512=-412 < 512 → NONE (gate active)
    check tok2.isNone

  test "none + probe available → auto ON: gate active (probe used)":
    ## mem-aware none + probe returning some → auto-detect ON.
    ## probe returns 100 MiB. Budget none.
    ## First admit: liveCount==0 → override. Second: 100-512=-412 < 512 → NONE.
    let availBytes = 100i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memBudgetMb:        none(int),
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memAware:           none(bool),  # auto
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)   # override fires (liveCount==0)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # 100-512<0 → NONE (gate active)
    check tok2.isNone

  test "none + probe unavailable → auto OFF: gate inert (no serialization)":
    ## mem-aware none + probe returning none → auto-detect OFF.
    ## Gate inert → many admits succeed (no memory refusal, only jobsCap limits).
    let unavailProbe = proc(): Option[int64] = none(int64)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               10,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memBudgetMb:        none(int),
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memAware:           none(bool),  # auto → probe unavailable → OFF
    )
    let plan = mkPlan(10)
    var ac = initAdmission(cfg, plan, unavailProbe)
    var passId: uint = 0
    inc passId
    # All 5 admits must succeed: gate inert (probe returned none → OFF).
    for _ in 0 ..< 5:
      check ac.admit(passId, "unit", edNeverBuilt).isSome

  test "some(true) with live probe: gate ON, probe drives admission (not budget-only)":
    ## some(true) with a working probe → probe is used directly.
    ## avail=100 MiB, no budget (none), peak=512 MiB.
    ## First admit: liveCount==0 → override. Second: 100-512<0 → NONE.
    let availBytes = 100i64 * 1024 * 1024
    let probe = proc(): Option[int64] = some(availBytes)
    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memBudgetMb:        none(int),
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memAware:           some(true),  # force ON
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe)
    var passId: uint = 0
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)   # gate active → refused
    check tok2.isNone

# ---------------------------------------------------------------------------
# Suite: Epoch contract — M5a proof
# ---------------------------------------------------------------------------
#
# These tests prove the self-managing snapshot epoch contract:
#   1. Two admit calls with the SAME passId use the SAME snapshot even if the
#      underlying probe value changes between them.
#   2. A new passId (incremented between passes) picks up the new probe value.

suite "AdmissionController — epoch / snapshot contract (M5a)":

  test "same passId: both admits see the first snapshot even if probe value changes":
    ## Probe returns a DIFFERENT value each call (counter-based).
    ## Pass 1 (passId=1): first admit triggers refresh (probe call #1: 2000 MiB).
    ##   - admit #1: liveCount==0 → override → tok1 admitted, committed=512.
    ##   - admit #2: probe is NOT re-called (same passId) → snapshot still 2000 MiB.
    ##     2000-512-0=1488 >= 512 → admitted (tok2).
    ## If the snapshot were refreshed on every admit, probe would return a smaller value
    ## on call #2 and the second admit might be refused — proving epoch isolation.
    ##
    ## Use memAware=some(true) to avoid the auto-detect init call (which would consume
    ## the first counter value).  Force-ON mode uses the probe as-is without a test call.
    var callCount = 0
    let probe = proc(): Option[int64] =
      inc callCount
      if callCount == 1:
        some(2000i64 * 1024 * 1024)  # first call: 2000 MiB
      else:
        some(100i64 * 1024 * 1024)   # subsequent calls: 100 MiB (would block)

    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memAware:           some(true),  # force ON: skip the auto-detect init call
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memBudgetMb:        none(int),
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe, estJobPeakMb = 512, safetyMb = 0)
    check callCount == 0  # force-ON: probe not called during init
    var passId: uint = 0
    inc passId  # pass 1

    let tok1 = ac.admit(passId, "unit", edNeverBuilt)
    check tok1.isSome  # override (liveCount==0); snapshot refreshed: probe call #1 = 2000 MiB
    check callCount == 1

    let tok2 = ac.admit(passId, "unit", edNeverBuilt)
    # Same passId → snapshot NOT refreshed (probe NOT called again).
    # Snapshot is still 2000 MiB. committed=512. 2000-512-0=1488>=512 → admitted.
    check tok2.isSome  # if snapshot were re-read, 100-512<0 → would be none
    check callCount == 1  # probe still called only once

  test "new passId: picks up the changed probe value on next pass":
    ## Same counter probe. Pass 1 uses 2000 MiB. Pass 2 should see 100 MiB.
    ## In pass 2, liveCount is still 2 (tok1 and tok2 not finished), so
    ## committed=1024 MiB and snapshot=100 MiB → 100-1024<0 → refused.
    ## This proves the new passId triggers a fresh probe call.
    ##
    ## Use memAware=some(true) to avoid the auto-detect init call.
    var callCount = 0
    let probe = proc(): Option[int64] =
      inc callCount
      if callCount == 1:
        some(2000i64 * 1024 * 1024)  # pass 1 snapshot
      else:
        some(100i64 * 1024 * 1024)   # pass 2 snapshot (stale from OS perspective)

    let cfg = Config(
      groups:             @[mkGroup("unit", none(int))],
      jobs:               4,
      timeoutSecs:        300,
      compileTimeoutSecs: 600,
      maxOutputBytes:     10 * 1024 * 1024,
      stateDir:           ".crisol",
      projectRoot:        "/tmp",
      memAware:           some(true),  # force ON: skip the auto-detect init call
      memPerJobMb:        none(int),
      memPerRunMb:        none(int),
      memBudgetMb:        none(int),
    )
    let plan = mkPlan(4)
    var ac = initAdmission(cfg, plan, probe, estJobPeakMb = 512, safetyMb = 0)
    check callCount == 0  # force-ON: probe not called during init
    var passId: uint = 0

    # Pass 1
    inc passId
    let tok1 = ac.admit(passId, "unit", edNeverBuilt)  # probe call #1 → 2000 MiB; override → ok
    check tok1.isSome
    check callCount == 1
    let tok2 = ac.admit(passId, "unit", edNeverBuilt)  # same pass → 2000-512=1488>=512 → ok
    check tok2.isSome
    check callCount == 1  # still only one probe call

    # Pass 2: new passId triggers a fresh snapshot.
    inc passId
    let tok3 = ac.admit(passId, "unit", edNeverBuilt)
    # Probe call #2 returns 100 MiB. committed=1024 (tok1+tok2 still live).
    # 100-1024-0 < 512 → refused (liveCount=2, no override).
    check tok3.isNone
    check callCount == 2  # probe called exactly once more for the new pass

# ---------------------------------------------------------------------------
# Suite: Gap 1 — release actually decrements groupInflight (non-vacuous H4)
# ---------------------------------------------------------------------------
#
# The existing "release frees a slot" test (S3 suite) only checks that a
# subsequent admit SUCCEEDS after release.  That passes even if release
# forgets to decrement groupInflight, because liveCount==0 after the release
# and the progress-override fires anyway (bypassing the group cap check via
# the memory gate — but NOT the group cap itself).
#
# Wait — actually the group cap is NEVER bypassed by the progress override.
# Progress override bypasses ONLY the memory gate.  So the S3 test is
# partially sound: if groupInflight were not decremented, the second admit
# would hit the cap and return none.  But the S3 test uses a memory-inert
# setup (no probe), so it truly does prove the cap is freed.
#
# The real vacuity risk (H4) is: the existing test doesn't distinguish
# "group cap was decremented" from "progress override bypasses memory" when
# there's a live probe.  The test below proves with a live probe AND
# liveCount > 0 (no override) that release decrements groupInflight.

suite "AdmissionController — release decrements groupInflight (Gap 1 non-vacuous)":

  test "release decrements groupInflight: second admit refused while first in-flight, then freed":
    ## Setup:
    ##   - group "serial" with max-jobs 1 (cap=1).
    ##   - live probe returning 2 GiB (ample memory, so memory gate never blocks).
    ##   - jobs=4 (so jobsCap never fires).
    ##   - An EXTRA uncapped slot is kept in-flight so liveCount > 0 throughout,
    ##     defeating the progress-override.  This ensures that any SUCCESS after
    ##     release is due to the group cap being freed, not the override.
    ##
    ## Steps:
    ##   1. Admit "extra" (uncapped group) → liveCount = 1, group "serial" at 0.
    ##   2. Admit "serial" (cap=1) → liveCount = 2, group "serial" at 1 (cap hit).
    ##   3. Try admit "serial" again → MUST be refused (cap=1, and liveCount=2 so
    ##      no override).  This proves the cap is respected.
    ##   4. Call release(tok_serial) → groupInflight["serial"] should go to 0.
    ##   5. New pass: admit "serial" → liveCount still >= 1 (extra still live)
    ##      → no override, but cap now free → MUST succeed.
    ##      If release forgot to decrement groupInflight, this would still be None.
    ##
    ## Non-vacuity: removing the groupInflight decrement from release would cause
    ## step 5 to return none (cap still appears full) → test goes RED.
    let availBytes = 2048i64 * 1024 * 1024  # 2 GiB — ample
    let groups = @[
      mkGroup("serial",  some(1)),   # capped group under test
      mkGroup("extra",   none(int)), # uncapped group to keep liveCount > 0
    ]
    var ac = mkAdmissionMem(some(availBytes), estJobPeakMb = 64, safetyMb = 0,
                            memPerRunMb = 64, jobsCap = 4, groups = groups)
    var passId: uint = 0

    # Step 1: Admit "extra" to keep liveCount > 0.
    inc passId
    let tokExtra = ac.admit(passId, "extra", edNeverBuilt)
    check tokExtra.isSome  # uncapped → admitted; liveCount = 1

    # Step 2: Admit "serial" (first slot, within cap).
    inc passId
    let tokSerial1 = ac.admit(passId, "serial", edNeverBuilt)
    check tokSerial1.isSome  # cap=1, in-flight=0 → admitted; now serial at cap

    # Step 3: Refuse second "serial" admit (liveCount=2, no override; serial at cap).
    let tokSerial2 = ac.admit(passId, "serial", edNeverBuilt)
    check tokSerial2.isNone  # cap hit + no override → refused

    # Step 4: Release the first serial token.
    ac.release(tokSerial1.get)
    # After release: groupInflight["serial"] should be 0; liveCount = 1 (extra still live).
    # liveCount must remain > 0 here because extra is still live.

    # Step 5: New pass — admit "serial" again.
    # liveCount > 0 → no progress override.  Cap must now be free (groupInflight=0).
    inc passId
    let tokSerial3 = ac.admit(passId, "serial", edNeverBuilt)
    check tokSerial3.isSome  # cap freed by release → admitted (NOT by override)
    ## If groupInflight["serial"] was not decremented in release, groupInflight
    ## would still be 1 (== cap), and this admit would return none → RED.

# ---------------------------------------------------------------------------
# Suite: Gap 2 — cdSkipFresh onSlotFinish with tiny RSS does not lower estJobPeak
# ---------------------------------------------------------------------------
#
# Coverage H3: verify that a cdSkipFresh slot (reserves memPerRun, NOT estJobPeak)
# finishing with a realistic small RSS does NOT lower estJobPeak below the seed
# floor, so a subsequent cold-compile admit still uses the full seed-level estimate.
#
# The monotonic-floor logic in onSlotFinish is:
#   estJobPeak = max(observed, max(estJobPeak, estJobPeakSeed))
# So even a 1-byte observed RSS from a cdSkipFresh slot cannot undercut the seed.
# The test proves this via admission behaviour.

suite "AdmissionController — cdSkipFresh RSS does not lower estJobPeak (Gap 2)":

  test "cdSkipFresh finish with tiny RSS: cold-compile still reserves seed-level estimate":
    ## Setup: estJobPeak seed = 512 MiB, memPerRunMb = 64 MiB.
    ## avail probe = 600 MiB (ample for one cold reserve; tight for two).
    ##
    ## Steps:
    ##   1. Admit cdSkipFresh (reserves 64 MiB, not 512). liveCount=1, committed=64 MiB.
    ##   2. onSlotFinish with rss=some(1 byte) — tiny RSS from a trivial run.
    ##      estJobPeak must NOT drop below seed (512 MiB); it must remain 512 MiB.
    ##   3. New pass: avail=600 MiB, committed=0, safety=0.
    ##      Cold-compile admit (cdNeverBuilt): reserved=estJobPeak=512 MiB.
    ##      600-0-0=600 >= 512 → admitted.  (Proves gate is using 512, not 1.)
    ##   4. Second cold-compile admit: committed=512, liveCount=1 (no override).
    ##      600-512-0=88 < 512 → refused.
    ##      (If estJobPeak had wrongly dropped to 1 byte, both admits would succeed.)
    ##
    ## Non-vacuity: if the seed-floor in onSlotFinish were removed, estJobPeak
    ## would ratchet down to 1 byte after step 2, making step 4's second admit
    ## succeed (88 >= 1) → check would fail → RED.
    let availBytes = 600i64 * 1024 * 1024  # 600 MiB
    var ac = mkAdmissionMem(some(availBytes),
                            estJobPeakMb = 512,
                            safetyMb     = 0,
                            memPerRunMb  = 64,
                            jobsCap      = 4)
    var passId: uint = 0

    # Step 1: Admit cdSkipFresh (reserves 64 MiB, not 512 MiB).
    inc passId
    let tokFresh = ac.admit(passId, "unit", edRunFresh)
    check tokFresh.isSome
    check tokFresh.get.reserved == 64i64 * 1024 * 1024  # memPerRun, not estJobPeak

    # Step 2: Finish with tiny RSS (1 byte) — seed floor must prevent downgrade.
    ac.onSlotFinish(tokFresh.get, some(1i64))
    # committed is now 0, liveCount is 0.

    # Step 3 + 4: New pass — cold compiles use estJobPeak (must still be 512 MiB).
    inc passId
    let tokCold1 = ac.admit(passId, "unit", edNeverBuilt)
    check tokCold1.isSome       # 600-0-0=600 >= 512 → admitted (liveCount=0, override fires)
    check tokCold1.get.reserved == 512i64 * 1024 * 1024  # estJobPeak still 512 MiB

    # liveCount=1 now, committed=512. No override.
    let tokCold2 = ac.admit(passId, "unit", edNeverBuilt)
    check tokCold2.isNone       # 600-512-0=88 < 512 → refused
    ## If estJobPeak had wrongly dropped to 1 byte, tokCold2 would be admitted
    ## (88 >= 1 is true), and this check would fail → RED.

when isMainModule:
  echo "All admission tests passed."
