# Handoff — RFC-0001 crisol test runner

## Stage
**4 — /code-review ✅ COMPLETE. Fix loop hit the floor: 0 Critical/High/Medium open. 4 review rounds + 3 fix waves. `./dev build` OK, `./dev test` EXIT=0, 0 FAILED, 89 suites. Remaining = deferred Lows only (see below). NOT committed (everything still untracked; commit when Corey asks). Stage F (amoxtli adoption + dogfood) is the next downstream step, separate from this RFC.**

Summary of what the review caught & fixed (all verified green at each wave):
- **2 Criticals** that the "Stage-3 green" claim had masked: signal handling was stranded in a worktree (recovered + wired), and the result protocol was never connected to the runner (wired via race-free `execvpe`/`forkExecEnv`, OR-rule now tested).
- **9 Highs**: CWD-relative `nim c` entrypoint path; `isEntryStale` ignoring projectRoot; deleted-dep dropped from closure; XOR closure-hash (→ chained); `@p` first-match (→ over-select); pipeline trapped in CLI (→ `pipeline.nim` + `planner.nim`); parent `setpgid`; EINTR→exit-1; wall-clock deadlines (→ MonoTime).
- **~17 Mediums**: protocol/runner seam, mkdtemp, sink cap, failure-path cleanup, gitdiff shell→startProcess, applyGates carries-path, gskFiles rename, handleInterrupt double-kill, cacheDir leak, dead-depparse trap (doc-neutralised — it's the @p soundness canary, can't delete), etc.
- **Refuted/out-of-scope**: cstring/ORC (non-moving GC), Windows separators (POSIX-only v1), cross-repo depRoot under-selection (Corey: out of scope — `--changed` is single-repo by design; RFC scope note added).

**Remaining deferred Lows (per mandate "leave Lows"):** L1 `Summary.noTestsRan` derived field; L2 error→exit mapping duplicated in CLI; L3 lock file 0o644; L4 `relPath` raw slice vs `relativePath`; L5 `CRISOL_SINK` opened without symlink constraint (client-side); L6 `projectRoot` reflected in stderr unsanitised; L7 `clean` saves graph when nothing dropped; L8 `nextVal` rejects flag values starting with `-`; + design Lows (`terminal.nim` shallow-but-justified, `RunPlanView.graph` handoff field). Several other Lows were fixed opportunistically in-wave (header-only-sink reconcile, `narrowByDiff` default removed, supervise+teardown EINTR via `reapBlocking`, ORC comment, GatedEntry doc).

New modules added this stage: `signals.nim` (recovered), `planner.nim`, `terminal.nim`, `pipeline.nim`. New tests: `test_signal`, `test_protocol_wire`, `test_soundness_{r4,r5,r6,r7,m9,m10,m14}`.

