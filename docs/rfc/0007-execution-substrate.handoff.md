# RFC-0007 — Execution substrate — handoff

- **Stage:** 1 (RFC drafted + sliced)   •   **Round:** — (architect round 1 not yet run)
- **Resume:** `/architect docs/rfc/0007-execution-substrate.md round 1` (then `round 2`; only then `/tdd`). Run architect lenses on **fable** (MEMORY → feedback-architect-agents-fable).
- **Sequencing (decided 2026-08-22):** #18 landed first (portable POSIX fix, no design dependency) → **0007 Stage A** (result model + contract + seam, Linux, folds #1) → **RFC-0005 build** (its `StoredEntry` wire freezes on A1's shape; FORK-2 still owed by Corey) → 0007 Stages B (Linux upgrades) / C (darwin) / D (windows, #15; green needs RFC-0009) → RFC-0008 (observed inputs) / RFC-0009 (ProjectPath). RFC-0006 is parked (negative benchmark).

## Slices
- [ ] A1a  types + derived `outcome` + run/v2 + consumers — **load-bearing** (hang fixture ⇒ `killed`/`cause:runner/timeout` via `crisol run --json`)
- [ ] A1b  authorship & grace (escalated, crash/external/limit, interrupt)
- [ ] A2   `process.nim` + `process/posix.nim`; runner loses std/posix; `SlotState` (#1); `ChildSpec.cwd = projectRoot` (#17, subdirectory `--config` integration test); `tests/conformance/`
- [ ] A3   `ioutils` sole owner of raw file I/O (grep-asserted)
- [ ] A4   `flock` lock; `shutdownRequested()`
- [ ] A5   rusage → `Exit.rusage`, ledger/admission, `nearAddressSpaceLimit`
- [ ] A6   kill snapshot + escapees + `evidenceSatisfies` gate + `--strict-hygiene`
- [ ] A7   `capabilities()` probe, `run/v2.substrate`, CHANGELOG, consumer notice  ⇒ **0005 build unblocked**
- [ ] B1 subreaper · B2 pidfd/event wait · B3 cgroup v2
- [ ] C1 darwin backend + macos CI leg
- [ ] D1 windows backend · D2 windows lock/io/signals/memprobe + windows CI leg

## Open forks (awaiting Corey)
- none for 0007. (RFC-0005 FORK-2 still open, unrelated.)

## Key decisions (this session, 2026-08-22 — grill-me, first-principles mode)
- 2026-08-23: #16 landed on main ahead of 0007 (8a1fa0f, c91988f, 793ac0a; depgraph format 5). #17 folded into A2 (compile/run cwd = projectRoot) rather than fixed standalone — A2 rewrites the spawn seam anyway.
- Executor **guarantees are identity; mechanisms are capabilities** (probed, degraded, reported). → RFC §Identity check.
- Result model = `Exit` (lossless) × `Cause` (authorship, asserted only when known) × `Evidence`; `Outcome` **derived, pure, never stored**; compile+run share `ProcessResult`. Clean break: `run/v2`, `oCrashed`/`oKilled` replace `oSignal`/`oTimeout`, `signal`/`exitCode`/`achieved`/`peakRssBytes` fields removed.
- Kill authorship from the runner's own action, never from the signal number; Windows forced kill uses a runner-chosen exit code.
- Escapees: verdict untouched, result uncacheable + warning, Linux-subreaper reaps, `--strict-hygiene` opt-in.
- Event-driven wait adopted for contract uniformity, not correctness (25 ms poll was sound; `killpg` pid-reuse-safe while the group lives).
- Lock → `flock` (RFC-0001's fcntl choice was a std/posix-coverage artifact).
- **No network enforcement in crisol on any platform** (not Seatbelt, not CLONE_NEWNET) — enforcement is the CI container's job; crisol observes. `hlNetwork` = network-independence asserted; unachieved until the RFC-0008 observer.
- **RFC-0008 = input observer** (files/dirs/network/randomness/exec via seccomp user-notif unprivileged, eBPF privileged, `coverage` reported; macOS/Windows `unobservable`); cache gate becomes "every observed input captured"; fixtures verifiable then auto-captured. Not in 0007.
- **RFC-0009 = `ProjectPath`** typed canonical identity, case-sensitivity probed per root (APFS too). Prereq for Windows green.
- #18 fixed as: `pipe`+`FD_CLOEXEC` (single-threaded executor ⇒ equivalent to pipe2) and parent-side `findExe` + `execve` (argv[0] preserved; unresolvable program ⇒ spawn error instead of child 127).

## Review ledger (stage 4)
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
