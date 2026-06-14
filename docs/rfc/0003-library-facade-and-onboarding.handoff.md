# RFC-0003 — Library facade + onboarding (docs) + CLI papercuts — handoff

- **Stage:** 4 code-review **— COMPLETE. ALL findings closed** (0 Critical; 4 High + 11 Med + 6 security + 5 Low + 1 design-Low fixed; L4 obsolete; La design-Low wontfix w/ rationale). `./dev test` green. NOTHING committed — commit only when Corey asks. RFC-0003 through all 4 rfc-flow stages.
  - Round 1: fixed H1–H4, M1–M9, P1–P4. Round 2 re-review caught: M6 OVER-CLAIMED (not applied), M10 dead param, M11 placeholder guard, P5/P6 residuals. Round 3: re-did M6 (control-loop-verified on disk), M10, M11, L6, P5, P6. Round-3 re-review = the floor.
  - **Remaining Lows (deferred, cosmetic):** L1 undocumented bare `version` subcommand; L2 InitTemplate placeholder URL `github.com/your-org/crisol`; L3 redundant allWarnings binding (api.nim); L4 three identical zero-runnable rsOk branches; L5 noopResult nil-fallback leans on private runner symbol. Plus 2 design Lows: ZeroRunnableReason CLI-centric names; planToJsonString/renderPlan two-place facade maintenance.
  - **Next:** Corey decides — (a) commit (then verify `git log -1` has no Co-Authored-By, per hooks memory), (b) mop up Lows, or (c) cross-repo: bump amoxtli milpa.kdl crisol pin.