### (historical — round-1 ledger)
**4 — /code-review IN PROGRESS (round 1 complete; findings verified; awaiting Corey's fix mandate).**

⚠️ **STAGE-3 "COMPLETE/green" RECORD WAS INACCURATE** — round-1 review proved two slices never reached the working tree:
- **A6 (signals) is stranded in worktree `.claude/worktrees/agent-a71af2418a93bd07c/`** — `src/crisol/signals.nim` + `tests/integration/test_signal.nim` exist ONLY there, never copied into the working tree. Production tree has no signal handling at all.
- **B1/B2→A4 protocol integration was never implemented anywhere** — `runner.nim` never sets `CRISOL_SINK`, never calls `readSink`/`reconcile`; `EntrypointResult.records` is always empty. The codec/emitter unit tests pass in isolation, masking the missing seam.
- The "319 [OK] / green" suite never exercised signals or the protocol end-to-end because those integration tests aren't in the working tree being tested. Git state: only 1 commit (A2a test); all of `src/` + integration tests are UNTRACKED.

### Round-1 review ledger
| id | sev | finding | file | status | proof / reason |
|----|-----|---------|------|--------|----------------|
| R1 | CRIT | Result protocol not wired — records always empty; OR-rule never applied; --filter-tag inert | runner.nim | open | grep: no CRISOL_SINK/readSink/reconcile in runner |
| R2 | CRIT | Signal handling absent from working tree — Ctrl+C orphans all children | (missing) signals.nim | open | no signals.nim in src/; only in worktree |
| R3 | HIGH | `nim c` gets raw relative ep.path, no chdir → compile fails when CWD≠projectRoot | runner.nim:231,473 | open | confirmed read |
| R4 | HIGH | isEntryStale ignores projectRoot → fileExists vs CWD; --changed never prunes off-root | depgraph.nim:181 | open | confirmed read (comment admits it) |
| R5 | HIGH | extractClosure fileExists-guard drops deleted dep → deletion missed in git diff (under-select) | closure.nim:191 | open | impact reviewer + read |
| R6 | HIGH | XOR closureHash not collision-resistant → stale binary reuse (cdSkipFresh) | depgraph.nim:143 | open | confirmed read |
| R7 | HIGH | @p first-match-wins across tracked roots → depRoot file mis-attributed → change missed | closure.nim:114 | open | impact reviewer |
| R8 | HIGH | Pipeline (buildPlanView) trapped in CLI, unexported → lib consumers can't drive crisol | crisol.nim:155 | open | design reviewer |
| R9 | HIGH | parent never setpgid(child) → narrow killpg race | spawn.nim | open | confirmed read |
| R10 | HIGH | waitpid EINTR → "exit 1", no retry (acute once signals wired) | spawn.nim:121, runner.nim:617 | open | confirmed read |
| R11 | HIGH | wall-clock epochTime deadlines → NTP step causes spurious timeouts | spawn.nim, runner.nim | open | confirmed read |
| M1 | MED | execute signature overdetermined; timeout dup; mutable-graph threading | runner.nim:678 | open | design |
| M2 | MED | GatedEntry/SelectionResult/SelectionReason in leaf modules, not types.nim | planview.nim, narrow.nim | open | design |
| M3 | MED | shouldEnableColor reads NO_COLOR inside "pure" render module | render.nim:117 | open | design |
| M4 | MED | DiscoveredSet protection bypassed by raw casts in 3 sites | discover/crisol/clean | open | design |
| M5 | MED | applySelection mutates Config; "cli" group not available to lib | crisol.nim:126 | open | design |
| M6 | MED | runEntrypoint duplicates entire compile+run path vs execute | runner.nim:195 | open | design |
| M7 | MED | unbounded readFile on untrusted sink → OOM (once protocol wired) | protocol.nim:168 | open | security |
| M8 | MED | predictable temp paths (PID only) → symlink/TOCTOU | runner.nim:208,461 | open | security |
| M9 | MED | gitdiff execCmdEx uses shell; projectRoot unvalidated | gitdiff.nim:73 | open | security |
| M10 | MED | deserialized closure paths not re-validated under root before readFile | depgraph.nim:138 | open | security |
| M11 | MED | no SIGTERM→SIGKILL grace; test cleanup hooks can't run | spawn.nim:128, runner.nim:406 | open | concurrency |
| M12 | MED | no cleanup of live children if onResult/IO raises in execute | runner.nim | open | concurrency |
| M13 | MED | releaseLock by-value → double-close doc claim false; can close reused fd | lock.nim:77 | open | concurrency |
| M14 | MED | untracked (un-staged) new .nim files not in git diff → under-select | gitdiff.nim:73 | open | impact |
| M15 | MED | per-slot cacheDir/binDir leak on compile-failure / fork-failure paths | runner.nim:797 | open | correctness |
| M16 | MED | depparse.nim dead code w/ wrong @p comment → re-introduction risk | depparse.nim | open | 3 reviewers + grep |
| L1 | LOW | Summary.noTestsRan stored derived predicate | types.nim | open | design |
| L2 | LOW | error→exit-code mapping duplicated 5× in CLI | crisol.nim | open | design |
| L3 | LOW | lock file created 0o644 | lock.nim:52 | open | security |
| L4 | LOW | relPath via raw slice not relativePath (breaks on trailing sep) | discover.nim:243 | open | security |
| L5 | LOW | CRISOL_SINK opened without symlink/path constraint (client-side) | report.nim:65 | open | security |
| L6 | LOW | projectRoot reflected into stderr unsanitised (terminal escapes) | gitdiff.nim:64 | open | security |
| L7 | LOW | clean.nim saves graph even when nothing dropped | clean.nim:138 | open | correctness |
| L8 | LOW | nextVal rejects flag values starting with '-' (tags/refs) | crisol.nim:343 | open | correctness |
| X1 | — | cstring argv GC-move hazard | spawn.nim:47 | refuted | ORC non-moving; strings alive through call |
| X2 | — | Windows path-separator mismatch | narrow/gitdiff | wontfix | out of scope — POSIX-only v1 |
| X3 | — | gcDeletedEntrypoints has no caller | depgraph.nim:200 | refuted | called from clean.nim (C4) |

**Mandate (Corey, 2026-06-13):** fix Critical+High+Medium, leave Lows. Recover A6 signals from worktree + verify.

**Fix-loop progress (Step 7):**
- ✅ Wave 1a (green): R2 signals recovered+wired, R9 parent setpgid, R10 EINTR retry, R11 MonoTime deadlines, M11 TERM→400ms→KILL, M12 finally-cleanup.
- ✅ Wave 1b (green): R1 protocol wired (execvpe/forkExecEnv, CRISOL_SINK, readSink→reconcile, OR-rule test), R3 absolute entrypoint path, M1 execute derives timeouts from config, M6 runEntrypoint→execute, M7 sink size cap, M8 mkdtemp, M15 failure-path cleanup.
- ✅ Wave 2 (green): R4 isEntryStale vs projectRoot, R5 deleted-dep kept in closure, R6 chained hash (XOR replaced), R7 over-selection fallback (robust -I parse infeasible — DOCUMENTED, sound), M10 deserialized-path revalidation, M14 untracked files unioned.
- 🔄 Wave 3 (in progress): 3a = R8 pipeline.nim extraction + M2 types moved + M3 shouldEnableColor out of render + M4 unsafeToSeq + M5 pure path-selection; 3b = M9 gitdiff shell→startProcess + projectRoot validation.
- ⏳ Pending: M16 (delete dead depparse.nim) — to do with final re-review.

All Lows (L1–L8) intentionally deferred per mandate. Refuted/oos: X1 (cstring/ORC), X2 (Windows), X3 (gcDeletedEntrypoints).

**Round-2 re-review:** all round-1 Crit/High soundness fixes confirmed HOLD; new in-scope items folded into round 3 (HIGH: pipeline→planner extraction, delete lossy execute compat overload; MED: handleInterrupt double-kill, cacheDir leak, applyGates-carries-path/remove unsafeToSeq-in-pipeline, gskPaths→gskFiles rename; + cheap in-file Lows).
**Round-2 escalation RESOLVED (Corey, 2026-06-13): cross-repo depRoot "under-selection" = OUT OF SCOPE / wontfix.** crisol `--changed` is scoped to the TARGET repo's `git diff`; depRoots serve closure-correctness + compile-avoidance (content-hash), NOT multi-repo change detection (that would be dependency-upgrade testing, a non-goal). Sibling-repo edits → run crisol in that repo. Absolute-path storage for out-of-projectRoot depRoot files is correct (they intentionally don't match a project-repo diff entry). ACTION: add a one-line scope note to the RFC §Impact Analysis; no code change. Impact-Issue-4 (narrowByDiff projectRoot="" default) IS a real cleanup → fixed in round 3.

