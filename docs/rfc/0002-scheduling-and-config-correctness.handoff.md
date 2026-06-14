# RFC-0002 — Scheduling & config correctness — handoff

- **Stage:** 4 `/code-review` — **COMPLETE. RFC-0002 DONE: committed `5c4de13` + pushed to origin/main (2026-06-13).** Full rfc-flow finished (RFC → 2 architect rounds → 9-slice TDD grind → code-review w/ 3 fix rounds). Whole suite green; history clean (Claude trailer stripped by hook; no stray binary; no hooksPath leak).
- **RFC:** `docs/rfc/0002-scheduling-and-config-correctness.md` (699 lines; round-1 + round-2 changelogs at end).
- **Resume:** nothing pending in crisol. Optional backlog: R2-2 DispatchCursor (deferred design Medium — Corey to accept/override), Low items (R2-5/6/7, L1/L3/L4/L6), H5 stronger compile-budget test. Cross-repo (post-RFC, NOT now): bump amoxtli `milpa.kdl` crisol pin `71e8719`→`5c4de13` & reconcile; unpause amoxtli RFC-0015 WS-C + RFC-0014.
- **Deferred follow-ups (flag at code-review, not blockers):** (1) the >~5s "memory-throttled" progress-line signal (RFC line 98) — schema field `memThrottledSlots` IS wired, but the live progress-line glyph was not implemented (noted by S6b agent). (2) S7's composition is proven across 3 test procs rather than one monolithic execute call (overlap fixture reads a single `CRISOL_TEST_OVERLAP_FILE`); the no-deadlock fail-fast+B+C proof IS one composed run, but A (per-group timeout) is exercised in a separate composed run — A and the memory gate are not asserted simultaneously.
- **Slices now (post round 2):** S1 (D warnings) · S2a (A pure: timeout resolution + schema fields) · S2b (A wiring: per-group deadline) · S3 (C max-jobs + overlap fixture) · S4 (B memprobe) · S5 (B admission logic) · S6a (B config parse) · S6b (B wiring; optional S6c split for adaptive estJobPeak) · S7 (composition). S2b and S6b share the `execute` fill/poll region — S2b first.