- **Progress:** 9/15 slices done — S1a–S1e (planTests, `tests/unit/test_api.nim`) + S2a–S2d (runTests, `tests/unit/test_run_tests.nim`). **Entire F1 facade built + boundary-tested.** `releaseLock` now `var LockHandle` + idempotent. Helpers in `tests/support/helpers.nim` (`withTempProject`/`withTempGitProject`/`seedLastRun`). **ALL DONE (15/15).** S3a/S3b: runMain thin shell over facade (132 lines dup orchestration deleted; planToJsonString Config-removal via precomputed PlannedEntrypoint fields; tests/integration/test_zero_runnable.nim). S4: help→stdout, clean+(-j/-t) in usage, --base-without---changed→exit 3 (test_changed.nim test REVERSED), clean --config, CHANGELOG.md (breaking-change note). S5: --version/-V/version → "crisol 0.1.0" via staticRead("../crisol.nimble"). S6: crisol init [path] [--force] writing InitTemplate. S7: README rewrite + RunV1Schema/PlanV1Schema consts (jsonout/planview, re-exported via api) + 2 drift guards (tests/unit/test_s7_guards.nim: InitTemplate zero-warning parse, schema-pin via consts). New test files: test_api, test_run_tests, test_zero_runnable, test_cli_s4/s5/s6, test_s7_guards. `./dev test` green at 15/15.
- **Resume:** `/loop implement the next unimplemented RFC slice with /tdd, following the standing rules; after each slice report one progress line; stop when every slice is implemented` — then `/code-review`.
- **Scope note (recorded clear-best call):** S1a re-exports `planToJsonString` with its CURRENT `Config` param; the Config-param-removal + `PlannedEntrypoint` runTimeoutMs/maxJobs precompute is DEFERRED to S3a-prep where the thin shell actually needs it (not testable in isolation at S1a).
## Review ledger (stage 4, round 1)
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
| H1 | High | Facade blanket-re-exports whole internal modules → leaked Config/Gate/Group/RunPlan/persist/load/ANSI consts. (design C1+H3+H4+L1, quality L6) | fixed | api.nim:60-92 → 17 explicit `export module.Symbol`; new tests/unit/test_api_boundary.nim guards it |
| H2 | High | Render helpers took internal `RunPlan`; CLI reconstructed it. (design C2+H2) | fixed | api.nim PlanReport-typed planToJsonString/renderPlan overloads; CLI RunPlan reconstruction deleted; RunPlan now fully internal |
| H3 | High | README:160 `--base` doc contradicted shipped exit-3. (quality H1) | fixed | README:160 rewritten |
| H4 | High | InitTemplate (crisol.nim) + README:80 `max-output-bytes 1048576` vs real 10485760. (quality H2) | fixed | crisol.nim:97 + README:80 → 10485760; test_s7_guards green |
| M1 | Med | `RunReport` didn't describe zero-runnable outcome; CLI re-derived from `narrowing.kind`. (design H1+M2) | fixed | ZeroRunnableReason enum + field; CLI switches on rr.zeroRunnableReason |
| M2 | Med | Zero-runnable all-gated bypassed `gateSkipMessages`. (quality L5, design M2) | fixed | crisol.nim:613-616 → gateSkipMessages(rr.plan.gatedOut) |
| M3 | Med | `structuralResult` returned empty `plan`. (quality M1, correctness Low) | fixed | structuralResultWithPlan template; lock/execute paths pass plan:pr |
| M4 | Med | README:205 `mem-aware` default `#false` vs auto. (quality M4) | fixed | README:205 → `auto` + probe note |
| M5 | Med | Unused imports in api.nim. (correctness Med, quality L2) | fixed | removed std/options + crisol/depgraph |
| M6 | Med | `crisol init` TOCTOU/symlink write-through. (security 1) | fixed | round-3: posix.open O_NOFOLLOW\|O_EXCL/O_TRUNC + short-write loop + close-all-paths; symlink-refusal test test_cli_s6.nim:118. CONTROL-LOOP VERIFIED on disk. |
| M7 | Med | `useFailed`/`useChanged` recomputed in runTests. (quality M2) | fixed | surfaced from PlanImplResult |
| M8 | Med | `parseNimbleVersion` prefix-greedy. (quality M5) | fixed | crisol.nim:67 delimiter check added |
| M9 | Med | api.nim module-doc re-export list drift. (quality M3) | fixed | doc list matches selective exports |
| L1 | Low | Undocumented bare `version` subcommand. | fixed | documented in usage() + README |
| L2 | Low | InitTemplate placeholder URL written to users' files. | fixed | → real repo URL github.com/coreyleavitt/crisol |
| L3 | Low | Redundant `allWarnings = cfgWarnings` binding. | fixed | removed; cfgWarnings passed directly |
| L4 | Low | Zero-runnable rsOk three "identical" branches → collapse. | obsolete | M1 made each set a distinct zeroRunnableReason — NOT collapsible |
| L5 | Low | `noopResult` nil-fallback depends on private runner symbol. | fixed | inline `(proc(r: EntrypointResult) {.closure.} = discard)` |
| Lb | Low | DESIGN: two-place RunPlan reconstruction in facade overloads. | fixed | extracted private `toRunPlan(report)` helper |
| La | Low | DESIGN: ZeroRunnableReason CLI-centric enum names. | wontfix | names describe the CAUSE (more informative than a generic name) — declined by control loop |
| P1 | Med | PRE-EXISTING (folded in): `state-dir` path traversal/absolute redirect. (security 2) | fixed | config.nim validateStateDir rejects absolute/`..`; 5 tests in test_config.nim |
| P2 | Low | PRE-EXISTING (folded in): `--base <ref>` git flag-injection. (security 3) | fixed | gitdiff.nim rejects ref starting `-`; 3 tests in test_soundness_m14 |
| P3 | Low | PRE-EXISTING (folded in): `persistLastRun` temp symlink write. (security 5) | fixed | jsonout.nim O_CREAT\|O_EXCL\|O_WRONLY\|O_CLOEXEC; symlink-not-followed test |
| P4 | Low | PRE-EXISTING (folded in): config `kvBigInt` misleading error. (security 4) | fixed | requireIntArg fixed (round 1); parseGroup completed in P6 |
| M10 | Med | NEW (round-2): `planToJsonString(report; warnings)` facade overload ignored the `warnings` param. | fixed | round-3: dead param removed (api.nim:231); verified |
| M11 | Med | NEW (round-2): test_api_boundary.nim negative tests were `check true` placeholders. | fixed | round-3: real `not compiles(Config/RunPlan)` guards; verified |
| L6 | Low | NEW (round-2): stale `[S2 — not yet implemented]` note in api.nim module doc. | fixed | round-3: removed |
| P5 | Low | NEW (round-2): depgraph.nim temp write symlink write-through (sibling of P3). | fixed | round-3: O_EXCL safe write mirroring jsonout; symlink test in test_depgraph; verified |
| P6 | Low | NEW (round-2): parseGroup int fields bypass requireIntArg. | fixed | round-3: both route through requireIntArg; 2 tests in test_config; verified |