**Resume:** when Wave 3 lands, do M16 + full re-review (re-run all 5 lenses incl. standing Security+Design on the changed scope; verify new findings per Step 4). Loop until a round finds 0 Crit/High/Med. Then report remaining Lows.

### (historical) Grind progress below

---
### (historical) Grind progress below
**3 — /loop + /tdd grind COMPLETE. Architecture review complete (both rounds applied). 27 TDD slices total (A1–D6); STAGES A, B, C, D COMPLETE except **D5 (the last slice, now UNBLOCKED)**. **26/27 slices done. ./dev build OK, suite green.** **Q1 RESOLVED → KDL** (via nkdl). Resume = implement **D5** (the final slice): `--changed [--base <ref>]` → `changedFiles(projectRoot, base)` shells `git diff --no-renames --name-only` (project-root-relative paths) → feed to `narrowByDiff` (D3/D4) between applyGates and plan; gates still applied after narrowing; non-repo/missing-git → `cekEnvironment` exit 3; combined `--failed --changed` = UNION (RFC line ~413). After D5: Stage 3 grind DONE → Stage 4 `/code-review`.

### TOOLCHAIN CHANGE (this session — important for recovery)
- **nkdl added via milpa** (Corey: "use milpa to add nkdl"). `milpa` host CLI at `~/.local/bin/milpa`. Ran `milpa add nkdl --git ssh://git@github.com/coreyleavitt/nkdl.git --ref v0.1.0` + `milpa fetch`. Created **`milpa.kdl` + `milpa.lock` (COMMITTED)**; `_deps/nkdl` (symlink into `~/.cache/milpa` CAS) + generated `nim.cfg` (`--path:_deps/nkdl/src`) are **gitignored**.
- **`./dev` now mounts the milpa CAS** (`~/.cache/milpa` → same abs path, ro) so the `_deps/nkdl` absolute-path symlink resolves IN-CONTAINER. Without that mount the symlink is broken in the container. `MILPA_CACHE` env overridable.
- nkdl API: `import nkdl`; `parse(src, path) -> Result[KdlDoc, ParseError]` (DOM); `.isErr`/`.getErr.formatError(src)`/`.get`; also typed `decode[T]`/`kdl:` macro (C1 used DOM parse). Source readable at `_deps/nkdl/src/`.