## Stage-3 grind progress (started 2026-06-13, uncommitted — all in working tree)
- [x] **S1** (D) — `ConfigWarning` in types.nim; `loadConfig → (Config, seq[ConfigWarning])`; `"warnings"` array in plan/v1 + run/v1; `RunPlanView.warnings`. Suite 332.
- [x] **S2a** (A pure) — `Entrypoint.runTimeoutSecs`; `discover` populates from `group.timeoutSecs`; new `src/crisol/scheduler.nim` with `effectiveRunTimeoutMs(ep,config): int` (ms; group>0 → global>0 → 300_000 builtin). plan/v1 emits `runTimeoutMs`; run/v1 emits per-ep `compileSkipped` + top-level `memThrottledSlots` (const 0, `# S6b` marker). maxJobs plan field DEFERRED to S3 (`# S3` marker). Suite 347.
- [x] **S2b** (A wiring) — `Slot.runTimeoutMs`; `pollSlot` lost its global `runTimeoutMs` param, sets `slot.deadline = now + slot.runTimeoutMs` at spCompiling→spRunning. `spawnRunDirect` lost its param too. New `tests/integration/test_per_group_timeout.nim` (run directly). Suite 350. **Feature A COMPLETE.**
- [x] **S3** (C) — `Group.maxJobs: Option[int]`; `max-jobs` parse (≤0 = cfgErr); new `admission.nim` (`SlotToken`+`AdmissionController`, group-cap-only `admit`/`release`/`onSlotFinish`); wired into `execute` (token on `Slot`, admit-before-spawn, release-on-fail, onSlotFinish pre-clear capture); overlap fixture `tests/fixtures/overlap_probe.nim` (line fmt `{pid}\tstart|end\t{monotonic_ns}`, 150ms sleep, atomic O_APPEND); maxJobs in plan/v1. **Feature C COMPLETE.**
- [x] **S4** (B) — `src/crisol/memprobe.nim`: `availableMemBytes(read)` (min of /proc/meminfo MemAvailable + cgroup v2 then v1 limit−current; `max`/sentinel = unlimited) and `procGroupRssBytes(pid,read)` (sums VmRSS over pgid). Injectable `read` seam (raises IOError = absent); cgroup smoke reads real memory.max. Never raise → none. Suite 383.
- [x] **S5** (B) — pure memory predicate in `admit`: `(group-not-at-cap) ∧ (liveCount<jobsCap) ∧ (memAdmits ∨ progressOverride)`, memAdmits = `avail.isNone ∨ avail-committed-safety≥reserved`, override = `liveCount==0`. `refreshAvail` snapshots probe; `release`/`onSlotFinish` subtract `token.reserved`; `onSlotFinish` ratchets `estJobPeak=max(rss,peak)` floored at seed. Seeds via `initAdmission` params (512/0/64 MiB) — Config stays pristine until S6a. Non-vacuity test RED-first. Suite 397.
- [x] **S6a** (B) — four `mem-*` Config fields (`memAware: Option[bool]` to distinguish unset/auto from explicit on/off); top-level KDL parse; `initAdmission` sources seeds from Config (test-injection params preserved); recognized keys → no warnings. Suite 417.
- [x] **S6b** (B) — probe injected w/ `mem-aware` resolution truth table (some(false)→off; some(true)/none+probe→on; none+no-probe→budget-only); real `procGroupRssBytes` → `onSlotFinish` (adaptive estJobPeak live); `memBudgetMb` clamp in `refreshAvail`; `memThrottledSlots` counter → run/v1. Serialization test RED-first vs inert probe; kill-switch test passes. One cycle — **no S6c**. **Feature B COMPLETE.**
- [x] **S7** (composition) — `tests/integration/test_composition_s7.nim`, 3 procs: C+B serialization, fail-fast clean drain (no deadlock, primary proof), A per-group timeout in composed run. No composition bug found (tokens released correctly on fail-fast drain). **ALL FEATURES A+B+C+D COMPLETE.**
- **NOT committed.** All in working tree. Will commit when Corey asks.