## Round-1 forks for Corey (in presentation)
- Fix mandate? Default per skill = fix through Medium, leave Low.
- H1 scope: full selective re-export (cleanest, but moves GroupSelection/RunNarrowing out of types.nim into the facade) vs. minimal trim (just drop `export jsonout` blanket + render internals). Lean: full.
- Pre-existing security P1–P4: fold into this round, or separate issue/RFC? Lean: P1 (state-dir traversal) worth folding now; P2–P4 separate.

## Awaiting Corey's veto window (carried from stage 2) on 3 round-2 judgment calls (non-blocking — RFC is /tdd-ready as written): (1) narrowing constructors folding onlyFailed/onlyChanged/baseRef into a `narrowing` field [APPLIED]; (2) FORCE_COLOR added as F3 papercut #7 [APPLIED]; (3) DECLINED (kept flat): decompose RunOptions into sub-objects, case-object `error` field, opaque `Selection` type — reversible if he wants stricter typing.

## Round-2 changes applied (24 edits)
- **Correctness:** releaseLock → `var`+`fd=-1` + no defer-plus-explicit double-release (4/4 lens convergence); planToJsonString was BROKEN post-dogfood (needed cfg.groups) → precompute runTimeoutMs/maxJobs onto PlannedEntrypoint so it drops the Config param; computeColorEnabled doesn't exist as a lib proc → dropped from re-exports; ResultCallback moved runner.nim→types.nim; filterRecordsByTag added to re-exports; gateSkipMessages → takes seq[GatedEntry], dedups internally.
- **Version:** committed to staticRead("../crisol.nimble") (dropped gorge) + compile-time assert; S5 asserts exact version string.
- **Slices:** S4 must rewrite existing test_changed.nim "--base without --changed" test (exit 0→3) + create CHANGELOG.md + clean --config gap; S3 reframed as substitution+deletion NOT re-implementation (kills double-build seam); added fixture-helper scaffolding (withTempProject/seedLastRun) + 3 zero-runnable regression tests as S3 anchor.
- **Design:** inline RunPlan into PlanReport (kills rr.plan.plan stutter); narrowing constructors (noNarrowing/failedOnly/changedOnly/failedOrChanged).
- **Doc/contract:** exit-table footnote (oSignal vs SIGINT-to-crisol) + oSpawnError; rsInterrupted leaves results empty/summary zeroed; jobs<=0 CLI-vs-lib note; ResolvedSettings.stateDir pre-joined absolute; F2 enumeration gaps (--fail-fast + 5 config keys + FORCE_COLOR/NO_COLOR); schema-version consts RunV1Schema/PlanV1Schema; execute() internal-catch layering documented; --failed zero-runnable collapse documented.

## Scope (Corey picked candidates #1, #2, #3 from the new-user-perspective architect exploration)
- **#1 (architectural core) — library facade.** No single entry point today: consumers hand-wire `loadConfig → buildRunPlan → execute → summarize → render` + DepGraph/lock/signals/narrowing, learning ~15 types. Only full orchestration is CLI-private `runMain` in `src/crisol.nim`.
  - **Proposed design (to be stress-tested in architect rounds):** two deep entry points —
    - `planTests(opts): PlanReport` — discover→gates→plan, no execution (powers `list`/`--dry-run` + consumers wanting just the plan).
    - `runTests(opts): RunReport` — full run: loadConfig + buildRunPlan(+narrowing) + lock + signals + execute + summarize + persistLastRun + exitCode mapping; loads/threads DepGraph internally.
  - `RunOptions` struct (config path, GroupSelection, failed/changed/baseRef, forceCompile, failFast, jobs, timeoutSecs, onResult, showProgress). `RunReport` returns summary + results + plan + gatedOut + warnings + memThrottledSlots + mapped exitCode. Facade returns DATA; CLI maps exit codes + renders.
  - **Dogfood:** refactor CLI `runMain` to a thin shell over the facade (arg-parse + render + quit) — proves the facade and deletes duplicated orchestration.