> REORDER RATIONALE: C1 (config load) needs the Q1 config-format decision (KDL vs TOML). D1a/D1/D2/D3/D4/D6 have NO dependency on C (only D5 "Depends on C1+C2"). To keep the unattended loop productive, doing all D-stage-except-D5 now; will pause and surface Q1 once only C1–C4+D5 remain.

### Slice progress (27 total: A1-A6, B1-B7, C0-C4, D1a,D1-D6)
- [x] **A1** discover — reconciled to revised API (`discover(config,selection)→DiscoveredSet`, `loadGateState`/`applyGates` seam split, `initGateState`/`toDiscoveredSet` ctors).
- [x] **A2a** pgroup spike — `tests/integration/test_pgroup.nim` proves `killpg` reaps grandchild (probes `/proc/<pid>/stat` for `Z`-or-absent; ESRCH insufficient in-container — recorded in RFC decisions table).
- [x] **A2b** supervised compile+run ONE entrypoint — `src/crisol/spawn.nim` (`forkExec`,`supervise`, async-signal-safe child path), `src/crisol/runner.nim` (`runEntrypoint`), `tests/fixtures/build.nim` (idempotent pre-compiler) + fixtures `pass_always`/`fail_compile`/`hang_forever`. `tests/integration/test_supervise.nim`.
- [x] **A3** plan/execute split + canonical types in `types.nim`: `Outcome`, `EntrypointResult`, `RunPlan`/`PlannedEntrypoint`+`CompileDecision`, `Summary`; `plan`(pure)/`execute`(seq, continue-on-fail)/`summarize`/`exitCode`/`isFailure`. Refactored A2b placeholders in. Renamed std/unittest-colliding `TestStatus→RecordStatus`. Added stub `DepGraph`, `TestRecord`, `ResultCallback`. `tests/integration/test_run_many.nim`, `tests/unit/test_plan.nim`, fixture `fail_always.nim`.
- [x] **A4** bounded-parallel poll-loop scheduler: `Slot`/`SlotPhase` state machine in `runner.nim` (`execute` honors `RunPlan.jobs`), per-slot deadline→`killpg`, fork-failure→`oSpawnError` containment, parallel==serial invariant (jobs=1 vs 4). `tests/integration/test_scheduler.nim`.
- [x] **A5** `crisol run [paths]` CLI: `src/crisol.nim` (`runMain`), `src/crisol/config.nim` (`loadConfig` convention-defaults stub: unit+integration groups, jobs resolved at plan, 300s timeout), `--jobs`/`--timeout`/`--fail-fast` overrides, positional paths→synthetic `cli` group, bad-usage→exit 3. `bin=@["crisol"]` enabled. `--fail-fast` stops pulling new work on first failure (in-flight drains). `tests/integration/test_cli_run.nim`.
- [x] **A6** signals: `src/crisol/signals.nim` (`{.noconv.}` handler sets `volatile cint` only; `installSignalHandlers()` opt-in), poll-loop TERM→400ms drain→KILL→reap→tmp cleanup, `execute` raises `CrisolInterrupted(signum)`, CLI→`quit(128+N)`. `tests/integration/test_signal.nim`, fixture `hang_with_pid.nim`.
- [x] **B1** `src/crisol/protocol.nim`: NDJSON codec (`encodeHeader`/`decodeHeader`, `encodeRecord`/`decodeRecord`), `readSink→SinkData{hasProtocol,header,records,truncated}`, `reconcile(records,exitCode)→Outcome` (OR rule; timeout/signal excluded — executor decides first). Truncated-final-line via trailing-`\n` check; opaque fallback when no valid header. `tests/unit/test_protocol.nim`.
- [x] **B2** `src/crisol/report.nim`: `initReport(ep)` + `emit(rec)`, unconditional flush-per-record, zero-cost no-op when `CRISOL_SINK` unset, `addExitProc` close hook. `resetReport()` test-only. `tests/unit/test_report.nim`.
- [x] **B3a** spike — confirmed std/unittest 2.2.10 formatter API (5 methods, `TestResult{suiteName,testName,status}` NO duration, `getMonoTime` timing, register before suites). Recorded in RFC.
- [x] **B3** `src/crisol/unittest_shim.nim` (`export unittest` + `CrisolFormatter`; registers CrisolFormatter+defaultConsoleFormatter → console+sink coexist). `tests/integration/test_shim.nim`, fixture `shim_demo.nim`.
- [x] **B4** `src/crisol/render.nim`: pure `render`/`formatProgressLine`/`shouldEnableColor(isTty)`; first-class labels, test-level slowest-N, color via isatty+NO_COLOR; poll-loop progress line (30s default, interval param, `showProgress`). `tests/unit/test_render.nim`.
- [x] **B5** `src/crisol/jsonout.nim`: `toJson`/`toJsonString` (`crisol/run/v1`, stable enums), `persistLastRun` (atomic, every run), `--json` (stdout-only, exit-invariant). RFC schema block. `tests/unit/test_jsonout.nim`.
- [x] **B6** `src/crisol/planview.nim`: `renderPlan`/`planToJson` (`crisol/plan/v1`); `list` + `run --dry-run` share `buildPlanView`, return before execute. `tests/unit/test_planview.nim`, `tests/integration/test_cli_list.nim`.
- [x] **B7** `--failed`: `loadLastRun(config)→(found,failed:HashSet[(path,group)])`; narrows after applyGates/before plan; absent→exit 3, all-gone→exit 0. `--dry-run --failed` tests.
- [x] **C0** spike — RFC C0 FINDING recorded (PASS; schema covers fresco env-gate + proptest per-group seed; caveat: random-per-run seed → proptest runtime env / v1.1 flag-template). Repos not local → re-verify on adoption.
- [x] **D1a** spike — VERIFIED nimcache dep source + corrected RFC: JSON named after `-o:` binary (not projectname); `@m` relative to ENTRYPOINT dir (not currentDir); `@@`→`@`; `nimexe` empty→version from `nim --version`; with/without `-d:extraDep` ⇒ different `compile` arrays (justifies (path,flag-hash) keying). Extracted `src/crisol/depparse.nim` (`decodeMangledPath`, `classifyMangled`) + `tests/unit/test_depdecode.nim`. Fixtures `deptest_main/dep/dep2/extra.nim`. **+ SOUNDNESS CORRECTION (my edit, critical):** the spike's first pass recorded "@p → EXCLUDE all"; that is UNSOUND — project source imported via `--path:src` (the standard src-layout, incl. crisol's own dogfood + amoxtli `src/amoxtli/…`) mangles as `@p` and would be silently dropped from every closure → under-selection + stale-binary false confidence. RFC §Dependency Source steps 4–5 now specify **path-location filtering**: decode @m (vs entrypoint dir) AND @p (resolve body vs tracked roots `projectRoot`,`projectRoot/src`,`dep_root`[/src]); keep iff the decoded path is an existing file under a tracked root; exclude only what resolves outside (true stdlib/nimble). **D1 MUST implement this** (extend `decodeMangledPath`/closure extractor to resolve @p against tracked roots, not prefix-exclude). Residual constraint documented: source must be reachable under projectRoot/src/dep_roots, else list in `dep_roots`.
- [x] **D1** `src/crisol/closure.nim` `extractClosure(nimcacheDir,binaryName,entrypoint,config)→HashSet[string]`; @m vs entrypoint dir, @p resolved vs tracked roots (projectRoot/src/depRoot[/src]), path-location filter. Soundness case verified (`--path:src` import → src module tracked). `tests/integration/test_closure.nim`, fixture `pathimport_main.nim`.
- [x] **D2** `src/crisol/depgraph.nim`: `(path,flagHash)`-keyed `DepGraphEntry`, atomic temp+rename, nim-ver+format-ver header, `isEntryStale`, `gcDeletedEntrypoints`; absence/corruption→empty. `tests/unit/test_depgraph.nim`.
- [x] **D3** `src/crisol/narrow.nim` pure `narrowByDiff(eps,changed,graph,projectRoot="")` — known closure∩changed; unknown⇒conservative. `tests/unit/test_narrow.nim`. (NOTE: added `projectRoot` param vs RFC sig line ~257 — minor doc drift, update RFC sig later.)
- [x] **D4** `selectByDiff→seq[(ep,SelectionReason)]` taxonomy (graphAbsent>ownFileChanged>unknownClosure>staleEntry>closureHit; only known-fresh-miss excludes), `fallbackNotes` ("dep graph absent — full run"). `tests/unit/test_fallback.nim`.
- [x] **D6** compile avoidance: `decideCompile` (binary presence + closure content-hash + nim-ver + protocol-major; `--force-compile`), `DepGraphEntry{closure,closureHash,protocolMajor}` (format v2), slug-keyed persistent `.crisol/bin/<slug>`+`.crisol/cache/<slug>`, execute runs binary directly on cdSkipFresh + records hash post-build. `tests/unit/test_freshness.nim`, `tests/integration/test_skipfresh.nim`. (Executor moved temp→persistent paths; updated test_depgraph/test_cli_list.)
- [x] **C2** `--group`(repeatable)/`--all-groups`→GroupSelection (contradiction→exit3, unknown→cekConfig→3); pure `gateSkipMessages` in render.nim (`skipped group "X" — env VAR not set`, deduped per group, exit-code-neutral); CLI paths still override to `cli` group. `tests/unit/test_c2_selection.nim`, `tests/integration/test_cli_group.nim`.
- [x] **C3** `--filter-tag`: pure `filterRecordsByTag`/`hasZeroTagMatches`, `RenderOpts.filterTag: Option[string]`; filters shown records + counts in human+JSON, leaves verdict/exit/slowest-N unchanged; zero-match→stderr warning. `tests/unit/test_filtertag.nim`.
- [x] **C4** `crisol clean` (`src/crisol/clean.nim`: forward-compute slug set from discover(gskAll), gates ignored, prune orphan cache/bin + gcDeletedEntrypoints; `--all`→rm `.crisol/`) + `src/crisol/lock.nim` (fcntl F_SETLK whole-file WRLCK, acquire after plan/before first compile, defer+death release, contention→exit3; clean locks, list/--dry-run don't). `tests/integration/test_clean.nim`.
- [ ] **C4** (Q1-independent) `crisol clean` (orphan pruning via forward-computation, `--all`) + `.crisol/lock` advisory fcntl F_SETLK lock. (D2 `gcDeletedEntrypoints` is the depgraph half.)
- [x] **C1** KDL config via nkdl (DOM `parse`→translate; `types.nim` stays nkdl-free). `crisol.kdl` schema (globals: jobs/timeout-secs/compile-timeout-secs/max-output-bytes/state-dir/flags/dep-roots; repeatable `group` blocks: opt-in/gate/timeout-secs/flags/globs). `loadConfig(configPath, startDir)`: `--config`→walk-up→convention fallback (root=.git-or-cwd). Flag merge global++group in parseGroup. Structured cekConfig (malformed/dup-group/no-globs/empty-gate/neg-timeout), cekEnvironment (missing --config). `--config` CLI flag. `tests/unit/test_config.nim` (15 tests).
- [ ] **D5** (NEXT — FINAL SLICE, unblocked) `--changed [--base <ref>]`: `changedFiles(projectRoot, base)` shells `git diff --no-renames --name-only` → project-root-relative changed set → `narrowByDiff` (between applyGates and plan); gates applied after narrowing; non-repo/no-git → cekEnvironment exit 3; `--failed --changed` = UNION. Then → Stage 4 /code-review.

## Q1 — RESOLVED (2026-06-13): **KDL** (Corey's pick). nkdl wired via milpa (see Toolchain Change above). No open forks remain.

## Q1 FORK — ACTIVE (blocks C1–C4 + D5 only)
**Config file format: KDL vs TOML.** RFC rule: "KDL if `lib/kdl` extracted as a standalone milpa dep by Stage C start, else TOML." Corey's lean: **KDL**. Genuine fork (depends on lib/kdl extraction timeline — owner's call). Loop pauses for this once D-stage-except-D5 is done; D1a/D1–D4/D6 proceed without it.