## Architect round 2 (applied 2026-06-13)
4 lenses again (depth/breadth/design/feasibility), hunting residual weakness after round 1. **No genuine forks.** Headline changes folded into the RFC:
- **Admission interface redesigned** (supersedes round-1's 3-call protocol): probe **injected at construction** + snapshotted per fill pass (`refreshAvail`); `admit → Option[SlotToken]`; `release(token)` rolls back on spawn failure; `onSlotFinish(token, rss)`. `SlotToken` carries per-slot `reserved` bytes → fixes missing reservation-release accounting (D1), types the spawn-failure rollback (De1), prevents double-finish, and removes `onSlotStart`. Probe moved to controller's side of the boundary (De2).
- **`committed` double-count documented as intentional** (probe already reflects live RSS; reservation is a forward pre-ramp guard) — so an implementer doesn't "fix" it and break the burst guard (D2).
- **Progress-override starvation window** stated + accepted (global, bounded, not deadlock) (D6). **`estJobPeak` monotonic-ratchet limitation** documented + per-group-isolation workaround + seed floor + mixed-batch `max` safety (D5/B2).
- **Feature A** run deadline explicitly anchored at run-start (D3); depgraph/clean unaffected note (B10). **`max-jobs 0`** = config error (B7).
- **`ConfigWarning`** tuple → named object isomorphic to wire schema (message composed once) (De5); `loadConfig` ~5-call-site migration called out (D4/B6); warnings threaded via `RunPlanView.warnings` (B5).
- **Observability completed**: plan-field placement specified; `compileSkipped` assigned to S2a; `memThrottledSlots` added to `run/v1`; golden-test impact flagged (B3/B5).
- **Ergonomics**: `mem-per-job-mb`/`mem-per-run-mb` marked advanced seeds (De3); Group encoding rationale → `types.nim` inline docs (De4). CLI flags for memory keys + user docs → **Non-Goals** (B1/B9).
- **Slices re-cut**: S2→S2a/S2b; overlap fixture hardened (150ms sleep + atomic single-`write` append) (D9/F3/F4); S4 cgroup smoke proves the cgroup branch ran (F6); S5 non-vacuity case for the memory gate (F5); S6b arithmetic pinned + optional S6c split (F5/F8); testing-strategy bootstrap coverage map (F9).

### Round-2 judgment calls (not forks — flagged for veto)
- **Revised round-1's own `AdmissionController` interface** (token-based, probe injected). Bigger than a tweak — reopens a round-1 decision — but dissolves 3 High findings (D1+De1+De2) and is strictly cleaner. If you'd rather freeze the round-1 interface and absorb D1's reservation-accounting fix more minimally (e.g. just add `Slot.reservedMem`), say so before the grind.
- **CLI flags for `mem-budget-mb`/`mem-aware` deferred to Non-Goal** (config-file + `--config` covers CI). Reversible later; flagged because CI is the motivating use.
- **`estJobPeak` ratchet kept global+monotonic for v1** (documented limitation + workaround), not made per-group now — even though the mixed light/heavy batch is exactly amoxtli's shape. Per-group is a future internal change (no interface break).

## Architect round 1 (applied 2026-06-13)
4 lenses (depth, breadth, design, feasibility). Headline changes folded into the RFC:
- **Feature B restructured**: `memprobe.nim` (cgroup-aware budget — `min(/proc/meminfo MemAvailable, cgroup memory.max−current)`; reading MemAvailable alone OOMs in CI containers) + `admission.nim` `AdmissionController` object (owns estJobPeak/committedHeadroom/groupInflight behind admit/onSlotStart/onSlotFinish) + thin runner wiring. Killed the 6-scalar `admitAnother` + scattered-state-in-`execute`.
- **`liveCount==0` override bypasses ONLY the memory gate, never the group cap** (would've broken `max-jobs 1`). `committedHeadroom` reservation is load-bearing (per-admit, synchronous) — closes open-Q3.
- **Feature A**: per-entrypoint timeout threads through new `Slot.runTimeoutMs` into `pollSlot` (compile→run transition) — RFC prose previously missed this path.
- **Feature C**: `maxJobs` OFF `Entrypoint` (it's group policy → `AdmissionController.groupCap` from `Config.groups`); `Group.maxJobs: Option[int]` (not 0-sentinel). cdSkipFresh slots use small `mem-per-run-mb` est, not estJobPeak.
- **Feature D**: `gate` is a leaf (no sub-block) — wording fixed; `loadConfig → (Config, seq[ConfigWarning])`; warnings added to `crisol/plan/v1` + `run/v1` JSON.
- **Observability** section added; **Goal 5 reworded** (additive at key-level; mem-aware default-on where probe works — closes Q4); `--jobs 1` ⇒ B inert noted.
- **Slices re-cut**: S6 → S6a (config parse) + S6b (wiring); new **S7** A+B+C+fail-fast composition test; probe needs injectable `read` seam; new `CRISOL_TEST_OVERLAP_FILE` timestamp fixture for concurrency observation; 512 MiB default estJobPeak seed.
- **All 4 open questions resolved** (Q1 cross-group=workaround/not-v1; Q2 estJobPeak=global; Q3 committedHeadroom=required; Q4 mem-aware=default-on-when-probe).

### Judgment calls made (not forks — flagged for veto)
- `Group.maxJobs: Option[int]` deliberately diverges from the legacy `0=inherit` sentinel (timeoutSecs). Rationale: 0 is a meaningful "uncapped" value; Option makes absent explicit.
- mem-aware default-on-when-probe-works changes existing-consumer (amoxtli) scheduling on upgrade — strictly safer (prevents OOM), degrades to identical where probe absent. Touched the "additive" Goal 5 (was author's open-Q4 lean).
- Feature B scope grew (cgroup support, AdmissionController + memprobe modules, S6 split, +S7) — bigger than the original draft, but all clear-best.

## Earlier handoff (stage 1) below
- **Origin:** spun out of amoxtli RFC-0015 WS-C — three of WS-C's steps were workarounds for crisol gaps (manual RSS-freeze, hermeticity-only isolation, dead per-group timeout). Corey: fix them upstream in crisol instead of working around. amoxtli RFC-0015 Track 2 (WS-C…) is PAUSED pending this; amoxtli RFC-0014 also PAUSED at 7/15 (B3).

## The four features (verified against crisol source)
- **A** per-group run timeout — `Group.timeoutSecs` parsed (`config.nim:164`) but never applied; executor uses global only (`runner.nim:528-534`). Thread via new `Entrypoint.runTimeoutSecs`, populated in `discover` (`discover.nim:204`), used at the run-deadline/`spawnRun` sites.
- **B** memory-aware admission — fixed pool, `jobs=max(1,cpu-2)` (`planner.nim:173`), no RSS awareness (`runner.nim:633`). Three modules: probe (`/proc/meminfo` MemAvailable + per-pgroup RSS, both `Option`, Linux-only), pure `admitAnother(...)` decision, fill-loop wiring + config keys (`mem-budget-mb`/`mem-per-job-mb`/`mem-aware`). Progress guarantee: `liveCount==0` always admits. Inert when probe = `none`.
- **C** per-group `max-jobs` — no concurrency annotation today; `Group`/`Entrypoint` carry none; flat slot array. Add `maxJobs` to both + parse + per-group in-flight gate in fill loop. `max-jobs 1` = serial group. Escape hatch, NOT a replacement for amoxtli WS-C hermeticity.
- **D** unknown-key warnings — `else: discard` silently drops typos (`config.nim:243` top, `:186` group). Accumulate + warn (never fail; forward-compat).

## Slices (6) — dependency order
- [ ] S1 (D) unknown-key warnings — smallest, independent
- [ ] S2 (A) per-group run timeout — `effectiveRunTimeoutMs` pure helper + executor wire
- [ ] S3 (C) per-group `max-jobs` — establishes group-aware fill loop
- [ ] S4 (B) memory probe module — `availableMemBytes` + `procGroupRssBytes`, `Option`, never-raise
- [ ] S5 (B) pure `admitAnother` decision
- [ ] S6 (B) wire admission + config keys (composes with S3's group gate)

## Open forks (awaiting Corey) — to resolve in architect rounds
- These 4 are in the RFC's "Open questions" §, all with a lean (so likely architect-resolvable, not true forks): C cross-group exclusion (lean: max-jobs only); B estJobPeak global vs per-group (lean global); B reservation necessity at 25ms cadence (needs depth lens); B mem-aware default (lean on-when-available).

## Key decisions (this session)
- Fix in crisol, not amoxtli (Corey, 2026-06-13). All four as ONE crisol RFC through full rfc-flow.
- WS-C hermeticity still proceeds after this lands (fixed-temp-path are real bugs); `max-jobs` is only the fallback for `test_mcp_sse`.
- amoxtli-side: tempdirs.nim support module + fixtures.nim re-export were ALREADY written this session (uncommitted in amoxtli) before the pivot; the ~18-file conversion was NOT started (subagent dispatch was interrupted by the pivot).

## Cross-repo state
- crisol pin in amoxtli `milpa.kdl` = `71e8719` (NOT on crisol main `8ff9112`; pre-squash review commit). Reconcile to new HEAD when bumping post-RFC.
- crisol HEAD = `8ff9112` (RFC-0001 Stages A–D + review). Nothing committed for RFC-0002 yet.

## Review ledger (stage 4 — round 1, 2026-06-13; 5 agents + verification done; awaiting Corey's fix mandate)
Contested Critical resolved: Design called nextEp starvation "Critical permanent stall"; Correctness called it "Medium by-design per RFC line 695". Adjudicated by reading runner.nim:686-700 + RFC: it's **High** — results stay correct & capped group drains (no crash/deadlock), but fill loop never skips past a cap-blocked head so all later work serializes behind a capped group; "RFC line 695" cited by Correctness is the *code comment*, not the RFC, and the RFC's accepted starvation window is the memory progress-override, NOT cross-group head-of-line blocking. Undocumented throughput defect that defeats max-jobs's purpose.

| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
| H1 | High | runner.nim fill loop: single monotone `nextEp`; cap-blocked head stalls all idle slots → uncapped work serializes behind a capped group | **fixed** | skip-ahead scan (dispatched[]/lwm/highWaterMark); test_headofline.nim (RED 459ms→GREEN). PLUS fixed secondary regression: fail-fast truncation now emits dispatched-only (was result[0..<highWaterMark] → phantom empty entry); test_failfast_phantom.nim |
| H2 | High | stray checked-in ELF binary `src/crisol/runner`, not gitignored | **fixed** | deleted; .gitignore now ignores extensionless artifacts in src/crisol/, keeps *.nim tracked (verified) |
| M1 | Med | cgroupBudget negative budget when current>limit; no clamp | **fixed** | max(0,·) clamp v1+v2; tests for current>limit→some(0) |
| M2 | Med | cgroupBudget dead code: maxOpt double-read, v2FilePresent unused, `if not false` hack | **fixed** | removed; single read per branch; behavior preserved |
| M3 | Med | persistLastRun omits warnings + memThrottledSlots → lastrun.json inconsistent w/ stdout | **fixed** | threaded both into persistLastRun; 3 round-trip tests (RED first) |
| M4 | Med | memory-throttled >5s progress-line glyph (RFC line 98) not implemented | **fixed** | MemThrottleSignalMs const + pure memThrottleActive() + formatProgressLine(memThrottled); throttledSince tracking in execute; render tests (no 5s sleep) |
| M5 | Med | AdmissionController shallow — refreshAvail footgun + kill-switch logic in execute | **fixed** | (a) admit(passId,…) refreshes snapshot internally, refreshAvail now private, epoch-contract test; (b) mem-aware 4-case truth table moved into initAdmission |
| M6 | Med | mem-* Config fields int 0-sentinel vs Option convention | **fixed** | memBudgetMb/memPerJobMb/memPerRunMb → Option[int]; .get(default) seed resolution |
| M7 | Med | ConfigWarning threaded through ~6 pass-through sites | **wontfix (assessed minimal)** | RFC deliberately keeps warnings off Config; downstream already reads single carrier pv.warnings; only pre-pv stderr site needs the local — no redundant dual-passing exists |
| M8 | Med | procGroupRssBytes /proc/__list__ magic path overloads read seam | **fixed** | explicit listProcs seam; magic path removed |
| M9 | Med | test gaps | **fixed (H5 partial)** | release-decrement non-vacuous test; cdSkipFresh-onSlotFinish floor test; memThrottledSlots e2e (test_mem_throttle); mem-aware 4-case (in M5b); cgroup fallback branches (in M1/M8). H5 compile-vs-run-budget: focused test added (test_compile_not_run_budget) but only fully decisive w/ a >2s compile — run-deadline path also covered by test_per_group_timeout |
| L2 | Low | negative mem-* silently→0 | **fixed** | now a config error (cfgErr), tested — done alongside M6 |
| L5 | Low | cleanup: dup M12 comment, stale "(no-op)" comment, _debug_memprobe scratch, test_mem_throttle stale `# RED:` | **fixed** | deleted scratch, dedup'd M12 comment, updated stale snapshot comment, removed stale # RED |
| L1 | Low | memThrottledSlots inflated ×idle-slots/pass — metric only | open (Low, skipped per mandate) | skip-ahead reduces inflation naturally; left as Low backlog |
| L3 | Low | BuiltinRunTimeoutMs not derived from DefaultTimeoutSecs*1000 | open (Low, skipped) | |
| L4 | Low | SlotToken.group exported on opaque token | open (Low, skipped) | |
| L6 | Low | test_max_jobs_overlap overlap-assertion timing-dependent | open (Low, skipped) | |
| R1 | refuted | "onSlotFinish with 0-RSS from dead pid collapses estJobPeak" | refuted | seed floor `max(rss,max(peak,seed))` protects it (C5, verified) |
| R2 | refuted | "liveCount==0 override bypasses group cap" | refuted | override is inside mem-gate block; cap/jobsCap return early (verified) |
| R3 | refuted | "token leak on spawnRun-fail path" | refuted | onSlotFinish runs on every pollSlot→true incl. spawn-fail (C5/verified) |

### Round 2 re-review (after fixes; security clean, correctness sound, design confirmed improvements)
Correctness verified the new scheduler sound on ALL critical properties: no double-dispatch, no lost entry, termination, exactly-one-snapshot-per-pass, token release every path, liveness. Security: no new exploitable issues (Option arithmetic can't overflow at real scale, nil-probe guarded in refreshAvailImpl, warning content JSON-escaped via newJString, reap ordering unchanged). New findings:
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
| R2-1 | Med | `mem-per-job-mb 0`/`mem-per-run-mb 0` → some(0) → 0-byte reservation silently makes mem gate inert (regression exposed by M6 Option change; pre-M6 int-0 fell to default) | **fixed (round 3)** | config now rejects `<=0` for per-job/per-run (cekConfig); `mem-budget-mb 0` still valid ("no cap"); 3 tests RED→GREEN |
| R2-2 | Med | design: `dispatched`/`lwm`/`highWaterMark` scattered as raw locals; should be a `DispatchCursor` object w/ nextAdmissible()/mark() | **deferred (wontfix-now)** | payoff is explicitly speculative ("as priority-groups/re-queuing are added" — none planned); loop is correct, tested (test_headofline/test_failfast_phantom/test_max_jobs_overlap/test_composition_s7/test_scheduler), well-commented; re-touching concurrency code a 5th time > readability gain. Revisit if those features land. |
| R2-3 | Low | `highWaterMark` dead after fail-fast rewrite to dispatched[] scan | **fixed (round 3)** | grep-confirmed no readers; removed; old `nextEp` also fully gone |
| R2-4 | Low | passId epoch boundary (uint wrap / init-0 reliance); "impossible to forget" overstated | **doc'd (round 3)** | both reviewers: fails-safe / "don't change now"; admit docstring now states the increment-before-pass contract; no signature change |
| R2-5 | Low | `memThrottledSlots` counts per-candidate-eval not unique slots (metric semantics) | open (Low) | same as L1; skip-ahead reduces inflation; backlog |
| R2-6 | Low | `initAdmission(probe=nil, memAware=some(true))` inert (test-author surprise; prod always passes non-nil probe) | open (Low) | backlog |
| R2-7 | Low | `initAdmission` auto-branch calls probe() as constructor side-effect (call-counting test seam surprise) | open (Low) | backlog |

**FLOOR REACHED:** 0 open Critical/High/Medium actionable defects. The one remaining Medium (R2-2 DispatchCursor) is a consciously-deferred design-opinion w/ speculative payoff (flagged for Corey to accept/override). Remaining opens are Low backlog (R2-5/6/7, L1/L3/L4/L6) + H5's partial test (test_compile_not_run_budget decisive only w/ >2s compile; run-deadline also covered by test_per_group_timeout). Whole suite green; working tree clean (stray ELF gitignored, scratch deleted); no commits (awaiting Corey). Hooks not leaked (no local core.hooksPath).