- **#2 — onboarding/docs.** README says "Pre-v1… No implementation yet." (false — shipped). Add quickstart, install-via-milpa, example `crisol.kdl`, CLI reference (incl. `clean`, `--version`), exit-code table, structured-protocol pointer; document the memory keys + opt-in/gate/group distinction. Idea: `crisol init` emits the canonical example config that the README references → single source of truth.
- **#3 — CLI papercuts.** `crisol clean` missing from `usage()`; help prints to stderr (should go stdout when explicitly requested); `--base` silently ignored w/o `--changed` (lean: make it an error — flag for architect/Corey); undocumented `-j`/`-t` short forms; **no `crisol --version`**; add `crisol init`.

## Final slices (per RFC §Slices; architect rounds may re-cut)
- [ ] **S1 (F1)** — `crisol/api.nim`: `RunOptions`/`PlanReport` + `planTests()` (loadConfig + jobs/timeout override + --failed/--changed input assembly + buildRunPlan); boundary-tested.
- [ ] **S2 (F1)** — `RunReport` + `runTests()` + `exitCodeFor()` (planTests + execute + summarize + persist + exitCode map; lock/signals behind manageLock/installSignals; CrisolError raised for structural failures); boundary-tested vs fixture suites.
- [ ] **S3 (F1)** — dogfood: rebuild CLI `runMain` on the facade; delete duplicated orchestration; map CrisolError/CrisolInterrupted → exit 2/3. Contract: existing CLI integration tests stay green.
- [ ] **S4 (F3)** — `--help`/`-h`→stdout/exit 0; `clean` in usage(); `-j`/`-t` documented; `--base` w/o `--changed` → error (exit 3).
- [ ] **S5 (F3)** — `crisol --version`/`-V` via `NimblePkgVersion` strdefine ("dev" fallback).
- [ ] **S6 (F3)** — `crisol init [path] [--force]`: writes canonical starter `crisol.kdl`; refuses overwrite w/o --force.
- [ ] **S7 (F2)** — README rewrite (status/install/quickstart/CLI ref/exit codes/config ref incl memory keys + selection model/library example/protocol pointer); testable core = canonical example config parses w/ zero warnings (single source of truth = S6 init output).

## Open forks (awaiting Corey / architect rounds)
- `--base` without `--changed`: error vs keep-warn (lean: error — clearer; small behavior change).
- Does `runTests` acquire the advisory lock + install signal handlers by default? (lean: yes, with opt-out flags — safe defaults matching CLI).
- Docs slices aren't TDD-able as prose; plan is verify-by-review + fold testable bits into `init`/`--version`.

## Key decisions (this session)
- Corey took #1+#2+#3 through full rfc-flow (this RFC). #4 (config conceptual model) and #5 (structured-protocol onboarding) NOT in scope (partially absorbed by #2's docs).

## Context / prior state
- RFC-0002 COMPLETE: committed `5c4de13`, pushed origin/main. Its handoff doc is content-current (stage 4 done). Deferred from 0002: DispatchCursor extraction (design Medium, wontfix-now) + Low backlog — see 0002 ledger.
- Cross-repo follow-up (not now): bump amoxtli `milpa.kdl` crisol pin `71e8719`→`5c4de13`.

## Blocker detail (2026-06-13)
`/tmp` filesystem full → Bash tool fails at output-file creation (ENOSPC) before any command runs. Asked Corey to free space (agent transcripts under `/tmp/claude-1000/.../tasks/`, nim/podman caches). Write tool still works (targets repo/home). Resume drafting once `df -h /tmp` shows headroom.