> History (2026-06-12): an earlier "rounds 1&2 / 54 findings" label was a drafting agent's invented self-review, not a team review. This session ran the FIRST two genuine 4-lens adversarial passes. Round 1 found deeper empirical holes (osproc setpgid EACCES; 32-bit slug non-injective; gate-in-discover; genDepend rejected for nimcache-JSON) → 20 fixes applied. Round 2 (run against the corrected RFC) found 50 findings → ~30 deduped → 35 surgical fixes applied. NO new genuine forks in either round; Q1 (config format) remains the only open fork.

## Work done this session (banked)
- **Toolchain:** `Dockerfile` (base `ghcr.io/coreyleavitt/nim:2.2.10`), `dev` wrapper (**podman**), self-discovering nimble `test` task over `tests/unit`+`tests/integration` (bootstrap rule). `./dev test` GREEN. Toolchain: NO host Nim — always `./dev run <cmd>` / `./dev test`.
- **A1 discover DONE & green (22 tests):** `src/crisol/types.nim`, `src/crisol/discover.nim` (`matchGlob`, `envGateCheck`, `discover`), `tests/unit/test_discover.nim`. **RECONCILE NEEDED at resume:** the round-1/2 fixes changed A1's contract vs the implemented code — (a) gate eval moved OUT of discover into pure `applyGates`+`loadGateState`; (b) `discover` now takes `(config, selection)` and derives root from `config.projectRoot` (no `root` param); (c) `discover` returns `DiscoveredSet` (distinct seq). First action of the grind: reconcile A1 code to the revised RFC API, keep its 22 tests green (adjust signatures), THEN proceed to A2a.

## Resume command (Stage 3 grind)
```
/loop implement the next unimplemented RFC slice with /tdd, following the
standing rules; after each slice report one progress line (e.g. "slice 4/8
done, 4 remaining"); stop when every slice is implemented
```
Good `/compact` point first. NOTE the slice list changed in round 2: **A2 split into A2a (pgroup spike + committed killpg regression test) and A2b (single-entrypoint supervised compile+run)**; D1a is now a verification spike (not a doc task). Next slice after A1-reconcile = **A2a**.

## Fork decisions
| # | Question | Status |
|---|---|---|
| Q1 | Config format | OPEN — only genuine fork. RFC rule = "KDL if lib/kdl extracted by Stage C else TOML". **Corey's lean: KDL.** Blocks only Stage C (C1); not A/B/D. |
| Q2 | Impact dep source | RESOLVED: nimcache `<nimcache>/<projectname>.json` `compile` array (genDepend rejected — empirically verified). |
| Q3 | Protocol transport | RESOLVED: env-passed sink file (CRISOL_SINK), NDJSON. |
| Q4 | Watch mode | RESOLVED: deferred to v1.1. |

## Round-1 findings (real; from the 4-lens review — synthesize when feasibility lands)
Sharpest so far (CONFIRMED against RFC text):
- **[depth, HIGH] slug injectivity false:** RFC line 273 claims the 8-hex (32-bit) slug is "injective over (path, flag-set)" — false; collision → shared nimcache/bin → the exact ORC corruption crisol prevents. Fix: full 64-bit slug suffix OR store canonical (path,flags) key + verify on lookup (hash match + key mismatch = miss).
- **[depth, CRITICAL] compile-avoidance mtime unsoundness:** freshness cond. 3 uses mtime≥; on 1s-resolution filesystems (Docker volumes, NFS) a same-second source edit with unchanged size is missed (cond. 2's content-hash only fires on mtime/size mismatch) → stale binary treated fresh. Fix: always content-hash, or document + require --force-compile.
- **[depth, HIGH] protocol vs exit-code precedence unstated:** reader contract (RFC 486–489) doesn't cover "fail record + exit 0" or oTimeout-with-partial-records. Fix: state OR rule (fail record OR nonzero exit ⇒ oFailed) explicitly.
- **[depth, HIGH] process-group setpgid race:** exec-wrapper is the only race-free option; A2 spike must exclude parent-side setpgid as primary, not "choose between".
- **[depth, HIGH] nimble-package updates invisible** to impact selection (only nim-version tracked) → document residual risk + "crisol clean after nimble upgrade".
- **[breadth, CRITICAL] Docker execution model blank:** Stage F never says host vs in-container; determines nim-version-key stability. Must specify before F2.
- **[breadth, CRITICAL] CI cache key incomplete:** needs os+arch (not just nim+flags); slug doesn't encode ABI.
- **[breadth, HIGH] CRISOL_TMPDIR cleanup contract**, flaky_test directory-isolation, `--failed` key by (path,group) not path-only.
- **[breadth, MED] no acceptance criterion that crisol runs its OWN suite under crisol** (dogfood gate missing from Stage F).
- **[design, CRIT] gateCheck seam placement** (discover vs downstream filter); **[design, HIGH] selectByDiff/plan ordering** + CompileDecision-vs-selection interaction; **[design, MED] Q1 timeline-coupling**, GroupSelection constructor ergonomics, render(Summary) can't produce B4 output without results.
(Full reports in the 4 reviewer outputs; design+breadth+depth done, feasibility pending.)

## Key decisions (this session)
- Sibling lib at ~/projects/nim/libs/crisol; out-of-process, assertion-agnostic; library-first (discover→plan→execute→report, pure/effectful split). Full scope v1; watch deferred.
- uuid7/B4 determinism fix is OUT of crisol scope — amoxtli domain code (fix in progress in amoxtli).

## Review ledger (Stage 2, round 1 — REAL)
| Lens | Status |
|---|---|
| Depth | done — 2 crit / 5 high / 4 med |
| Breadth | done — 2 crit / 5 high / 6 med |
| Design & ergonomics | done — 1 crit / 4 high / 6 med |
| Feasibility | done — 2 crit / 3 high / 5 med (EMPIRICAL, verified vs Nim 2.2 osproc + live tests) |

## Round-1 feasibility (empirical — highest-confidence findings)
- **[CRIT C1] process-group kill impossible via osproc on Linux:** osproc never takes posix_spawn path on Linux (`useProcessAuxSpawn` excludes linux); parent setpgid → EACCES (errno 13, live-verified). FIX: spawn via raw std/posix fork+setpgid(0,0)+execve (all primitives present) OR C shim; raw posix preferred. Split A2→A2a(spike: passing killpg test)+A2b(impl); A4 blocked on A2a. Also fixes H1 output-redirect (posix_spawn_file_actions_addopen / dup2-to-file; avoids 64KB pipe deadlock).
- **[CRIT C2] dep source RESOLVED → nimcache `<nimcache>/projectname.json` `compile` array** (@m/@s path decode), project-root filtered, ZERO extra cost, complete (verified 3-level import chain). genDepend REJECTED (quit(1) even on success; ~75% compile cost). D1a: research spike → documentation task.
- [H1] osproc can't redirect to file at spawn → use raw-posix spawn (per C1) w/ addopen; else non-blocking pipe drain or deadlock at 64KB.
- [H2] A2 over-scoped → A2a/A2b split. [H3] std/unittest TestResult has NO duration field → shim times via monotonic clock (epochTime testStarted/testEnded); formatters is threadvar (fine single-thread); check resetOutputFormatters; B3a → 2h verification.
- [M] flock NOT in std/posix → fcntl F_SETLK (present, death-safe). [M] ~1GB/compile claim is 7× off (~141MiB); cpu-2 = I/O headroom not RAM. [M] fail_compile exemption must be explicit in build.nim.

## ROUND-1 RESOLUTIONS (to apply to RFC before round 2)
Clear-best (apply): A2 split + raw-posix spawn/kill/redirect; nimcache-JSON dep source (D1a→doc); slug canonical-key-verify (drop false "injective"); always-content-hash freshness; Docker = in-container (Stage F); protocol-vs-exit OR rule; --failed key (path,group); gate eval out of discover→pure filter; render takes results; CI key +os/arch; "crisol runs own suite under crisol" acceptance; nimble-upgrade staleness doc; clean prunes depgraph; flock→fcntl; mem estimate fix; D3/D4 co-spec; dep_roots minimal spec; CRISOL_TMPDIR cleanup; flaky_test dir-isolation; NO_COLOR/isatty.
FORK (Corey): Q1 KDL vs TOML — lean KDL unconditional.
