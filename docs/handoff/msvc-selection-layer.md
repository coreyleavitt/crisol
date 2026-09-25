# MSVC selection layer — handoff (issues #21 / #22 / #23)

- **Scope:** making crisol's **impact selection** correct under the `cc = vcc`
  (MSVC) Windows toolchain. Three issues, one workstream, deliberately split
  because they have different blast radii.
- **Not an RFC.** Reviewed and decided 2026-09-20 (Corey): no new RFC; an
  RFC-0007 addendum records the toolchain findings. This lives in
  `docs/handoff/` rather than `docs/rfc/` so `docs/rfc/` keeps meaning
  "an RFC and its handoff" — there is no RFC number here to fake.
- **Parent:** `docs/rfc/0007-execution-substrate.handoff.md` (POST-CLOSE, MSVC
  shakeout). Its stage line points here; this doc is the source of truth for
  #21/#22/#23.
- **Also touches:** `docs/rfc/0009-path-identity.handoff.md` — three of the
  four tests in #21's acceptance are RFC-0009 conformance tests. They are NOT
  re-opened RFC-0009 work; RFC-0009 stays COMPLETE.

---

## Stage

| Issue | What | State |
|---|---|---|
| **#22** | `readAll()` truncates child stdout on Windows; undrained stderr deadlocks | **DONE, COMMITTED** (`9219670`, docs `630ecc6`) |
| **#23** | `ccVersion` is toolchain-blind on Windows, and version-string-keyed everywhere | **DONE, 9/9 slices — UNCOMMITTED** |
| **#21** | MSVC dep extraction (`/sourceDependencies`) — the actual capability | **DONE in code, all slices (1a/1b/1c/2/3/4) — UNCOMMITTED.** Only `test_rfc9_a5c_cache_portability.nim`'s real-body verdict is outstanding, and only a windows CI run can give it (see `### Remaining` under #21) |

All three issues are now under `/code-review #21-23`. That review, not further
slices, is the active work: see the review state below and the Resume block.

**Review state — 2026-09-25.** `/code-review #21-23` has run **eight rounds** over
this workstream (the sections "Code review — 2026-09-21", "Round 2 re-review",
"Round 3 re-review", "Round 4 re-review", "Round 5 re-review", "Round 6
re-review", "Round 7 re-review", "Round 8 re-review"). Each round's
dispositions are in its own findings table's status column — deliberately not
restated here, because a second copy of them drifts (R5-14).

Round 5 is the first round to find anything **above Medium**, and both Highs are
defects in fixes this loop itself produced: R5-1 in the R3-8 change made the same
day, and R5-2 in the gate that R4-3/R4-6 added. Rounds 1-4 found no Critical and
no High. **17** findings at Medium or above (2 High + 15 Med) and **9** Lows, 26
rows — counted from the table, not maintained by hand (the previous "sixteen and
thirteen" summed to 29 against a 26-row table). R5-26 was
opened by the fix round itself, when closing R5-11 showed that collapsing the two
gate copies removed their disagreement but not the class that produced it.

Round 6 ran the same three dimensions (Security, Design & ergonomics,
Liveness/completeness) over round 5's fix diff. It found no Critical and **one
High**, R6-S1, and the High is again in the previous round's remedy (R5-4's
`ccidentity` predicate). That makes three consecutive rounds. Round 6 has **10**
findings at Medium or above (1 High + 9 Med) and **17** Lows, 27 rows. Counted
from its table: 17 fixed, 8 deferred (all Low), 2 closed. (Round 7, R7-D3,
added the two rows the table had been missing — the stale "107" figure and mawk
on ubuntu — so these figures moved from 25/15/16/1.) **Round 6's fixes have
landed**, and every round-5 and round-6 row has a terminal status. Fix lanes ran
on Opus 5.5 at Corey's request.

**Round 7's fixes have landed** and every row in "Round 7 re-review" has a
terminal status. Counted from its table by script: **22 rows** — **1 Critical,
1 High, 6 Med, 14 Low**; 19 fixed, 2 deferred (both Low), 1 split out. The
Critical, **R7-S6** (the compile environment reaches the compile but not the
key; a cached PASS served to a host whose own binary fails), is pre-existing at
`630ecc6` and was SPLIT OUT by Corey as a separate issue; it is not fixed here.
The High, **R7-S1**, is fixed, and for the **fourth consecutive round** it
traces to a prior round's remedy — this time to the measurement R4-1 was
founded on, which was wrong (corrected in place below, marked CORRECTED IN
ROUND 7).

**Round 8's fixes have landed** and every row in "Round 8 re-review" has a
terminal status. Counted from its table: **20 rows**, of which **1 Critical,
5 Med and 14 Low**. 18 are fixed, 1 is deferred (R8-S3, Low) and 1 is folded
into the split-out issue. The Critical, **R8-S1** (user and global `nim.cfg`
change the compile but not the key), is pre-existing at `630ecc6`. It shares
R7-S6's root, so it is proposed to fold into R7-S6's issue under one design;
filed as #24 on 2026-09-25. There was no High. For the **fifth consecutive round**
the worst in-scope finding traces to the previous round's remedy: R8-D1, the
no-caching-at-all cost of R7-S1's refusal, which the warning understated.
R7-S5's comment carry-over is closed (R8-D4).

**This is NOT the floor**: the loop stops only when a round surfaces nothing above
Low, and round 8 surfaced a Critical (out of scope, folded into the split-out
issue) and five Meds. **Round 9 runs next**, over round 8's fix diff (re-sweep
first).

**Current verification state:** see "Verification state at the end of round
8". The round-5 paragraphs below are history. Their figures (258/259
entrypoints, 197 records over 1010 signatures) are superseded: there are now
264 entrypoints, and the census holds 231 records over 1131 signatures.

Five items sit with Corey: R7-S6 + R8-S1 (both Critical, one issue to file,
needs a yes), R7-S7 (a trust-gate default, Low), W9c (feature-sized, and now
known to need a *windows* producer, not the Linux one it was scoped as), R2-8
(needs a Windows-capable check) and R4-11 (a pre-existing flake outside this
workstream — a scope call, not a technical one). R3-8 came off the list in round 5: it was
escalated as a fork and turned out to be decided by RFC-0003, which makes
`crisol/planner` an implementation detail rather than library surface. See
`## Open for Corey`, which is the live list; the section near the top of this
file titled "Open forks awaiting Corey" is now only a pointer to it (R5-3).

**Verification state at the end of round 5.** The authoritative sweep is **258
entrypoints, not 255** — the figure restated for three rounds. The delta is
**3**, not the "five test files" the round-5 text claimed; that attribution never
reconciled with its own arithmetic and is withdrawn rather than patched, since the
only durable instruction is to re-derive the count. Round 5's sweep
before its fixes: **256 pass, 2 fail** — `test_fallback.nim` (the documented
bind-mount `a.fold == b.fold` artifact, never red on CI) and
`test_nimcache_persistence_real.nim` (R5-1, since fixed and mutation-proven three
ways). `test_api.nim` (R4-11) passed that run, consistent with its measured
one-in-three rate.

**After the fixes: 259 entrypoints, 258 pass / 1 fail** — only the fold-policy
artifact. The count moved by one because R5-10's fix added
`tests/integration/test_r5_10_toolchain_unsound_wire.nim`. Re-derive it; do not
restate it.

**Verification state — end of round 5, after its fixes landed.** The gate paragraph
that used to sit here warned you not to read a green gate as "src/ is clean". That
warning is now DISCHARGED, and by construction rather than by assertion.
`ci/source-soundness-gate.sh` is one script shared by `./dev check` and CI (R5-11),
it runs **18 `nim`
invocations across 3 targets** (5 on linux, 7 on windows, 6 on macosx — one
aggregator plus four out-of-closure mains each, plus the per-OS backends) with both
`--warningAsError:Deprecated:on` and
`--warningAsError:UnusedImport:on`, and its last step **measures its own coverage**
and fails if any `.nim` file under `src/` is compiled by no pass (R5-26,
mutation-proven four ways). Current run: `78 of 78 files, per-target closure reach
71/66/70`, exit 0, 26.6 s. `ci/assert-defaulted-params.sh` (R5-15) also passes: 197
pinned records over 1010 signatures, exit 0, failing in both directions. (Round 6
changed both of these. The census now pins values as well as names, over **1014**
signatures (R6-D2), and has its own CI self-test (R6-S2). The gate now names the
failing pass (R6-D3). See the round-6 section for its verification state.)

Two numbers in that sentence were corrected by the machines that now check them,
which is the round's most useful pattern: the coverage assertion's first run
reported 78 files where the header said 76, and the census enumerator found 1010
signatures where a `git ls-files` enumerator found 969 — both because
`ccidentity.nim` and `toolrun.nim` are real, compiled, and untracked. Two
independent methods, same session, same gap.

No RFC `review` field is set for this workstream: there deliberately is no RFC
here, and the field on RFC-0007 describes the review of RFC-0007, not this one —
flipping it would be a false claim.

**Resume:**

```
/code-review #21-23 round 9
# The active work is the REVIEW LOOP, not slices. All three issues are done in
# code: #22 committed; #23 9/9 and #21 1a/1b/1c/2/3/4, both UNCOMMITTED.
# The RFC-0007 addendum is written (docs/rfc/0007-execution-substrate.md,
# "Addendum — MSVC toolchain findings"). #21's only open item is the a5c
# real-body verdict, which only a windows CI run can give.
#
# Round 8 is closed: every row terminal, fixes landed (lanes A-D). Round 9
# re-sweeps first (enumerate entrypoints as the nimble task does; re-derive,
# do not restate, the counts), then reviews round 8's fix diff (R8-N
# markers; interim liveness IDs, see the round-8 "On IDs" note), same three
# dimensions. Look hardest at: the stateDirOf semantics change (a bare
# Config() now raises), the new ci.yml gating/steps (never run on Actions
# yet), and the census's backward object walk. For any fix founded on a
# measurement, re-measure the real binary.
# R7-S6 + R8-S1 (Critical) are one split-out issue, filed as #24
# (2026-09-25) -- not round 9's scope.
# NOTHING HERE IS COMMITTED and nothing may be without Corey saying so.
```

**Slices done / remaining on #23:** **9 of 9 done** (1, 2, 3, 4a, 4b, 6, 7, 8;
slice 5 absorbed into 4a, and 4b retired `LddSentinel`, which was slice 7's
third item). Plan approved 2026-09-20, including the RFC-0004 spec change.
Remaining: **none**. Nothing is committed yet: `ccprobe.nim`,
`render.nim`, `test_ccprobe.nim`, `test_render.nim`, `.github/workflows/ci.yml`,
the new `tests/integration/test_issue23_cc_identity.nim`, and slice 8's
amendments to `docs/rfc/0004`, `0005`, `0006` and the `0004`/`0006`/`0007`/
`0009` handoffs are all dirty.

**Ordering rationale (decided 2026-09-20).** #23 before #21, because #21's own
design notes rest on a premise that is false today — "gcc-closure and cl-closure
results key apart by construction". Under vcc the closure is currently empty/
wrong, so the keys are garbage anyway; landing #21 first would convert that into
*correct-but-collidable* — real cl-derived header sets sharing a fingerprint with
mingw-gcc ones, on a machine that ships both images. Changing the fingerprint
self-invalidates Windows entries (they MISS rather than collide, the safe
direction), and doing it once before #21 produces entries worth keeping beats
invalidating twice. Counter-argument on record: #21 introduces cc-family
classification from the manifest's driver token and #23 wants the same "this is
MSVC, ask cl for its banner" logic, so the other order would hand #23 that for
free — judged not to outweigh the soundness ordering, since `ccVersion` probes
PATH with no manifest in hand and needs its own resolution regardless.

---

## Environment — read this before running anything

**The MSVC toolchain is a WINDOWS container.** `./dev` cannot reach it: podman
on this host is WSL-backed and runs Linux containers only. Use Docker Desktop's
Windows engine directly — it is up even when the Docker Desktop GUI is not, and
the GUI's `desktop-windows` context pipe is usually absent:

```powershell
$env:DOCKER_HOST='npipe:////./pipe/docker_engine_windows'
docker run --rm -m 8g -v "C:\Users\corey\projects\crisol:C:\workspace" -w C:\workspace `
  ghcr.io/coreyleavitt/nim:2.2.10-windows cmd /c "nim r --hints:off --warnings:off --path:src --nimcache:C:\workspace\.wincache\<tag> <test>.nim"
```

- `--nimcache:` into `.wincache/` (gitignored) or every run recompiles from
  cold: ~6 min vs ~1 min.
- **Never link a binary into the bind mount twice in one run** — relinking over
  an `.exe` that was already spawned fails `LNK1104`. Build helper binaries to a
  container-local path (`C:\out\…`) or compile each fixture once per test file.
- Give `-o:` an explicit `ExeExt`; an extensionless output is not spawnable on
  Windows, and the resulting spawn failure looks exactly like an empty capture.
- `where cc`, `where gcc`, `where ldd` all FAIL in this image. That is #23.

**`./dev` is broken on this host** (unrelated to this work, worth fixing
separately): the podman machine's netavark/nftables is wedged, so `./dev image`
cannot build and any networked container run dies with
`netavark … nftables error: "nft" did not return successfully`. Workaround —
the base image plus `--network=none`, which is what CI does anyway:

```powershell
podman run --rm --network=none -v "${PWD}:/workspace" -w /workspace `
  ghcr.io/coreyleavitt/nim:2.2.10 bash -c 'nim r --hints:off --path:src <test>.nim'
```

`ci/run-tests.sh` will NOT work under `--network=none` (nimble tries to fetch a
compiler); drive `nim r` per file instead.

**Deps:** `_deps/` and the generated root `nim.cfg` are gitignored and absent on
a fresh checkout. `bash ci/fetch-deps.sh` (needs network, runs on the host)
materialises them.

**Two unit tests fail locally at pristine HEAD — do not chase them.** Verified
against a clean `git worktree` at `8e527bb`:
`tests/unit/test_api.nim` (`perfBaselineUs was 0`) and
`tests/unit/test_fallback.nim` (`TrackedPath: same rootTag compared under two
different fold policies`). Bind-mount / timing artifacts of podman-on-Windows;
they pass in real CI. Full local sweep is 128 files, `fail=1` with exactly those
two.

---

## #22 — DONE (uncommitted)

### What it was

Two defects at five hand-rolled `osproc` capture sites.

1. **Truncation, Windows-only.** `streams.readAll` reads in 1024-byte chunks and
   stops at the first SHORTER read. POSIX `osproc.outputStream` returns a
   buffered C `FILE*` (`osproc.nim:1447` → `createStream` → `open(f, handle)`)
   whose `fread` loops to EOF, so POSIX is immune. Windows returns
   `newFileHandleStream`, whose `hsReadData` calls `winlean.readFile` directly
   (`osproc.nim:838`, `:558-568`) and returns the child's first partial flush.
   Upstream half-knew: `s.atTheEnd = br == 0 #< bufLen`.

   Measured, same command and options:

   ```
   readAll (crisol today):    rc=0 bytes=8   lines=1  includeNotes=0
   readData drain loop:       rc=0 bytes=717 lines=14 includeNotes=13
   readLine loop:             rc=0 bytes=703 lines=14 includeNotes=13
   waitForExit then readAll:  rc=0 bytes=717 lines=14 includeNotes=13
   ```

   An earlier revision of issue #22 called this cross-platform. **Retracted** —
   found when slice 1's RED passed on Linux.

2. **Undrained stderr, both platforms.** `ccprobe` never read stderr;
   `gitdiff` read it only after `waitForExit`. A child that fills the stderr
   pipe blocks in its own `write`, so it never finishes stdout and never exits.
   `gitdiff.nim` dismissed this because git's stderr is "a few short warning
   lines" — the `core.autocrlf` warning it cited is emitted **per file**.

Impact beyond MSVC: `gitdiff` truncation means a **silently short changed-file
set**, i.e. `--changed` selecting fewer tests than the change touched, on
Windows, with exit code 0.

### What landed

New std-only leaf `src/crisol/toolexec.nim` owns subprocess capture:

- `drainToEof(Stream)` — `poStdErrToStdOut` spawns (one pipe).
- `drainBoth(Process)` — separate-stderr spawns; `poll(2)` on POSIX,
  `PeekNamedPipe` on Windows. **Not threads**: `src/` has no `createThread` and
  a tool side channel is the wrong place to introduce a threading model.

All five sites route through it: `ccprobe.runViaOsproc` and `gitdiff.runGit`
(`drainBoth`), `compiledriver.runCompileOnly`/`realLink` and
`icbaseline.realIcRun` (`drainToEof`). `toolexec` added to `AllowedPosixFiles`
in `test_rfc7_a3_ioutils_ownership.nim` with the readiness-query-vs-file-I/O
rationale (same shape as `lock/posix.nim`'s flock, `paths.nim`'s pathconf).

**Files — new:** `src/crisol/toolexec.nim`, `tests/support/deadline.nim`,
`tests/fixtures/{two_burst_output,fake_git,gitdiff_probe,capture_probe}.nim`,
`tests/integration/test_issue22_{capture,changed_completeness}.nim`,
`tests/unit/test_issue22_capture_ownership.nim`.
**Modified:** `src/crisol/{toolexec←new,ccprobe,gitdiff,compiledriver,icbaseline}.nim`,
`tests/unit/test_rfc7_a3_ioutils_ownership.nim`, `.github/workflows/ci.yml`,
`.gitignore`, both handoff docs.

### Evidence

MSVC container, all green (RED taken first for each, in the MSVC container):

```
[Suite] issue #22 — child output is captured in full
  [OK] realRun returns the payload a two-burst child writes after its banner
  [OK] realIcRun returns both bursts when the child's streams are merged
  [OK] a child whose stderr overruns the pipe buffer neither wedges the probe nor loses its stdout
[Suite] issue #22 — --changed sees every changed file
  [OK] changedFiles returns all names when git's diff arrives in two bursts
  [OK] a git whose stderr overruns the pipe buffer neither wedges nor is truncated
[Suite] issue #22 — toolexec owns subprocess output capture
  [OK] no module reads a child's stdout or stderr with readAll
```

REDs were: `output.len was 18` (banner only, `ok` still true); 1 of 100 changed
names; `Check failed: finished` (probe wedged, killed at the 60 s deadline).
Linux green alongside `test_changed.nim` (real git) and
`test_compiledriver_real.nim` (real nim/cc/link), which exercise the POSIX
`poll(2)` arm against real tools.

### Traps this left behind

- **These tests cannot fail on Linux** (see the mechanism above). RED must be
  taken in the MSVC container.
- **Fixture sizing is governed by Nim's ~4 KB default pipe buffer** —
  `osproc.createPipeHandles` calls `CreatePipe` with `nSize = 0`
  (`osproc.nim:664`). A payload ABOVE it makes a truncating caller **hang**
  instead of failing; truncation cases stay under it, deadlock cases go far
  above it. This is documented in `two_burst_output.nim`'s header.
- **CI wiring must not be dropped.** Both integration tests are pinned as
  per-file steps on the windows leg (after the A0-spike step) because that leg
  sweeps `tests/unit:tests/conformance` only. Without them the fix has no
  producer on the one platform that can regress it. An unquoted YAML `name:`
  containing `#` is truncated at the `#` as a comment — both names are quoted.

### Commit message (drafted)

```
osproc: toolexec owns child-output capture -- readAll truncates on windows

streams.readAll stops at the first read shorter than its 1024-byte buffer.
On POSIX osproc hands back a buffered FILE* whose fread loops to EOF, so it
is sound there; on Windows it hands back a raw-handle stream whose reads
return the child's first partial flush, so a child that flushes twice is
captured as if it had written only its banner -- with exit code 0 and
nothing in the result to say otherwise.

gitdiff was one of the five sites, which made this a live --changed
selection bug on windows: a short changed-file set, silently.

Second defect at the same sites: ccprobe never drained stderr and gitdiff
read it only after waitForExit, so a child filling the stderr pipe blocks
in its own write and never exits. gitdiff's comment dismissed this because
git's stderr is "a few short warning lines"; core.autocrlf emits one per
file.

New std-only leaf src/crisol/toolexec.nim: drainToEof for merged-stream
spawns, drainBoth (poll(2) / PeekNamedPipe, not threads) for separate-stderr
spawns. All five hand-rolled sites route through it.

Closes #22.
```

---

## #23 — DONE, 9/9 slices, uncommitted (design revised 2026-09-20 after measurement; supersedes the earlier cl-banner-only plan)

### The problem, restated

`ccprobe.ccVersion()` is the C-toolchain half of the soundness key:
`cc --version` first line ⊕ `"|"` ⊕ `ldd --version` first line. On Windows
neither command exists under any toolchain, so every Windows host folds to the
constant `<cc-unavailable>|<ldd-unavailable>` and an mingw-gcc cache entry keys
identically to an MSVC one. Issue #21's design notes assert the opposite
("key apart by construction") — true on Linux, false on Windows, and the reason
#23 goes first.

**The measurement then widened the problem.** It is not a Windows bug; it is a
design inconsistency that Windows made total instead of partial. See "Why a
version string is the wrong primitive" below.

### Measured, 2026-09-20, `ghcr.io/coreyleavitt/nim:2.2.10-windows` (cl 19.44.35228)

| Probe | stdout | stderr | rc |
|---|---|---|---|
| `where cl` / `where vccexe` | both ON PATH — `C:\msvc\vc\bin\cl.exe`, `C:\nim\2.2.10-patched\bin\vccexe.exe` | — | 0 |
| `where cc` / `gcc` / `ldd` | — | not found | 1 |
| `cl` (no args, `CL` empty) | `usage: cl [ option... ] filename... [ /link linkoption... ]` | `Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64` | **0** — only with `CL` empty (R7-S1) |
| `cl /nologo` (no args) | *(empty)* | `cl : Command line error D8003 : missing source filename` | ~~0~~ **2** — CORRECTED IN ROUND 7 (R7-S1) |
| `cl`, `CL=/W4` | — | the banner AND `D8003` | **2** (R7-S1) |
| `cl`, `CL=/nologo` | — | `D8003` only | **2** (R7-S1) |
| `cl`, `_CL_=/W4` | as plain `cl` | as plain `cl` | **0** — `_CL_` is ignored with no arguments (R7-S1) |
| `vccexe` (no args) | `usage: cl ...` | **the same banner** | 0 — and identical to `cl` in every row above, rc included (R7-S1) |
| `vccexe`, no reachable `cl` (Nim + mingw host) | `Hint: vcvarsall.bat was not found` | unhandled-OSError traceback | **1** (R7-S1) |

**CORRECTED IN ROUND 7 (R7-S1): the `cl /nologo` row's rc was wrong, and R4-1
was founded on it.** Re-measured 2026-09-25 in the same image with
`cmd /v:on` and `!ERRORLEVEL!` (delayed expansion, read after each command
runs): plain `cl` rc=**0**, and only with `CL` empty; `cl /nologo` as an
argument rc=**2** (and 2 again as the container's own process exit code, which
involves no `%ERRORLEVEL%` at all); `CL=/W4` prints the banner plus `D8003`,
rc=**2**; `CL=/nologo` prints `D8003` alone, rc=**2**; `_CL_=/W4` is ignored
(no arguments), rc=**0**. `vccexe` is identical to `cl` in every case. So
`cl` exits 2 whenever `CL` is set to anything, not only `/nologo`. The
original 0 was `%ERRORLEVEL%` expanded at PARSE time on a `&`-joined cmd line
— the status of whatever ran before `cl`, not of `cl` — and that is now
reproduced, not inferred: `(cl /nologo & echo pct=%ERRORLEVEL%
bang=!ERRORLEVEL!)` prints `pct=0 bang=2`. The stdout and stderr columns of
the original rows stand. Consequence: the trigger rounds 4-6 defended against
(`CL=/nologo` making `cl` answer rc=0 with `D8003`) never reaches the refusal
logic in reality — the probe's `not ok: continue` drops `cl` as ABSENT, and a
bystander gcc/clang becomes the identity. See R7-S1 in "Round 7 re-review".

The banner is on **stderr**, which the current `RunProc` seam does not return.
And **`vccexe` yields it without `cl` being on PATH** — on a real dev box `cl` is
on PATH only inside a Developer Command Prompt, while `vccexe` (Nim's own
wrapper, always beside `nim`) locates it regardless.

**What a Nim vcc binary actually links** — `dumpbin /dependents` on a
`nim c --cc:vcc` build:

```
    KERNEL32.dll            <- the entire dependency list
```

**Nim+vcc links the CRT statically.** There is no libc DLL on Windows to
fingerprint. This makes the two obvious candidates *actively wrong*, not merely
costly: hashing `System32\ucrtbase.dll` or keying on the OS build would
invalidate on Windows Updates that cannot affect the binary while staying silent
on SDK changes that can.

**What the linker actually consumes** — `link /nologo /VERBOSE:LIB`, and
identically via `vccexe /nologo m.c /link /VERBOSE:LIB` in one shot:

```
    C:\msvc\vc\lib\LIBCMT.lib           <- static CRT        (VC toolset)
    C:\msvc\vc\lib\libvcruntime.lib     <-                   (VC toolset)
    C:\msvc\sdk\lib\ucrt\libucrt.lib    <- the UCRT          (Windows SDK)
    C:\msvc\sdk\lib\um\kernel32.lib, uuid.lib, OLDNAMES.lib
```

`LIBCMT`/`libvcruntime` ship with the VC toolset, so cl's banner covers them.
**`libucrt.lib` ships with the Windows SDK, versioned independently of cl** — so
a sentinel, or any cl-banner-only fix, leaves exactly that gap open.

**Linux side**, `ghcr.io/coreyleavitt/nim:2.2.10`:

```
cc -print-file-name=libc.so.6  ->  /usr/lib64/gcc/x86_64-suse-linux/16/../../../../lib64/libc.so.6
                               ->  /usr/lib64/libc.so.6
ldd --version | head -1        ->  ldd (GNU libc) 2.43
```

TRAP: gcc **echoes the bare name back** when the file is not found (musl hosts),
with rc=0. Discovery must `fileExists`-check, never trust the exit code.

### Why a version string is the wrong primitive (the spec change)

RFC-0006 §Soundness already argues the principle, about headers:

> a distro header backport that patches a struct layout without moving a
> version string must invalidate

A RHEL or Debian glibc backport moves no version string. By crisol's own stated
standard `ldd --version` is a **live Linux soundness hole today** — not a
Windows-only problem.

The fix pattern already exists one field over. `nimVersion` is the full
`nim --version` text **plus a content hash of the nim binary** (RFC-0005:21,
"sound by construction, not by luck"). And `nimprobe.nim`'s module doc justifies
itself as closing a gap "symmetric to the one `ccprobe.nim` already closes for
the C compiler" — **which is false**; ccprobe closes it with a version string.
`docs/rfc/0005-distributed-cache-and-trust.md:389` even records the asymmetry
deliberately: `kcCcVersion is <cc first line>|<ldd first line> (ccprobe.nim —
no binary hash)`. Someone built the right pattern for Nim, documented it as
mirroring ccprobe, and never went back.

**Decided (Corey, 2026-09-20): fix it the right way; the RFC-0004 spec change is
accepted and gets noted in the RFC.**

### Design

Two `|`-separated halves as now — `render.splitFirstPipe` and `--explain-miss`
depend on that shape. Each half becomes legible text ⊕ content hash, the
`nimprobe` idiom exactly:

| | discovery | fingerprint |
|---|---|---|
| cc half | `versionLine` of the merged banner; `findExe` for the driver | `Microsoft (R) ... 19.44.35228 for x64 #<hash of driver>` |
| runtime half | Linux `cc -print-file-name=libc.so.6`; MSVC trivial TU + `vccexe ... /link /VERBOSE:LIB` | `ldd (GNU libc) 2.43 #542b390a4be6deb6` / `kernel32+libcmt+libucrt+libvcruntime+oldnames+uuid #0d8cab78a8b5d998` (both measured) |

- **`RunProc` is NOT widened.** Re-exported by `artifactid`/`closure`/`nimprobe`
  and destructured at ~10 sites plus ~8 test fakes. Instead a second
  *implementation* of the same type: `realRunMerged` (`poStdErrToStdOut` +
  `toolexec.drainToEof`). Every existing fake compiles verbatim. This also stops
  #22's `drainBoth` stderr half being discarded.
- **Extraction is content-selected, never position-selected.** Merged output can
  interleave `usage: cl ...` ahead of the banner, and resting on flush ordering
  is how #22 happened. `versionLine(s)`: first non-empty line bearing a dotted
  version token, else the first non-empty line. Locale-proof by construction (a
  localized cl banner still carries `19.44.35228` — the trap `/showIncludes`
  walks into in #21).
- **cc candidates are ENUMERATED and every distinct answer folded**, not
  first-match-wins. Windows `["cl","vccexe","gcc","clang","cc"]`, POSIX `["cc"]`.
  First-match-wins is unsound: on a box with both mingw and VS it reports `cl`
  while nim builds with gcc, so a gcc upgrade does not invalidate.
  **Under-invalidation is the bug class #23 exists to kill; over-invalidation is
  only a miss.** Deduped on BANNER TEXT, not driver name — `cl` and `vccexe`
  return byte-identical banners, so folding by text gives the same fingerprint
  whether or not crisol was launched from a Developer Command Prompt.
- **MSVC runtime arm hashes EVERY library the linker searched**, deduped and
  ordered by basename — no cherry-picking which ones "count", because that is a
  judgment call that can be wrong. `libucrt.lib` is then covered without ever
  parsing a Windows SDK version out of a path.
- **Paths never enter the fingerprint — only basenames and content.** This makes
  the key MORE host-portable, not less: two hosts whose distro both prints
  `glibc 2.38` but ships differently-patched `.so` files collide into one key
  today.
- **Degradation ladder:** full fingerprint -> per-artifact sentinel for an
  unreadable file -> `<runtime-unidentified>` when discovery fails entirely.
  Never raises, never empty; "probe succeeded but found nothing" stays
  unrepresentable.
- **Platform profile so the Windows arm is testable on Linux.** The only
  `when defined(windows)` is one line:

  ```nim
  type RuntimeProbe* = enum rpPrintFileName, rpMsvcLinkVerbose
  type CcProbeProfile* = object
    ccCandidates*: seq[string]
    runtime*: RuntimeProbe
  const PosixCcProfile*, WindowsCcProfile*   # both live, both produced this slice
  proc hostCcProfile*(): CcProbeProfile      # the single `when defined(windows)`
  proc ccVersion*(run: RunProc = realRunMerged;
                  profile: CcProbeProfile = hostCcProfile();
                  hashFile: BinHashProc = realFileHash): string
  ```

  Without it the whole Windows behaviour is exercisable only in the container —
  the #22 trap repeated.

**Not doing:** hashing `c1.dll`/`c2.dll`/`cc1` behind the driver. Driver hash +
version banner catches driver swaps and version bumps but not a backend-only
change. A real limit; documented honestly rather than implied away.

### Fallout map (measured, not assumed)

- **ioutils ownership does NOT bite.** `test_rfc7_a3_ioutils_ownership.nim`
  scans exactly two things: `import std/posix` (path allow-list) and
  `import std/osproc` (must carry `# process-contract-exempt` on the line).
  **Plain `std/os` file I/O is unconstrained**, and `ccprobe.nim:62` already
  carries the osproc marker. No exemption, no allow-list entry needed.
- **The probe cost is paid ONCE PER RUN, not per worker.** `cachedCcVersion()`
  has exactly two production call sites — `crisol.nim:585` and `api.nim:1863` —
  both in the host process. `measureworker.nim` (the re-exec'd child) imports
  neither `ccprobe` nor carries a `ccVersion` field in its plan schema. The
  ~200 ms MSVC compile+link probe is once, not x N slots.
- **`crisol/fnv.nim` is a genuine std-only leaf** (`import std/algorithm` alone),
  so `ccprobe` can hash without a cycle. `nimprobe` currently reaches through
  `crisol/depgraph` for the same primitive, dragging in `closure` transitively.
  **Stale as of the #21-23 wiring audit / W9f (2026-09-21): this was NOT
  fixed by slice 4.** `nimprobe.nim:71` still `import crisol/depgraph`
  (confirmed by re-reading the module today); the `nimprobe` → `crisol/fnv`
  refactor this paragraph predicted was never done and is not part of the
  #21-23 work. It is Corey's own structural change, sequenced separately —
  do not attempt it opportunistically alongside an unrelated fix.
- **Sentinels have no production consumers.** `CcSentinel`/`LddSentinel` are
  referenced only inside `ccprobe.nim` and by 6 literal assertions in
  `test_ccprobe.nim`. Retiring `LddSentinel` is cheap.
- **Conformance tests.** `test_rfc9_a4b_determinism.nim` and
  `test_windows_cli_smoke.nim` have no `ccVersion` reference.
  `test_rfc9_a5c_cache_portability.nim` runs both its runs in ONE process and
  relies on `cachedCcVersion`'s process-lifetime memoization — safe, but it
  imposes a HARD CONSTRAINT: **the probe must be deterministic within a
  process, so the scratch directory name must never reach the fingerprint.**
- **The 9-component key pins stay untouched** [corrected 2026-09-21 by the code review, row W9g: the key folds **ten** components, not nine -- `cwdPosture` was appended by RFC-0007 r57. Slice 8 verified the six pins as *untouched* rather than as *correct*, so this line recorded a stale number as confirmed. The pins themselves are genuinely untouched; only the count was wrong] (`0004.handoff:16`, `0005.md:27`,
  `:35`, `:511`, `0005.handoff:44`, `:63`). We change `ccVersion`'s derivation,
  not the component set.
- **NOTHING to mark with a completion tick.** RFC-0006's review-ledger row R2
  (`0006.handoff:237`, "objcache key omits libc fingerprint") is moot twice
  over: fixed (`:255`), then Stage R was deleted outright on 2026-07-30
  (`:66`, `:68-69`). Verified — `objkey.nim`/`objcache.nim`/`cacheworker.nim`
  are absent and `captureFirstVersionLine`/`captureToolchainCcVersion` exist
  nowhere in `src/` or `tests/`. Recorded because the standing order is to mark
  closed bullets, and here the correct action is to mark none.
- **Docs that become factually wrong:** `0004.md:87`, `:238`, `:249`;
  `0004.handoff:13`, `:132`; `0005.md:21`, `:56`, `:389`, `:485`;
  `0006.md:239`; `0006.handoff:74`, `:76`. House style is to amend the RFC
  IN PLACE with a dated/round tag (no separate-addendum precedent exists) and
  log the change in the paired `*.handoff.md`.
- **`render.nim`**: `splitFirstPipe`'s doc comment states the cc/ldd shape and
  `renderCcVersionLines` labels the second segment `ldd:`. Both move in slice 4.
  The split logic itself is unaffected (`#` is not `|`).

### Slices — 9 (4a/4b split out of the planned 4), all 9 done

Measured fingerprints after slices 4b and 6, both real, both from the production
accessor (`cachedCcVersion`, no seam injected):

```
windows (MSVC container) : Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64|kernel32+libcmt+libucrt+libvcruntime+oldnames+uuid #0d8cab78a8b5d998
linux   (nim:2.2.10)     : cc (SUSE Linux) 16.2.0 #b0dd4cd034d13600|ldd (GNU libc) 2.43 #542b390a4be6deb6
```

Both halves now identify something real on both platforms. `libucrt` in the
Windows one is the library that a cl-banner-only fix would have left invisible.
The Linux digest is the real `libc.so.6` content, so a distro backport
invalidates where it previously could not -- and it is BYTE-IDENTICAL to the
value slice 4a produced, so 4b caused no POSIX drift.

**Probe cost, measured.** Windows 193-242 ms for the whole `cachedCcVersion()`
(five driver candidates, plus a `vccexe` compile-and-link of a trivial TU, plus
hashing six `.lib` files); Linux 9 ms. Once per host process, memoised after
(second call: 0 us). Never in `measureworker`. The Windows cost is the price of
asking the linker instead of guessing, and guessing was measured to be wrong --
see below.

| # | Behaviour | RED | State |
|---|---|---|---|
| **1** | **Tracer.** `cachedCcVersion()` — real accessor, real runner, no seam — names this host's actual C toolchain | MSVC container: `ccHalf was <cc-unavailable>` | **DONE** |
| 2 | An MSVC host and a mingw host key apart, neither the all-sentinel constant | Linux, compile error: `ccVersion` had no candidates parameter | **DONE** |
| 3 | Banner survives a merged capture with the usage line first, and a localized banner | **NO GENUINE RED — see below** | **DONE (pin)** |
| **4a** | **POSIX runtime half becomes a content fingerprint.** Two libc builds reporting the same `ldd` version key apart. **Closes the Linux hole.** `render`'s second label moved `ldd:` -> `runtime:` in the same slice | Linux, compile error: no `BinHashProc` | **DONE** |
| 5 | Degradation ladder + path-independence | — | **ABSORBED into 4a** for the POSIX arm (see below); 4b carries its own |
| **4b** | **MSVC runtime arm**: trivial TU + `/VERBOSE:LIB`, hash every library the linker searched. Replaced `rpNone` in `WindowsCcProfile` and removed that enum arm; retired `LddSentinel` with it. **Closes the Windows hole.** | MSVC container: `runtime half = <ldd-unavailable>` | **DONE** |
| **6** | **cc half gains the driver-binary content hash.** Two gcc builds reporting the same version key apart. POSIX only -- see the asymmetry note below | Linux: both new tests failed, the fingerprint had no driver digest | **DONE** |
| **7** | **`test_ccprobe.nim`'s POSIX gate narrowed** to the three suites that touch the real environment; the tracer wired into the windows CI leg (`LddSentinel` already retired in 4b) | MSVC container: `test_ccprobe: skipped (POSIX shell/binaries)` -- zero assertions | **DONE** |
| **8** | **Docs/spec.** RFC-0004 amended in place at component 4, the cache-key default and the A2-pre line; RFC-0005 (×4), RFC-0006 and four handoffs corrected | — (docs slice, no test) | **DONE** |

**Slice 3 had no genuine RED, and that is worth recording.** Slice 1 over-built:
its GREEN only needed the banner extracted, and cl happens to flush stderr
first in the container, so a positional first-line rule would have passed.
`versionLine`'s content-selection was written then. Slice 3's tests therefore
passed on their first run. Rather than fake a RED, the tests were checked for
SENSITIVITY: `versionLine` was temporarily reverted to a first-line rule and
all three failed, the third most usefully — two different toolsets both
fingerprinted as `usage: cl [ option... ]|<ldd-unavailable>`. Then restored.
They are pins, not driven behaviour; treat them as such.

**What slice 4a absorbed from 5.** `test_ccprobe.nim` now pins: cc-fails
(runtime survives on text alone), ldd-missing (musl / Windows-hosted gcc — the
artifact is still resolved and hashed, so the fingerprint still moves when the
runtime BYTES move), nothing-answers (`<cc-unavailable>|<runtime-unidentified>`,
stable and non-empty), and path-independence (same content at
`/usr/lib64/...` and `/nix/store/...` gives the same fingerprint — what
RFC-0005's shared-cache argument needs).

**Sentinels now mean two things, and no longer three.** `RuntimeSentinel =
"<runtime-unidentified>"` (nothing identified the runtime at all) and
`FileHashSentinel = "<artifact-unreadable>"` (named but unreadable -- which is
what a musl host produces, since gcc ECHOES THE NAME BACK from
`-print-file-name=` with rc 0). `LddSentinel` was a third, meaning "this
platform has no runtime probe"; slice 4b gave Windows one and retired it. A
value that means "we did not look" is indistinguishable, inside a soundness
key, from two hosts genuinely agreeing -- which is the entire defect of this
issue, in one constant.

**What slice 4b measured, and what it invalidated.** Three things were measured
in the container before a line was written, and two of them changed the design:

- `link /nologo /VERBOSE:LIB` with **no input object fails at LNK1561 (entry
  point must be defined) and names no library at all**. The trivial translation
  unit is mandatory, not a convenience.
- `vccexe /nologo <tu> /link /VERBOSE:LIB` compiles AND links in one process,
  exit 0. This is the invocation, not `cl` + `link`: those two are on PATH only
  inside a Developer Command Prompt, while `vccexe` is Nim's own wrapper and
  sits beside `nim`.
- The search list **repeats once per resolution pass** (three passes for the
  probe's TU, the last one truncated). How many passes the linker makes is a
  property of the program being linked, so folding the repeats would make the
  fingerprint depend on crisol's own probe. Dedup is load-bearing.

**Slice 4b's unit tests were pins too, and were checked for sensitivity.** Like
slice 3, all five passed on their first run -- the implementation was written
against the measured trace. So four deliberate breaks were applied to
`ccprobe.nim` in turn, each run through the suite, then reverted:

| break | caught by |
|---|---|
| dedup removed from `parseVerboseLibPaths` | "named, once each" (+ the path and localization tests) |
| the full path used as the entry name | "the library PATHS never reach the fingerprint" |
| lines matched on the literal `"Searching "` | "a localized linker still yields its libraries" |
| the fold chains the name but not the digest | "two SDKs differing only in libucrt.lib CONTENT key apart" |

The first sweep **failed to catch the dedup break**: a second dedup inside
`msvcRuntimeIdentity` masked the first, so the test was pinning the wrong one.
The entry-level dedup was removed -- `parseVerboseLibPaths` is now the single
place duplicates collapse, which is also where the cost lives, since dedup is
what stops six multi-megabyte `.lib` files being hashed three times each. The
break is caught now. Worth remembering: a redundant guard does not make a
system safer, it makes a test lie.

**Slice 6 narrowed its own scope, deliberately — read this before slice 8.**
The plan said "cc half gains the driver-binary content hash". It does, on
POSIX. The Windows profile keeps `cdVersionOnly`, and that is a decision, not
an omission:

- Windows has **no canonical driver**. Which candidates answer depends on the
  shell -- `cl` is on PATH only inside a Developer Command Prompt, `vccexe`
  always -- and those are two different binaries for one toolchain. Banner-text
  dedup is exactly what keeps both launches on one key; a per-driver hash would
  split them, and a spurious miss on every shell switch is a cost RFC-0005's
  shared cache cannot carry.
- **Nothing is lost.** The gap the hash closes on POSIX is a rebuild that moves
  no version string. cl's banner carries a full build number (`19.44.35228`)
  that moves with every toolset patch, and the Windows RUNTIME half already
  content-hashes the `.lib` files the linker consumes. The bytes that matter
  are keyed either way.

It is recorded on `WindowsCcProfile` in the source, and RFC-0004's amendment
(slice 8) must state it rather than claiming both halves are hashed on both
platforms.

**Test churn is sanctioned, not incidental.** Suites 1-3 of
`test_ccprobe.nim` pinned the OLD spec (`<cc>|<ldd>`) and were migrated to the
new shape through a single `expectFp(cc, runtimeLabel, digest)` helper -- twice
now, once for each half -- so each shape change is visible in one place
instead of smeared across twenty string literals. 34 tests green on Linux (`test_ccprobe`), 3 in the integration tracer
(2 on Windows, the third POSIX-gated); `test_render` 81, `test_nimprobe` 18,
`test_artifactid` 36, `test_issue16_unit` 13, `test_keys` and the ioutils
ownership test green; `src/crisol.nim` compiles on both platforms.

**Slice 7 found a test that was skipping INVISIBLY, which is worse than one
that fails.** `tests/unit/test_ccprobe.nim` sat inside a single file-wide `when
defined(posix)` whose `else` branch printed `test_ccprobe: skipped (POSIX
shell/binaries)` -- not the `CRISOL-SKIP: <path>` marker that
`ci/assert-subset-honesty.sh` audits. So it was absent from that script's
pinned `EXPECTED_SKIP` set for the windows leg, absent from
`tests/conformance/test_rfc9_bucket_inventory.nim`'s B2/B3b buckets, and
absent from every other list in the repo (`grep -rn test_ccprobe` outside the
file itself returns NOTHING). The honesty gate that exists precisely to catch
"a load-bearing test silently starts skipping" could not see it, because the
file never claimed to be skipping in the vocabulary the gate reads. Two suites
whose entire subject is how a WINDOWS toolchain keys ran only on Linux.

The gate is now narrow, and the file is ordered by it: everything sealed behind
seams sits above the line and runs on both platforms; below `when
defined(posix)` sit the only three suites that touch the real environment --
**3f**, which needs a `cc` that actually resolves on PATH (the driver is found
with `findExe`, which no seam intercepts, so on a host without `cc` both sides
of its key-apart assertion degrade to `FileHashSentinel` and the test would
fail for the wrong reason), and **4**/**5**, which run binaries at absolute
POSIX paths to pin process-spawning behaviour. Windows went **0 -> 26**
assertions; Linux holds at **34**, the difference being exactly those three
suites (2 + 4 + 2).

`driverDigestFor` is what makes the synthetic suites platform-neutral: it
COMPUTES the expected driver digest from `resolveDriver("cc")` rather than
assuming one, so the same test states the same fact on a host with a `cc` and
on a host without. That helper was written in slice 6 for its own reasons; it
is the reason slice 7 was a gate move and not a rewrite.

**Sensitivity check -- the narrowing is load-bearing, measured.** `ccIdentity`
was temporarily changed to hash the driver's BARE NAME instead of
`resolveDriver(...)`'s resolved path. On Linux the suite reported **34 OK, 0
FAILED**: the fake hash seam returns a digest for any non-empty string, and
`cc` resolves there, so the defect is structurally invisible. On Windows the
same build failed **6 tests, exit 1**, because `cc` does not resolve there and
the expected value correctly degrades while the actual one does not. A whole
defect class -- "a path that is only ever empty on Windows" -- had no CI
producer before this slice. Restored; both legs green again.

**The tracer is wired into the windows leg as a per-file step**, for the same
reason #22's two capture tests are: this leg's suite step sweeps
`tests/unit:tests/conformance`, and `tests/integration/` is out of scope.
The Linux `test` job needs no change -- `crisol.nimble`'s default dir list is
`["tests/unit", "tests/integration", "tests/conformance"]`, so the tracer has
always run there. YAML note: the step `name:` contains `#`, so it is quoted.

**Slice 8 amended the RFC in place, and kept the wrong sentences.**
RFC-0004 is a closed RFC, and the house style for changing one is RFC-0009's
(`0009-path-identity.md:144`, `:506`): keep the original sentence and append a
bracketed, dated amendment. That is deliberately not a rewrite — the original
`cc --version` first line ⊕ `ldd --version` first line` text is the audit trail
of what was actually specified and built in A2-pre, and deleting it would erase
the evidence that the soundness argument had a hole rather than record that it
was closed. Three points in `0004-incremental-hermetic-execution.md`: **component
4** of the `KeyInputs` fold (the substantive amendment — both halves, the
POSIX-only driver-hash decision, the retired `LddSentinel`, the measured
fingerprints and probe cost, and the no-migration argument), the **cache-key
resolved default** at `:238` (the input-equivalence-class argument is untouched:
what is hashed is the TOOLCHAIN's bytes, not the produced binary's), and the
**A2-pre slice line** at `:249`.

Corrected elsewhere, each because it asserted something now false:

| where | was | now |
|---|---|---|
| `0005:21` | cross-host soundness rests on `nimVersion`'s binary hash; cc is a version string | `ccVersion` is content-hashed too; the "same toolchain *binaries*" claim no longer rests on the operator pinning an image |
| `0005:56` | "`ccVersion` is the cc/ldd fingerprint" | cc-driver + link-time-runtime fingerprint; host-independence now established (path-independence is pinned by test) rather than assumed |
| `0005:389` | "(ccprobe.nim — no binary hash)" — the asymmetry recorded DELIBERATELY, plus `ldd:` as a render label | asymmetry closed; label moved `ldd:` → `runtime:`, since the segment no longer names a program |
| `0005:485` | "the same cc + libc. Pin the toolchain image." | enforced by the key, not advised; pinning is how you GET a hit, not what makes one sound |
| `0006:239` | "probes cc+libc via version *strings*" | text ⊕ content hash — but the parenthetical survives and is the load-bearing part: it hashes toolchain ARTIFACTS, still not header content, so the explicit `cc -M` closure stays necessary in the key |
| `0004.handoff:13`, `:132` | A2-pre's "sentinels for missing cc/ldd", 13 tests | seam set, sentinel set and test count all superseded |
| `0006.handoff:74`, `:76` | nimcache cleared on "cc/ldd version change" | same rule, sharper trigger — a same-version toolchain rebuild now moves the fingerprint, so strictly more clearing, never less |
| `0009.handoff:41` | `ccprobe` listed as a gcc/Make-shaped POSIX hazard | partially closed: the identity probe dispatches on `CcProbeProfile`; the `cc -M` half is untouched and is **#21's** subject |

**Two things slice 8 deliberately did NOT touch.**

- **`0006.handoff:237` (review-ledger R2)** says the objcache key omits the libc
  fingerprint and cites `ccprobe.ccVersion` folding `cc|ldd`. That sentence is
  now false about `ccprobe`, but the finding is a dated record of a review on
  2026-07-29, and its subject — `runCompileCacheWorker` / Stage R — was REMOVED
  in `33a0459` (`grep -rn captureFirstVersionLine src/ tests/` returns nothing).
  Editing a historical review ledger to match today's code rewrites the record
  instead of correcting a spec. R1–R5 are all moot for the same reason, and the
  file already carries a CLOSED banner over Stage R.
- **The RFC-0007 addendum** recording the `/Zs`-dominance, stream-routing and
  locale findings is **still owed, and is #21's**. Its scope was fixed when this
  workstream was spun out; #23's findings are RFC-0004/0005/0006 material and
  landed there. Writing #21's addendum now would be documenting a capability
  that does not exist yet.

No `✅ <evidence>` bullets were appended anywhere: nothing #23 built closes an
open leftover-work bullet in any `docs/rfc/` file. The one candidate was R2
above, which is moot rather than fixed.

### Surfaces

`src/crisol/ccprobe.nim` (the only substantial production file),
`src/crisol/render.nim` (two labels), `src/crisol/nimprobe.nim` (slice-4
refactor), `tests/unit/test_ccprobe.nim`, `tests/unit/test_render.nim`,
`tests/integration/test_issue23_cc_identity.nim` (new),
`.github/workflows/ci.yml`; and in slice 8 `docs/rfc/0004-incremental-hermetic-execution.md`, `docs/rfc/0005-distributed-cache-and-trust.md`, `docs/rfc/0006-cross-entrypoint-compile-reuse.md` and the `0004`, `0006`, `0007` and `0009` handoffs.

---

## #21 — DONE in code, all slices, uncommitted (a5c verdict is CI-only; see `### Remaining`)

### Progress, 2026-09-21

**The issue's premise was incomplete.** #21's description says the gap is
`deriveCcMInvocation` being GNU-only. That gap is real, but it was
UNREACHABLE: crisol died on MSVC nimcaches two stages earlier, and each layer
was only visible once the one above it was fixed. Found by running
`tests/integration/test_issue16_headers.nim` (which drives the real
`crisol run` / `crisol closure --json` entry points and asserts
`"native/add.h" in closureSet`) inside `ghcr.io/coreyleavitt/nim:2.2.10-windows`
— it had never run on Windows, because the windows CI leg's bulk step sweeps
only `tests/unit:tests/conformance` and this file is an integration test.
Four gcc-isms in a chain:

| layer | site | symptom under vcc | state |
|---|---|---|---|
| 1 | `closure.moduleMangledNameOf`, `closure.externalMangledNameOf` — both hardcoded `.o` | EVERY link entry (module objects included) fell through to `flkTupleCompile` and RAISED; closure empty, record invalidated every run | **slice 1a, done** |
| 1' | `runner.bustStaleExternalObjects` — `endsWith(".o")` | rule 2 busted NOTHING, so a header-only edit relinked the stale object | **slice 1a, done** |
| 2 | `closure.ccCmdOutputObj` — recognised only `-o <obj>`/`-o<obj>`, vcc spells it `/Fo<obj>` | no `compile` entry was ever paired with its `link` object, so every external looked cache-served and `extractCompileInputs` failed closed | **slice 1b, done** |
| 3 | `ccprobe.deriveCcMInvocation` — GNU `-M` derivation | the originally-scoped bug | **slice 1b, done** |
| 4 | make-rule parser vs `/sourceDependencies` JSON | ditto | **slice 1b, done** |
| 5 | `paths.matchRoots` — case-SENSITIVE root membership | `/sourceDependencies` lowercases every path, so under any mixed-case project root every MSVC header classifies `pcOutside` and is dropped | **slice 1c, done** |

**Slice 1a — the object extension belongs to the toolchain that PRODUCED the
nimcache.** `closure.ObjectExtensions = [".o", ".obj"]` plus `objectExtOf` /
`hasObjectExt*`; both decoders split the object extension from the backend
extension instead of matching `".nim.c.o"` wholesale. Accepted unconditionally
rather than switched on `defined(vcc)` or the host, for the same reason the dep
family is read from the manifest: a gcc-built crisol must resolve a cl-produced
nimcache. Neither spelling is a suffix of the other, so order is irrelevant.
Tests: `test_closure_warm.nim` (+2, a real vcc-shaped `link` array),
`test_issue16_unit.nim` (+2, `isModuleObjectName`).

**Slice 1b — family-aware dependency probing.** New in `ccprobe.nim`:
`CcFamily` (`ccfGnuMake`/`ccfMsvc`), `DepProbeError`, `MsvcDrivers`,
`ccFamilyOfDriver` (basename, case-folded, `.exe` stripped — never
`defined(vcc)`), `deriveDepInvocation` (renamed from `deriveCcMInvocation`,
returns the family), `parseMsvcSourceDeps`, `depIncludeHeaders` (renamed from
`ccIncludeHeaders`, dispatches and returns a `DepProbeError`). The MSVC arm is
a PURE PREPEND of `/Zs /sourceDependencies-` with zero removals — `/Zs`
dominates `/c` and `/Fo<obj>`, so the object is never rewritten as a side
effect. `closure.extractCompileInputs` and `artifactid.ccIncludeClosure` both
consume the new API and turn a `DepProbeError` into a loud failure;
`artifactid` re-exports the renamed pair.

**Measured, in-container, through crisol's own code** (project at `C:\p`, so no
case mismatch): `vccexe.exe /Zs /sourceDependencies- /c --platform:amd64 ...`
returns `add.c` + the JSON document; `c:\p\native\add.h` classifies
`pcTracked`, the six MSVC system headers `pcOutside`. Through the real CLI:
`"closure":["native/add.c","native/add.h","tests/test_cadd.nim"]`. **The
mechanism works.**

**Green:** Linux/gcc, all 10 suites touched — `test_closure_warm` 7,
`test_issue16_unit` 16, `test_artifactid` 36, `test_ccprobe` 34,
`test_rfc9_f13_externals_portability` 2, `test_depgraph_guard` 30,
`test_issue16_headers` 6, `test_artifactid_real` 2, `test_closure` 10, 0
failures. The GNU path is unchanged.

### Fork A — RESOLVED (Corey, 2026-09-21): `paths.classify` root membership is case-sensitive

`matchRoots` (`src/crisol/paths.nim:526`) decides root membership with
`underRoot`, a component-boundary but **case-sensitive** string prefix test.
The fold policy is attached to the resulting `TrackedPath` AFTERWARDS
(`fold: roots.project.foldPolicy`) and applied to the relative tail for
identity — it never reaches the membership decision. `classify`'s own doc says
it "folds for SELECTION identity"; for the membership half, it does not.

Measured both ways in the container, same project, same code:

- project root `C:\p` (case-trivially equal to cl's lowercased output) →
  `c:\p\native\add.h` → `pcTracked`, closure correct.
- project root `C:\Users\ContainerAdministrator\AppData\Local\Temp\p5` →
  `c:\users\containeradministrator\appdata\local\temp\p5\native\add.h`
  → `pcOutside`, header silently dropped. `foldPolicy` reports `asciiLower`
  in both runs.

This is NOT MSVC-specific — any tool that reports a differently-cased path hits
it — but `/sourceDependencies` makes it total, because it lowercases
unconditionally. It is also the SAME CLASS as the RFC-0009 wiring-audit F18
hole (an 8.3 short-name candidate under a long-form root landing `pcOutside`),
which was fixed inside `classify` as a gated fallback.

**Decision: fix it properly — and the first-proposed fix was WRONG.**

The obvious move, folding the operands inside `matchRoots`, would have been a
soundness bug, caught by reading two invariants rather than by a test:

- `paths.nim:61` — `TrackedPath.rel` is documented **real-case**; it is "the
  STORED identity field".
- `paths.nim:289` — `keyBytes` is "Canonical, **UNFOLDED** cache-key bytes …
  keyBytes == rel".

`==`/`hash` fold on the fly, so folding only the membership test LOOKS fine —
equality still holds. But the `rel` sliced out of cl's lowercased candidate
would be lowercase, and `rel` IS the cache-key material. A cl-populated
closure and a gcc-populated one would then produce different `headersHash`,
different closure hashes and different cache keys for byte-identical files.
Because equality folds, that divergence would never surface as a failed
comparison — only as a permanent cross-host cache MISS. It would have been
caught, eventually and confusingly, by `test_rfc9_a5c_cache_portability.nim`,
one of #21's own four acceptance tests.

**What slice 1c actually does.** The candidate is RESOLVED to its real on-disk
spelling and the UNCHANGED case-sensitive `underRoot` decides, so `rel` comes
out real-case by construction. `matchRoots` and `underRoot` are not touched at
all. Concretely, `classify`'s existing F18 fallback trigger widens from
`plausibly8Dot3` to `plausibly8Dot3 or foldMatchesSomeRoot` — 8.3 was only
ONE SPELLING of "a non-canonical spelling of a real tracked file", and case is
the same defect. `winRealPath` (`GetFinalPathNameByHandleW`) already returns
the true case, and already resolves 8.3 and reparse points as a side effect.

`foldMatchesSomeRoot` is a FILTER over whether to pay for that resolution,
never the identity decision. It is allocation-free (`underRootFolded` compares
byte-by-byte under the root's policy and short-circuits at the first
difference — `c:/msvc/...` vs `c:/users/...` parts at index 3), because it
runs on every classify MISS and misses are the common case: every system
header, every stdlib path. A root probed `fpNone` is skipped entirely — there
two casings ARE two files, and rescuing one into the other would be the
soundness bug this is avoiding.

Recorded as an in-place amendment on RFC-0009's "8.3 short names / junctions"
accepted-risk bullet, in RFC-0009's own bracketed-dated house style. The
bullet's premise — "nothing crisol reads emits a non-canonical spelling" —
was true of git-diff and `walkDir` and false of a C compiler; the junction
half is unchanged and still accepted. The F18 row in
`0009-path-identity-review.md` is a DATED review record and was deliberately
left alone (same reasoning as #23 slice 8 and `0006.handoff:237`).

Tests: `tests/unit/test_paths.nim` +6 (`classify — F18 candidate-side CASE
expansion`), including the two negative controls that matter — a
genuinely-outside candidate never invokes the expander, and an `fpNone` root
never rescues.

### The tracer is GREEN — the load-bearing property, proven end to end

`tests/integration/test_issue16_headers.nim`, in
`ghcr.io/coreyleavitt/nim:2.2.10-windows` under real `cc = vcc`, **6/6 OK,
exit 0** — driven through the real `crisol run` and `crisol closure --json`
entry points, not a hand-built fixture:

```
[OK] native/add.h appears in the closure after a full run; every closure path is root-relative
[OK] editing only the header selects the includer under --changed --dry-run
[OK] T3: a header-only edit flips the probe's outcome on the next full run
[OK] T4: a header-only edit is busted even with a warm nimcache and no depgraph record
[OK] T5: an unchanged second run neither recompiles nor busts the external's object
[OK] T6: a carried-forward header record still busts correctly after a warm module-only recompile
```

T5's own `base.endsWith(".o")` external-object scan was `.o`-only and now uses
`closure.hasObjectExt` — a test-side Windows blindness, fixed with the rest.

**This file is now a per-file step on the windows CI leg** (`ci.yml`,
alongside #22's and #23's). Its absence there is the single reason four
stacked gcc-isms survived unnoticed: it lives in `tests/integration/`, and the
bulk sweep step covers only `tests/unit:tests/conformance`. Every one of the
four failed SILENTLY rather than erroring, so no other step could have caught
them.

### Slice 2 — loud failure, and one production fix the tests forced

`tests/unit/test_ccprobe.nim` +15 (49 OK total), `tests/unit/
test_issue16_unit.nim` +1 (17 OK total). Covers: banner-only stdout is
`dpeNoJson`; a truncated / `Data`-less / `Includes`-less / non-string-element
document is diagnosed precisely; **an EMPTY `Includes` array is a real answer,
not a failure** (the distinction `/showIncludes` cannot express); the document
is located by CONTENT so extra banner lines do not shift the parse; the GNU
arm is unchanged; `ccFamilyOfDriver` classification (`.exe`, casing, absolute
driver path, and `clang` NOT being `clang-cl`); and `deriveDepInvocation`'s
pure-prepend-vs-strip split. At the closure boundary, a probe that exits 0
with no document raises `CrisolError(cekEnvironment)` naming both the source
and `dpeNoJson`.

**The tests forced a parser change, and it was the right one.** The locator
originally required a line that IS exactly `{`. Written that way, a document
present but COMPACT (one line) reports `dpeNoJson` — "the probe did not run" —
which is a misdiagnosis, not merely a stricter check: the whole point of
`DepProbeError` is to tell "no document" apart from "a document of the wrong
shape", and a locator that collapses the second into the first defeats the
enum. Relaxed to "the first line whose first non-blank character is `{`". cl's
banner is a source FILENAME and cannot begin with `{`, so nothing is given up.

### Slice 3 — acceptance, on the real MSVC leg

Run in `ghcr.io/coreyleavitt/nim:2.2.10-windows` with
`CRISOL_EXPECT_FOLD=fpAsciiLower`:

| test | result |
|---|---|
| `test_windows_cli_smoke.nim` | **2/2 OK** — including "`--changed` selects only the entrypoint whose closure member changed (case-variant spelling)" |
| `test_rfc9_a3bii_fold_selection.nim` | **1/1 OK** — real body, dependent selected via folded closure membership |
| `test_rfc9_a4b_determinism.nim` | **1/1 OK** — the recorded spelling is on-disk real case for both importers, cold and warm |
| `test_rfc9_a5c_cache_portability.nim` | **SKIPPED locally — verdict is CI-only** |

**a5c is not claimed.** It self-skips with "symlink creation failed in this
environment: Access is denied" — Windows containers run without
`SeCreateSymbolicLinkPrivilege`. Confirmed NOT a bind-mount artifact (it skips
identically from a container-local checkout). `windows-latest` has the
privilege (`ci/assert-subset-honesty.sh` carries `EXPECTED_SKIP_TEST=""` for
that leg and lists a5c as must-execute), so its verdict lands on CI — exactly
the CI-paced definition-of-done RFC-0009 records for windows-runtime-only
slices. Memory `[[windows-latest-no-symlink-privilege]]` covers the same
ground.

Also confirmed, as the caveat already in this doc predicted: **there are no
vcc self-skips to remove.** `grep -rn "defined(vcc)" tests/ src/` is empty and
the windows `EXPECTED_SKIP` list names none of the four. #21's acceptance is
"make them pass", not "remove gates".

### Slice 4 — docs

- **RFC-0007 gained its long-owed addendum**, "Addendum — MSVC toolchain
  findings (issues #21/#22/#23)": stream routing is a property of the tool AND
  the question (cl splits by MESSAGE, not severity — with the measured
  three-row table, and why that forces TWO `RunProc` implementations rather
  than one widened type); a tool that cannot answer still exits 0; `/Zs`
  dominance and the object-rewrite side effect it removes; locale; and why
  Windows capture is not POSIX capture with different paths.
- **RFC-0009's "8.3 short names / junctions" accepted-risk bullet amended in
  place**, bracketed-dated, keeping the original sentence (see fork A above).
- RFC-0007 and RFC-0009 handoff pointers updated. The RFC-0009 pointer's
  standing claim that "nothing here changes RFC-0009's recorded decisions" is
  explicitly corrected rather than left silently false.

### Remaining

- **Nothing in code.** The load-bearing property is green end-to-end under
  real MSVC; slices 1a/1b/1c/2/3/4 are done.
- `test_rfc9_a5c_cache_portability.nim`'s real-body verdict, which only a
  windows CI leg can give (above).
- **Everything is UNCOMMITTED**, #23's nine slices included.

### Measured: what a driver that cannot answer actually does

`ghcr.io/coreyleavitt/nim:2.2.10-windows`, cl 19.44.35228:

```
vccexe.exe /Zs --platform:amd64 /nologo /Qzzzbogus unit.c
  rc     = 0
  stdout = "unit.c\n"
  stderr = "cl : Command line warning D9002 : ignoring unknown option '/Qzzzbogus'"
```

rc is **zero** and stdout is a bare banner, so `ranOk` is true and nothing in
the run's own result says anything went wrong; `realRunIn` captures stdout
only, so the D9002 never reaches crisol. The STRUCTURAL absence of the
document is therefore the only available signal, which is exactly why it must
be the thing that fails the probe — and why `/showIncludes`, which cannot
distinguish "no report" from "no includes", was the wrong mechanism.

(Note: `/sourceDependenciesNOPE` is NOT a way to test this — cl reads it as
"write the document to a file named NOPE", so it exits 0 with an empty stderr
and no stdout document for an entirely different reason.)

### Original notes (AFTER #23)

### Decided (Corey, 2026-09-20): `/Zs /sourceDependencies-` JSON, NOT `/showIncludes`

Every claim below is measured against cl 19.44 in the MSVC container, not
assumed.

- **`/Zs` DOMINATES `/c` and `/Fo<obj>`** — no `.obj`, no `.pdb`, no `.idb` is
  written even with both left in place. So the MSVC derivation is a **pure
  prepend of two flags with ZERO removals**: a stronger form of the module's
  replicate-don't-allow-list rule than the GNU arm manages, since `-M` does not
  suppress `-c`.
- **JSON is locale-proof** — no localized prefix to detect. `/showIncludes`'s
  `Note: including file:` prefix is localized, which is why CMake ships a
  prefix-detection probe.
- **Paths arrive fully canonicalized and quote-delimited** —
  `./inc/../inc/deep.h` → `c:\poc\inc\deep.h`, and a header path containing a
  space survives. `/showIncludes` echoes the directive's literal spelling with
  mixed separators (`C:\poc\inc/top.h`, `C:\poc\./inc/../inc/deep.h`).
- **Absent JSON is structurally distinguishable from an empty include list**, so
  "the probe silently returned nothing" becomes unrepresentable. `/showIncludes`
  cannot give that.
- **cl's command-line diagnostics go to stderr**, not stdout, so stdout is
  exactly `<banner>\n<pretty JSON>` and the document starts at the first line
  that is `{`.
- **Cost:** needs cl ≥ 19.27 (VS2019 16.7). An older cl warns on stderr
  (`D9002 ignoring unknown option`) and emits no JSON, which the JSON-absence
  check turns into a loud, specific failure.
- **Caveat:** `/sourceDependencies` lowercases paths. A no-op under Windows'
  usual `fpAsciiLower` fold; under a case-sensitive-flagged directory (`fpNone`)
  it breaks and fails closed at the header content-hash read. `/showIncludes` is
  no better there — its spelling is the directive text, not the on-disk name.

### What is broken today

The current GNU derivation under vcc does **not** fail — it succeeds with
garbage. `deriveCcMInvocation` strips `-c` and `-o`, but the vcc manifest spells
them `/c` and `/Fo<obj>`:

```
vccexe.exe /c --platform:amd64 /nologo /IC:\nim\...\lib /IC:\poc /nologo /FoC:\poc\nc\@munit.c.obj C:\poc\unit.c
```

so both survive. cl answers `D9002 ignoring unknown option '-M'` on **stderr**
(uncaptured), exits **0**, prints only its source-name banner on stdout, and
`ccIncludeHeaders` parses that banner into a single bogus entry. Silently wrong,
never an error — and the surviving `/c` + `/Fo` mean the probe **rewrites the
nimcache object** as a side effect.

### POC — green, 9/9 units, 0 failures

Replayed a real `cc:vcc` nimcache manifest through the family-aware derivation
with #22's drain-loop reader:

```
OK family=ccfMsvc unit.c                  headers=13  (project=4 system=9)
      [project] c:\poc\inc\top.h
      [project] c:\poc\inc\sub\mid.h
      [project] c:\poc\inc\deep.h
      [project] c:\poc\a file with space.h
OK family=ccfMsvc @pstd@sexitprocs.nim.c  headers=234
OK family=ccfMsvc @psystem.nim.c          headers=240
units=9 failures=0
```

Three-level nesting, a space in a header path, and a 240-header ~15 KB
multi-chunk report all handled; system headers separate cleanly and are dropped
by `index.tracked` as before.

**POC artifacts** live in the session scratchpad
(`…/scratchpad/poc/{depadapter,driver,isolate1..4}.nim` plus a C fixture tree
with nested, spaced and mixed-case headers). They are throwaway — the shapes
worth keeping are reproduced here. `depadapter.nim` lifts into `ccprobe.nim`
close to as-is.

### Design

- **cc family is classified from the MANIFEST's own driver token** (`cl`,
  `vccexe`, `clang-cl`), never `defined(vcc)`: a gcc-built crisol can read a
  cl-produced nimcache, and the classification is per compile unit.
- `deriveCcMInvocation` → `deriveDepInvocation`, returning the family alongside
  cmd/args/sourceFile.
- MSVC arm: `@["/Zs", "/sourceDependencies-"] & toks[1..^1]` — verbatim replay,
  nothing removed.
- Parser: locate the first line that is `{`, `parseJson`, require
  `Data.Includes` to be an array of strings. Anything else is a LOUD failure,
  never an empty header set.
- `clang-cl` classifies as MSVC-style but does **not** support
  `/sourceDependencies`; the JSON-absence check tells the truth there. Confirm
  nothing in crisol claims clang-cl support before shipping.

### Acceptance (from the issue)

Four tests run their real bodies and pass on the windows MSVC leg:
`tests/conformance/test_windows_cli_smoke.nim` (`--changed` suites),
`test_rfc9_a3bii_fold_selection.nim`, `test_rfc9_a4b_determinism.nim`,
`test_rfc9_a5c_cache_portability.nim`. Remove the interim vcc-gated self-skips,
including the MUST-EXECUTE / EXPECTED_SKIP accounting in
`ci/assert-subset-honesty.sh`.

**Note:** as of 2026-09-20 those vcc self-skips are **not in the tree yet** —
`grep -rn "defined(vcc)" tests/ src/` returns nothing, and
`ci/assert-subset-honesty.sh`'s windows `EXPECTED_SKIP` list does not mention
them. The issue describes them as interim state; either they were never landed
or they live on an unmerged branch. Check before planning their removal.

### Recorded fixtures wanted

Real `/sourceDependencies` JSON captured as fixtures for the parser unit tests,
per the ccprobe test convention — including an older-cl (no-JSON) shape so the
loud-failure path has a pin.

---

## Open forks awaiting Corey

**This section is a pointer. The live list is `## Open for Corey`, at the end of
this file.**

It used to hold the list itself, and by round 5 every item in it was settled
while the text still read as blocking: "Commit #22 ... nothing else should start
until this lands" (#22 is `DONE, COMMITTED` at `9219670`, per the Stage table at
the top of this file), "#23's plan needs approval before any code" (#23 is
`DONE, 9/9 slices`), the libc sentinel question (decided against in slices
4a/4b), and the RFC-0007 addendum (written). Round 5 found it and rated it the
round's second-highest finding, because `CLAUDE.md` tells the next session to
re-read this doc before continuing, and a top-down reader reaches these
stop-work orders roughly 1300 lines before the list that supersedes them.

Why it survived four rounds of review that each audited this doc: it carried no
finding id and no status cell, so it appeared in no round's table and in no
closed list. That is the same failure mode the project already named — progress
lives in a table's status column, and a row in neither list vanishes — applied
to a whole section rather than a row. The round-1 wiring audit had already
flagged it ("this doc contradicts itself in ways that would send the next
session to redo settled work") and nothing acted on it, because that flag was
prose too.

The one item here that was never settled is the environment fact, and it has a
real home: `## Environment — read this before running anything` records the
podman networking breakage and the `--network=none` workaround.

## Cross-references

- Issues: [#21](https://github.com/coreyleavitt/crisol/issues/21),
  [#22](https://github.com/coreyleavitt/crisol/issues/22),
  [#23](https://github.com/coreyleavitt/crisol/issues/23).
  #21 carries a long comment with the full POC results and the mechanism
  decision; #22's body was corrected after the Windows-only finding.
- `docs/rfc/0007-execution-substrate.handoff.md` — MSVC shakeout chain, sello
  ct-barrier history, toolchain-parity migration.
- `docs/rfc/0009-path-identity.handoff.md` — fold policy, `TrackedPath`,
  `classify`; owns three of #21's four acceptance tests.

---

## Wiring audit — 2026-09-21 (`/wiring-audit #21-23`)

Three read-only lenses (selection path / soundness key / CI-and-claims), then
each finding above the noise floor re-verified against the code by hand. **The
verdict on the contract is at the bottom.** Nothing here is a deletion
candidate; every row is a connection that is missing or a claim that stopped
being true.

**Load-bearing property, as stated for the audit:** a `{.compile.}`d C source's
`#include`d header is a tracked closure member and drives `--changed`
selection, under real `cc = vcc`, through the real `crisol run` /
`crisol closure --json` entry points — with a soundness key that keys an MSVC
toolchain apart from a mingw-gcc one.

### BLOCKING — the load-bearing property is not yet proven

**W1. `classify`'s case expansion fires only when the ROOT PREFIX mis-cases; a
mis-cased relative TAIL is claimed directly and STORED as the identity.**
Kind 2 -> 7. `paths.nim:651-652` returns on `matchRoots`' direct hit before the
F18 trigger at `:654` is ever evaluated. `underRoot` (`:435-441`) is
case-sensitive on the root prefix only and slices the tail **verbatim** into
`rel`; `underRootFolded` (`:539-551`) likewise iterates `for i in 0 ..< rl`
over the *root* length, so neither the direct match nor the trigger ever
examines the tail. `/sourceDependencies` lowercases **every** component, so on
any root whose absolute path already case-matches — `C:\workspace` in the MSVC
container, `D:\a\crisol\crisol` on `windows-latest`, any lowercase clone — a
tracked header actually named `native/Add.h` is a direct hit and `rel` is
stored as `native/add.h`. That violates `paths.nim:61` (`rel` is real-case,
"the STORED identity field") and `:289` (`keyBytes == rel`, UNFOLDED), so
`headersHash`, the closure hash, key component 1 and `closure --json`'s wire
output all diverge between a cl-populated and a gcc-populated closure for
byte-identical files — and because `==`/`hash` fold (`:250`, `:256`), it
surfaces only as a permanent cross-toolchain cache MISS. **This is verbatim
the soundness failure Fork A says slice 1c was designed to avoid.** 1c closed
the root half.

*Not MSVC-only:* gcc/clang `-M` echo the `#include` directive's literal
spelling, so `#include "Add.h"` against on-disk `add.h` has the same shape on
any case-insensitive volume — including **macOS/APFS**, a shipping leg, where
`osQueryFoldPolicy` answers `fpAsciiLower` (`paths.nim:953-960`). The GNU arm
needs the capability 1c built and does not get it.

*Why the tracer is green anyway:* both measured container runs use the
all-lowercase tail `native/add.h`. `tests/unit/test_paths.nim:484` pins the gap
open — "an exactly-cased candidate still never invokes the expander (direct
match wins first)", with an input exactly-cased in *both* halves, so it asserts
the optimisation without distinguishing "tail verified" from "tail assumed".

*Recommend:* resolve eagerly at the dep-probe boundary rather than via a
miss-triggered fallback — the seam already exists (`classify`'s
`expandCandidate: CandidateExpander`). Route header candidates through
`safeExpandFilename` at `closure.nim:1621-1626` before `index.tracked`, or give
`classify` an explicit `spelling: csCanonical | csUntrusted` so the probe
boundary opts into resolution while `buildSourceIndex`'s walk (real-case by
construction, `closure.nim:325-340`) keeps the lexical hot path. Header sets
are tens of paths per external, not the thousands `SourceIndex` classifies.
`matchRoots`/`underRoot` still stay untouched and `rel` still comes out
real-case by construction. Then add the missing vector — exact root, mis-cased
tail — and revise `:484` so "direct match wins" is asserted only where the tail
is also verified.

**W2. Nothing asserts the windows leg is actually on the vcc backend.**
Kind 3. `ci.yml:315` appends `cc = vcc` to the fetched toolchain's
`config/nim.cfg`; the very next step is *named* "Toolchain sanity (patched
build, **vcc backend**)" (`:318`) and its body greps `nim --version` for
`2.2.10` and nothing else. Exhaustive: `grep -rn "defined(vcc)" src/ tests/`
returns four hits, all prose in doc comments; `vcc` appears in `ci.yml` only at
that `printf` and that step name. Because every MSVC capability in this
workstream dispatches on **runtime** facts (`ccFamilyOfDriver`,
`ObjectExtensions`, `foldMatchesSomeRoot`) — the right design — a leg that
silently reverted to mingw-gcc would take the GNU arm everywhere and **pass
every test green, proving nothing**: `test_issue16_headers` would exercise
`ccfGnuMake`, `test_issue23_cc_identity`'s cc half would find `gcc`, and
`classify`'s new branch would never fire. The sole CI producer for each of #21
and #23 is load-bearing on a premise nothing checks. No live override was found
(root `nim.cfg` carries only `--path:`; `src/crisol.nim.cfg` only
`--define:ssl`; no `--cc:` on any command line), so the append most likely
works today — but `fetch-nim-toolchain.sh:54`'s `find -maxdepth 2 -name bin |
head -1` plus the caller's `tail -1` is exactly the path derivation that drifts
silently on an artifact-layout change.

*Recommend:* in the existing sanity step, `grep -c 'cc = vcc'` the appended
config, and compile a one-liner that hard-fails off-vcc:
`when not defined(vcc): {.error: "windows leg is NOT on the vcc backend".}`.

### HIGH — soundness, in the under-invalidation direction

**W3. `planner.decideCompile` is blind to the C toolchain; its `nimVersion`
sibling is wired.** Kind 2, with a kind-1 tell. `planner.nim:192-197` takes
`nimVersion` and no `ccVersion`; `:230` returns `cdStale` on
`graph.header.nimVersion != nimVersion` with no cc equivalent.
`DepGraphHeader` (`depgraph.nim:249-252`) stores `nimVersion`,
`formatVersion`, `roots` — no cc field — so `DepGraphDiscardKind`
(`depgraph.nim:317-321`) has `dgdNimVersion` and no analog, and `loadDepGraph`
cannot discard on a cc change. Upgrade the C toolchain without changing Nim and
`decideCompile` returns `cdSkipFresh`: the stable binary linked by the **old**
cc is re-run, and the toolchain-keyed nimcache #23 makes correct is never
consulted. The soundness key *does* move, so the run misses and executes live —
and then `shouldStore` (`cachedispatch.nim:611-651`) publishes that pass under
the **new** toolchain's key, whose evidence is the old toolchain's binary. A
peer on the shared L2 then skips execution entirely.
`tests/integration/test_nimcache_persistence_real.nim:207-211` documents the
gap in a comment and works around it with `forceCompile = true`, calling the
compile-skip decision "orthogonal". Compounding: `clean.cleanOrphans` prunes
`cache/` against the toolchain-fingerprinted slug set and `bin/` against the
bare one (`clean.nim:191-193`), so `crisol clean` deletes the old nimcache and
keeps its binary.

*Recommend:* add `ccVersion` to `DepGraphHeader`, a `dgdCcVersion` arm, and a
step-4b cc check in `decideCompile`, threaded from `pipeline.nim:114` /
`planner.nim:284` where `ccVer` is already in hand; make the `bin/` prune
toolchain-aware.

**W4. The degradation ladder has no consumer.** Kind 4. `CcSentinel`
(`ccprobe.nim:82`), `RuntimeSentinel` (`:84`) and `FileHashSentinel` (`:94`)
are all genuinely produced (`:497`, `:545`, `:600`, `:259-265`), and
`LddSentinel` is confirmed gone with "no runtime probe" made unrepresentable
(no `rpNone` arm). But no production consumer reads or branches on any of them:
`keys.nim:215` folds the string, `render.nim:442-444` prints it,
`planner.nim:120` hashes it. On a host where nothing answers, the fingerprint
folds to the constant `<cc-unavailable>|<runtime-unidentified>` — structurally
the same constant-folding defect #23 was opened to kill, narrowed to a broken
host — and `shouldStore` publishes under it.

*Recommend:* one consumer. Minimal — after `api.nim:1863`, if both halves are
sentinels, `warnStderr` (precedent at `:869-875`). Stronger — a
`cdmToolchainUnidentified` decision refusing the publish, on
`cdmHermeticityDeg`'s principle.

### MEDIUM — partial consumer sets on fixes recorded as landed

**W5. Three silent-skip holes the honesty gate cannot see, one of them slice
7's own subject.** Kind 3/5. `tests/unit/test_ccprobe.nim:505` is a bare `when
defined(posix):` with no `else:` and no marker, and `:801` prints "All ccprobe
tests passed." — so slice 7 fixed the *zero-assertions* half of its stated
diagnosis (Windows 0 -> 26) and left the *invisible-to-the-gate* half open,
which was the half that let the defect survive. Same shape, previously
unreported: `tests/unit/test_memprobe.nim:523-525` (bespoke line, no marker,
skips on **both** swept legs) and `tests/unit/test_rfc0007_b2_fd_leak.nim:23`
(`when defined(linux):`, no else, and its `when isMainModule: echo "... done"`
at `:71` sits at column 0 **outside** the gate — zero assertions, prints
`done`). Plus ~20 unmarked per-test skips where the convention is established
(`test_source_index.nim` x8, `test_paths.nim:290`/`:312`,
`test_fold_probe_tiers.nim` x8 plus a linux-gated suite). Convention:
`test_depgraph.nim:323`, `test_discover.nim:350`,
`test_windows_cli_smoke.nim:146`. `EXPECTED_SKIP_TEST=""` on both legs, so the
gate reports OK. Note `test_paths.nim:312` is the `classify` dep-root vector —
the machinery W1 is about.

**W6. `StoredEntry.keyInputs` is written on every store and read by nothing.**
Kind 5 + 3. Producers at `cachedispatch.nim:920` and `cachewire.nim:513`;
`grep -rn keyInputs src/` is 18 hits — all producers, type decl, codecs and
comments, **zero readers**. `RFC-0005:391` declares *"a backfill-on-hit seeds
the local sidecar from it — so a fresh host's next miss on that path is
explainable"*, and `:574` ticks B1b with "seeded on backfill". The sidecar is
written at exactly one place (`cachedispatch.nim:938-940`), gated on a local
**store**; the backfill path (`cachetier.nim:265`) decodes `keyInputs` and
drops it. So the one miss the mechanism was built to explain is the
cross-toolchain miss #23 exists to *create*, and `--explain-miss` says "no
prior inputs recorded" instead of naming the toolchain.

*Recommend:* in `realSeams`' `load`, on a hit with `keyInputs.isSome` and a
local root, `writeSidecar` — the same call `:940` already makes.

**W7. `renderCcVersionLines` has no `#`-digest arm, and `test_render.nim` pins
it shut.** Kind 1/5. `renderNimVersionLine` (`render.nim:409-424`) splits on
the last `|` and, when only the hash moved, prints "compiler binary differs".
`renderCcVersionLines` (`:425-450`) splits on the first `|` and prints each
half verbatim; nothing in `src/` splits on `#`. So a distro gcc rebuild at an
unchanged version string now correctly misses, and `--explain-miss` renders two
visually identical strings differing in one 16-hex tail. `RFC-0005:389`'s
slice-8 amendment *declares* the behaviour ("a changed hash with an unchanged
banner means exactly what it means for `kcNimVersion`"). The `git diff` shows
slice 4a changed **only the label string** in two fixtures: the suite is still
titled "(accurate two-segment shape, **NOT a binary hash**)", all five fixtures
are still the pre-#23 `cc (GCC) 12.2.0|ldd (GNU libc) 2.36` shape with no `#`
anywhere, and `check "compiler binary differs" notin l` (`:697`) survives — the
test actively pins shut the arm the RFC now claims exists.

**W8. `parseCcMDeps` still uses `splitWhitespace()`.** Kind 2/3.
`ccprobe.nim:866`, inside the GNU arm — the exact defect `shellSplit` exists to
prevent, one proc over, per its own doc ("a whitespace-containing path … would
otherwise silently corrupt a naive `splitWhitespace()` derivation instead of
failing loudly"). GNU `-M` escapes a space as a backslash-space, so
`inc/a\ file.h` shatters into two fragments, both classify `pcOutside`, both
are dropped: silent under-selection. The MSVC arm handles this correctly by
construction (measured: "a header path containing a space survives"; the POC
lists `[project] c:\poc\a file with space.h`), so the two arms of
`depIncludeHeaders` now disagree on a property its doc says they share.

**W9-W18, condensed.** `drainBoth`'s `errOutput` is captured and discarded at
`ccprobe.nim:156`, so the D9002-on-stderr blindness this doc documents is now a
*plumbing* gap rather than a capture gap — an old `cl` yields `dpeNoJson` and a
driver name, never the driver's own words (`closure.nim:1606-1610`).
`hasObjectExt` reached one of three test-side nimcache scans;
`test_compiledriver_real.nim:55` (`walkFiles("*.o")`) and
`test_closure_searchpath.nim:286`/`:588`/`:645` (`endsWith("dep.nim.c.o")`) are
still `.o`-only, and the latter is the only producer for the `@m`-mangled
dep-object shape. `artifactid.ccIncludeClosure`, slice 1b's second consumer, is
reachable only through off-by-default `--measure-compile-reuse`
(`measureworker.nim:173`), has **no MSVC test at all**, and collapses every
`DepProbeError` arm to a bare `ok=false` while printing "cc -M include-closure
probe failed" even for a `/sourceDependencies` failure. A5c has no MSVC
producer and its property is substituted from macOS, which has no `cl` and
cannot produce a mis-cased candidate — and A5c is the test Fork A names as the
detector for W1's class, so **the substitution removes exactly the net W1 would
fall into**. `shellSplit`'s backslash arm is gated on `defined(windows)` — the
*reader's* host — violating the manifest-not-host rule 1a/1b were built on, so
a POSIX crisol reading a cl manifest eats `/FoC:\p\nc\x.obj` into
`/FoC:pncx.obj` and reproduces layer 2 on the mirror host. `ccprobe.nim:63`'s
"true leaf (std-only imports)" is false (it imports `crisol/toolexec` and
`crisol/fnv`) and `nimprobe.nim:71` still imports `crisol/depgraph`, so
"slice 4's refactor fixes that direction too" (`:414-417`) is stale — this is
the cost open-fork 3 predicted for the path 4a/4b took, and it landed
(`toolexec` itself IS genuinely std-only; that claim holds). "The 9-component
key pins stay untouched" (`:427-429`) — `keys.soundnessKey` folds **10**,
numbered in source, since r57 added `cwdPosture`; slice 8 verified six pins as
*untouched* rather than as *correct*, so the audit trail now carries a dated
confirmation of a stale number. `CRISOL_EXPECT_FOLD` is on the windows
*per-file* a3bii step (`:491`) and the macos *bulk* step (`:649`) but not the
windows bulk step, so the only log the gate reads shows A3b-ii's weaker mode 3.
The gate structurally cannot read any pinned integration step — `harness.log`
comes from the bulk step alone — so a per-file test that starts *skipping*
rather than failing exits 0 green. `parseMsvcSourceDeps` extracts `Data.Source`
and no consumer reads it, discarding the one available stale-document
cross-check. `compiledriver.defaultRunCc:248` passes `poStdErrToStdOut` beside
`poParentStreams`, where osproc ignores it — a declared merge that does not
happen. The measurement streams (`ArtifactRow`, `CompileCostRow`) carry no
toolchain column, so `--measure-compile-reuse` aggregates across a cc upgrade
and a slower cc reads as a code regression. `foldMatchesSomeRoot` asks
`== fpAsciiLower` where `narrow.anyRootFolds:214` asks `!= fpNone`; equivalent
today, and the day a third `FoldPolicy` arm lands, W1's trigger goes silently
dead.

### W-audit status table — added round 5 (R5-13)

The audit above tracked ~21 findings as bold-lead prose, and the thirteen in the
`W9-W18, condensed.` paragraph as a single blob in which most statements carry no
id at all. Round 5 recorded that as R5-13: with no status column, a row's
disposition lived only in a prose list somewhere else, and **the document used two
incompatible numbering schemes for the same findings** — letters (`W9a`…`W9m`,
thirteen of them, which is what the closure list used) and numbers (`W9`…`W18`,
ten of them, which is what `W12` and `W18` are cited by in the prose). Neither
scheme is defined anywhere. `W9d` is referenced by nothing; `W12` and `W18` are
cited but never introduced.

**This table is authoritative from round 5 onward.** Statements are numbered in
the order they appear in the condensed paragraph above.

| # | Finding (condensed paragraph, in order) | Also cited as | Status |
|---|---|---|---|
| W9.1 | `drainBoth`'s `errOutput` captured and discarded at `ccprobe.nim`, so D9002-on-stderr blindness is a plumbing gap, not a capture gap | W9a | closed (round 1) |
| W9.2 | `hasObjectExt` reached one of three test-side nimcache scans; two remain `.o`-only, one of them the only `@m`-mangled dep-object producer | W9b | closed (round 1) |
| W9.3 | `artifactid.ccIncludeClosure` reachable only via off-by-default `--measure-compile-reuse`, no MSVC test, all `DepProbeError` arms collapsed to bare `ok=false` | W9c | **ESCALATED — with Corey.** Sharpened by R3-9; see `## Open for Corey` |
| W9.4 | A5c has no MSVC producer and its property is substituted from macOS, which has no `cl` — removing exactly the net W1's class would fall into | **W12** | open — carried; the W1 fix (round 1) closed the trigger, not the detector |
| W9.5 | `shellSplit`'s backslash arm gated on `defined(windows)` — the *reader's* host — violating the manifest-not-host rule | W9e | deferred (Low, per mandate) |
| W9.6 | `ccprobe.nim`'s "true leaf (std-only imports)" claim false; `nimprobe.nim` still imports `crisol/depgraph` | W9f | closed (round 1) |
| W9.7 | "the 9-component key pins stay untouched" — `keys.soundnessKey` folds **10** since r57 added `cwdPosture`; slice 8 verified six pins as untouched rather than correct | W9g | closed (round 1) |
| W9.8 | `CRISOL_EXPECT_FOLD` set on the windows per-file and macos bulk steps but not the windows bulk step — the only log the gate reads shows the weaker mode | W9h | closed (round 1) |
| W9.9 | the honesty gate structurally cannot read any pinned integration step (`harness.log` comes from the bulk step alone), so a per-file test that starts *skipping* exits 0 green | **W18** | closed (round 1) |
| W9.10 | `parseMsvcSourceDeps` extracts `Data.Source` and no consumer reads it, discarding the available stale-document cross-check | W9i | closed (round 1) |
| W9.11 | `compiledriver.defaultRunCc` passes `poStdErrToStdOut` beside `poParentStreams`, where osproc ignores it — a declared merge that does not happen | W9j | closed (round 1) |
| W9.12 | `ArtifactRow`/`CompileCostRow` carry no toolchain column, so `--measure-compile-reuse` aggregates across a cc upgrade and a slower cc reads as a code regression | W9k | closed (round 1) |
| W9.13 | `foldMatchesSomeRoot` asks `== fpAsciiLower` where `narrow.anyRootFolds` asks `!= fpNone` — equivalent today, silently dead the day a third `FoldPolicy` arm lands | W9l / W9m | closed (round 1) |

And the numbered leads above the paragraph:

| # | Finding | Status |
|---|---|---|
| W1 | `classify`'s case expansion fires only on a mis-cased ROOT PREFIX; a mis-cased relative TAIL is claimed and stored as the identity | **fixed** (round 1, uncommitted) — see "W1 and W2 — FIXED" |
| W2 | nothing asserts the windows leg is actually on the vcc backend | **fixed** (round 1, uncommitted) |
| W3 | `planner.decideCompile` blind to the C toolchain | fixed — core + production wiring. **Note:** R3-8 later deleted `decideCompile`'s staleness arms as unreachable; the live mechanism is `loadDepGraph`'s discard. See the R2-3 supersession note |
| W4 | the degradation ladder has no consumer | fixed — landed **stronger** than recommended (`toolchainUnsound` fires on *either* half) |
| W5a-W5d | three silent-skip holes the honesty gate cannot see | all four closed (round 1) |
| W6 | `StoredEntry.keyInputs` written on every store, read by nothing | closed (round 1) |
| W7 | `renderCcVersionLines` has no `#`-digest arm, and `test_render.nim` pins the gap | closed (round 1) |
| W8 | `parseCcMDeps` still uses `splitWhitespace()` | closed (round 1) |

**Provenance of the status column, stated because it is reconstructed rather than
recorded.** Until round 5 these dispositions existed only in a prose list in the
round-1 section, which read verbatim:

> **Closed — carried-over rows:** W3 (core + production wiring), W4, W5a, W5b,
> W5c, W5d, W6, W7, W8, W9a, W9b, W9f, W9g, W9h, W9i, W9j, W9k, W9l, W9m.
> **Still open:** CR7, CR8, CR10 (design rows), CR16-CR18 (Low, deferred by the
> mandate), W9c (escalated — see below).

That list is the source for every `closed (round 1)` cell above. It named letters
and no statements, so the letter→statement mapping in the "Also cited as" column
is **inferred from order** and is not independently verifiable — except for
`W9c`, `W9e`, `W12` and `W18`, which the prose anchors to specific statements by
description. Two things follow, and a later round should not mistake either for
certainty: the letters may be off by one somewhere in the middle of the list, and
`W9d` corresponds to nothing in the letter scheme because the item it should
name is cited as `W12` instead. `W9.4`/`W12` is the one substantive row the old
list left in neither category — which is what R5-13 meant by "a row in neither
list vanishes", demonstrated on a finding about a *missing detector for a
blocking defect*.

**Doc-state findings.** This doc contradicts itself in ways that would send the
next session to redo settled work: the Resume block says `Remaining: slices
2-5` and "Still owed … the RFC-0007 addendum" while `### Remaining` says
"Nothing in code" and slice 4 says the addendum is written (as does
`0007.handoff:5`); forks 1, 2, 3 and 5 are all stale and two of them are
*blocking* instructions ("Nothing else should start until this lands", "needs
approval before any code"); fork 3 recommends the sentinel that 4a/4b
deliberately did not take; `## #23 — NEXT` still heads a DONE section; "the six
slices" vs 9. Fork 4 (`./dev`/podman) is the only live one. Slice 8's edits
themselves were audited claim-by-claim against the code and **check out**,
including the POSIX-only driver-hash asymmetry being stated rather than papered
over; `0006.handoff:237` and the F18 review row were confirmed untouched as
intended.

**Inter-lens disagreement, resolved by reading the code.** One lens filed
`icbaseline` as an unwired capability (kind 5); another found the module's own
header declares *"It is NOT wired into the production compile path"*. Both
halves are true: it is honestly declared, so it is not a wiring defect — but it
absorbed one of #22's five `toolexec` rewires, so that hardening protects
nothing, and its `nim c` argv omits `-d:nimBetterRun` (so any nimcache it
produced would make `analyzeManifest` raise). Low severity either way.

### Verdict on the contract

**NOT COMPLETE — do not proceed to `/code-review`.** The tracer is genuinely
green end to end under real MSVC, and that is real: layers 1-4 of the gcc-ism
chain are fixed and proven. But layer 5 — the case defect — is closed only for
a mis-cased **root prefix**, and the property's own stored identity field is
still the probe's lowercased spelling whenever the root case-matches, which is
the configuration both the container and `windows-latest` run in (W1). The one
CI producer that would notice rests on a vcc premise nothing asserts (W2), and
the acceptance test Fork A names as the detector for exactly W1's failure class
has no MSVC producer at all (W12). W1 and W2 are blocking; W3 and W4 are
soundness defects in the under-invalidation direction and should land in the
same pass. Return the list to `/tdd`.

### W1 and W2 — FIXED, 2026-09-21 (uncommitted)

Both blocking findings are closed. The verdict above is superseded on those
two rows only; W3, W4 and W5-W18 are untouched and still stand.

**W1 — `classify` now decides membership on a RESOLVED spelling when the
candidate's provenance is a foreign tool.**

New `paths.CandidateSpelling` (`csTrusted` / `csReported`) is a property of
the CANDIDATE, never of the host or the toolchain — the same rule
`closure.ObjectExtensions` and `ccprobe.ccFamilyOfDriver` already follow.
`classify` gained it as its third parameter (defaulting to `csTrusted`, so
`SourceIndex`'s thousands-per-run walk keeps the purely lexical hot path),
and for `csReported` the existing F18 expansion now runs BEFORE `matchRoots`
instead of as a fallback after it. The predicate is unchanged
(`plausibly8Dot3 or foldMatchesSomeRoot`), so a genuinely-foreign path still
reaches no disk and an `fpNone` root still never rescues a mis-cased
candidate. `matchRoots` and `underRoot` remain untouched, and `rel` still
comes out real-case by construction.

The producer is wired in the same change: `closure.extractCompileInputs`'
header loop passes `csReported` (`closure.nim`, the `index.tracked(habs,
csReported)` call), which is the one place a C compiler's dependency report
crosses into identity. `closure.tracked` carries the parameter through.

Extracted `matchExpanded` so the resolve-and-rematch step exists once rather
than twice; a `csReported` candidate that it cannot rescue does not re-run
the old fallback, because that would be a second identical `none`.

*Proof, end to end, through the real entry points.* The tracer
`tests/integration/test_issue16_headers.nim` gained
`native/AddMixed.h` — the fixture's only header whose on-disk case differs
from what `/sourceDependencies` reports (`add.h` is already all-lowercase,
which is exactly why the original six tests could not see the tail half) —
and a test that drives `crisol run` + `crisol closure --json` with the config
path spelled in LOWERCASE. That reproduces `windows-latest`'s own shape
(`D:\a\crisol\crisol`, all lowercase) on any host: same directory, a root
`abs` that case-matches cl's output exactly, so the direct match wins and the
tail is all that can differ. The container's mixed-case `getTempDir()` had
been MASKING the defect by making the prefix mismatch and the fallback fire.

- RED, `ghcr.io/coreyleavitt/nim:2.2.10-windows`, real `cc = vcc`:
  `closureSet was @["native/add.c", "native/add.h", "native/addmixed.h",
  "tests/test_cadd.nim"]` — cl's lowercased spelling stored as the identity.
  Other 6 tests green.
- GREEN, same container: **7/7 OK, exit 0.**

*Unit coverage and the pin that was holding the gap open.*
`tests/unit/test_paths.nim`'s F18 CASE suite moved to `csReported` (the 8.3
suite stays `csTrusted`, which proves the hot path is unchanged). The test
that read "an exactly-cased candidate still never invokes the expander
(direct match wins first)" — whose input was exactly-cased in BOTH halves, so
it asserted the optimisation without distinguishing "tail verified" from
"tail assumed" — is replaced by three: the W1 vector (exact root, mis-cased
tail), the `csTrusted` zero-cost guarantee, and an explicit statement of the
cost this fix accepts (a `csReported` exactly-cased candidate pays one
resolution, counted).

*Sensitivity, measured.* With the `csReported` arm forced off, the suite
reports **4 FAILED / exit 1** — the W1 vector, both pre-existing 1c vectors,
and the resolution-count test. Restored, green.

**W2 — the windows leg now asserts it is on the vcc backend.**

New `tests/conformance/test_cc_backend.nim` reports the backend Nim actually
selected and turns that into a HARD assertion when `CRISOL_EXPECT_CC` is set
— the repo's existing `CRISOL_EXPECT_FOLD` idiom, not a new invention. It
lives in `tests/conformance/` rather than in a shell step precisely so it
runs inside the `ci/run-tests.sh` sweep whose log
`ci/assert-subset-honesty.sh` audits; a bare CI-step check would sit outside
the honesty regime, which is the structural gap this audit recorded as W18.

Verified that `setCC` defines the backend symbol from a CONFIG FILE and not
only from `--cc:` — that is the mechanism actually under test, since CI
appends `cc = vcc` to the fetched toolchain's `config/nim.cfg`:

| run | result |
|---|---|
| linux image, unpinned | `CRISOL-CC-BACKEND: gcc`, OK |
| linux image, `CRISOL_EXPECT_CC=vcc` | **FAILED, exit 1**, "but this build used gcc" |
| linux image, `CRISOL_EXPECT_CC=gcc` | OK |
| MSVC container, `CRISOL_EXPECT_CC=vcc` | `CRISOL-CC-BACKEND: vcc`, OK |

Wired at two points in `ci.yml`, deliberately: an early per-file step right
after `Toolchain sanity` (fails in seconds rather than after twenty-odd steps
of misleading green; imports only std, so it needs no deps and runs before
`Fetch vendored deps`), and `CRISOL_EXPECT_CC: vcc` on the B4b bulk step,
whose output is the only one that reaches `harness.log`. The install step
additionally `grep -q`s the appended config, so the mechanical half
(`fetch-nim-toolchain.sh`'s `find … | head -1` plus this caller's `tail -1`
drifting on an artifact-layout change) fails with its own message.

**Regression sweep.** Linux, all 160 files under `tests/unit` +
`tests/conformance`: **158 pass, 2 fail** — `test_api.nim` and
`test_fallback.nim`, the two this doc already documents as local-only. Both
were re-run at pristine HEAD with the W1 changes stashed and **fail there
too**, so they are not this change's. `src/crisol.nim` compiles.
`test_paths.nim` 93 OK on Linux / 92 on Windows (the delta is the one
POSIX-gated symlink vector). `test_closure_warm` 7, `test_issue16_unit` 17,
`test_discover` 37, `test_artifactid` 36, `test_B4_quarantine_per_test` 14,
`test_depgraph` PASS — all 0 failures.

**Not done here, deliberately.** W7 (`CRISOL_EXPECT_FOLD` missing from the
windows BULK step, so the log the gate reads takes A3b-ii's weaker mode 3) is
a one-line addition to the very `env:` block W2 just touched. It was written
and then reverted, because the approved scope was W1+W2 and widening it is
not this session's call. It is the cheapest remaining row in the ledger.

**Still uncommitted**, with everything else in this workstream. New untracked
file: `tests/conformance/test_cc_backend.nim`.

---

## Code review — 2026-09-21 (`/code-review #21-23`)

Six reviewers (correctness, cross-platform/toolchain, security, design, liveness,
test-coverage/honesty) over the whole workstream: the uncommitted #21/#23 tree
plus #22's code as committed at `9219670`. Five adversarial verifiers then tried
to **refute** every Critical/High and every claim resting on a checkable fact.
Wiring precondition satisfied: `/wiring-audit #21-23` ran the same day; W1/W2
fixed, W3-W18 re-verified here rather than re-derived.

Session base sha: `630ecc6`. Status values: open | fixed | deferred | wontfix |
refuted. Verified = an adversarial verifier confirmed with a concrete trigger.

### New findings

| id | sev | file | finding | status | verdict |
|---|---|---|---|---|---|
| CR1 | High | `ccprobe.nim:308-320` | `libPathIn` anchors on a drive letter and falls back to drop-first-word. A UNC library path has no drive letter; on a locale whose `/VERBOSE:LIB` verb phrase is 2+ words (the repo's own `LocalizedTrace` fixture proves such locales exist) the fallback leaves a garbage leading token, `readFile` fails, and **every** entry degrades to `FileHashSentinel`. `libBasename` still recovers the name, and the fold chains name+digest — so two genuinely different toolchains sharing the standard `.lib` basename set fold to an **identical fingerprint**. Under-invalidation: the exact defect class #23 exists to kill, surviving in the one path shape the locale-proofing never covered. English+UNC is fine; the trigger is locale AND UNC. | **fixed** | CONFIRMED |
| CR2 | Med | `closure.nim:1632`, `ci.yml:672,716` | The W1 fix's `csReported` arm is toolchain-generic, but only MSVC has an end-to-end producer. The sole mismatch-manufacturing fixture (`test_issue16_headers.nim`, on-disk `native/AddMixed.h`) relies on cl's lowercasing; gcc/clang echo the `#include` literal. The one leg that could trigger the gcc arm — macOS/APFS — pins `CRISOL_TEST_DIRS: tests/unit:tests/conformance`, excluding `tests/integration/`, and has no per-file step for it. Linux is ext4/`fpNone`, structurally inert. *Precision:* the `classify`/`csReported` logic itself IS unit-proven on every leg (`test_paths.nim:484-522`, fake expander). What is missing is end-to-end proof for the gcc/clang arm. | fixed | CONFIRMED (downgraded) |
| CR3 | Med | `artifactid.nim:300-327` | `ccIncludeClosure` reproduces W1 and the W1 fix structurally cannot reach it. `includeClosureContentHash:297` chains the raw header **path string** into the hash before content, so a mis-cased spelling changes the hash for byte-identical files; the proc takes no `TrackedRoots`/`SourceIndex` (zero matches in the file) so it cannot call `classify` even in principle. *Bounded:* diagnostic-only — `keyHash` reaches `reuseRatios`/`compilereport` and never a cache key or selection decision. Reachable only via `--measure-compile-reuse` (default false; **zero occurrences in `ci.yml`**). Unlike `icbaseline`, the module does not declare the limit. | fixed | CONFIRMED (downgraded) |
| CR4 | Med | `ccprobe.nim:157`, `gitdiff.nim:82` | No deadline on subprocess capture. `drainBoth`'s POSIX arm polls with `-1`, the Windows arm spins, and every caller then `waitForExit()`s with no timeout and never terminates. These two sites run in the **host process during plan-building** (`api.nim:1234`, `api.nim:1863`) — before the Supervisor exists — so a `git` blocked on a credential prompt or a wedged `cc --version` hangs the whole invocation unrecoverably. `tests/support/deadline.nim` already implements the mechanism but is test-only. *Not a #22 regression* — verified absent before `9219670`. `compiledriver.nim`'s two sites are mitigated by the outer `compileTimeoutMs` + tree-kill; drop `icbaseline.nim:89` from the finding, it has **no production caller**. | fixed | CONFIRMED (narrowed) |
| CR5 | Med | `test_ccprobe.nim:72-91` | `driverDigestFor`/`expectFp` compute the expected driver digest by calling `resolveDriver("cc")` — the same unseamed call production makes at `ccprobe.nim:505`. All **13** tests in suites 1-3 are insensitive to a `resolveDriver` regression: 7 cancel out through the shared call, 4 are self-differential, 2 short-circuit before the hash. Two other tests catch only *total* failure (empty resolution -> `FileHashSentinel`), never a wrong-but-nonempty path. No test anywhere fakes PATH or pins a literal driver path. | DROPPED in r1 — dispatched r2 | CONFIRMED |
| CR6 | Med | `test_issue23_cc_identity.nim:103-106` | Bare `skip()` with no `CRISOL-SKIP-TEST` marker, in the proof file for #23 — a fresh instance of the W5 class written by this workstream, in the same change that closes W2. Wired only as a per-file step, whose stdout never reaches `harness.log`, so `assert-subset-honesty.sh` cannot see it either way: one fewer real assertion on Windows, forever, with no trace. The sibling `test_windows_cli_smoke.nim:146` uses the convention correctly. Found independently by two passes. | fixed | CONFIRMED |
| CR7 | Med | `ccprobe.nim` (963 ln) | Two independent subsystems in one file: identity fingerprint (`:1-632`) and dependency probe (`:634-964`), sharing no type or proc. The module doc's cycle-avoidance rationale applies **only** to the dep-probe half, which `closure` needs as a leaf; the identity half's consumers (`crisol.nim:585`, `api.nim:1863`, `keys`, `planner`) never touch `closure` and have no cycle to avoid. #23 grew the identity half ~15 -> ~250 lines while #21 grew the other in parallel. Split `ccidentity.nim` out. | fixed | — |
| CR8 | Med | `ccprobe.nim`, `artifactid.nim:144-148` | Over-export. **8** genuinely unread exports: `versionLine`, `ccIdentity`, `runtimeIdentity`, `realLinkVerbose`, `hostCcProfile`, `MsvcDrivers`, `PosixCcCandidates`, `WindowsCcCandidates` — zero readers in `src/` or `tests/`, including `test_ccprobe.nim`. The module doc's own "Public API" lists only `ccVersion`, `realRun` and the sentinels. Plus **4 dead re-exports** in `artifactid` (`parseMsvcSourceDeps`, `ccFamilyOfDriver`, `CcFamily`, `DepProbeError`) — every importer checked, none uses them; `ccFamilyOfDriver` has real callers but always via a direct `import crisol/ccprobe`. *Corrected from the reviewer's 11:* `RuntimeProbe`, `CcDriverIdentity`, `CcCandidate` are exempt (types of exported `CcProbeProfile` fields). | fixed | PARTIALLY CONFIRMED |
| CR9 | Med | `ccprobe.nim:840-855`, `closure.nim:1220-1230` | The GNU `-o <obj>` / `-o<obj>` predicate is byte-for-byte duplicated — `deriveDepInvocation` to STRIP it, `ccCmdOutputObj` to EXTRACT it — with no shared constant or helper, and no test exercising both against the same `ccCmd`. A divergence is silent, and `closure.nim:1198-1203`'s own comment records that exactly this class of gap silently broke MSVC impact selection once already (#21 layer 2). *Corrected:* the `/Fo` grammar is NOT duplicated — `deriveDepInvocation`'s MSVC arm is a blanket verbatim replay and never mentions `/Fo`. | fixed | PARTIALLY CONFIRMED |
| CR10 | Med | `paths.nim:502,641-642` | `CandidateSpelling`'s `csTrusted` default is right for the hot path and silently wrong at any NEW foreign-tool boundary a future contributor adds. The failure never surfaces as a crash or a comparison mismatch — only as a permanent cross-toolchain cache miss. Getting the one existing producer right already required a dedicated post-hoc audit (W1). **CR3 is a live instance of exactly this.** Carrying provenance in the value (`distinct string ReportedPath` returned by `depIncludeHeaders`) makes "provenance was considered" a compile-time property at zero cost to `csTrusted`. | fixed | — |
| CR11 | Med | `ccprobe.nim:606-618`, `render.nim:392-450` | The fingerprint is a rendered string with an ad-hoc pipe / ` #` / `+` grammar that three consumers must know, one of which (`render`) re-parses it back into components. That re-parse has **already drifted** — it has no `#` arm (W7). A structured `CcFingerprint` consumed as data would remove the class and give the sentinels a compiler-checked home (W4). This is the root cause of W4 and W7, not a separate issue. Registers disagreement with the recorded "keep the pipe shape for `--explain-miss` continuity" call. | fixed | — |
| CR12 | Med | `test_ccprobe.nim:661-673`, `test_issue16_unit.nim` | No committed test puts a **space in a header path** through the MSVC `/sourceDependencies` JSON path, though the handoff measured exactly that (`[project] c:\poc\a file with space.h`) — the fixture died with the scratchpad POC. The GNU arm's equivalent is W8, still open; the two arms' shared claim is untested on both sides. | fixed | — |
| CR13 | Med | `ccprobe.nim:492-494` | The Windows cc-candidate "exits 0 and answers nothing" case is untested. `ccIdentity` treats `ok=true`+empty identically to `ok=false`; POSIX pins this (`test_ccprobe.nim:157`) but `makeMsvcRun`/`makeMingwRun` (`:205-230`) only ever model "not found". The handoff measured this exact shape for a real driver (`rc=0`, bare banner, D9002 on stderr). | fixed | — |
| CR14 | Med | `test_ccprobe.nim`, `test_issue16_unit.nim` | **Zero** MSVC fixtures use CRLF — 0 raw CR bytes and 0 backslash-r escapes across both files. `firstLine`, `versionLine` and `parseVerboseLibPaths` are CRLF-safe by design (`splitLines`+`strip`); `parseMsvcSourceDeps` is CRLF-safe only by **incidental** `parseJson` whitespace tolerance — its `pos += line.len + 1` under-counts one byte per CRLF line, harmless at 1-2 preceding lines and corrupting at >=3 (see CR-X1). Narrowing a trim would regress silently with no test signal. | fixed | CONFIRMED |
| CR15 | Low | `ccprobe.nim:858-867` | `parseCcMDeps` takes `find(':')`, which on a mingw rule (`C:/proj/build/add.o: ...`) matches the **drive-letter** colon, emitting one bogus token (`/proj/build/add.o:`) per invocation. Verified harmless to selection: the real dependency tokens after the target are untouched, and the garbage resolves to nothing and is dropped at `closure.nim:1633`. Cost is a wasted `winRealPath`/`realpath` resolution under `csReported`. Fix alongside W8, which is the same proc. | fixed | CONFIRMED (Low) |
| CR16 | Low | `ccprobe.nim:606` | `ccVersion` takes four seams whose correlation the type does not express: `linkProbe` is consulted only under `rpMsvcLinkVerbose`, yet a caller passing `PosixCcProfile` still receives a live Windows-effecting default — harmless only because the `case` never reaches it. Folding the runtime seam into `CcProbeProfile.runtime` as a variant makes the pairing a compile-time fact. | deferred (Low, per mandate) | — |
| CR17 | Low | `ccprobe.nim:399-407` | `RuntimeProbe`'s arms name the mechanism (`rpPrintFileName`, `rpMsvcLinkVerbose`) while the sibling axis `CcDriverIdentity` names the effect (`cdVersionOnly`, `cdVersionAndBinary`) — inviting a new near-duplicate arm per OS API. | deferred (Low, per mandate) | — |
| CR18 | Low | `ccprobe.nim:145-160,200-237` | The version probes `startProcess` with no explicit `env:`, so a PATH-hijacked `gcc.exe`/`vccexe.exe` receives `CRISOL_CACHE_TOKEN*` (`cacheregistry.nim:69,301-326` — the credential is env-borne, not file-borne). Hygiene only: such an attacker already has code execution via the real `cc`/`nim` invocation. Pass an explicit env without the token. | deferred (Low, per mandate) | — |

### Refuted — recorded, not presented

| id | claim | why it fails |
|---|---|---|
| CR-X1 | `parseMsvcSourceDeps`'s CRLF offset drift misdiagnoses a well-formed document as `dpeBadJson`, which `closure.nim:1612-1616` turns into a hard `CrisolError`. | The arithmetic is wrong. Byte-level simulation: N=1 preceding line -> slice starts at LF+brace, N=2 -> CRLF+brace — both pure whitespace, which `std/json` skips. Corruption first appears at **N>=3**, and real `cl` emits exactly one banner line (diagnostics go to stderr). The downstream raise is real but never reached. Survives only as the latent half of CR14. |
| CR-X2 | The W1 fix goes dark when a root's fold policy degrades to `fpNone`, reproducing W1 on a case-insensitive volume whose probe failed. | Premises all check out — `foldMatchesSomeRoot` does gate on `== fpAsciiLower` (`paths.nim:585`), `plausibly8Dot3` does not rescue a lowercased long path, and `fpNone` IS the probe-failure default (`paths.nim:1463-1467`). But the same failure sets `TrackedRoots.degraded`, which disables the entire persistence pipeline: no `CacheRuntime` is constructed (`api.nim:1725`), the context is forced to `cacheDisabled` (`:1893`), the flush is gated off (`:2004`), and the dep graph is never written (`depgraph.nim:1057`). A mis-cased `rel` can exist in memory but has no path to a persisted `keyBytes`. The state is also surfaced (`jsonout.nim:1028-1033`). |
| CR-X3 | Unbounded `readFile` in `realFileHash`, steered by inherited `LIB`/`LIBRARY_PATH`, is a memory-exhaustion DoS. | Not a boundary crossing: whoever sets `LIB` can already point the real linker at a malicious static lib linked into every binary crisol builds — strictly worse than a DoS. Uncapped `readFile` is the repo-wide convention (`fnv.chainedContentHash:83` does the same over a far larger surface) and no streaming primitive exists to have used. Bounded in practice to the CRT's default-lib set (~6 files, 1-2 MB each), once per process, memoised. |
| CR-X4 | Enumerating 5 Windows driver candidates widens PATH-hijack surface 5x. | crisol's core function is spawning PATH-resolved compilers and test binaries with the parent env copied verbatim; a 5-name bare version query is noise against that. The enumeration is an argued decision (`ccprobe.nim:378-395`, handoff `:361,:463`) that the claim did not engage: first-match-wins is the under-invalidation bug #23 exists to kill. Only the token-inheritance sub-point survives, as CR18. |

### Carried over — wiring-audit rows, re-verified 2026-09-21

All 21 open rows from the `/wiring-audit` section were re-read against today's
tree by a dedicated liveness pass, twice. **No row was refuted; none was found
already fixed.** W1 and W2 were independently re-confirmed as genuinely closed
by their recorded fixes. Two rows gained detail:

- **W9c** is not merely "off by default" — `--measure-compile-reuse` has **zero
  occurrences in `ci.yml`**, so that path never executes in CI on any leg under
  any toolchain. CR3 is a soundness defect living inside it.
- **W9g**'s stale "9-component key" is not only a prior audit's prose: it is
  still live in `docs/rfc/0005-distributed-cache-and-trust.md:511`, while
  `keys.nim:186-229` numbers 10.

W3 and W4 remain the two highest carried-over rows (both soundness, both
under-invalidation). CR11 is the shared root cause of W4 and W7; CR15 shares a
proc with W8; CR6 is a new instance of the W5 class.

### Fix loop — round 1 (2026-09-21, base `630ecc6`)

Mandate approved by Corey: **fix through Medium, leave Low.** Applied to both the
new CR-rows and the carried-over wiring-audit rows above Low. Work delegated to
sonnet subagents on disjoint file sets, serialized where they collided;
`ccprobe.nim` was the contended file throughout and was worked as a single lane.

**Dispositions live in the table's status column above, not here.** This block
used to restate them as three prose lists, and by round 5 it contradicted the
table it summarised: it read `Still open: CR7, CR8, CR10` while all three rows
carry `fixed`, and `Every finding above Low is fixed through round 3` while
`R2-8` and `R3-9` are `BLOCKED` and `R2-7` was `partial`. Round 5 recorded it as
R5-14 and deleted the lists rather than correcting them, because the project
already adopted the rule that makes them a defect: progress lives in the status
column, and a second copy of it drifts silently. The only thing a summary here
can honestly add is the count, so: of this round's rows, the ones NOT closed are
`CR16`-`CR18` (Low, deferred by the mandate) and `W9c` (escalated — see
`## Open for Corey`).

Notable decisions taken inside the loop, recorded because they departed from
what the finding proposed:

- **W4 landed STRONGER than the audit's recommendation.** The trigger is
  `toolchainUnsound` = **either** half `cfsUnavailable`, not both. A single
  degraded half still folds to a fixed sentinel, so a fleet sharing one
  correctly-identified compiler but differing in a silently-failed second probe
  collides on one key — the same poisoning defect, narrowed to one axis and
  likelier to occur, since total blindness gets noticed and a missing `ldd`
  does not. `cdkNone` (a known half with no digest — the Windows
  `cdVersionOnly` profile) explicitly does NOT trip it. Write path only; a
  degraded host still READS the shared cache.
- **CR11 preserved the fold value byte-for-byte.** The structured
  `CcFingerprint` reconstructs the identical serialized string for every probe
  outcome, so no cache entry self-invalidated and no golden pin moved. `keys`,
  `planner`, `depgraph`, `pipeline` and `cachedispatch` needed zero edits.
- **CR3 did NOT unify the two header loops**, on argued grounds:
  `closure.extractCompileInputs` drops headers outside every tracked root,
  while `ccIncludeClosure` must KEEP system headers (RFC-0006's
  `cc -M`-not-`-MM` soundness argument). A genuine semantic fork; the part
  that is shared (`paths.classify`) already has one implementation.
- **W8 was fixed without touching `shellSplit`.** Make-rule escaping is a
  property of GNU make's output, not of shell quoting, so `parseCcMDeps` got
  its own host-independent unescape reversing cpp's `mkdeps.cc make_write_name`
  (N backslashes before a space collapse to `N div 2`, odd/even deciding
  separator-vs-literal). `shellSplit`'s host-gated backslash arm remains W9e's
  subject, untouched and still open as a Low.
- **W5a was fixed differently from the recipe handed over.** The handoff note
  proposed a whole-file `CRISOL-SKIP:` marker; that would have been FALSE — the
  file runs the great majority of its suites on both platforms, and only four
  sit behind the POSIX gate. Per-suite `CRISOL-SKIP-TEST:` markers were used
  instead, pinned on the windows leg only. Telling the gate a convenient lie is
  the defect class, not the fix for it.

### Three defects INTRODUCED and caught inside the fix loop

Recorded deliberately: each is the same shape as the findings the review was
chartered to catch, which is the argument for the re-review round being
load-bearing rather than ceremonial.

| # | what | how it was caught |
|---|---|---|
| L1 | **W3's mechanism landed dark.** The first W3 agent's scope excluded `api.nim`, so `ccVersion` took its `= ""` default on every production path: `decideCompile` compared `"" != ""` and the new staleness check never fired on a real run. Built, unit-tested, green, and completely inert. | The agent reported the gap rather than overreaching. A follow-up wired it end to end, made `buildRunPlan`'s `ccVersion` **required** at the production boundary, and added a liveness test driving the real CLI. |
| L2 | **macOS CI had no `pipefail`.** W9i's fix pipes each pinned per-file step into `tee -a harness.log`. GitHub's implicit non-Windows default is `bash -e {0}` — pipefail is set only by an explicit `shell: bash`. The windows job sets it; the macOS job did not. So the new macOS CR2 step — the SOLE producer proving the gcc/clang arm — would have returned tee's exit code and reported green on failure. | Control loop, reading W9b's passing remark about `PIPESTATUS`. Fixed by adding the `defaults: run: shell: bash` block with the reasoning recorded inline. |
| L3 | **W3's discard message erased half the fingerprint.** `dgdCcVersion` rendered via `sanitizeHeaderField(pipeAware = true)`, which splits on the FINAL `\|` and keeps 12 characters after it — correct for the Nim fingerprint (a bare hash) and destructive for ccVersion, whose tail is the runtime identity. Observed live: `current toolchain is cc (SUSE Linux) 16.2.0 #b0dd4cd034d13600\|390a4be6deb6`, the whole `ldd (GNU libc) 2.43 #542b` half gone — on the one message whose job is to say WHICH half moved. Its doc comment asserted the truncation was "a harmless no-op". | Control loop, reading the failure text of an unrelated test. Fixed with `sanitizeCcFingerprintField` (both halves keep their text, only the digests abbreviate), the false doc claim corrected, and a regression test added. |

**Procedural note for the next session.** Two broad test sweeps run *while*
subagents were editing produced large phantom failure sets (one reported 25).
Both resolved to shared-tree compile races — a missing `case` arm from an
in-flight edit, and a momentarily malformed character literal. **A sweep is only
evidence when the tree is quiescent.** Per-file runs during the loop are fine;
whole-suite verdicts are not.


### CR10 — closed (2026-09-21)

`ReportedPath* = distinct string` now carries a foreign tool's path spelling
from `ccprobe.parseCcMDeps`/`parseMsvcSourceDeps`/`depIncludeHeaders` through
`closure.extractCompileInputs` and `artifactid.resolveReportedHeaderPath`/
`ccIncludeClosure` into the one `classify`/`tracked` overload that resolves it.
It exposes only `len` and a heterogeneous `==` against a trusted `string`; no
`$`, no `&`, no converter. `string(rp)` is the sole, greppable unwrap.

**Decision 6 of the loop — `CandidateSpelling` was COLLAPSED, not kept
alongside.** The review row asked whether the enum should survive next to the
new type; the answer taken was no. `csTrusted`/`csReported` are deleted and
provenance is now decided by OVERLOAD DISPATCH on the argument's type, both
overloads delegating to a private `classifyCore`. Rationale: the whole defect
class here is a soundness argument a caller can default away, and a parameter
that no longer exists cannot be forgotten. Grep confirmed no call site ever
passed `csTrusted` explicitly and only two ever passed `csReported`, so the
removal is a simplification rather than a behavior change. Same pass removed
`ccIncludeClosure`'s `roots: TrackedRoots = TrackedRoots()` default — the same
footgun in miniature, and the third instance of it in this review.

The `==` overload is `string(a) == b`, i.e. case-SENSITIVE, preserving the
prior semantics of `depIncludeHeaders`' `p != sourceFile` exclusion filter
rather than quietly changing it. There is deliberately no
`ReportedPath == ReportedPath`: two unresolved foreign spellings are not
comparable without resolution first.

Verified independently of the agent's report, because `not compiles(...)` is
the classic assertion that passes for the WRONG reason (a typo'd name or wrong
arity makes it vacuously true):
- three of the four seals have explicit positive controls in the same suite —
  `compiles(fromCanonical(string(rp), roots))` etc. — so the expression is
  proven to compile with a `string` and fail only on the distinct type;
- the fourth, `fromCanonical(RootTag(0), rp, roots)`, matches a real overload
  at exactly that arity (`paths.nim:856`), so it too fails on the type alone;
- no `converter` exists anywhere in `paths.nim`.

### Procedural note — the quiescence test was too weak, and it bit twice

The round-1 note said whole-suite verdicts are only evidence on a quiescent
tree. That was right but under-specified: a subagent can send a completion
notification while its OWN background children are still running, and this one
did — its first notification carried an explicit "result may be interim"
warning, and a supplementary 268-file sweep of its own was still live. A sweep
launched on that signal raced it over the shared bind mount and reported a
phantom `FAIL tests/unit/test_api.nim`, which passed standalone at exit code 0
and passed again on the re-run.

**The rule that actually holds:** no whole-suite verdict until `ListAgents`
shows no running subagent AND no background shell of the orchestrator's own is
live. "The agent said completed" is not the same fact.

Second: that agent's own exhaustive verification was `nim check` across 268
files — type-checking only. A runtime regression is structurally invisible to
it. Sweeps in this loop must execute (`nim c -r`), per-entrypoint nimcache.

Quiescent-tree result after CR10: `CRISOL_COMPILES=yes`, **PASS=253 FAIL=1**,
sole failure `tests/unit/test_fallback.nim` on the documented bind-mount fold
assert (`paths.nim(275) a.fold == b.fold` — the Windows mount probes
`fpAsciiLower`, `/tmp` probes `fpNone`), which never fails on CI.

### CR7 + CR8 — closed (2026-09-22)

`ccprobe.nim` (~1600 lines) carried two concerns sharing only the letters
"cc". Split three ways:

| module | lines | concern |
|---|---|---|
| `ccprobe.nim` | 633 | dependency-header probing only — now I/O-free |
| `ccidentity.nim` | 919 | toolchain/runtime identity + fingerprinting |
| `toolrun.nim` | 294 | the shared process-execution seam |

**Decision 7 — the shared seam became its OWN module** rather than staying in
either half. The dependency-probing half is otherwise pure; making it import a
process seam it never calls would have rebuilt the same "shares nothing but a
name" coupling CR7 existed to remove. `ccprobe.nim` dropped its `toolexec` and
`fnv` imports entirely as a consequence — the purity is load-bearing, not
decorative. Corroborating evidence: `nimprobe.nim` had been importing the whole
misleadingly-named `ccprobe` module solely for `RunProc`/`realRun`, and now
imports `toolrun` directly.

**Decision 8 — per-consumer imports over a compatibility re-export**, so a
reader can see which concern each consumer actually needs. Two exceptions kept
deliberately: `closure.nim` and `artifactid.nim` re-export the `toolrun`
symbols because their own downstream callers take the seam unqualified through
them, and removing that would be churn unrelated to this row.

`tests/unit/test_ccprobe.nim` was deliberately NOT split to mirror the source.
One of the four pinned `CRISOL-SKIP-TEST` labels
(`#cc_half_content_fingerprint_realenv`) names an identity-concern suite;
moving it to a new `test_ccidentity.nim` would relocate it out from under its
path pinned in `ci/assert-subset-honesty.sh`, which the fix loop may not edit.
Keeping one physical file with all three imports avoids the conflict. Verified:
all four emitted labels still match the four pinned, and the block is still
last in the file with W5a's banner removal intact.

CR8, re-derived AFTER the split (the boundary moved, so the pre-split list was
not reusable): un-exported `realLinkVerbose`, `hostCcProfile`, `runtimeIdentity`,
`ccFingerprint`, `MsvcDrivers`, `CcCandidate`, `PosixCcCandidates`,
`WindowsCcCandidates`. Kept exported with reasons recorded in their docs:
`LinkProbeProc` (used by `test_ccprobe.nim:63`), `CcProbeProfile` (appears in
`ccIdentity`/`ccVersion` signatures; un-exporting leaves an unnameable type in a
public signature), and all six enums — Nim exports enum VALUES with the type and
offers no per-value control, and each of the six has at least one externally-read
value, so a single reachable value pins the whole type.

**One claim checked rather than credited.** The split added a
`# process-contract-exempt` marker to `toolrun.nim`'s `import std/osproc`,
satisfying the guard in `tests/unit/test_rfc7_a3_ioutils_ownership.nim`. Adding
an exemption to a soundness guard warrants scrutiny, so: `git show
HEAD:src/crisol/ccprobe.nim` line 62 already carried the identical exemption.
The import MOVED and its marker moved with it; the number of annotated exempt
sites is unchanged and the rationale text got more specific, not vaguer. Not a
widened guard.

Independently verified on a quiescent tree (0 containers running):
`CRISOL_COMPILES=yes`, **PASS=253 FAIL=1**, sole failure `test_fallback.nim`
on the documented bind-mount fold assert.

**All 33 mandated rows are now closed.** Round 2 re-review dispatched over the
full uncommitted diff (73 tracked files, +6919/-855, plus 7 new): the three
standing dimensions (security, design, liveness) plus a fourth reviewing the
fix loop's OWN diff, on the evidence that round 1 introduced three defects
(L1/L2/L3) at the same rate as ordinary development.

## Round 2 re-review — 2026-09-22/24 (base `630ecc6`, still uncommitted)

Four dimensions over the full diff (73 tracked files, +6919/-855, plus 7 new):
the three standing ones (security, design, liveness) plus a fourth pointed at
the FIX LOOP'S OWN diff, on the evidence that round 1 introduced three defects
(L1/L2/L3) at roughly the rate of ordinary development.

### Findings

| id | sev | where | what | status |
|---|---|---|---|---|
| R2-1 | High | `ccidentity.nim` `versionLine`/`toolchainUnsound` | A fallback-derived identity is recorded as a KNOWN toolchain and publishes to shared L2 | fixed |
| R2-2 | High | `ci.yml`, `toolexec.nim:181-306` | CR4's deadline guard had NO producer on any leg; its `when defined(windows)` `PeekNamedPipe` arm had never executed | fixed |
| R2-3 | Med-High | `planner.nim:247-248` | Dead staleness check whose purpose-built liveness test proves a different mechanism | fixed (documented + test claim corrected) |
| R2-4 | Med | `artifactid.nim:503-522` | `ccIncludeClosure` ignored `dscMismatch` — empty closure reported as complete | fixed |
| R2-5 | Med | `api.nim:1908,1916` + 20 files | Stale `ccprobe.X` references after CR7, including user-facing `warnStderr` text | fixed |
| R2-6 | Med | `test_ccprobe.nim` (= **CR5**) | Test seam cancels out `resolveDriver`; a wrong-but-nonempty answer invisible across all 82 tests | fixed |
| R2-7 | Med | `runner`/`planner`/`depgraph`/`clean` | Defaulted soundness parameters, 4th-7th instances | partial — see below |
| R2-8 | Med | `ci.yml`, `test_closure_searchpath.nim` | `.obj` branch has no CI producer | BLOCKED — see below |
| R2-9 | Low | `parseCcHalf`, `sanitizeCcFingerprintField` | Both split on the FIRST pipe; a pipe in compiler text misattributes halves | deferred (Low) |
| R2-10 | Low | `test_paths.nim:620-627` | `cmpKeyBytes` `not compiles(...)` seal has no positive control | deferred (Low) |
| R2-11 | Low | `assert-subset-honesty.sh` | Comment says "six marker-bearing sites"; `test_source_index.nim` now has 8 | deferred (Low) |

### R2-1 — the exemption's own justification did not cover the dangerous case

`versionLine` returns the first non-empty line when no dotted-version token is
found. `WindowsCcProfile` is `cdVersionOnly`, so the compiler half carries no
content digest (deliberate: it keeps `cl` and `vccexe` on one key).
`toolchainUnsound` tripped only on `cfsUnavailable` and explicitly exempted a
`cfsKnown` half with `cdkNone`. So any Windows driver that exits 0 and prints
any non-empty text was recorded as a KNOWN identity and published to the shared
tier; two hosts with two different broken drivers emitting the same text fold
to one key.

The decisive point, and the reason this stopped being a judgment call: the
exemption was justified in its own doc by *"That half's TEXT still varies by
real compiler identity; only the extra content proof is missing."* **That
premise is false on the fallback path** — fallback text was never established
to describe a compiler at all. Round 1 escalated this as a genuine fork between
two deliberate decisions (issue #23 slice 3's locale-proofing vs W4's soundness
semantics). It is not a fork. The two reconcile once the missing bit — *was
this text a fallback?* — is consulted at the decision point:

`toolchainUnsound` now also trips when the compiler half is `cfsKnown` AND
carries no real digest AND its text has no dotted-version token. Real `cl`
banners carry a build number (`19.44.35228`), so legitimate Windows publishes
are unaffected — which is exactly the cost objection the old doc raised against
broadening, and it does not apply to this narrower trigger. The condition is
scoped to the COMPILER half: the runtime half's text is a library list with no
version convention. No `CcHalf`/`$`/`parseCcFingerprint` change, so **no
serialized key bytes moved** and no fleet-wide invalidation.

### R2-3 — the code was fine; the TEST was the defect

`planner.decideCompile`'s `graph.header.ccVersion != ccVersion` check cannot
fire in production: `loadDepGraph` discards a mismatched graph up front and, on
the success path, unconditionally re-stamps
`stored.header.nimVersion`/`.ccVersion` to the live values before returning
(verified by reading both exits). So `graph.header.X == X` is a structural
invariant by the time `decideCompile` runs.

**Departed from the reviewer's recommendation** (which was to delete the line).
Two reasons. First, the `nimVersion` check immediately above it is dead for
exactly the same reason, so deleting only the `ccVersion` twin would leave an
incoherent asymmetry — and the `nimVersion` line is pre-existing, outside this
review's scope. Second, and decisive: the defect was never the line. It was
`tests/integration/test_w3_cc_liveness.nim` claiming in its own header doc to
prove BOTH `decideCompile`'s check and `loadDepGraph`'s discard, when it can
only prove the latter. Both lines are now documented as redundant-with-
`loadDepGraph` defence in depth, and the test's doc states which mechanism it
proves and which it does not.

Confirmed by mutation that the test is genuinely live against the REAL
enforcement point: with `loadDepGraph`'s `if ccMismatch:` disabled in a scratch
copy, the file FAILS at its run-3 assertion (`compileSkipped was true`).

**SUPERSEDED IN ROUND 5 (R3-8) — read this before acting on the section above.**
Both lines were deleted. R2-3's recorded decision was the opposite — *keep them,
documented as redundant-with-`loadDepGraph` defence in depth* — and round 5 found
the two dispositions sitting in this document side by side with nothing
connecting them (R5-14). The reasoning that changed: a guard that cannot fire is
not defence in depth, it is a safety net that invites reliance while holding
nothing, and the objection that had blocked deletion ("it would break a library
consumer who hands `plan` a raw stored graph") falls to RFC-0003, which makes
`crisol/planner` an implementation detail rather than contracted surface. Round 3
was also right that the asymmetry mattered: R3-8 removed the `nimVersion` twin at
the same time, so no incoherence was left behind.

Two consequences for a reader arriving here. The grep anchor this section offers
for its mutation proof — `if ccVersion.len > 0 and` — now matches nothing;
`loadDepGraph`'s own discard arms are the live mechanism and
`tests/unit/test_depgraph.nim`'s four `dgd*` blocks are its coverage. And R2-3's
*actual* finding — that `test_w3_cc_liveness.nim`'s header doc over-claims which
mechanism it proves — recurred in round 5 as R5-7, because R3-8 deleted the
mechanism that round 3's rewritten doc had been careful to describe. The same
doc has now over-claimed twice, for opposite reasons.


### R2-6 / CR5 — and how it was lost

Two false starts worth recording, because both were instructive:

1. An assertion on the resolved driver path's BASENAME ("must be named `cc`")
   is simply WRONG, not merely weak. Nim's `findExe` follows symlinks, so on
   the CI container `resolveDriver("cc")` legitimately answers
   `/usr/bin/gcc-16`. The first attempt failed on a clean tree, and the failure
   was the code being right.
2. A custom `CcProbeProfile` with a candidate driver of the test's choosing is
   no longer constructible — **CR8 un-exported `CcProbeProfile`/`CcCandidate`**,
   which closed this testing seam. Worth knowing: an un-export can remove a
   test's only lever.

The row itself named the missing ingredient ("No test anywhere fakes PATH or
pins a literal driver path"), so the fix fakes PATH: it plants an executable
`cc` in a private temp dir, puts that dir first on PATH, and has the hash seam
identify the file by CONTENT rather than spelling — immune to symlink
resolution, absolute-vs-relative spelling and path separators alike. PATH is
restored in a `finally`.

Mutation-proved: clean run exits 0 with **84 OK** (was 82); with `resolveDriver`
returning a wrong-but-nonempty path, BOTH new tests fail.

**How CR5 was lost in round 1**, recorded because the mechanism matters more
than the row: CR5 appeared in the findings table and in NEITHER the "Closed"
nor the "Still open" list. The loop tracked progress against the CLOSED list
rather than against the table, so a row missing from both was invisible to every
later status check — and the table's own status column still read `open` for all
18 rows, closure being recorded only in prose beneath it. Two readers were
misled by this: a round-2 agent reported CR6 as open from the stale cell. Fixed:
the status column is now written per row, and `W9e` (a deferred Low with the
same double-omission) is listed. Independently, the liveness dimension
rediscovered CR5 by mutation from a different direction, which is the only
reason it did not ship unnoticed.

### R2-7 — the reviewer's minimum done in full; the robust version deferred

The pattern's 4th-7th instances: `runner.execute*` (`ccVersion: string = ""`),
`planner.cachePath`/`toolchainFingerprint` (`toolchainFp: string = ""`),
`depgraph.initDepGraph`/`loadDepGraph`, `clean.cleanOrphans`. Nothing is unsound
today — every production call site threads a real value. The risk is L1's exact
muscle memory: `execute` is `runner.nim`'s documented public API, crisol is
consumed as a library by five siblings, and the defaulted spelling is normalised
across hundreds of test call sites.

Measured churn for removing the defaults: **527 call sites** (execute 291,
initDepGraph 100, loadDepGraph 63, toolchainFingerprint 32, cachePath 23,
cleanOrphans 18), ~450 of them in tests, with only 76 passing the value
explicitly today.

> **CORRECTED IN ROUND 5 (R5-9).** The aggregate is wrong, and it has exactly one
> bad component. `execute 291` counted comment PROSE: crisol's own comments discuss
> `execute(` constantly, and a bare `grep` cannot tell a call from a mention. The
> true figure is **117** (`src` 3, `tests` 114) — which is what `runner.nim`'s
> R4-7 block had already measured independently. Substituting it, `527 - 291 + 117`
> = **353 call sites, 326 of them in tests**. Re-measured on the whole set today
> (2026-09-24, current working tree): execute 117, initDepGraph 100, loadDepGraph
> 67, toolchainFingerprint 26, cachePath 24, cleanOrphans 19. Method, stated
> because the original's was not and that is the whole defect: per `.nim` line,
> truncate at the first `#`, skip the declaration lines, count matches of
> `(?<![A-Za-z0-9_.])<name>\(` under `src/` and `tests/`. The non-`execute`
> subtotal reproduces the census's own 236 exactly.
>
> `clean.nim`'s *"63 were measured"* is **not in conflict** and needs no change: it
> is `loadDepGraph`'s tests-only count for one proc, which the re-measurement
> reproduces to the digit. It only read as a third contradictory number because
> nothing at the site said it was per-proc and tests-only.
>
> None of this changes the round-2 conclusion, and that is worth stating plainly:
> 353 hand-edited call sites is still far past the threshold that made a partial
> manual change worse than none, so R2-7's deferral and R3-7's deprecated-companion
> remedy both stand on the corrected number. The finding is about a figure no
> reader could re-derive, not about a decision that turned on it. That is well past the point where a hand-applied partial
change is worse than none — it would leave the pattern alive while looking
handled. Done now: the reviewer's stated minimum, in full — each of the four
declaration sites carries a warning cross-referencing L1's postmortem, at the
point where the next author actually decides. Deferred: the default removal, as
ONE atomic batch. It is mechanical, not subtle, and wants delegation.

### R2-8 — blocked, deliberately not half-done

`tests/integration/test_closure_searchpath.nim`'s `.obj` branch genuinely has no
CI producer, while its sibling `test_compiledriver_real.nim` is pinned on
windows. But that file carries **seven bare `skip()` calls** gated on
`symlinksAvailable()` with no `CRISOL-SKIP-TEST` markers. On Windows symlinks
generally need privilege, so pinning it there would add seven SILENT skips —
and because a bare `skip()` emits nothing, `assert-subset-honesty.sh` cannot see
them in either direction. That trades a coverage gap for exactly the darkness
the honesty regime exists to prevent (the W5/CR6 class). Wiring it correctly
requires seven labelled markers plus seven pinned entries on the windows leg,
and the pin cannot be verified from this host. Left unwired with the requirement
stated rather than shipped half-right.

### Round 1's fixes held

The regression and liveness dimensions re-derived round 1's work from code
rather than trusting the ledger, several times by live mutation: L1, L2, L3, W4
(`or` to `and` broke 2 tests), W6, CR3, CR6, CR9, CR10, CR12-CR14 all confirmed
live. No proc body was altered in transit by the CR7 split. The
`process-contract-exempt` marker count is unchanged at 5 sites — the import
moved and its marker moved with it.

### Operational note — delegation stopped mid-round

Round 2's fix batch was dispatched as four subagents on disjoint file lanes. All
four were terminated by the account's weekly sonnet rate limit (resets 2026-09-26).
Two had already landed their core source edits (R2-1 in `ccidentity.nim`, R2-4 in
`artifactid.nim` with its test) before dying; the tree was left compiling
(`LIB_EXIT=0`), verified before continuing. The remainder of round 2 was
completed directly. R2-7's deferral is a consequence of this: a 527-site
mechanical sweep is precisely the work that should be delegated, and delegation
was unavailable.


## Round 3 re-review — 2026-09-24 (base `630ecc6`, still uncommitted)

Three standing lenses (security, design, liveness) on **fable** — the weekly
sonnet allowance was exhausted mid-round-2 and does not reset until 2026-09-26,
so the delegation model changed but the dimension set did not. Scope inverted
deliberately onto **round 2's own fix diff**, on the same evidence that set
round 2's scope: round 1's fixes introduced three defects (L1/L2/L3) and round
2's review of them found six more. All three lenses were read-only and
mutation-tested against copies outside the repo.

Convergence was the round's most useful signal: **three independent lenses hit
R2-1's aggregate-text hole** (S1, D1, and the orchestrator's own check of
`ccidentity.nim:786`), and **three hit its missing test** (S3, D2, L1). Three
also converged on `runEntrypoint*` as R2-7's one real omission.

### Findings

| id | sev | where | what | status |
|---|---|---|---|---|
| R3-1 | Med | `ccidentity.nim:684` + `:786` | R2-1's gate is evaluated on the `"; "`-JOINED text of every answering driver, so one honest driver launders a fallback line into a KNOWN identity | **fixed** (mutation-proven) — INSUFFICIENT, see R4-1 |
| R3-2 | Med | `test_cachedispatch.nim:740-776` | R2-1's new arm has no test producer anywhere; deleting the disjunct leaves every suite green | **fixed** (mutation-proven) — HELD, re-proved in round 4 |
| R3-3 | Med | `toolexec.nim:343-352` | The CR4 deadline is defeated by a TERM-ignoring child: `terminate()` then an UNBOUNDED `waitForExit()` | **fixed** (mutation-proven) — time bound HELD; escalation untested, see R4-2 |
| R3-4 | Med | `api.nim:1911-1916` | The degraded-toolchain warning is factually false for R2-1's new case (both halves answered) | **fixed** (explicit third branch) |
| R3-5 | Med | `test_depgraph_guard.nim:475-476` | Bare unmarked `skip()` that fires on BOTH the windows and macOS legs — invisible to the honesty gate in either direction | **fixed** (marked + pinned both legs) |
| R3-6 | Med | `runner.nim:3044-3047`, `planner.nim:314-316` | `runEntrypoint*` omits both versions, falsifying R2-7's own note; and R2-7's inventory missed `planner.plan` | **fixed** |
| R3-7 | Med | R2-7’s remedy | A deprecated companion overload gets compile-time enforcement at ~6 declarations instead of 527 call sites | **fixed** — RESOLVES R2-7; mechanism HELD, enforcement gap see R4-3 |
| R3-8 | Med | `planner.nim`, `decideCompile` | The dead staleness checks' underlying smell is that `decideCompile` takes two values already in `graph.header` | **fixed** round 5 (mutation-proven) — NOT a fork: RFC-0003 decided it |
| R3-9 | Med | `artifactid.nim:547`, `ci.yml` | `cpeSourceMismatch` is unit-live but has ZERO producers on any leg, and W9c's Linux producer as scoped cannot supply one | **BLOCKED, with Corey via W9c** — sharpens W9c (= W9.3 in the W-audit status table); needs a Windows-capable producer |
| R3-10 | Low-Med | `toolrun.nim:25-38, 66-100` | The module defining the process boundary misstates its own importer set (says three, names `ccprobe`/`runner`; the real set is five) and omits two exports | **fixed** — INCOMPLETE, see R4-7 |
| R3-11 | Low | `ccidentity.nim:225-234` | `hasDottedVersion` accepts ANY `digit.digit`, so a path segment (`C:\tools\1.5\`) or a date (`2024.09.01`) in error text passes as KNOWN | **deferred (Low, per mandate)** — but NOW LOAD-BEARING after R4-1, and SHARPENED by R5-4: see the R3-11 note in round 4 and R5-4 in round 5. The obvious two-dot fix is refuted (the ldd constraint); the live remedy is R5-4 banner-vs-diagnostic at the degrade site |
| R3-12 | Low | `toolexec.nim`, `gitdiff.nim:298-306` | A valid driver whose grandchild holds the pipe is reported unavailable and leaves an orphan (over-invalidation + no tree kill) | deferred (Low, per mandate) |
| R3-13 | Low | `test_ccprobe.nim:1371-1373` | The R2-6 helper `removeDir`s a predictable shared-tmp name before creating it; a pre-planted symlink there is followed | deferred (Low, per mandate) |
| R3-14 | Low | `test_api_boundary.nim:89,96` | `not compiles(...)` seals with no positive control (`test_paths.nim`'s equivalents DO have them, at 944 and 998) | deferred (Low, per mandate) |
| R3-15 | Low | `test_compiledriver.nim:229`, `test_fold_probe.nim:41`, `test_spike_import_case.nim:132` | Three more unmarked or bespoke `skip()`s inside the win/mac sweep scope that do not fire today | deferred (Low, per mandate) |
| R3-16 | Low | `test_ccprobe.nim`, five sites | Tests hand-split the fingerprint pipe instead of using `parseCcFingerprint`, CR11's single parser — which no test in the tree uses | deferred (Low, per mandate) |
| R3-17 | Low | `artifactid.nim` `toClosureProbeError` | `of dpeNone: cpeNone` maps an error enum's success value to success and calls itself unreachable; a `doAssert` would make that a checked claim | deferred (Low, per mandate) |

### R3-1 — the fix was right about the bit, wrong about the operand

R2-1 asked the right question (*was this text a fallback?*) and consulted it in
the wrong place. `ccIdentity` asks every candidate driver, keeps the distinct
answers, and folds them with `found.mapIt(it.line).join("; ")`
(`ccidentity.nim:786`) BEFORE `toolchainUnsound` ever sees them. So
`hasDottedVersion(fp.compiler.text)` is an **existential** over the aggregate
where the property needed is **universal** over the candidates: one driver
contributing a dotted token vouches for every other driver's text.

The security lens's trigger is concrete and rests on this repo's own
measurement (`docs/handoff/msvc-selection-layer.md:268` — `cl /nologo` with no
source file prints `D8003` and **exits 0** — CORRECTED IN ROUND 7: it exits
**2**, and so does `cl` under `CL=/nologo` or `CL=/W4`; plain `cl` is the one
that exits 0. See the correction under the #23 measurement table and R7-S1): a
Windows host with `CL=/nologo`
in the environment (a common CI/dev setting, and the probes inherit the parent
env — that is CR18) and mingw `gcc` on PATH beside MSVC, which is what
`windows-latest` ships while this repo's own Windows leg compiles with
`cc = vcc` (`ci.yml:314`). Compiler half becomes
`"cl : Command line error D8003 : missing source filename; gcc (GCC) 13.2.0"`,
`toolchainUnsound` returns false, the entry publishes to shared L2 — and the
actual MSVC identity is absent from the key. Reproduced in a probe: the joined
case reports `unsound=false`; `cl` alone correctly reports `unsound=true`.
(CORRECTED IN ROUND 7: "reproduced in a probe" means an injected `RunProc`
returning `rc=0` — synthetic input. The real `cl` exits 2 under `CL=/nologo`, so
in reality this capture never reached `toolchainUnsound`; `not ok: continue`
dropped `cl` as absent and gcc became the identity. See R7-S1.)

Medium rather than High because the runtime half content-hashes
`libcmt.lib`/`libvcruntime.lib`, which are toolset-versioned, so a cross-toolset
collision additionally needs identical `.lib` bytes under a different `cl`. The
gate's stated guarantee is defeated; what remains is incidental, not designed.

**The fix decides per candidate instead**, which is available because
`versionLine` is already applied per candidate at `ccidentity.nim:779`. Under
`cdVersionOnly` — the Windows profile, and the only profile where the compiler
half carries no digest — a candidate whose line carries no version token
contributes nothing identifiable and is dropped from the fold. Three
consequences, all wanted:

- If NO candidate is versioned, `found.len == 0` and the half becomes
  `cfsUnavailable` through `toolchainUnsound`'s ORIGINAL first disjunct. R2-1's
  third disjunct is then redundant by construction rather than load-bearing.
- `cfsKnown` regains the meaning its own doc claims ("the probe ran and
  identified something real"), which is the type-level point D1 made: a case
  object exists precisely so "succeeded but found nothing" is unrepresentable,
  and the fallback path had been smuggling that state through anyway.
- **R3-4 dissolves rather than needing its own fix.** With the compiler half
  now honestly `cfsUnavailable`, `isFullyDegraded` is false only when the
  runtime half answered — so `api.nim`'s "a compiler driver or a runtime
  library answered, but not both" becomes TRUE for exactly the case where it
  was false.

POSIX is untouched: `PosixCcProfile` is `cdVersionAndBinary` with exactly one
candidate, and its half always carries a `cdkKnown` digest, which is why the
existing clause already exempts it. Dropping candidates under the digest
profile would have discarded a sound content hash to punish unversioned text —
strictly worse — so the filter is scoped to `cdVersionOnly` only. Serialized
bytes change only for hosts whose drivers answer nothing identifiable, which is
the intended re-key; `$`/`parseCcFingerprint` are untouched, verified by
round-tripping all nine probe cases.

### R3-3 — the deadline guard had its own hang

R2-2 wired a producer for the CR4 deadline and the guard itself went 3/3 red
under mutation, so the drain loops are live. `terminateAndReap` is not.
`toolexec.nim:343-352` does `p.terminate()` and then an **unbounded**
`discard p.waitForExit()`. On POSIX `terminate()` is SIGTERM alone, so a driver
that traps TERM — or one wedged in D-state — turns the deadline straight back
into the hang it was built to prevent, after having already printed
`giving up`. Measured: a `cc` shim doing `trap "" TERM; echo banner; sleep 45`
printed `crisol: warning: cc did not answer within 10000ms; giving up` and then
returned after **45006 ms**; a cooperative hang returned in 10011 ms. For the
motivating case — `git` blocked on a credential prompt in the host process
before the Supervisor exists — the wait is unbounded in principle.

The proc's doc reasons carefully about why this is deliberately NOT a process-
TREE kill, and that reasoning still holds (a tree kill would pull
`crisol/process` into a std-only leaf and cross RFC-0007's boundary). What it
never considered is escalation on the SAME process: bounded wait, then
`kill()`, then bounded wait.

One side effect, caught by the sweep and worth recording because it is the
honesty regime working: the new fixture
`tests/fixtures/hang_ignores_term.nim` imports `std/posix` (for
`signal(SIGTERM, SIG_IGN)`), which turned RFC-0009's B-inventory meta-test red —
`test_rfc9_bucket_inventory.nim` asserts `live ⊆ union`, so ANY newly-added
`std/posix` import fails until it is triaged into a Stage-B bucket. Triaged to
**B2** (Category B, pure signal use, already whole-file `when defined(posix)`-
gated — same rule as the r69 signal-restore test), counts moved 13/33/38/1 →
13/34/38/1 and the frozen total 85 → 86, with the lineage sentence extended.
Re-run green. While there, the stale "the frozen `union.len == 75` pin below"
comment — 75 against what was already an 85-file inventory — was rewritten to
stop restating a number it cannot keep current.

### R3-7 — R2-7's cost objection does not apply to deprecation

R2-7 was escalated because removing the defaults touches 527 call sites, ~450
of them in tests, which is past the point where a hand-applied partial change
is worse than none. That reasoning is sound for *removal* and does not apply to
a **deprecated companion overload**: the full-arity proc loses its default, and
a deprecated overload at the old arity forwards to it.

Compiled against Nim 2.2.10 with an `execute`-shaped signature (six params,
mixed defaults, a required `ccVersion` in the middle): every omitting call
site — positional, named, or named-tail — resolves to the deprecated overload
and emits a `file:line` warning; every explicit site resolves to the full
overload with no ambiguity. **Zero call-site edits are needed to land it**, so
it is genuinely atomic, and `--warningAsError:Deprecated:on` over `src/` makes
a production omission impossible while tests burn down file by file. It also
puts the signal where the author actually is: a `#` comment above a proc is
read by whoever opens that file, a deprecation warning by whoever calls it —
including the five sibling projects that consume crisol as a library.

### Round 2's fixes that HELD

Recorded because a fix proven live is exactly as valuable as a fix proven
inert, and because round 2's own ledger could not claim this:

- **R2-2** — all four deadline guards mutated to `if false`: 3/3 fixtures RED,
  each driving a real production path (`realRunMerged` → `drainToEofDeadline`,
  `realRun` → `drainBothDeadline`, `gitdiff.changedFiles` → `runGit`). The CI
  step is correctly wired: inside `windows:`, `runs-on: windows-latest`, job
  `defaults.run.shell: bash`, `tee -a`, no `when defined(posix)` gate, and the
  named file exists. The `PeekNamedPipe` arm still has never executed anywhere
  — it executes first on the next push.
- **R2-3** — unreachability independently re-derived by reading all six
  `loadDepGraph` exits, then proven both ways by mutation: disabling
  `if ccMismatch:` turns `test_w3_cc_liveness.nim` RED at line 172 (round 2
  cited ~151; the file has since grown), while disabling
  `decideCompile`’s `ccVersion` staleness check (`planner.nim`, grep `if ccVersion.len > 0 and`) leaves it GREEN. The corrected test doc is exactly
  accurate.
- **R2-4** — mutating `if probed.sourceCheck == dscMismatch:` to `if false`
  turns `test_artifactid.nim` RED at 533-538. The diagnostic-only claim was
  independently confirmed: `keyHash` has one producer and flows only into
  `ArtifactRow` → ledger/compilereport/`reuseRatios`. See R3-9 for the
  producer gap.
- **R2-5** — all 14 rewritten symbols have exactly one definition in the tree
  and no same-name proc exists elsewhere in `src/`, `tests/support` or
  `tests/fixtures`, so a silent retarget was not possible.
- **R2-6** — 2/2 RED under a wrong-but-nonempty `resolveDriver` (at 1412/1415
  and 1439). Also confirmed **not** POSIX-gated: the `when defined(posix)`
  block opened at 721 closes before the column-0 suite at 1388, so the suite
  runs in the windows unit sweep, and `withFakeCcOnPath` is Windows-aware
  (`cc.exe`, `;`, no chmod).
- **R2-1's blast radius** — `toolchainUnsound` is a pure predicate over
  `CcHalf` fields; `serializeCcHalf`/`$`/`parseCcHalf`/`parseCcFingerprint`
  are untouched, round-tripped `ok=true, equal=true` on all nine probe cases.
  The gate reaches L2 only via `cachedispatch.shouldStore:686`, and tier
  backfill is downward-only (`cachetier.nim:263-282`), so there is no upward
  republish path.
## Round 4 re-review — 2026-09-24 (base `630ecc6`, still uncommitted)

Dispatched on **round 3's own fix diff**, on the same principle that set round
3's scope: round 1's fixes introduced three defects, round 3's review of round 2
found three more, so round 3's fixes get the same treatment. Three standing
dimensions in parallel (security; design and ergonomics; liveness and
completeness), each given the 16-file round-3 surface explicitly rather than
"the repo", and each told to distinguish *mutation-proved* from *read the code*.

Scope note on identifying the surface: every round-3 change carries an `R3-N`
rationale marker, which makes the diff greppable without a commit to diff
against. That is a genuine benefit of the convention, with one trap — RFC-0009's
own review also numbers its rounds `R3-N`, so `config.nim`, `discover.nim`,
`paths.nim` and the `test_rfc9_*` files match the grep and are a DIFFERENT
review. All three reviewers were told so explicitly.

**No Critical, no High.** Seven Mediums after dedupe, two of them found
independently by two dimensions, which is the loop's only real cross-check. Two
more rows were added later, DURING the fix batch rather than by the review:
R4-10 (a hazard of the remedy itself, hit while applying it) and R4-11 (a
pre-existing flake the verification sweep surfaced). Eleven rows total; the two
late ones are marked as such, because a round that silently folds its own
discoveries into its review findings is overstating what the review caught.

### Findings

| # | Sev | Where | What | Status |
|---|---|---|---|---|
| R4-1 | Med | `ccidentity.nim`, the `cdVersionOnly` candidate filter | R3-1 DROPS the unidentifiable candidate instead of degrading on it, so the `CL=/nologo` + mingw-gcc trigger it cites still publishes, with gcc standing in for the MSVC toolset. CORRECTED IN ROUND 7: the trigger's premise (`cl` exits 0 under `CL=/nologo`) was a measurement error — real `cl` exits 2, so it is dropped by the `not ok` arm this fix never touched | **fixed** (mutation-proven; degrades instead of dropping) — but only for the synthetic rc=0 capture; the real trigger is R7-S1 |
| R4-2 | Med | `toolexec.nim`, `terminateAndReap` | `p.kill()` is dark: removing it leaves every suite green and leaks an orphan. The test asserts elapsed time, which the bounded waits alone already satisfy | **fixed** (mutation-proven: survivor pid, state S, at 14015 ms) |
| R4-3 | Med | `dev`, `ci.yml` | `--warningAsError:Deprecated:on` has NO automated producer; R3-7's guarantee is enforced by a local target that cannot run on this host | **fixed** — real CI producer in the Linux `test` job, both flags |
| R4-4 | Med | `pipeline.nim`, `cachedispatch.nim`, `planner.nim` | the defaulted-soundness-parameter population is larger than either inventory recorded, for the third consecutive round | **fixed** — 3 params treated, 3 mutation proofs; `plan` exclusion now reasoned |
| R4-5 | Med | `clean.nim`, `depgraph.nim` | six comment/`##` blocks still describe the defaults R3-7 removed, two of them on the consumer-facing doc surface | **fixed** (4 stale blocks + 2 consumer-facing `##` docs) |
| R4-6 | Med | `compiledriver.nim:62`, `runner.nim:48` | crisol's own source hard-fails a consumer building with `--warningAsError:UnusedImport` — a flag RFC-0004's handoff already recommended adopting | **fixed** — both imports dropped, gate adopted, zero exemptions |
| R4-7 | Med | `toolrun.nim:26`, `planner.nim`, this doc | three of round 3's own bookkeeping fixes state something untrue, including R3-10 not deleting the roll-call it reports deleting | **fixed** (roll-call deleted, census → grep, reason corrected, citations anchored) |
| R4-8 | Low | `toolexec.nim`, `test_r3_terminate_escalation.nim` | `TerminateGraceMs` exported with no consumer while the test hand-duplicates its value; `CeilingMs` dead as a bound; documented worst case understated by a full probe deadline | **fixed** with R4-2 — bound now computed from both constants |
| R4-9 | Low | `toolrun.nim:195` | `lastProbeStderr` doc promises `""` on timeout while the non-merged path keeps partial stderr; diagnostics only, never reaches a key | deferred (Low, per mandate) |
| R4-10 | Low-Med | `runner.nim`, qualified re-exports | `export mod.sym` of a name that gains a deprecated companion errors AT THE EXPORT, an unfixable site that can mask real omissions behind one confusing error | **guarded** + documented at the gate; grep-assertion declined, see note |
| R4-11 | Med | `test_api.nim:2926`, `api.nim:1637` | PRE-EXISTING intermittent flake, found by the round-4 sweep: `regressed == true` while `perfBaselineUs == 0` — the C6 verdict flags a regression while reporting no baseline. 1 fail in 3 identical fresh containers | NEW — outside this workstream, for Corey |

### R4-1 — the fix asked the right question, in the right place, and then let the answer go

R3-1's own rationale comment names the disease precisely: "the joined text then
carries gcc's version and the MSVC identity is simply absent from the key". The
filter it added ends in `continue`, which merely drops the unidentifiable
candidate — so it cures the case where NO candidate survives (`found.len == 0`
reaches `ccUnavailable()`) and leaves the cited case untouched. `cl` is dropped,
`gcc` survives, `found` is non-empty, the half is `cfsKnown` carrying gcc's
banner, `toolchainUnsound` is false, and the run publishes to the shared L2 tier
with a bystander's identity standing in for the toolset that actually compiles.

Proved live with a realistic `/VERBOSE:LIB` runtime half, so both halves are
genuinely `cfsKnown`: poisoned `cl` plus versioned mingw `gcc` gives
`toolchainUnsound: false` and STORES; poisoned `cl` alone gives `cfsUnavailable`
and refuses. `WindowsCcCandidates` asks five drivers, so the multi-candidate
case is the normal one on a windows-latest-shaped host, not an edge.

Two things worth separating, because the ledger should not overclaim in either
direction. This is **not a soundness regression**: the bytes R3-1 removed were
`cl`'s constant `D8003` error string, which carried no more identity than their
absence does, so the key was equally blind to the MSVC toolset before and after.
What IS wrong is the claim — the findings table said **fixed**, and `cfsKnown` is
documented as meaning "the probe ran and identified something real", and neither
holds for the scenario the row cites.

The remedy is to stop conflating two different situations: a candidate that is
absent or failed (`not ok` — says nothing about the host, correctly dropped) and
a candidate that ANSWERED `rc=0` and would not identify itself (positive
evidence that the probe cannot enumerate the toolchain). The second must degrade
the half, not silently shrink it, which is the direction the doc of
`WindowsCcCandidates` mandates: "Under-invalidation is the defect this probe
exists to prevent; over-invalidation only costs a miss."

**CORRECTED IN ROUND 7 (R7-S1).** The premise under this whole section — that
`CL=/nologo` makes `cl` answer `rc=0` with `D8003` — came from the #23
measurement table's `cl /nologo` row, and that row was wrong: re-measured with
`cmd /v:on` and `!ERRORLEVEL!`, plain `cl` rc=0, `CL=/W4` rc=2, `CL=/nologo`
rc=2 (and `cl /nologo` rc=2). So the real `cl` under any `CL` lands in the
`not ok` arm this section calls "says nothing about the host, correctly
dropped" — which is false for it — and "Proved live" above means proved
against an injected rc=0 capture. The degrade logic is sound for the input it
was given; it was never given the real one. See R7-S1.

### R4-2 — the escalation was proven to be fast, not to be an escalation

R3-3's fix has two halves: bound the waits, and escalate to `kill()`. The test
it shipped with asserts elapsed wall-clock only. The bounded waits ALONE cap
elapsed time at roughly the drain deadline plus two grace periods, comfortably
inside both bounds, so `kill()` contributes nothing any assertion can observe.
Both the liveness and the security dimension independently replaced `p.kill()`
with a no-op, got a green test, and caught the TERM-ignoring child alive and
reparented to PID 1 with most of its sleep remaining.

This is the R3-2 class exactly — "deleting the disjunct leaves every suite
green" — reproduced one round later, in the round that found it. The lesson the
loop keeps re-learning is narrow and worth stating plainly: when a fix has two
separable halves, an assertion that only one half can satisfy is not coverage of
the other. R3-3's test was written against the SYMPTOM that motivated the
finding (45 s instead of 10 s) rather than against the GUARANTEE the fix claims
("a timed-out caller cannot leak a process"), and the symptom was curable by
half the fix.

### Round 3's fixes that HELD

Recorded because a re-review that only reports defects gives a false picture of
the diff, and because these were independently re-derived rather than taken from
round 3's own ledger:

- **R3-1's mechanism** (as distinct from its sufficiency, above) — removing the
  per-candidate filter turns two `test_ccprobe.nim` cases RED. Also confirmed
  the suite sits BEFORE that file's only `when defined(posix)` block, so it runs
  on all three legs, not just Linux.
- **R3-2** — neutering the third disjunct of `toolchainUnsound` turns exactly one
  of the four new `test_cachedispatch.nim` cases red, the other three being
  negative and differential controls. The wording of the row matches what the
  mutation shows, which was checked rather than assumed.
- **R3-3's time bound** — genuinely live: control 14.3 s against the recorded
  45006 ms pre-fix.
- **R3-5** — the emitted marker and both pinned entries verified BYTE-EXACT via
  `od -c` and `cat -A`: no trailing whitespace, no typo, present in the windows
  AND macos sets. The `/proc` trigger is a deterministic platform fact, so the
  pin cannot flap. No bare `skip()` remains anywhere in round 3's surface, and
  all five `| tee` occurrences in `ci.yml` are `tee -a`.
- **R3-7's mechanism** — proved correct on Nim 2.2.10 across 11 call shapes
  (positional, all-named, reordered-named, named-tail) with zero ambiguity
  errors, including the 3-arg `loadDepGraph` whose third parameter is
  `var DepGraphDiscard` rather than `string`; the `auto` returns in `clean.nim`
  neither swallow the deprecation nor break the result tuple; and every
  companion forwards the value its base-commit default supplied, checked against
  `git show 630ecc6:`. `src/` is zero-deprecation across ALL 65 modules, not
  merely the import closure of `crisol.nim` — checked with a generated module
  importing every one.
- **R3-9's characterisation** — accurate as recorded: one producer, guarded by
  `dscMismatch`, set only in the MSVC `/sourceDependencies` arm, and
  `measureCompileReuse` appears zero times in `ci.yml`.
- **The B2 triage** — live in the direction that matters: `live` is a subset of
  `union` by a walk of the tree, which is why the new fixture turned it red in
  the first place.

Two guards were examined and deliberately NOT reported as findings, recorded so
a later round does not re-raise them. The third disjunct of `toolchainUnsound`
is unreachable from production by construction once R3-1 is in place, and both
the code and its test say so explicitly — the right treatment for a declared
backstop is to pin it over its own input space, which is what exists. And the
second bounded wait of `TerminateGraceMs` can fire (a SIGKILL pending against a
process in uninterruptible D-state) but its timeout arm and its success arm are
behaviourally identical, so nothing can observe which happened; bounding is its
whole purpose.

### A method correction: one aggregator module cannot detect an unused import

Round 4's design pass established that `src/` is deprecation-clean across all 65
modules by generating a module that imports every one and checking that. That is
valid for `Deprecated`, and it is INVALID for `UnusedImport` — the compiler marks
the imported module used for the whole compilation, so a single module's use of
`std/strutils` silences every other module's dead import of it. The first sweep
done that way reported nothing.

Only a PER-MODULE `nim check` is honest, and done that way there were two hits
repo-wide, not zero: `compiledriver.nim:62` and `icbaseline.nim:54`, both
`std/streams`, both dead on both platforms (neither file has a `when defined`
branch that could hide a use; the only stream contact in each is
`drainToEof(p.outputStream)`, where `outputStream` is osproc's accessor and
`toolexec.drainToEof` is what touches the streams API). Both dropped.

This also sharpens WHY the gate belongs in crisol rather than in the consumers:
whether a sibling hits an unused import in crisol depends on THEIR import
closure, so the same crisol tree can be clean for one consumer and a hard build
failure for another. `docs/rfc/0004-incremental-hermetic-execution.handoff.md:34`
had already recorded the precedent (a past commit dropped an unused `ioutils`
import that was fatal under amoxtli's `--warningAsError:UnusedImport`) and
recommended adopting the flag here; round 4 did.

The gate as landed covers `src/crisol.nim` plus the four modules outside its
import closure — `depparse`, `icbaseline`, `report`, `unittest_shim` — measured
from the `-d:nimBetterRun` depfiles manifest of a real compile rather than by
grepping import lines, which got it wrong. Closure coverage is 61 of 65, hence
the four extra targets. It runs in the Linux `test` job with both
`--warningAsError:Deprecated:on` and `--warningAsError:UnusedImport:on`, and
`./dev check` runs the same thing locally with `--network=none` scoped to that
arm only (a `podman_run` default would have broken `./dev test`, which needs
network for nimble).

Deliberately NOT extended to `tests/`: the deprecated-overload remedy's whole
premise is that tests compile under `--warnings:off` and stay silent, so gating
them would re-impose the ~450 call sites the overloads exist to spare. And
`icbaseline` was briefly excluded from the gate rather than listed-and-failing,
on the principle that a gate which red-fails on day one gets disabled instead of
fixed — then its import was dropped in the same round, so the exclusion is gone
and nothing in `src/` is exempt.

### R3-11 re-examined: load-bearing now, still Low, and the obvious fix is wrong

R4-1 changes what `hasDottedVersion` is FOR. As a component of
`toolchainUnsound`'s third disjunct it was a backstop behind other evidence;
at the R4-1 degrade site it is the sole thing deciding whether a driver that
answered identified itself. R3-11 — that it accepts ANY `digit.digit`, so a path
segment or a date in error text reads as a version — is therefore the only
remaining way a poisoned candidate reaches the key. The fix lane raised this
itself, correctly.

Kept at **Low** anyway, and the reasoning is recorded so the next round does not
have to re-derive it:

- **The exploit needs a narrow conjunction**: a driver that exits 0, omits its
  banner, AND prints a `digit.digit` token that is STABLE across compiler
  upgrades. An unstable token (a date, a temp path) over-invalidates, which is
  only a miss. The measured, reproducible trigger R4-1 closed (`CL=/nologo`
  makes `cl` print `D8003`) carries no dotted token at all. (CORRECTED IN
  ROUND 7: that trigger was mismeasured — under `CL=/nologo` real
  `cl` exits **2**, not 0, so its `D8003` never reaches this predicate at all;
  see R7-S1.)
- **The obvious fix is wrong, which is the part worth writing down.** Requiring
  two dots would accept every real `cc` banner on this path (`cl`
  `19.44.35228`, mingw `gcc` `13.2.0`, `clang` `17.0.6`) — but
  `hasDottedVersion` is not private to that path: `versionLine` uses it to
  select a line BY CONTENT, and `versionLine` is also what labels the ldd half
  (`ccidentity.nim:986`), where the real banner is `ldd (GNU libc) 2.38` — a
  SINGLE dot. Tightening the shared predicate would silently degrade the runtime
  half's line selection back to first-non-empty-line, which is the positional
  rule issue #22 was about.
- So a correct fix needs a SEPARATE, stricter predicate used only at the degrade
  site, plus evidence about the real banner population on Windows that cannot be
  gathered from this host. That is a design change, not a tweak, and it is worth
  doing deliberately rather than inside a fix round — the over-correction risk
  runs the wrong way here: too strict means a legitimate Windows host stops
  publishing, on the platform this whole workstream exists to serve.

### A hazard of the R3-7/R4-4 remedy, found while applying it

Nim charges a `{.deprecated.}` warning to whatever NAMES the symbol, not only to
what calls it. So when `cacheEnabled` gained its R4-4 companion overload,
`runner.nim`'s `export cachedispatch.cacheEnabled` began tripping
`--warningAsError:Deprecated:on` on the export statement itself — a site with no
argument to pass and therefore no way to comply, and one that cannot simply be
deleted without breaking consumers who `import crisol/runner`.

Left unguarded this is worse than the defect it reports: it would make that one
export the only thing the gate ever reports, masking every real omission in
`src/` behind a single unfixable error. Fixed with a `{.push warning[Deprecated]:
off.}` / `{.pop.}` scoped to that one `export` statement, with the reasoning
recorded in place. Every actual call site keeps its warning.

The scope of the hazard was then bounded empirically rather than left as a
caution. It applies ONLY to the qualified `export module.symbol` form:
`runner.nim` also carries an unqualified whole-module `export planner`, and
`planner.nim` has carried a deprecated `cachePath` companion since R3-7, yet the
gate is clean — so a whole-module re-export does not name the symbol and does not
trip. A grep for qualified re-exports of every treated name across `src/` finds
exactly one, the one above. Anyone extending this remedy to a further proc should
re-run that grep, because the failure mode is a gate that reports one
unactionable error and hides everything else.

Confirmed independently by the fix lane with a three-module minimal repro on
2.2.10, which also settled two details: a `template` companion behaves exactly
like a `proc`, and the push/pop guard suppresses ONLY the export line while a
genuine caller still errors. It also explains why R3-7 never hit this —
`planner`, `depgraph`, `clean` and `pipeline` are re-exported wholesale or not by
symbol at all; `cachedispatch` is the only module whose symbols are exported
individually.

**A `ci/` grep assertion was recommended and declined**, recorded here so it is a
decision rather than an omission. Doing it correctly means resolving each
exported symbol to its defining module and asking whether that proc carries a
deprecated companion — more machinery than one live instance warrants, and the
kind of check that rots into a false positive. The deciding argument is that the
failure mode is a LOUD build error, not a silent pass: the gate does fail, it
just names a line nobody touched. So the real risk is a contributor misreading
the error and dropping the flag, and that is addressed by putting the
explanation, the fix, and the "never drop the flag" instruction in the gate's own
comment block in BOTH `dev` and `ci.yml` — where someone hitting it will be
looking. Tracked as R4-10.

### A note on citing by line number

R4-7's third part is that this doc cited `planner.nim:244-275` for the R3-8
comment, which the overload insertion of R3-7 had already pushed to `:295` — in
the same round. The "Round 2's fixes that HELD" list above shows the identical
drift a round earlier ("round 2 cited ~151; the file has since grown"). Line
citations in this doc rot within one round whenever the fix batch touches the
same file, and a stale pointer is worst exactly where the remedy IS a pointer.
Round-3 and round-4 rows are therefore cited by grep anchor where an anchor
exists.

### R4-11 — a pre-existing flake the sweep surfaced, deliberately not fixed here

`tests/unit/test_api.nim:2926` fails intermittently: **one failure in three
identical fresh containers**, and a second run inside the SAME container always
passes (the test writes `perf_r64_counter.txt` as a bare relative path, so it
lands in the spawned child's CWD and survives within a container). Measured this
round; it is not a round-4 regression, and the data flow rules round 4 out —
`perfBaselineUs` comes from `api.nim:1637` (`verdict.baselineUs`, the C6 perf
ledger), `api.nim` is in no round-4 lane, and `icbaseline.nim` despite its name
is the INCREMENTAL-COMPILE baseline, a different subsystem from the perf one.

The failure shape is the interesting part, and it is not mere timing noise. At
the failing point `check rr2.results[0].regressed == true` has already PASSED and
`check rr2.results[0].perfBaselineUs > 0` is what fails — so the C6 verdict
flagged a regression while reporting no baseline at all. With the test's
`sample-floor 1`, that means the sample COUNT was satisfied while the MEDIAN came
back 0: count and median disagreeing about the same ledger set. That is a
plausible correctness defect in the C6 read path, intermittently visible, not
just a slow runner.

**Not fixed here, and that is a scope decision rather than an omission.** It sits
in the C6 perf-regression subsystem, which has nothing to do with the MSVC
selection layer; diagnosing it properly means reading the ledger's count/median
code, and this loop's mandate covers findings in the reviewed surface. It also
matters more than its severity suggests in one specific way: `tests/unit/` is
swept on ALL THREE CI legs, so this is an intermittent red on every leg, and an
intermittently red gate is how gates get switched off — the same failure mode
R4-3 and R4-6 were about. Recommend it become its own `[[item]]` with an owner.

## Round 5 re-review — 2026-09-24 (base `630ecc6`, still uncommitted)

Dispatched on **round 4's own fix diff plus the R3-8 change**, three standing
dimensions in parallel (security; design and ergonomics; liveness and
completeness). Same scoping trick as round 4 — every round-4 change carries an
`R4-N` marker, so the diff is greppable without a commit to diff against — and
the same trap called out again in every brief: RFC-0009's separate review also
numbers its rounds `R3-N`/`R4-N`, so `config.nim`, `discover.nim`, `paths.nim`
and `tests/conformance/test_rfc9_*` match the grep and belong to a different
review.

**The first round to find anything above Medium, and both Highs are defects in
fixes this loop produced.** R5-1 is in the R3-8 change made hours earlier; R5-2
is in the R4-3/R4-6 gate. Rounds 1 through 4 found no Critical and no High.

One methodological note worth keeping, because it changes what a later round
should trust. A reviewer observed that `git diff 630ecc6` **cannot see** this
workstream's churn: the `ccVersion` staleness arm and its test were both added
and removed entirely inside the uncommitted working tree, so a diff against base
makes round 5's own claims about them look fabricated. Diff-vs-base is blind to
intra-working-tree history. The `R4-N`/`R3-N` marker convention is what makes
this reviewable at all, which is an argument for keeping it.

### Findings

| # | Sev | Where | What | Status |
|---|---|---|---|---|
| R5-1 | **High** | `planner.nim`, `test_nimcache_persistence_real.nim` | R3-8 deleted the arm a soundness test depended on; the tree went RED, and the reachability premise is falsified by a file R3-8's own census cited | **fixed** (mutation-proven ×3) |
| R5-2 | **High** | `dev`, `ci.yml`, `src/crisol/process/*` | the soundness gate is Linux-only; nine real unused imports exist on the macOS target on a clean tree; three modules under `src/` are in no gate at all | **fixed** — `ci/source-soundness-gate.sh`, 18 invocations over 3 targets; union coverage **measured**, and R5-26 then corrected the figure this cell first carried to **78 of 78** on-disk (not 76 tracked) |
| R5-3 | Med | this doc, `## Open forks awaiting Corey` | stop-work orders for work the Stage table records as committed and done | **fixed** |
| R5-4 | Med | `ccidentity.nim` | R4-1's implemented predicate is "no dotted token anywhere", not "would not identify itself"; one incidental token defeats the degrade AND the backstop | **fixed** (mutation-proven ×4; A/B/D re-measured) |
| R5-5 | Med | `ccidentity.nim`, the empty-output arm | R4-1's second half is observed by nothing — hoisting the skip leaves every suite green | **fixed** (mutation-proven) |
| R5-6 | Med | `planner.nim`, `plan` | R3-8's new comment claims a use that does not exist — the R4-7 class, reintroduced by the round that fixed it | **fixed** |
| R5-7 | Med | `test_w3_cc_liveness.nim`, `pipeline.nim` | two docs R3-8 invalidated and never swept; one now contradicts `decideCompile`'s own new doc | **fixed** — and surfaced R5-25 |
| R5-8 | Med | `runner.nim` | soundness block asserts a public-API boundary RFC-0003 denies, and counts 5 deprecated companions where there are 9 | **fixed** — RFC-0003 quoted verbatim on both halves; the 527 quote replaced with the measured 117 (tests 114 / src 3); the hand-maintained sibling count removed, not corrected |
| R5-9 | Med | `cachedispatch.nim` | the "~450 call sites" justification transplanted onto a proc with 27 — off by 17× | **fixed** — measured `cacheEnabled` at 29 sites, 26 omitting the parameter (claim was off ~17×); method stated so it re-derives; honest conclusion recorded (at 26 sites churn is not the reason) |
| R5-10 | Med | `api.nim` | nothing at runtime observes the wire from `toolchainUnsound` to `cacheEnabled`; severing it leaves the tree green | **fixed** (mutation-proven ×3) — seam is `CcFingerprintProbe`; new `test_r5_10_toolchain_unsound_wire.nim`, 5 cases, no `skip()` |
| R5-11 | Med | `dev` + `ci.yml` | the two gate copies are hand-duplicated, already disagree with themselves, and nothing detects drift | **fixed** — one script, both callers invoke it; the residual drift class is closed by R5-26 |
| R5-12 | Med | `dev`, the `check)` arm | 62 comment lines to 11 executable — review archaeology stored in an instruction file | **fixed** — 62:11 → 12:4; four passages owed a move to the RFC-0004 handoff (see below) |
| R5-13 | Med | this doc | no round-5 table; four rows in neither list; the W1–W18 audit has no status column at all | **fixed** |
| R5-14 | Med | this doc | R2-3's recorded resolution was "do not delete the line"; R3-8 deleted it, with no forward pointer | **fixed** |
| R5-15 | Med | `artifactid.nim`, and the census **method** | a defaulted cache-key input outside R4-4's population — and the prescribed grep census is structurally incapable of finding a new one | **fixed** — (a) `artifactKeyHash` got the full class remedy, zero churn; (b) new `ci/assert-defaulted-params.sh` pins 197 records over 1010 signatures, fails BOTH directions, mutation-proven ×3; wired into `ci.yml` |
| R5-16 | Low | `ccidentity.nim` | `cdVersionAndBinary`'s "POSIX has exactly one candidate" premise is a comment, not an invariant; an exported profile with two candidates folds N banners behind a digest of the first | deferred (Low, per mandate) |
| R5-17 | Low | `dev`, `ci.yml` | the stated reason for the gate's five-invocation shape is FALSE on 2.2.10 — the aggregator does catch a dead shared import | **fixed** with R5-2 — false rationale replaced with the true one (per-target `--os:` coverage) |
| R5-18 | Low | `dev`, `ci.yml` | "`cachedispatch` is the only module whose symbols are exported individually" — 13 modules use the qualified form; the narrow claim holds, the sentence does not | **fixed** with R5-2 — narrowed to "among the modules carrying a deprecated companion" |
| R5-19 | Low | `toolexec.nim` | the reap half of `terminateAndReap` is unobserved; closing it needs a `/proc/<pid>/stat` `Z` check, not a `cmdline` scan | deferred (declared backstop) |
| R5-20 | Low | `test_cachedispatch.nim` | a doc describes the signature R4-4 removed, and the case now pins the deprecated overload's publish-anyway semantics | deferred (Low, per mandate) |
| R5-21 | Low | `cachedispatch.nim`, `depgraph.nim` | two navigational docs recommend a deprecated arity and point at "the 3-arg overload" that is now 4-arg | deferred (Low, per mandate) |
| R5-22 | Low | `test_freshness.nim` | a case named `cdNeverBuilt` asserts `cdStale`; pre-existing, byte-identical at base | deferred (Low, pre-existing) |
| R5-23 | Low | this doc | nine of twenty spot-checked line citations have rotted, three of them invalidated by R3-8 itself | deferred — the anchor convention is the standing remedy |
| R5-24 | Low | `planner.nim`, `plan` | after R3-8, `plan` takes two parameters its body never reads, and Nim never warns on an unused parameter — no gate can see it | deferred (Low) — **recommendation recorded below** |
| R5-25 | Med | `src/`, `tests/` (census-defined, not file-listed) | stale code-comment citations: comments crediting a fix, check or behaviour to a proc, file or line that no longer holds it; the first ten sites asserted `decideCompile` performs a toolchain comparison, and one R4-4 clause propagated three times was **never true, not even at base** | **fixed for the census-matched population** — the original ten closed out-of-lane; round 6 replaced the hand enumeration (declared complete five rounds running, while `clean.nim`'s W3 attribution survived outside it) with a rerunnable grep census: every hit verdicted, **83 stale, all fixed, 0 open**, plus ~45 stale neighbours found while reading, also fixed. Completeness is claimed only for what the census matches — see the subsection for what it cannot catch |
| R5-26 | Med | `ci/source-soundness-gate.sh`, new `ci/assert-gate-coverage.py` | R5-11 collapsed two gate copies into one but the survivor still CLAIMED its coverage in a comment; a new out-of-closure module would be in no gate, green | **fixed** (mutation-proven ×4) — coverage now measured every run; first run corrected 76—>78 |

### R5-1 — the fix was proved against the wrong tests

R3-8 removed `decideCompile`'s two staleness arms on the argument that
`loadDepGraph` discards a header-mismatched graph and re-stamps the header on
its success path, so the arms cannot fire. That argument is sound **for
production**, and three independent readings confirmed it. What it is not is a
statement about the test suite.

`tests/integration/test_nimcache_persistence_real.nim`'s case *"a
toolchain-fingerprint change lands on a fresh dir; the old dir is never read"*
hand-builds `initDepGraph("nim-v1", "cc-OLD")` — a graph that never went through
the loader — and passed `ccVersion = "cc-NEW"` to reach the deleted arm. It went
red on three checks, reproduced alone in a clean copy under no parallel load.

The history is what makes this sharp. At base `630ecc6` the case used
`forceCompile = true`. The uncommitted W3 work deliberately rewrote it onto the
real decision, with the comment *"decideCompile now itself detects the ccVersion
change and returns cdStale — no forceCompile workaround needed. This exercises
the REAL compile-skip decision."* R3-8 then deleted that mechanism, so **both
routes the case had ever used were gone** and the end-to-end property was pinned
by nothing.

Two defects, and the second is why this is High rather than Medium. The sweep was
red on a row marked *fixed (mutation-proven)* — the third time in this review
that a fixed row had a test that could not observe it, or that it broke. And the
reachability claim is false as written: the R4-4 census **names this exact file**
as a `plan` call shape, in the same note whose rationale concluded no such path
existed. The file was handed to the R3-8 lane as census data and never as a test
to run; the lane ran five files and this was not among them. A census that lists
a call site is a list of things to run, and was not used as one.

**The fix routes the case through the loader rather than reverting to
`forceCompile`.** A revert would have been green while proving less than base
did, because `forceCompile` bypasses the decision entirely and so says nothing
about a *toolchain change* being the trigger — the W3 author's instinct was
right, only the mechanism moved. The case now executes under `cc-OLD`, performs a
same-toolchain confirming load (asserting `dgdNone`, so the later discard can
only be the cc change and not a coincidental nim/format/root mismatch), then
loads under `cc-NEW` and asserts `dgdCcVersion` with its `stored`/`current`
provenance, an emptied graph, and the header stamped to the requested values,
before planning and executing. Every original assertion is kept, none dropped.

`edStale` is still the expected decision, reached by a different step: with the
graph emptied, `decideCompile` lands on *entry absent* → `(cdStale, "no closure
record in dep graph")`. Step 1 (`binary absent → cdNeverBuilt`) cannot fire
because `binPath` is keyed on (path, flags) only and is **not** toolchain-keyed,
unlike `cachePath` — so run 1's stable binary is still on disk. Established by
reading, then confirmed two ways: the assertion passes, and the mutation below
shows the un-discarded path yielding `edRunFresh`, so the branches are
distinguishable rather than coincident.

Three mutations, all RED: neutering `loadDepGraph`'s `ccMismatch` arm reproduces
the R5-1 symptom exactly (including `edecision was edRunFresh`) from the
mechanism's absence rather than the test's shape; corrupting the discard path's
header stamp fails the stamp assertion; and blanking `cachePath`'s
`toolchainFp` folding fails the dir-disjointness half. The lane also stated
plainly what it did *not* prove — the success-path re-stamp, which its rewrite
does not depend on, since the only load reaching that line is the confirming one
where the re-stamp is a no-op.

### R5-2 — the gate was one-dimensional, and it was already failing

Found independently by all three dimensions, which is this loop's only real
cross-check, and then escalated by one of them from hypothetical to
present-tense.

I wrote, in both `dev` and `ci.yml`, that the gate covers *"every module in
`src/`, with no standing exemption for anything to hide behind"*. `src/` holds 76
tracked `.nim` files; the 65 I counted is `src/crisol/*.nim` alone. Also present
are `src/crisol.nim` and eleven modules under `src/crisol/process/` and
`src/crisol/lock/`, of which `process/windows.nim`, `process/darwin.nim` and
`lock/windows.nim` are in no gate invocation at all — they are absent from any
Linux compilation and were never added as their own main files. Neither are the
~34 `when defined(windows)` and 13 `when defined(macosx)` blocks inside the
modules that *are* gated. Mutation-proved: the exact R4-4 unsound call placed
inside a `when defined(windows):` block gives `RC(linux)=0` and `RC(win)=1`, and
an unused import in `lock/windows.nim` is invisible both to the full gate and to
the Windows leg's own `nim check`, which carries neither `--warningAsError` flag.

The half that makes it High: **nine real unused imports exist on the macOS target
right now, on a clean tree** — in `process/procscan.nim`, `process/cgroup.nim`,
`process/caps.nim` and `process/posixcore.nim`. R4-6's stated motivation is that
*"an unused import in `src/` is a HARD build failure for a consumer while being
invisible here"*, and `ci.yml`'s `macos-latest` leg runs Nim natively without the
gate. So a macOS consumer building with the flag this project recommends cannot
build crisol today, and the gate written to prevent exactly that could not see
it.

The census was one-dimensional in a way worth naming, because it is not the same
error as the earlier count mistakes: it enumerated **modules** carefully and
correctly — the 61-of-65 closure claim was verified against `nim genDepend` and
holds exactly, with precisely `depparse`, `icbaseline`, `report` and
`unittest_shim` out of closure — and then treated "every module" as equivalent to
"every compilation". For a codebase whose whole subject matter is per-platform
toolchain behaviour, the target is a dimension of the population, not a detail.

### R5-4 and R5-5 — two doors into the same room, and R4-1 closed one of them

R4-1's degrade is documented as firing on *"a candidate that answered and will not
identify itself"*. Its implemented condition is `not hasDottedVersion(line)`
where `line = versionLine(output)` — and `versionLine` returns the first line
carrying a dotted token **if any line does**. So the real predicate is "no line
in the entire output contains a `<digit>.<digit>` anywhere", which is a strictly
smaller set. One incidental dotted token and the degrade never fires.

Measured, not read: a poisoned `cl` whose rc=0 output carries an SDK version
echoed in a `D9024` diagnostic leaves the half `cfsKnown`, folded with mingw
gcc's `13.2.0` banner, `toolchainUnsound` false, publishing to shared L2 — R4-1's
own named laundering scenario verbatim. Worse in one way: with no bystander at
all, the half's entire text is a pure diagnostic that cannot vary with the
installed toolset, so two hosts with **different MSVC toolsets** fold to an
identical compiler half. And the backstop is disarmed by the same token, because
`toolchainUnsound`'s third disjunct tests the same predicate — the guard round 4
accepted as a declared backstop fails on exactly the input that slips past the
primary check. `cl : Command line warning D9024` genuinely echoes the offending
token, and `CL`/`_CL_` routinely carry vcpkg/Qt/SDK paths containing
`digit.digit`.

The fix is constrained in a way that matters: **`hasDottedVersion` and
`versionLine` must not change.** `versionLine` also selects ldd's single-dot
runtime banner, and R3-11 already established that requiring two dots would push
the runtime half back onto the positional first-line rule issue #22 existed to
remove. So the tightening belongs at the degrade site — distinguishing a *banner*
from a *diagnostic* — and must not reject a localized `cl` banner, since
locale-proofing is why `hasDottedVersion` exists at all.

R5-5 is the same fix's other half, and it is dark. The empty-output skip was
deliberately placed *below* the check, with a comment asserting that as measured
behaviour. Hoisting it back — the pre-R4-1 order, and what a tidying refactor
would naturally produce — leaves `test_ccprobe`, `test_cachedispatch`,
`test_render`, `test_issue23_cc_identity` and `test_w3_cc_liveness` all green,
because no fixture anywhere produces `(output: "", ok: true)`.

So round 4's report that R4-1 "HELD" was true of the input class its tests pose,
and I passed it on in good faith. What was never done is separating the
documented predicate from the implemented one — which is a different question
from "does the test go red when I delete the fix", and the one a mutation proof
cannot answer on its own.

### R5-9 and R5-15 — the same finding about method, at two scales

The block justifying the companion-overload remedy claims *"hundreds of call
sites (~450 in tests)"*. That figure is the aggregate for
`execute`/`initDepGraph`/`loadDepGraph`; `cacheEnabled` is not in it. Measured:
`cacheEnabled` 27 test sites, `shouldStore` 25, `buildRunPlan` 26. Off by ~17×,
and its sibling block one file away gets it right — so it is transcription, not
measurement. At 27 sites the cheap remedy was a `sed`, and the population was
**sized by inheritance rather than measured**.

The larger version of the same error is the census tool itself. `planner.nim`
prescribes `grep -rl "SOUNDNESS-PARAMETER WARNING" src/`, and **that grep can
only return sites someone already annotated.** It is structurally incapable of
finding a new one. That is why the population grew in round 2, round 3, round 4
and again in round 5 — four consecutive rounds — and I wrote the pointer that
guarantees it keeps happening.

A reviewer demonstrated the method that works and takes about two minutes:
enumerate every signature under `src/` whose parameter list contains a `=` (107
of them), then judge each by **direction** — does omitting it weaken a key, a
staleness comparison or a trust gate, or does it fail safe? That separates the
handful that matter from seams-defaulting-to-real, capacity and telemetry knobs,
and genuinely fail-safe defaults like `depgraph.updateEntry`'s `closureHash = ""`
(which forces `cdStale`). It found one real miss outside R4-4's set:
`artifactid.artifactKeyHash`'s `normalizedCcCmd = ""`, a defaulted cache-key
input. Low in effect today, because it feeds only Stage-M measurement and Stage R
was deleted 2026-07-30 — omitting it over-counts sharing in a report rather than
serving a wrong artifact. Noted for whoever revives an object cache, and note
also that `test_artifactid.nim` currently pins
`artifactKeyHash("body","closure") == artifactKeyHash("body","closure","")`,
which is the "assertion pins the defect in place" shape R4-1 was about.

Direction-judging is not mechanisable, so the remedy is the shape
`ci/assert-subset-honesty.sh` already uses here: enumerate mechanically, compare
against a pinned human-classified set by exact-set equality, fail in **both**
directions. A new defaulted parameter fails as unclassified; a vanished one fails
as a stale pin.

**Resolution (fix round, same session).** Both landed, and the census half landed
as a gate rather than as a better instruction.

*R5-9.* `cacheEnabled` measured: **29 call sites, 26 of them omitting the
parameter** (tests 27, src 2). The transplanted "~450" was off by roughly 17x. The
comment now states the method so the figure re-derives — strip from the first `#`,
skip the two declaration lines, count `cacheEnabled(` — and reaches the honest
conclusion instead of the retrofitted one: *at 26 sites the churn is a `sed`, not a
hand edit, and "too much churn" is NOT why this overload exists.* The real reason,
consistency with its siblings, is stated with the siblings named and no count.

*R5-15(a).* `artifactid.artifactKeyHash` got the class remedy in full: default
removed from the 3-arity proc, `{.deprecated.}` 2-arity companion forwarding `""`,
`SOUNDNESS-PARAMETER WARNING` header. Churn was zero — the one `src/` caller already
passed a real value, and the 17 test call sites bind the companion. Two independent
reasons are recorded in the source: RFC-0004 requires Stage M to measure on the
exact key material Stage R would use, so the default is a live under-invalidation
the moment an object cache returns; and `ccIncludeClosure`'s `roots` had its default
removed at CR10 on identical reasoning with an equally telemetry-only blast radius,
so treating this one differently would be the inconsistency.

`tests/unit/test_artifactid.nim`'s pinned equality still holds unchanged because the
companion forwards `""` — but **what it pins changed without the assertion
changing**, from a default's value to the companion's forwarding contract. Its name
and doc said "the third parameter defaults to ''", which is now false. Rewritten;
this is the R5-6/R5-25 class arriving in a test file, and the only reason it was
caught is that the fix lane reported it as out-of-lane rather than leaving it.

*R5-15(b), the method half.* New `ci/assert-defaulted-params.sh`, wired into
`ci.yml` as the first step of the linux job (no Nim, no network, no deps, source
text only). It pins **197 records** over `signatures=1010
with-parameter-lists=1010` as an exact set in the form
`<path>:<routine>:<parameter>` — no line numbers, because citations rot here (R5-23)
— and **fails in both directions** like `ci/assert-subset-honesty.sh`: a new
unclassified parameter, and a stale pin. Exit 2 is reserved for a broken
enumerator, including zero signatures found, which it refuses to report as a clean
tree. The allowlist carries a one-line reason per record in five buckets: A
injection seams 39, B fail-safe defaults 35, C capacity/policy/telemetry knobs 112,
**D documented soundness exception 2** (`runner.execute`'s `ccVersion` and
`nimVersion`), E direction named but narrowest margin 9. The script itself makes no
judgement and reads no intent — it only pins, which is what makes it a gate rather
than an opinion.

Three things about it are worth keeping:

- **It answers R5-15's actual complaint.** The finding was not "one proc was
  missed"; it was that the prescribed remedy was a grep a reviewer runs by hand,
  which is structurally incapable of noticing the next one. A pinned exact set is.
- **Multi-line signatures were the whole risk, and were proved.** Only 29 of 187
  records at proof time came from single-line signatures; **123 came from
  signatures spanning three or more lines** — `runner.execute` alone is 63 lines
  and 12 records. The B mutation planted a new default on its own continuation
  line inside `ccIncludeClosure` and was caught. A line-oriented scanner would
  have passed that.
- **`globstar`, not `git ls-files`, and that choice was load-bearing.**
  `git ls-files` under-enumerated `src/` by the two untracked modules
  (`ccidentity.nim`, `toolrun.nim`): 76 files instead of 78, 969 signatures instead
  of 1010, **11 records missing**. A new module is the likeliest place for a new
  defaulted parameter to arrive, so a tracked-files-only enumerator would have had
  its hole exactly where the gate matters most. This is the same 76-vs-78 gap the
  coverage assertion in R5-26 found from the other direction, in the same session,
  by a different method — which is the strongest evidence either measurement is
  right.

**Left for a reviewer's eye, not deferred silently.** Bucket E is the nine records
whose direction is named but whose margin is narrowest: `ccidentity.ccKnown:digest`,
`ioutils.exclusiveCreate:noFollow`, `ioutils.createOverwrite:noFollow`,
`discover.matchGlob:fold`, `gitdiff.changedFiles:base`, `api.changedOnly:baseRef`,
`api.failedOrChanged:baseRef`, and both `cachedispatch.shouldStore:cacheable`
overloads. Each is pinned with its reason, so none can change unnoticed; none is a
present-tense defect.

And the census independently re-surfaces **R5-24**: `planner.plan`'s `nimVersion`
and `ccVersion` are still defaulted, and they are the same pair `runner.execute`
documents as the census's only bucket-D soundness exception. R5-24's recommendation
is to delete them outright, which is stronger than classifying them — see that
section. Whoever acts on R5-24 also removes two census records.

### What held, independently re-derived

Nine fixes or fix-halves held under mutation, none taken from round 4's ledger:

- **R4-1's degrade mechanism and all three over-correction controls.** Deleting
  `sawUnidentifiable` reddens exactly the two intended assertions and nothing
  else; moving the degrade above the `not ok` check reddens all three controls,
  including "an ABSENT candidate is still dropped silently". The `3c-iii` suite
  goes through the real `ccVersion` → `$` → `parseCcFingerprint` round trip and
  asserts the runtime half `cfsKnown` *first*, so only the compiler half can trip
  the gate. It sits above the file's `when defined(posix)` line, so it runs on
  all three legs.
- **R4-2's `p.kill()`, now genuinely observable.** Replacing it with a no-op:
  `survivors.len was 1`, `pid 168 (state S)` — while `elapsed=14012ms` against a
  30 s ceiling, so the timing half stayed green. Round 4's diagnosis reproduced
  precisely. The anti-vacuity guard is live too: blinding `procsRunning` fails the
  self-check while the escalation test still reports `[OK]`, which is the hole
  that test exists to close.
- **R4-L2/L3's derived ceiling.** Raising `SlackMs` to 20 s trips
  `static: doAssert CeilingMs + 10_000 <= ChildLifetimeMs` with its own message
  intact.
- **All four new `test_depgraph.nim` blocks, individually.** The naive mutation is
  masked — a pre-existing block aborts the file first — and the reviewer found
  that the pre-existing blocks use plain `assert` while all four new ones use
  `doAssert`, so `--assertions:off` isolates them exactly. Each block reddens on
  its own mechanism, including the priority block, which is the unique observer of
  nim-before-cc ordering.
- **R4-4's compile-time proofs**, with the exact error text, plus confirmation
  that wholesale `export planner` does not trip the gate while
  `planner.cachePath` carries a companion.
- **R4-6's `{.push warning[Deprecated]: off.}` is exactly one statement wide** —
  proved three ways, including that a consumer reaching `cacheEnabled` *through*
  the guarded re-export still gets the error at its own line, so the suppression
  does not leak.
- **R3-8's loader invariant**, both halves: neutering the `ccMismatch` discard and
  deleting the success-path re-stamp each redden a specific new assertion.
- **The 61-of-65 closure claim**, verified against `nim genDepend` rather than a
  hand-rolled parser (one reviewer's hand parser said 28 and was wrong — recorded
  so round 6 does not repeat it).
- **The B2 triage**, including the part that matters for completeness: the
  inventory is not a frozen literal, because `live ⊆ union` is derived from disk,
  so a new posix importer fails until triaged.

Two guards re-examined and deliberately left as declared backstops, matching
round 4's disposition: `toolchainUnsound`'s third disjunct (unreachable from
production once R4-1 is in place, but genuinely pinned over its own input space —
deleting it reddens a case), and `terminateAndReap`'s second bounded wait. The
reap half is unobserved (R5-19) and that is a *declared* gap, not a discovered
one; closing it needs a `/proc/<pid>/stat` `Z` check rather than a `cmdline`
scan.

### R5-24 — `plan`'s two vestigial parameters, and the recommendation on them

R3-8 removed `decideCompile`'s `nimVersion`/`ccVersion`, and `decideCompile` was
`plan`'s only reader of them, so `plan` now takes two parameters its body never
touches. Nim does not warn on an unused parameter, so **no gate can see this** —
not the deprecation gate, not `UnusedImport`, nothing. It is recorded here with an
id because round 5 found it stated in the ledger as "a live question, deliberately
not answered", which is a row in neither list (R5-13).

Low as it stands. The Medium in this area was R5-6, the comment claiming the
parameters *are* used, and that is fixed regardless.

**Recommendation: remove them, as its own change.** The reasoning, because two of
the three arguments I originally gave for keeping them do not survive scrutiny:

- *"R4-4's call-shape census is an independent reason to keep the signature"* —
  conflates two questions. The census is evidence that the deprecated-companion
  remedy cannot be applied cheaply to `plan` (four incompatible call shapes, with
  `forceCompile` wedged between the two defaults). It is not evidence that the
  parameters should exist.
- *"a caller threading real probe values documents its own soundness posture"* — a
  discarded parameter documents nothing. The caller's own `execute`/`clean` call
  does that, and is unaffected by `plan`'s signature.
- *"the values are what `runner.execute`/`clean` feed to `toolchainFingerprint`"* —
  true, and an argument for **those** procs' parameters, not for `plan`'s.

Against keeping them: a parameter that gates nothing is worse than the
defaulted-soundness-parameter pattern this project spent four rounds eradicating,
because no remedy makes it visible — no deprecation fires, no gate trips, and the
only thing between a future reader and the wrong conclusion is prose. **That prose
has already failed once, inside the R3-8 fix itself** (R5-6), and then misled a
second reader in real time: the R5-1 fix lane read the comment, concluded the
parameters "feed `toolchainFingerprint`, so I read it as intentional, not a
finding", and moved on. That is the concrete cost, observed rather than predicted.

Cost of removal is bounded and, unlike the deprecation work, **fully
compiler-enforced**: an arity reduction has no silent form, so the compiler names
every site. Two call sites in `src/` (`pipeline.nim`, `runner.nim`) and roughly 25
in `tests/`. Target signature: `plan(config, eps, graph, forceCompile = false)`.
Pair it with deleting the `SOUNDNESS-PARAMETER WARNING` block above `plan`, which
post-R3-8 warns about parameters that cannot affect soundness at that site and
whose "NARROWED round 5" paragraph is now longer than the thing it narrows.

**One decision, not two.** If `crisol/planner` should instead become supported
library surface, then the parameters stay, the deleted defence-in-depth arms come
back, and RFC-0003's boundary needs amending. Today this document keeps that
boundary question open while having already spent the answer — R3-8's whole
justification was that `crisol/planner` is *not* contracted surface. Whoever
resolves R5-24 resolves that too.

### R5-25 — the same class, ten more sites, and one clause that was never true

Found by the R5-7 lane while auditing its own three files, and it is a larger
population than the finding it was dispatched for. Ten further sites across
`depgraph.nim`, `api.nim` and `ccidentity.nim` assert that
`planner.decideCompile` performs a toolchain-version comparison. They were true
when written and R3-8 falsified all of them in one edit, without a sweep.

The part that is not merely rot: R4-4's `SOUNDNESS-PARAMETER WARNING` on
`pipeline.buildRunPlan` claimed `nimVersion` governs a second surface because
"it flows through `plan` into `planner.toolchainFingerprint` and thence
`planner.cachePath`". **That was false when round 4 wrote it** — checked against
`630ecc6`, where `plan` called neither. Round 4 wrote a mechanism sentence it had
not traced; round 5's R3-8 then edited around that sentence without re-checking
it; and the same unverified clause had already been copied into the
deprecated-overload note *and* into the `{.deprecated.}` pragma string, so one
untraced claim reached three places and became a compiler-emitted message.

That is a different defect from R5-6 and R5-7, which are true-then-invalidated.
This one was never true, and the mechanism that let it spread is worth naming:
a rationale comment written at the same time as the code it justifies gets the
code reviewed and the rationale taken on faith.

Fixed in round 5: the four `depgraph.nim` sites (module doc, the History-9
bullet's `""`-convention sentence, the `DepGraphHeader.ccVersion` field doc, and
`loadDepGraph`'s check-ordering comment, whose "mirroring `decideCompile`'s own
check ordering, below" also dangled into the wrong file) and the
`{.deprecated.}` pragma message; the `api.nim` and `ccidentity.nim` sites were
closed later, out-of-lane.

**Round 6: the population was never the ten sites.** Five consecutive rounds
declared this population complete, and each time the declaration rested on a
hand enumeration of files someone had already looked at. The sixth review found
an eleventh site in a file that was never in the list — `clean.nim`'s bin-prune
comment credited the next-run recovery to "`decideCompile`'s own W3 fix,
planner.nim", which R3-8 had removed (the recovery is `loadDepGraph`'s header
discard, after which every entrypoint lands on `decideCompile`'s "no closure
record" arm). A population defined by who happened to look cannot be closed. It
is now defined by a command, run from the repo root:

```sh
{ grep -rnE "#.*('s (own )?([A-Za-z0-9-]+ )?fix\b)" src tests --include=*.nim
  grep -rnE "#.*\`[A-Za-z_][A-Za-z0-9_.]*\`.*\b[a-z_0-9]+\.nim\b|#.*\b[a-z_0-9]+\.nim\b.*\`[A-Za-z_][A-Za-z0-9_.]*\`" src tests --include=*.nim
  grep -rnE "#.*\b(R[0-9]+-[0-9]+|CR[0-9]+|W[0-9]+)\b" src tests --include=*.nim
} | sort -t: -k1,1 -k2,2n -u
```

That is: every comment line (`#` or `##`, full-line or trailing) in `src/` and
`tests/` that makes an "X's fix" attribution, names a backticked identifier on
the same line as a `.nim` file, or carries a W-/R-/CR-series finding id. On
2026-09-24 it returned **1028** lines (493 in editable `src/` files, 132 in
the five `src/` files other lanes own, 403 under `tests/`). Every line was read in its enclosing comment block and verdicted
against the current tree: no checkable claim (history tag, or explicitly past
tense) 342, verified true 612, stale **74** (`src/` 43, `tests/` 31). Three
more stale sites the census also matches were fixed just before it ran
(`clean.nim`'s, and two in `artifactid.nim`'s module doc), so the census-visible
population was **77**. Four files were then substantially rewritten by
another lane (`ccidentity.nim`, `test_ccprobe.nim`, `test_cachedispatch.nim`,
and the new `test_cc_banner_selection.nim`); their 128 current census hits were
re-verdicted from scratch (74 true, 48 no claim, **6 stale**), bringing the
census-matched stale total to **83**. Reading the blocks
surfaced roughly forty-five more stale claims on lines the census does not match
(for example the two deprecated `loadDepGraph` pragma strings, which said
omitting `ccVersion` "disables the cc-version staleness check" when
`loadDepGraph`'s `ccMismatch` expression actually discards any graph stamped
with a real cc identity — the same false "passing `""` disables the check" wording
also sat in `loadDepGraph`'s own doc, `pipeline.buildRunPlan`'s doc and its
`nimVersion` pragma string; a `planner.nim` "~450 test call sites" eleven
lines below that doc's own corrected 353/326; and five comments crediting
`cachedCcVersion` as the memoised probe or as `api.nim`'s source, when it is
`cachedCcFingerprint` and `$ccProbe()`).

What the stale set looked like, so the next reader knows what to grep for:
rotted line numbers (`closure.nim:1632`, `runner.nim:379-393`, `paths.nim:289`,
`httpraw.nim:529`, `api.nim:~1514`); procs cited in the module they left in a
split (CR7 `ccprobe` -> `ccidentity`/`toolrun`, r27 `posixcore` ->
`caps`/`procscan`); removed defaults still described as defaults (R3-7, CR10,
R2-D3); procs that never existed under the cited name (`resolveMangled`,
`keyInputsFromRunPlan`); "leaf module" import claims falsified by one later
import; and the R5-25 original, `decideCompile` credited with toolchain
staleness.

All fixed — comment text, plus three `{.deprecated.}` message strings (the two
`loadDepGraph` overloads and `pipeline.buildRunPlan`'s). Verified: `nim check
--path:src src/crisol.nim` clean; `nim c --compileOnly` clean on all 28 test
files touched; `nim r` green on `test_ccprobe.nim` (104) and
`test_cc_banner_selection.nim` (26); `ci/assert-defaulted-params.sh` unchanged
(197 records). **Open for the census-matched population: 0.** One off-census
residue is left deliberately: the test NAME at
`test_rfc7_a3_ioutils_ownership.nim`'s `std/posix import count outside
process/, ioutils, lock, signals is zero` still names `signals.nim` and omits
`httpraw`/`toolexec`/`paths` — a test rename, not a comment fix, so it is left
for whoever owns that suite.

**What the census cannot catch, stated so nobody reads "0 open" as "all
citations true":** a claim with no backticked identifier on the same line
as a file name and no finding id (a proc named in prose three lines away from
its file; `planner.nim`'s call-site count above was found only because a
reviewer quoted it); citations in `.nims`, shell, Python, YAML or Markdown,
including this document; citations into Nim's own stdlib or upstream sources
(`osproc.nim:664`, `extccomp.nim:877`), which were checked where a 2.2.10 tree
was at hand and otherwise marked unverified; and any claim that becomes false
after 2026-09-24. The verdicts themselves are human judgement over a mechanical
population, so the "no checkable claim" bucket (342 + 48 lines) is where a
misjudgement would hide. The census itself drifts — it returned 1066 lines
after the fixes, because corrected comments carry identifiers and ids too, and
other lanes kept editing. Rerun the command and re-verdict the diff; do not
extend a list.

Two related rots the same lane caught in its own files, both recorded because
they show a remedy re-rotting: R4-7 replaced planner's rotted line-number census
with *fresh line numbers*, and one of the three
(`test_nimcache_persistence_real.nim:198`) had already drifted one round later —
now cited by grep anchor, each anchor run and confirmed. And a
`{.deprecated.}`-adjacent note plus two mis-attributed quotes in
`test_w3_cc_liveness.nim` (a promise attributed to `cachedCcVersion()` that lives
on `cachedCcFingerprint()`, and a quote attributed to `ccprobe.nim` that is in
`ccidentity.nim`).

### R5-26 — the gate's coverage claim, made machine-checkable

Opened in round 5 while closing R5-11, from the fix lane's own observation that
the Medium it had just fixed left a residue. R5-11 was "two hand-duplicated gate
copies, already disagreeing, with nothing detecting drift". Collapsing them to one
script removed the *disagreement* but not the *class*: the surviving copy still
decided by hand which modules and which targets it compiled, and still asserted in
a comment that the union covered all of `src/`. A new module landing out of
`src/crisol.nim`'s import closure on all three targets, and not named in
`OUT_OF_CLOSURE`, would be in no gate at all — every check green, the header still
reading "no exemptions".

That is not hypothetical in this repo. It is R5-2 exactly: nine real unused imports
standing unnoticed on the macOS target, on a clean tree, under a comment claiming
full coverage. The remedy for a coverage claim maintained by a human instruction to
re-measure is never a better instruction.

**Closed by measuring, at almost no cost.** The three aggregator passes already had
to compile everything, so they now run as `nim c -d:nimBetterRun --compileOnly`
rather than `nim check`, and the `depfiles` key of each nimcache's `crisol.json` is
the compiled-set manifest as a side effect. `ci/assert-gate-coverage.py` unions the
three manifests, adds the individually gated main files, and exits non-zero naming
any `.nim` file under `src/` that no pass compiled. Codegen also type-checks
strictly more than `nim check` does, and cross-generates on any host because
`--compileOnly` never invokes a C compiler. Whole gate: **26.6 s**, down from 31 s.

Two design points worth keeping:

- **Coverage is credited conservatively.** An individually gated main file counts
  only for itself, never for its own import closure. The check can therefore
  over-report — name a module some secondary pass does in fact compile — but cannot
  under-report. A false alarm costs one entry in `OUT_OF_CLOSURE`; a false pass
  costs R5-2.
- **`python3` is required, not optional.** Absent, the gate exits 2 and says so. A
  coverage check that skips itself when a tool is missing reports success having
  verified nothing, which is precisely the darkness class
  `ci/assert-subset-honesty.sh` exists to audit.

**The first run corrected the number it was added to defend.** It reports **78 of
78** files, per-target closure reach 71/66/70 — not the 76 and 69/64/68 in the
header. Both are right about different sets: 76 is what `git ls-files` tracks, 78
is what is on disk, and the two untracked modules are `ccidentity.nim` (CR7's
completed split) and `toolrun.nim`. A consumer that vendors the tree compiles all
78, so the check counts all 78, and the header now says so. This is the third
stale-figure finding of the round after R5-9 and R5-18, and the first where the
figure was corrected by a machine rather than by a reviewer.

**Mutation-proven in four directions**, in an isolated copy (`src ci _deps nim.cfg
crisol.nimble` into a fresh `mktemp -d`, per the shared-nimcache rule):

| Mutation | Expected | Observed |
|---|---|---|
| control, unmodified copy | pass | `rc=0`, "78 of 78" |
| add `src/crisol/orphan_mut.nim`, imported by nothing | fail, naming it | `rc=1`, "1 of 79 ... `src/crisol/orphan_mut.nim`" |
| drop `report` from `OUT_OF_CLOSURE` | fail, naming it | `rc=1`, "1 of 78 ... `src/crisol/report.nim`" |
| aggregator loses `-d:nimBetterRun` | cannot tell, not a pass | `rc=2` |
| `python3` unavailable | cannot tell, not a pass | `rc=2`, refusal message |

The third is the load-bearing one: it proves the explicitly-gated-mains credit is
live rather than a no-op, and independently re-confirms that `report.nim` really is
out of closure on all three targets. The last two matter because the two ways this
check could fail *silently* are a missing manifest and a missing interpreter, and
both exit 2 rather than 0.

Residual, stated rather than left implicit: the check proves every module is
compiled by *some* pass, not that every module is compiled on every target it can
reach. A module in the Linux closure only, carrying a `when defined(windows)` block,
is covered by this check while that block stays unexamined. Closing that needs
per-target rather than union accounting and is not obviously worth it — the three
aggregator passes already cross-target, so the gap is confined to modules reachable
from only one of them.

### Verification state at the end of round 5

The authoritative sweep is **258 entrypoints, not 255** — a count I had been
restating for three rounds. The drift is five test files added across rounds 3
and 4, still untracked. Round 5's sweep before fixes: **256 pass / 2 fail**,
those being `test_fallback.nim` (the known-benign bind-mount fold-policy
artifact, never red on CI) and `test_nimcache_persistence_real.nim` (R5-1).
`test_api.nim` (R4-11) **passed** this run, consistent with its measured
one-in-three rate.

`ci/run-tests.sh` genuinely cannot run on this host: under `--network=none`,
nimble tries to satisfy `requires "nim >= 2.0"` from the network and dies. The
sweep was therefore run by replaying the `crisol.nimble` `test` task body
verbatim — same discovery rule, same per-file command, sliced across four
containers each with its own `XDG_CACHE_HOME` and never a shared `--nimcache`.
Worth recording as the standing method, since this is the third round to hit it.

**Sweep after round 5's fixes: 259 entrypoints, 258 pass / 1 fail.** The one
failure is `test_fallback.nim`, the documented bind-mount `a.fold == b.fold`
artifact, byte-identical to its pre-fix failure and never red on CI.
`test_api.nim` (R4-11) passed, consistent with its measured one-in-three rate.
Nothing that round 5 touched is red, and the count moved 258 -> 259 for exactly
one reason: `tests/integration/test_r5_10_toolchain_unsound_wire.nim`, added by
R5-10's fix. The count is worth re-deriving rather than restating each round --
it was wrong for three rounds at 255, and it is a property of the tree, not a
constant.

Method, for the fourth round running, and it should stay recorded: replay the
`crisol.nimble` `test` task body verbatim -- same discovery rule (`test_*.nim`
under `tests/unit`, `tests/integration`, `tests/conformance`, sorted), same
per-file `nim r --hints:off --warnings:off --path:src` -- sliced across four
containers, each with its OWN `XDG_CACHE_HOME` and never a shared `--nimcache`.

Both CI gates pass on the tree as it stands:

    bash ci/assert-defaulted-params.sh   -> exit 0, 197 records, signatures=1010
    bash ci/source-soundness-gate.sh     -> exit 0, 78 of 78 files, 26.6 s

## Round 6 re-review — 2026-09-24 (base `630ecc6`, still uncommitted)

Dispatched on **round 5's own fix diff**, with the same three standing dimensions
run in parallel (security; design and ergonomics; liveness and completeness).
Scoped the same way as rounds 4 and 5: every round-5 change carries an `R5-N`
marker. Every brief carried the same warning as before: RFC-0009's separate
review numbers its rounds the same way, and its files are not this review's.
Fix lanes ran on Opus 5.5 at Corey's request.

**No Critical and one High. For the third consecutive round, the High is in the
previous round's remedy.** R6-S1 is a defect in R5-4's `ccidentity` predicate.
This pattern is now the most reliable signal the loop has: round 7 should look
hardest at round 6's own fixes, starting with `bannerLine`.

### Findings

| # | Sev | Where | What | Status |
|---|---|---|---|---|
| R6-S1 | **High** | `ccidentity.nim`, `ccIdentity` | the selector and the acceptor disagreed. `versionLine` (first dotted token) *selected* the line and `namesCompilerVersion` *judged* it. Poisoned `cl` captures C (a wrapped D9002 with an unquoted `3.11` inside a quoted path), D (a bare echoed command line) and E (a LINK diagnostic plus an unprefixed SDK-path line) were **believed**: `cfsKnown`, and they would publish to L2 | **fixed**. New `bannerLine`: one predicate both selects and accepts. The line predicate is tightened. 26-test matrix, and every arm is mutation-proven in isolation |
| R6-D1 | Med | `ccidentity.nim`, `api.nim` | the same root cause, seen from ergonomics. F1 (banner, then D9024) was believed, and F2 (the same lines reversed) was refused. The verdict depended on merged-stream order | **fixed** with R6-S1. F1 == F2. One deliberate widening (see below). The `api.nim` warning ladder is now exhaustive over `toolchainUnsoundReason` |
| R6-L2 | Med | `ccidentity.nim`, `hasDiagnosticCode` | no test observed the diagnostic-code arm | **fixed** with R6-S1. The arm has its own case in the matrix, and its mutation kills exactly that case |
| R6-S2 | Med | `ci/assert-defaulted-params.sh` | the census awk depth walk counted parens inside string literals and never reset state at `FNR==1`. One `"("` default blinded the rest of that file **and every later file** | **fixed**. Masked-line scanner, per-file reset, and exit 2 for anything open at EOF. Identical output under busybox awk, mawk 1.3.4 and gawk 5.3.2 (this also closes L10) |
| R6-D2 | Med | `ci/assert-defaulted-params.sh`, its allowlist | the census pinned parameter *names*, not *values*, so a flipped default passed | **fixed**. Records now carry `= <default>` and the drift report has a VALUE CHANGED section. All 197 records regenerated with their reasons kept verbatim. New `ci/assert-defaulted-params.selftest.sh`, wired into `ci.yml` this round. Also replaces the "107" figure (S3/D9/L7) with the measured 197/1014 and the command that produces it |
| R6-L1 | Med | `api.nim` → `compilereport.nim` | the `toolchainFp` producer chain could be cut at any hop with zero red tests | **fixed**. New `tests/integration/test_toolchainfp_producer_chain.nim`, plus assertions in `test_workerplan.nim` and `test_measureworker_real.nim`. 7-hop chain, 17 mutants, all red |
| R6-L3 | Med | `ci.yml`, B4b windows/macos steps | under `-eo pipefail`, a failing suite ended the step before `ci/assert-subset-honesty.sh` ran. The audit was dark exactly when it mattered | **fixed**. `set +e` bracket, both exit codes logged, and the step fails if either one fails. 4-combination table verified |
| R6-D3 | Med | `ci/source-soundness-gate.sh` | a gate failure did not say which pass, main file or target produced it | **fixed**. A `run_pass` helper names all three and points at the header's two explanatory sections. Mutation-verified ×3 |
| R6-D4 | Med | `clean.nim:230`, and the R5-25 **population** | an 11th R5-25 site: `clean.nim` credited `decideCompile` with the W3 fix, which R3-8 had removed | **fixed**. The population is now defined by a rerunnable grep census: 83 stale, all fixed, and ~45 neighbours also fixed. Recorded in the R5-25 row and subsection above and not repeated here |
| R6-D5 | Med | this doc | five stale figures: severity counts, 76/69/64/68 vs 78/71/66/70, "3 targets × 18" and "drifted by five" | **fixed** during verification |
| R6-L4 | Low | `ccidentity.nim` | no test observed the English-phrase arm | **fixed** with R6-S1 |
| R6-L5 | Low | `ccidentity.nim` | no test observed the `quoteFlanked` arms | **fixed** with R6-S1. `quoteFlanked` no longer exists |
| R6-S4 | Low | `ccidentity.nim` | `quoteFlanked`'s doc cited a token that the predicate did not reject | **fixed** with R6-S1. Replaced by `freeStanding` |
| R6-D7 | Low | `planner.nim:176` | the "~450" call-site figure, again | **fixed** (folded into R6-D4) |
| R6-D8 | Low | `artifactid.nim` | a doc's claim about the `roots` default did not hold | **fixed** (folded into R6-D4) |
| R6-D11 | Low | `closure.nim` | citations that had rotted | **fixed** (folded into R6-D4) |
| R6-S5 | Low | `ci/assert-subset-honesty.sh` | the honesty gate does not audit `test_cc_backend` | deferred (Low, per mandate) |
| R6-S6 | Low | `ccidentity.nim` / `api.nim` | a doc claims `$(CcFingerprint)` round-trips, and nothing proves it | deferred (Low, per mandate) |
| R6-S7 | Low | host dispatch | `shellSplit` on the host-dispatch path | deferred (Low, per mandate) |
| R6-D6 | Low | `api.nim` | a consumer of `crisol/api` has no way to construct a `CcFingerprintProbe` | deferred (Low, per mandate) |
| R6-D10 / L8 | Low | `dev` | the help text cites a fixed line range | deferred (Low, per mandate) |
| R6-D13 | Low | `artifactid.nim` | where the `roots` parameter sits in the signature | deferred (Low, per mandate) |
| R6-L6 | Low | `planner.nim` | no test observes the plan-time `$ccProbe()` | deferred (Low, per mandate) |
| — | Low | `tests/unit/test_rfc7_a3_ioutils_ownership.nim` | a leftover test NAME still says `signals.nim` | deferred (Low, per mandate) |
| R6-D12 / L9 | Low | repo root | `.sweep-tmp.sh` left behind | **closed**. Already removed |
| R6-S3 / D9 / L7 | Low | this doc, `ci/assert-defaulted-params.sh` | the census population was quoted as "107", a stale figure the census itself no longer produced | **fixed** in R6-D2's lane: replaced with the measured 197 records over 1014 signatures and the command that produces them (row added in round 7, R7-D3) |
| R6-L10 | Low | `ci/assert-defaulted-params.sh` | ubuntu-latest's `awk` is mawk, and the census had only ever run under gawk/busybox | **closed** by R6-S2's lane, which verified byte-identical output under busybox awk, mawk 1.3.4 and gawk 5.3.2 (row added in round 7, R7-D3) |

Totals, counted from the table by script: **27 rows**, of which **1 High, 9 Med,
17 Low**. **17 fixed** (1 High, 9 Med, 7 Low), **8 deferred** (all Low) and **2
closed** (one already removed, one verified). Every row has a terminal status.
(Round 7, R7-D3: the table previously lacked the S3/D9/L7 and L10 rows, which
the prose cited but no status column carried; the old totals were 25 rows, 15
Low, 16 fixed, 1 closed.)

### R6-S1 / R6-D1 — the selector and the acceptor were two different predicates

R5-4 fixed the acceptor. `namesCompilerVersion` became a real test of whether a
line identifies a compiler, and it was mutation-proven. Nobody checked which line
it was being asked about. `ccIdentity` still *selected* its candidate with
`versionLine`, the first line carrying any dotted token. The two predicates
disagreed, and every poisoned capture lived in the gap between them:

- Capture C is a wrapped D9002 whose quoted path contains an unquoted `3.11`.
- Capture D is a bare echoed command line.
- Capture E is a LINK diagnostic followed by an unprefixed SDK-path line.

All three came back `cfsKnown`: believed, and eligible for L2 publication. The
same gap made the verdict depend on line order (R6-D1). F1, a banner followed by
D9024, was believed. F2, the same two lines reversed, was refused.

**The fix removes the second predicate.** `bannerLine` both selects and accepts.
It returns the first line that *is* a banner, so a line can no longer be selected
without being accepted. The line predicate was tightened at the same time. A
banner line must have a free-standing version token of at least three components.
It must also have none of these: a diagnostic code, an English diagnostic phrase,
a `<program>:` prefix, a quote or a switch token.

- **Matrix:** `tests/unit/test_cc_banner_selection.nim`, 26 tests.
- **Mutation, one arm at a time:** each of the 8 arms, reverted on its own, kills
  exactly its own test and no other. Reverting only the selector (back to
  `versionLine`) kills F2.
- **F1 == F2** now holds by construction.

**One deliberate widening, on record.** A real banner that appears *after* a
dotted diagnostic is now believed. Before the fix, the diagnostic won selection
and the capture was refused. The diagnostic carries no toolset identity, so
refusing because of it protected nothing. That rationale is in `bannerLine`'s doc
comment, where the next reader of the predicate will find it.

**The warning ladder is now exhaustive.** `api.nim` now cases over
`toolchainUnsoundReason` with no `else` branch, covering `turSound`,
`turCompilerRefused`, `turBlind`, `turCompilerUnnamed` and `turHalfMissing`.
`turCompilerUnnamed` has its own message naming `CL` / `_CL_`. `ccUnavailable`
gained an `answeredUnidentified: bool` parameter with **no default**, so it cannot
become the next defaulted soundness input in R5-15's census.

R6-L2, R6-L4, R6-L5 and R6-S4 were each an arm of the old predicate that was
unobserved or misdocumented. The matrix above closes each one, or the arm no
longer exists.

### R6-S2 / R6-D2 — the census was itself an unverified parser

R5-15's census walks Nim signatures by bracket depth, in awk. It had two faults
that made each other worse. It counted `(` and `)` inside string literals, and it
never reset its state at `FNR==1`. So a single `"("` default left the walk one
level deep for the rest of that file and for every file after it. A census that
has gone blind gives the same report as a clean tree.

**Scanner.** The walk now runs over a masked copy of each line. The masking
handles `".."`, `r".."`, `ident".."`, `""".."""`, char literals, numeric suffixes
such as `0o600'u32`, `#` and `##` comments, and nested `#[ ]#`. State resets for
each file. If a signature, string or block comment is still open at EOF, the
census exits **2** (cannot tell). It never exits 0 or reports drift in that case.
The output is byte-identical under busybox awk, mawk 1.3.4 and gawk 5.3.2, which
also closes L10.

**Values, not names (R6-D2).** Each record is now
`<path>:<routine>:<param> = <default>  # <reason>`. The drift report has a VALUE
CHANGED section next to the new and stale sections. All 197 records were
regenerated with their reasons kept verbatim, and no reason contradicted its
value. Two reasons are imprecise; they are noted here and not rewritten:

- The `closure`/`depgraph` `ccRun` reasons abbreviate
  `realRunIn(config.projectRoot.absolutePath.normalizedPath)`.
- `initSupervisor`'s `installSignals` defaults to `true`, but `runner` and `api`
  pass `false`.

The "107" figure quoted under S3/D9/L7 is replaced with the measured **197
records over 1014 signatures**, together with the command that produces it.

**Self-test.** `ci/assert-defaulted-params.selftest.sh` mutation-tests the census
on temp copies of `src/`. Its cases cover literal and comment brackets, value
flips, anything left open at EOF, and an added and a removed parameter. It is now
a CI step that runs immediately after the census.

### R6-L1 — the `toolchainFp` producer chain, traced and pinned

Any hop from the API to the report could be cut with the suite still green. The
chain, as traced:

1. `api.runTestsWith`
2. `runner.execute`
3. `ExecCtx`
4. `buildCompileWorkerPlan`
5. `plan.json`
6. `measureworker` rows
7. the `artifactledger`/`compilecost` encoders, then the `compilereport` segments

New `tests/integration/test_toolchainfp_producer_chain.nim`, plus assertions in
`test_workerplan.nim` and `test_measureworker_real.nim`. **17 mutants, all red.**

### R6-L3 — the honesty audit was dark exactly when the suite failed

The B4b windows and macOS steps ran the suite and then
`ci/assert-subset-honesty.sh`, under `-eo pipefail`. A failing suite ended the
step before the audit ran. The fix brackets both commands with `set +e`, logs both
exit codes, and fails the step if either one failed. Verified on the exact
extracted step bodies:

| Suite | Audit | Old: audit ran? | New: audit ran? | New: step result |
|---|---|---|---|---|
| pass | pass | yes | yes | pass |
| pass | fail | yes | yes | fail |
| fail | pass | **no** | yes | fail |
| fail | fail | **no** | yes | fail |

### R6-D3 — a gate failure now says where it came from

`ci/source-soundness-gate.sh` runs 18 passes. A failure used to print the
compiler's error and nothing about which pass produced it. The new `run_pass`
helper names the pass kind, the main file and the `--os` target. It also points at
two header sections: **"WHAT THE TWO FLAGS ARE FOR"** and **"IF THIS GATE ERRORS
ON A LINE NOBODY TOUCHED"**. Mutation-verified in three places: a windows backend,
the aggregator closure and an out-of-closure module.

### R6-D4 — the eleventh R5-25 site, and the end of hand enumeration

`clean.nim:230` credited `decideCompile` with the W3 fix that R3-8 removed. This
site was outside the ten that R5-25 had declared complete. The finding is recorded
where it belongs, in the R5-25 row and subsection above. The population is now
defined by a rerunnable grep census rather than a list. The same pass corrected
two deprecation messages: `loadDepGraph` and `buildRunPlan` said that omitting
`ccVersion` "disables" the staleness check, which was false. R6-D7, R6-D8 and
R6-D11 were folded into that sweep.

### Deferred

Eight Lows are deferred, all under the standing mandate (fix findings above Low,
record Lows). None is a soundness defect on its own. R6-D6 is the one most likely
to matter to a consumer: `CcFingerprintProbe` is R5-10's seam, and it can
currently only be exercised from inside the package.

### Verification state at the end of round 6

**Sweep after round 6's fixes: 261 entrypoints, 260 pass / 1 fail.** The one
failure is the known fold-policy mismatch (`test_fallback.nim`, `paths.nim(275)
a.fold == b.fold`), which comes from the local bind mount and never reproduces on
CI. The count moved 259 -> 261 for exactly the two new files
(`test_cc_banner_selection.nim`, `test_toolchainfp_producer_chain.nim`). The
entrypoints were enumerated the way the nimble task does it (`walkDirRec`, which
includes the four files under `tests/unit/ssl/`).

Two further entrypoints failed in the parallel run and passed in isolation:

- `test_api.nim`: the known R4-11 flake (`perfBaselineUs was 0`). It passed on rerun.
- `test_rfc0007_a5_rusage_limits_wire.nim`: **this one is new to this handoff.**
  - In the parallel run (four containers at once), `firstEntrypoint` got crisol
    exit code 3 and stdout that is not JSON (`{ expected`).
  - It passed 3 of 3 runs in isolation.
  - Nothing round 6 touched is on that path, so it is recorded as a load-sensitive
    flake rather than a regression. Round 7's liveness dimension should confirm or
    refute that.
  - **Refuted as "load-sensitive" in round 7 (R7-L3):** exit 3 is crisol's
    lock-contention exit ("another crisol run is in progress"). The first test
    ran from the repo root and so took `<repo>/.crisol/lock`, which the other
    parallel containers' crisol runs held. Deterministic under contention, not
    load. Fixed: that test now runs from its own temp project root.

Other gates:

- `ci/source-soundness-gate.sh` exits 0, covering 78 of 78 files.
- `ci/assert-defaulted-params.sh` exits 0: 197 records over 1014 signatures.
- `ci/assert-defaulted-params.selftest.sh` exits 0, 8 of 8 cases.
- `ci.yml` parses to the five expected jobs.

### Round 7

Ran; see "Round 7 re-review" below.

## Round 7 re-review — 2026-09-25 (base `630ecc6`, still uncommitted)

Dispatched on **round 6's own fix diff**, same three standing dimensions
(security; design and ergonomics; liveness and completeness), scoped by the
`R6-N` markers. **Findings presented; round 7's fixes have LANDED** (parallel
lanes, all terminal). The status column below is the live record — a finding
that is not a row here does not exist (R5-14).

**One Critical and one High.** The Critical, R7-S6, is NOT among this loop's
fixes: it is pre-existing (proven against a clean `git archive` of `630ecc6`),
its remedy is a design question, and Corey split it out as a separate issue —
see "R7-S6" below and `## Open for Corey`. **For the fourth consecutive round,
the High traces to a prior round's remedy** — and this time not to its logic
but to the measurement it was founded on.

### Findings

| # | Sev | Where | What | Status |
|---|---|---|---|---|
| R7-S1 | **High** | `ccidentity.nim`, `ccIdentity`'s candidate loop | real `cl` exits **2** whenever `CL` is set to anything, so `not ok: continue` drops it as ABSENT and a bystander gcc/clang becomes the compiler identity (`cfsKnown`, eligible for L2). R4-1's founding measurement ("`cl /nologo` exits 0") was wrong — most likely `%ERRORLEVEL%` expanded at parse time. Measured with `cmd /v:on` + `!ERRORLEVEL!`: plain `cl` rc=0, `CL=/W4` rc=2, `CL=/nologo` rc=2 (and `cl /nologo` rc=2, also as the container's own exit code) | **FIXED**. Re-measured on real MSVC (`cmd /v:on`, `!ERRORLEVEL!`): plain `cl` rc 0; `CL=/W4` banner + `D8003` rc 2; `CL=/nologo` `D8003` only rc 2; `_CL_=/W4` ignored rc 0; `cl /nologo` (argument) rc 2; `(cl /nologo & echo pct=%ERRORLEVEL% bang=!ERRORLEVEL!)` prints `pct=0 bang=2`, reproducing the original mistake. `vccexe` with no reachable `cl` (Nim + mingw host): rc 1 with a traceback. Design: `runViaOsproc` returns `""` on every path that did not run the command to exit (stated in `toolrun`'s seam contract, pinned by the new `tests/integration/test_r7_probe_presence_contract.nim`), so `ok = false` with non-empty output means "ran and exited non-zero". `CcCandidate` gained a role: a `crDriver` (`cl`/`gcc`/`clang`/`cc`) that is present but failed is refused whatever it printed; a `crWrapper` (`vccexe`) is refused only if it relays evidence that `cl` ran (a banner line or an MSVC diagnostic code), else it reads absent. Both apply only under `cdVersionOnly`. `CcHalf.answeredUnidentified: bool` became `refusedDrivers: seq[string]` with a derived `answeredUnidentified()` accessor, and the warning names the drivers. Residuals, documented in code: a wedged driver times out, returns `""` and reads absent (it has its own warning); a wrapped `cl` that fails with neither banner nor code reads absent; `_CL_` is invisible to the no-argument probe. 26 mutants, all red. Windows end to end after the fix: plain → `turSound`/`cdmStored`; `CL=/W4` or `CL=/nologo`, with or without gcc → `<cc-unavailable>`, `turCompilerRefused`, `cdmToolchainUnidentified`, correct warning; mingw only → gcc believed, `turHalfMissing` (unchanged) |
| R7-S2 | Med | `ci/assert-defaulted-params.sh` | the census is blind to 7 signature shapes | **FIXED**. The census now finds routine keywords anywhere on a line, follows name/generics/params across lines, and accepts non-ASCII identifiers. UNPARSED exits 2, with a backstop that signatures equal with-params plus no-param-list. Anonymous procs and proc types are recorded as `anon_proc(<bound name>)` (114 in the tree, none defaulted). Object-field defaults are a new pinned class, `<path>:<Type>.<field> = <value>`: 34 pinned (32 `RunOptions` in `api.nim`, `ChildSpec.claimOrphans`, `TrustConfig.policy`). Gate: 231 records, exit 0. Self-test: 21 cases green under busybox awk, mawk 1.3.4 and gawk 5.3 |
| R7-D1 | Med | `ccidentity.nim`, `bannerLine`'s `hasQuote` arm | refuses a real localized banner: the French banner's apostrophe trips the quote rejection | **FIXED**. An apostrophe flanked by letters (including non-ASCII) is elision, not a quote. The French banner is believed; the quote-arm fixture is still refused |
| R7-L1 | Med | `api.nim`, the `toolchainUnsoundReason` warning ladder | exhaustive since R6-D1, but no test observes its arms | **FIXED**. New `tests/integration/test_r7_toolchain_warning_ladder.nim`: one real run per reason, stderr captured. Swap and silence mutants go red |
| R7-L2 | Med | `ci.yml` | the windows F16 and B4b steps were the only two without `if: always()`, so any earlier red step skipped the unit+conformance sweep AND `ci/assert-subset-honesty.sh` — the audit that judges the markers the earlier steps `tee -a` into harness.log. Same pattern on macos (CR2 producer, suite, timing) and in the `test` job (every step gated on the census) | **FIXED**. `if: always()` on windows W2, Fetch deps, `nim check`, smoke, F16, B4b; macos pre-check, CR2, suite, timing; `test` job every step after the census except its self-test, which genuinely needs a green census. B4b does not depend on F16 (the longpath test picks TIER A/B at runtime; a failed registry write degrades it to TIER B), recorded in the step's comment. `timing`/`cgroup` have no independent predecessor. `ci.yml` parses to the five jobs |
| R7-D2 | Med | this doc, Resume block and Stage table | Resume said "Remaining: slices 2-5" and "Still owed … the RFC-0007 addendum", contradicting `### Remaining` (all slices done) and the addendum at `0007-execution-substrate.md:643`; the Stage table showed #21 as "tracer GREEN (1a/1b/1c)"; `## #23 — NEXT` headed a DONE section | **FIXED**. Each claim checked against code and docs; Stage table, review-state block, Resume (now the review loop: land round 7, then round 8) and both issue headings rewritten |
| R7-D3 | Med | this doc, round-6 table | no rows for R6-S3/D9/L7 (the stale "107" figure) or R6-L10 (mawk untested on ubuntu), though prose cited both; the counts built on the table were wrong | **FIXED**. Two rows added with terminal statuses; round-6 totals and the review-state block recounted by script: 27 rows, 1 High / 9 Med / 17 Low, 17 fixed / 8 deferred / 2 closed |
| R7-S6 | **Critical** | `runner.nim` ~1570 (the compile `ChildSpec.env`) / `keys.nim` | the compile child gets the WHOLE parent environment (`filterEnv(envPairs, SandboxSpec(envScrub: false))`), so `CPATH`, `CL`, `_CL_`, `INCLUDE`, `LIB` and the rest reach `nim c` → gcc/cl, while the key's only environment component is `hermeticEnvHash` over the TEST child's allowlist. Proven end to end on Linux: a cached PASS is served to a host whose own binary FAILS. A second defect shares the root: `decideCompile` ignores the compile environment. Pre-existing (reproduced on a clean `git archive` of `630ecc6`). See "R7-S6" below | SPLIT OUT — separate issue (Corey, 2026-09-25); design under discussion |
| R7-S7 | Low | `types.nim`, `TrustConfig.policy = "none"` | observed while pinning object-field defaults (R7-S2): a trust-gate input defaults to the non-verifying policy. Safe today — `config.nim` sets it explicitly, `api.nim:1799` builds a config with no remotes, and `configuredCache` rejects unsigned `s3://` and `http://` — but a `file://` or `https://` remote in a `TrustConfig` built in code without `policy` would be read unverified | DEFERRED (Low; needs Corey's eye — candidate for the no-default + `{.deprecated.}` companion treatment) |
| R7-S3 / D7 | Low | `ccidentity.nim` | `cfsNotProbed` fails open | **FIXED**. `toolchainUnsound` requires both halves `cfsKnown`, so the zero value is refused and reports `turBlind` |
| R7-S4 | Low | `pipeline.nim`, the R4-4 overload comment | still said `""` "quietly disables a staleness check" | **FIXED**. Now states what `""` does: a real-stamped graph is discarded, the rebuilt graph is saved stamped `""`, and later `""` loads accept that one unchecked |
| R7-S5 | Low | `depgraph.nim`, both deprecated `loadDepGraph` overloads | the message said a real-identity graph "is discarded on every load" — overstated: after the discard the caller saves a `""`-stamped graph, which later `""` loads accept | **FIXED** (message text only). `nim check` and the source-soundness gate exit 0. The same overstatement survives in two source comments no round-7 lane was allowed to edit: `depgraph.nim` ~1720-1724 (the `##` block above the R3-7 deprecated overloads: "discarded on every load (over-invalidation)") and `pipeline.nim` ~75 ("discards a real-stamped one on every load"). Correct text: a real-stamped graph is discarded, the caller then saves a rebuilt graph stamped `""`, and later `""` loads accept it unchecked. Carried to round 8 as a comment-only fix. **Carry-over closed in round 8 as R8-D4** (both comments plus a sibling at `pipeline.nim` ~99) |
| R7-D4 | Low | `ccidentity.nim`, docs | stale docs: `versionLine`'s fallback under `cdVersionOnly`, the `toolchainUnsound` fallback prose, a wrong cross-reference, `hasDottedVersion` where `namesCompilerVersion` is meant, "the one place", and `ccUnavailable()`'s arity | **FIXED** (docs only) |
| R7-D5 | Low | `ccidentity.nim`, `answeredUnidentified` / `CcDriverIdentity` docs | `answeredUnidentified`'s "iff" held only under `cdVersionOnly`; the reason is not a function of the serialized value; `CcDriverIdentity`'s doc did not say what it selects | **FIXED**. The "iff" is scoped to `cdVersionOnly`, the doc says the reason is not recoverable from the serialized value, and `CcDriverIdentity` now says it selects `bannerLine` vs `versionLine` |
| R7-D6 | Low | `api.nim`, the `turCompilerRefused` warning | the message did not say which driver was refused | **FIXED**. It names the refused drivers (from `refusedDrivers`, R7-S1) |
| R7-D8 | Low | `test_zero_runnable.nim`, `test_w3_cc_liveness.nim` | the first said `planImpl` threads `ccidentity.cachedCcVersion()` (it threads `$ccProbe()`) and cited `ccprobe.nim` for memoization (`ccprobe` is I/O-free; the memo is `ccidentity.cachedCcFingerprint`); the second misquoted `cachedCcFingerprint`'s doc | **FIXED** (comments only), checked against `api.nim` and the current `ccidentity.nim` doc |
| R7-D9 | Low | `ci/source-soundness-gate.sh`, `run_pass` | the failure text offered only the two flag remedies, so an ordinary type error got the wrong advice | **FIXED**. It now says the error came from this invocation, may be an ordinary compile error, and points at the header only "if it is a deprecation or unused-import error". Gate exits 0 on the real tree |
| R7-D10 | Low | `ci/assert-defaulted-params.selftest.sh`, header | the header did not document the census's exit 2 (UNPARSED) | **FIXED** (the header documents exit 2) |
| R7-L3 | Low | `test_rfc0007_a5_rusage_limits_wire.nim` | the first test ran from the repo root, so it took `<repo>/.crisol/lock` and failed with exit 3 (lock contention) under any parallel crisol run — round 6's "load-sensitive flake" | **FIXED**. Runs from a unique temp project root, like its second test; 2/2 OK in the container |
| R7-L4 | Low | `ccidentity.nim`, `freeStanding` | its delimiter set was wider than anything observed: `(` on the left and `)`, `,`, `;` on the right; `;` was dead and its doc claim false | **FIXED**. Those four removed. `-` kept: Ubuntu clang needs it, now observed rather than assumed |
| R7-L5 | Low | `ci/assert-defaulted-params.selftest.sh` | no case for raw strings or for the census's per-file state reset | **FIXED**. Both cases added; each kills its mutant |
| R7-L6 | Low | `ci.yml` | `test_toolchainfp_producer_chain.nim` (R6-L1) lives under `tests/integration` and never runs on the windows or macos legs | DEFERRED (Low, per mandate) |

Every row is terminal. Counted from the table by script: **22 rows** — 1
Critical, 1 High, 6 Med, 14 Low; **19 fixed, 2 deferred** (R7-S7, R7-L6, both
Low), **1 split out** (R7-S6, to its own issue). R7-S7 is a row the review did
not raise: it was observed by R7-S2's fix, when the census began pinning
object-field defaults.

### The insight — the refusal logic was sound; the input it was judged on was not real

Rounds 4, 5 and 6 each hardened how `ccIdentity` judges a candidate that answers
but does not identify itself (R4-1 degrade-not-drop, R5-4's predicate, R6-S1's
`bannerLine`), and each hardening was mutation-proven. That logic is sound. But
every capture it was ever judged on was **synthetic** — an injected `RunProc`
returning `rc=0` — because R4-1 took its trigger from the #23 measurement table,
and that table's `cl /nologo` rc was wrong. The real trigger exits non-zero and
takes the `not ok` arm, which none of the three rounds examined, because the
premise said nothing interesting could happen there.

It was found only by running the real binary. Mutation proofs could not have
found it: they show the tests would notice a change in the logic, not that the
tests feed the logic what production feeds it. A measurement error at the root
survives any amount of rigor downstream of it.

This is the **fourth consecutive round** whose worst finding traces to a prior
round's remedy (R5-1/R5-2, R6-S1, now R7-S1). The instruction for round 8
follows: look hardest at round 7's own fixes, and for any fix founded on a
measurement, re-measure the real binary before judging the logic.

### R7-S6 — the compile environment reaches the compile but not the key (Critical, split out)

Raised in triage as "`CL`, `_CL_`, `INCLUDE` and `LIB` reach the compile but not
`KeyInputs`", and proven far wider than that. **Pre-existing** — reproduced on
Linux against a clean `git archive HEAD` of `630ecc6` — so it is not a defect
of this loop's fixes, and Corey split it out as a separate issue on 2026-09-25;
the design is under discussion there. It is recorded here because the loop
found it and because it is the worst thing the loop has found.

**The mechanism.** The compile `ChildSpec.env` at `runner.nim` ~1570 is
`filterEnv(envPairs, SandboxSpec(envScrub: false))`: the whole parent
environment is passed to `nim c`, and through it to gcc or cl. The result
key's only environment component is `hermeticEnvHash`, computed over the TEST
child's allowlist (`sandbox.nim`, `DefaultEnvAllowlist`). Anything the
compiler reads from the environment — `CPATH`, `C_INCLUDE_PATH`, `CL`, `_CL_`,
`INCLUDE`, `LIB`, and so on — changes the binary without changing the key.

**The proof** (scripts: session `29afe317` scratchpad, `r7-s6/poc2.sh` —
`%TEMP%\claude\C--Users-corey-projects-crisol\29afe317-0186-48bd-8de8-fc3ed74aec5f\scratchpad\r7-s6\`;
temporary, so copy it into the split-out issue). A header
`probecfg.h` defining `PROBE_VALUE` as 1 in `hdrA` and 2 in `hdrB`, selected by
`CPATH`. Both hosts compute the same key, `ebd5bc3634fe9378`. Host B was served
host A's PASS (`hit`, `tier=shared`, `run=cached`, exit 0) while its own binary
prints `FAIL: PROBE_VALUE=2` and exits 1. The same happens on one host through
L1.

**A second defect, same root.** `decideCompile` ignores the compile environment
too. Under `--hermetic none`, where the key does change, a stale `CPATH=A`
binary is reused and its PASS is stored under the B key; `--no-cache` also
reuses it.

**And a gap beside it.** Headers read through environment-supplied or `-I`
paths outside the tracked roots are not content-hashed:
`closureContentHash` covers tracked-root headers only.

### Verification state at the end of round 7

Reconstructed in round 8 (R8-D8): round 7 closed without this subsection,
the only round that did.

**Sweep after round 7's fixes: 263 entrypoints, 259 pass / 4 fail.** It ran
at the start of round 8, over four parallel containers on the one bind-mounted
tree. The count moved 261 -> 263 for exactly the two new round-7 files
(`test_r7_probe_presence_contract.nim`, `test_r7_toolchain_warning_ladder.nim`).
Entrypoints were enumerated as the nimble task does (bash globstar, which
includes `tests/unit/ssl/`).

- `test_fallback.nim`: the known bind-mount fold-policy artifact. It never
  reproduces on CI.
- `test_rfc0007_a1f_authorship.nim`: crisol exit 3 ("another crisol run is in
  progress"), then `{ expected` from the JSON parse. This is the R7-L3 shape
  in a different file.
- `test_run_many.nim` and `test_supervise.nim`: `oSpawnError`.
  `test_supervise` then raised a `FieldDefect` reading `res` on a
  `pkSpawnFailed` phase.

All three non-fold failures passed 2/2 each when rerun in isolation. Round 8
root-caused them: they were not load-sensitive but a deterministic collision on
cwd-relative state (R8-D3/L6, below).

Other gates, as reported by the round-7 lanes:

- `ci/source-soundness-gate.sh` exits 0: 78 of 78 files, closure reach linux
  71 / windows 66 / macosx 70.
- `ci/assert-defaulted-params.sh` exits 0: 231 records (34 of them the new
  object-field class) over 1131 signatures. The signature count rose from 1128
  to 1131 during the lanes' own runs because other lanes were editing
  `ccidentity.nim` and `api.nim`. No defaulted parameter came in with that
  rise.
- `ci/assert-defaulted-params.selftest.sh` exits 0: 21 cases under busybox
  awk, mawk 1.3.4 and gawk 5.3.
- `nim check --hints:off --path:src src/crisol.nim` exits 0.
- R7-S1 was re-measured end to end on real MSVC (see its row). R7-L3's test
  passed 2/2 in the container.
- `ci.yml` parses to the five expected jobs.

## Round 8 re-review — 2026-09-25 (base `630ecc6`, still uncommitted)

Dispatched on **round 7's own fix diff**, with the same three standing
dimensions (security; design and ergonomics; liveness and completeness), scoped
by the `R7-N` markers, after the re-sweep recorded above. **Findings presented;
round 8's fixes have LANDED**: four parallel lanes (A: warnings and cc docs,
B: census, C: CI, D: stateDir isolation), all code-writing lanes on Opus 5.5.
The status column below is the live record (R5-14).

**One Critical, no High.** The Critical, R8-S1, is **pre-existing**. It was
reproduced on a clean `git archive` of `630ecc6`. It is the same family as
R7-S6, so it is **folded into R7-S6's separate issue** rather than fixed here.
See "R8-S1 and R7-S6" below and `## Open for Corey`. **For the fifth
consecutive round, the worst in-scope finding traces to the previous round's
remedy.** R8-D1 is a consequence of R7-S1: since any non-empty `CL` now
refuses `cl`, a common setting such as `CL=/MP` turns off all result caching,
and the warning said otherwise.

**On IDs.** The liveness dimension sent an interim report and then a final
one that renumbered its rows. The findings were presented to Corey, and fixed,
under the **interim** numbering, and the IDs below follow it. Under that
numbering L2 is the non-ASCII elision half, L3 is the `.strip` rule, L4 is the
census object-field arms, L6 is the parallel-sweep collision, L7 is
`always()` versus cancel, and L8 is the overfit ladder check. The final report
calls these L3, L2, L5, L7, L6 and L4 respectively. The source comments that
cite them (for example `ccidentity.nim`'s "R8-L3" on the whitespace rule) use
the interim IDs too.

### Findings

| # | Sev | Where | What | Status |
|---|---|---|---|---|
| R8-S1 | **Critical** | `keys.nim` (`KeyInputs`), `cachedispatch.nim`, `closure.nim` (tracked-root filter), `ccidentity.nim` | Nim config files outside the tracked roots change the compile but not the key: `~/.config/nim/nim.cfg`, `/etc/nim`, `<nim>/config/nim.cfg`. They can select the backend (`cc = clang`, `cc = vcc`) and add defines. The closure drops every file outside the tracked roots, and `flagHash` covers only crisol's own config flags. The cc identity cannot tell which compiler Nim actually ran. On POSIX it asks only `cc`, and on Windows every candidate is folded in. CI uses this exact mechanism: `ci.yml` appends `cc = vcc` to `<nim>/config/nim.cfg`. Proven: host A with no user config gives `passed`/`stored`. Host B with `cc = clang` in `~/.config/nim/nim.cfg` gets `hit` on the **same key**, and its own binary prints `FAIL: built by clang` and exits 1. `define:hostBFlag` gives the same result. Scripts: scratchpad `r8-sec/poc_cfg.sh` (working tree, key `21f52f8e3b41e089`) and `r8-sec/poc_cfg_head.sh` (clean `630ecc6`, key `e8bc2e0e776747e9`), re-run by the orchestrator. Nim's own manifest `depfiles` already lists `/opt/nim/.../config/nim.cfg`, `config.nims` and `/root/.config/nim/nim.cfg`, and crisol discards them as outside the tracked roots | FOLDED INTO the R7-S6 separate issue: one issue, one design (see below). **Filed as #24** (2026-09-25), with the `--backend:cpp` findings. Pre-existing, so not fixed in this loop |
| R8-D1 | Med | `api.nim`, the `toolchainUnsoundReason` warning ladder; `ccidentity.nim` comments | every refusal warning said results "will NOT be published to the shared cache … reads are unaffected". In fact `shouldStore`'s refusal (`cdmToolchainUnidentified`) gates the runner's single store call, which writes every tier, local L1 included. The refused key (`<cc-unavailable>\|…`) is one no host ever publishes under, so every run misses. Verified by a real run: refused gives `cdmToolchainUnidentified` twice, and the control gives `cdmStored` then `cdmHit`. `ccIdentity`'s "costs one cache MISS" was wrong the same way | **FIXED** (Lane A). Lane A verified the claim against `shouldStore` and the lookup path before rewriting. Each of the four messages carries one shared sentence: results are "NOT cached for this run, locally or remotely … every test runs every time". Each then says what restores caching (for a refused `cl`: unset `CL`, otherwise repair the driver). The comment above the ladder now states the real cost, including `CL=/MP`. "One MISS" is corrected in five places in `ccidentity.nim`. New two-run test in `test_r7_toolchain_warning_ladder.nim`: a sound host gives stored then hit, and a `CL=/W4` host gives `cdmToolchainUnidentified` twice |
| R8-D2 / L7 | Med | `.github/workflows/ci.yml` (test, windows, macos jobs) | R7-L2 used `if: always()`, where GitHub recommends `if: ${{ !cancelled() }}`. With `cancel-in-progress` on PRs, a superseded run kept executing roughly 35 windows and 4 macos `nim r` steps, and no job had `timeout-minutes`. A failed `Install patched Nim toolchain` or `Toolchain sanity` on windows was followed by every later `always()` step failing with `nim: not found`, which is the noise R7-L2's comment said it prevented | **FIXED** (Lane C). `!cancelled()` replaces every `always()`; none remains outside comments. Windows: `id: toolchain` and `id: sanity`. W2 and the deps fetch need sanity, and every later step needs the fetch. F16 needs neither and carries `!cancelled()` alone. macOS: `id: deps` gates every later step. Linux `test`: the Nim steps need the fetch, and the census self-test still needs a green census. Job timeouts, set from runs 35491097764 and 35486328581: test 90, timing 30, cgroup 90, windows 150, macos 60 minutes. R7-L2's comments were rewritten to match |
| R8-D3 / L6 | Med | `config.stateDirOf`, `planner.binPath`/`cachePath`, `runner.runEntrypoint`; ~15 tests | an empty `stateDir` resolved against the process cwd. Tests therefore shared `<repo>/bin/`, `<repo>/cache/` and `<repo>/.crisol/lock`. This explains every parallel-sweep failure (see the round-7 verification state). Reproduced with two containers on one tree | **FIXED** (Lane D). `""` now means `<projectRoot>/.crisol`, never cwd. An empty or relative `projectRoot` raises `CrisolError(cekConfig)`. `runEntrypoint` uses a private temp state dir. Tests are isolated through the new `tests/support/statedir.nim`. Before/after repro: scratchpad `r8d3/`. See "R8-D3 / L6" below |
| R8-L1 | Med | `tests/integration/test_r7_probe_presence_contract.nim`, `ci.yml` | the presence contract that R7-S1 rests on claims "every platform" but ran only on the Linux `test`/`cgroup` legs. No CI step or test ever set `CL`, so R7-S1's real trigger reached the logic only as synthetic `RunProc` captures on Linux. That repeats round 7's own lesson inside round 7's own fix | **FIXED** (Lane C). The presence-contract test has its own step on windows and macos, teed into `harness.log`, and `ci/assert-subset-honesty.sh` requires its three `[OK]` lines on both legs. New `tests/integration/test_r8_real_cl_refusal.nim`: when a real `cl` is on PATH, it sets `CL=/W4` in-process and calls `ccIdentity(realRunMerged, WindowsCcProfile, realFileHash)`, avoiding the memo. It asserts raw `cl` ran and exited non-zero, the half is refused with `cl` in `refusedDrivers`, and the reason is `turCompilerRefused`. The control (`CL` unset) asserts known, Microsoft, `turSound`, and `CL` is restored. The windows step imports `vcvars64.bat` (found with `vswhere`) into its own shell only and fails loudly if `cl` is still missing. The audit requires the real body on windows (`R8-REAL-CL REAL`, done, both `[OK]`), and macos pins both skip labels. Passed on the real MSVC container and self-skips on Linux. **The new `ci.yml` steps have only been dry-run with stubs, not on GitHub Actions** |
| R8-L4 / S2 | Med | `ci/assert-defaulted-params.sh` (object-field scanner), its self-test | four object-field scanner arms were observed by nothing: continuation lines, variant-branch `of`/`else`/`elif`/`when` prefixes, field pragmas and `ref`/`ptr object`. Mutating each left the gate and the self-test at rc 0 (L4). Separately, the recognizer required `=` and `object` on one line, so three valid shapes whose default `nim r` confirms is applied were invisible, with census exit 0 and zero records: `T* =` then `object`, a comment after `=`, and `= ref` then `object`, including `ref object of Base` (S2). Nothing in `src/` uses those shapes today | **FIXED** (Lane B). The scanner finds `object` (or a line-ending `tuple`) and walks back across whitespace, line breaks, comments and at most one `ref`/`ptr` to the `=`. All four split shapes are recorded, plus `=` then `ref object of B`. Self-test: **34 cases**, green under busybox awk, mawk and gawk. Each new case has an exact exit code and a required output line. 13 scanner mutants, each red in exactly its own case. Real tree: 231 records, unchanged |
| R8-S3 | Low | `toolrun.nim` timeout arm, `ccidentity.nim` | a wedged driver returns `""` on timeout and reads as absent. It warns (CR4) but does not refuse. Suggested trigger: a cold `vccexe`/vcvarsall passing 10 s on `windows-latest` while the later link probe finishes, so bystander gcc/clang banners become the compiler half. Not proven (measured `vccexe` at ~60 ms in the container), and the runtime half still hashes the VC toolset's `libcmt`/`libvcruntime` | DEFERRED (Low, per mandate) |
| R8-S4 | Low | `ci/assert-defaulted-params.sh` | tuple field defaults (`tuple[policy: string = "none"]`, applied via `default(T)`) and `do`-block parameter defaults escaped the census | **FIXED** (Lane B). Tuple defaults are recorded in both forms as `anon_tuple(<binder>):<field> = <value>`. `do` blocks are recorded as `anon_do(_)`: the lambda's type drops the default today, but a template or macro taking the block `untyped` could splice it in. `src/` has 127 + 1 tuple types, none with a field default, and no `do` blocks |
| R8-S5 | Low | `ci.yml`, the meta-test step | under `always()` the meta-test passed whenever the harness exited non-zero for any reason, so a failed deps fetch printed "META-TEST OK" | **FIXED** (Lane C). The step runs only after a successful fetch. It passes only on a non-zero exit plus all three of: the dummy's `deliberate failure: CI meta-test…` text, `FAILED: 1 file(s)`, and the `tests/meta/test_fail_dummy.nim` line. A dry run with stubbed `docker` reproduced the false pass first, then showed it fixed |
| R8-D4 | Low | `depgraph.nim` ~1720-1724, `pipeline.nim` ~75 and ~99 | R7-S5's carry-over, confirmed, plus a sibling: `pipeline.nim` ~99 said `""` would "disable both checks" | **FIXED** (Lane D, comments only). A real-stamped graph is discarded once and replaced by an empty graph stamped `""`. Once saved, later `""` loads accept it with no toolchain check. Closes R7-S5's carry-over |
| R8-D5 | Low | `ccidentity.nim` docs | five doc statements no longer matched the code after R7-S1: `presentButFailed`'s "empty means it never ran", `bannerLine`'s rationale contradicting `ccIdentity`'s refusal, `toolchainUnsound`'s "WHERE THE REAL GUARANTEE LIVES", `CcSentinel`, and the module doc's "every test goes through `ccVersion`" | **FIXED** (Lane A). The contract is recorded as one-directional, with the residual. The two rationales are reconciled (see "Lane A's two decisions" below). The guarantee section now includes the non-zero-exit refusal. `CcSentinel` covers refused drivers. The module doc names the three test files that call `ccIdentity` directly |
| R8-D6 | Low | `api.nim`, the refused-driver warning | "driver(s) … did not identify themselves" was wrong for one driver and wrong under `CL=/W4` (cl printed its banner and was refused for its exit status). "Also check `_CL_`" misdirected, because the no-argument probe ignores `_CL_` | **FIXED** (Lane A). Singular or plural by count. The message now says "refused … exited non-zero or printed no version banner". The `_CL_` hint is gone from the message and from `toolchainUnsoundReason`'s doc |
| R8-D7 | Low | `ci/assert-defaulted-params.sh` | the header said "exactly those buckets (A … E)", but block F exists. `TrustConfig.policy` was filed as bucket E, which its own reason contradicts. Typed bindings were labelled by type name (`anon_proc(Handler)`). The drift report did not say a new F reason must open with its bucket letter | **FIXED** (Lane B). The header documents six blocks and defines a `PENDING COREY (<finding>)` marker. `TrustConfig.policy` is marked `PENDING COREY (R7-S7)`. Typed bindings are labelled by the bound name (`anon_proc(h)`). The drift report gives the F guidance |
| R8-D8 | Low | this doc | round 7 had no "Verification state" subsection. The review-state block still presented round 5's figures (258/259, 197/1010) as current. R7-S5's carry-over lived only in prose | **FIXED** in this recording: the round-7 subsection above was reconstructed from the session record, the review-state block and Resume block were updated, and R7-S5's row now points at R8-D4 |
| R8-D9 | Low | `test_supervise.nim` ~45-49, `test_rfc0007_a1f_authorship.nim` | `check outcome(o) == oPassed` does not stop the test, so a spawn failure became a `FieldDefect` on `.res` and hid `spawnError` | **FIXED** (Lane D). Both files log the phase kinds and the spawn error, then `require` a real run before reading `run.res` (six tests in a1f) |
| R8-D10 | Low | `toolrun.nim` (`RunProc`), `ccidentity.ccIdentity*` | the `""`-on-did-not-run contract was stated only in the module doc, not where someone writing a new `RunProc` would look | **FIXED** (Lane A). It is on the `RunProc*` type doc and on `ccIdentity*`'s doc, which warns that a fake returning text for a command that never ran makes an absent driver look present |
| R8-L2 | Low | `ccidentity.nim`, `ElisionSide` | the non-ASCII half of R7-D1's elision rule was unobserved. `ElisionSide = Letters` stayed green, because `d'optimisation` is pure ASCII | **FIXED** (Lane A). New French fixture `l'éditeur … 19.44.35228`, believed. Mutant M13 (non-ASCII range dropped) goes red |
| R8-L3 | Low | `ccidentity.nim`, `presentButFailed` | `output.strip.len == 0` was unobserved (mutant to `output.len` stayed green). Also, the `candidate.driver notin refused` guard is dead in practice, because candidate names are unique | **FIXED** in two passes. Lane A (the brief omitted the guard half): now `output.len == 0` (see "Lane A's two decisions"), with `cl` whitespace-only (refused) and `vccexe` whitespace-only (absent) fixtures. Mutant M12 goes red. Guard half, a follow-up lane: the dead `candidate.driver notin refused` guard is removed from both `refused.add` sites, and a `static:` block after `WindowsCcCandidates` asserts driver-name uniqueness at compile time (mutant renaming `clang` to `gcc` fails `nim check` with `duplicate cc candidate driver: gcc`) |
| R8-L5 | Low | `ci/assert-defaulted-params.sh`, count backstop | the backstop was unreachable by construction, and no self-test observed it | **FIXED** (Lane B). Documented as defense in depth that only a scanner bug can reach. A self-test case runs a gate copy with `withparams++` removed and requires exit 2 and the backstop's message |
| R8-L8 | Low | `test_r7_toolchain_warning_ladder.nim` | the driver-name check was overfit: a hard-coded "`cl`, `vccexe`" stayed green | **FIXED** (Lane A). New single-`gcc` case, and a helper asserts the named drivers appear and every other candidate name does not. Mutants M3 (hard-coded names) and M9 (first driver only) go red |

Counted from the table: **20 rows**, of which **1 Critical, 5 Med and 14 Low**.
**18 fixed**, **1 deferred** (R8-S3, Low) and **1 folded into the split-out
issue** (R8-S1). R8-L3 took two passes: its dead-guard half was closed by a follow-up lane. R8-L4/S2 and the two D/L pairs are single rows, because each pair
is one defect seen from two dimensions.

### R8-D3 / L6: empty `stateDir` meant the working directory

**Root cause.** With `Config.stateDir` empty, `stateDirOf` returned `""`.
`planner.binPath` and `cachePath` then built `"" / "bin" / slug` and `"" /
"cache" / slug`, which are relative to the **process cwd**. That is why the
repo root carried gitignored `bin/`, `cache/` and `depgraph`. It also
contradicted `stateDirOf`'s own doc (an absolute path) and RFC-0009 A2
("never cwd"). `runEntrypoint` built its `Config` with no `stateDir`, and so
did about fifteen tests (`Config(projectRoot: getCurrentDir())`). Two sweeps
in one tree then shared `bin/<slug>_<pepIdx>` and `cache/<slug>`. One run's
`removeFile`/`removeDir` of its slot deleted the other's binary, which gave
`oSpawnError` ("could not promote its compiled binary") and, through
concurrent nimcache writes, "failed to parse nimcache JSON … `{ expected`".
Separately, `runMain(@["run", …])` with no `--config` resolved the project to
cwd and took `<repo>/.crisol/lock`, which gave exit 3. That is a
deterministic shared-path collision whenever two runs share a tree, not load.
CI was never affected (one checkout per job), but local parallel sweeps got
false reds. R7-L3 had fixed one instance of the class.

**Semantics chosen.** `""` means `<projectRoot>/.crisol`, the default the CLI
already gets from the config loader and the no-`crisol.kdl` fallback, and what
`types.nim`'s `Config.stateDir` comment already said. The order in
`stateDirOf` is: `CRISOL_STATE_DIR` first (unchanged), then `""` becomes
`DefaultStateDir`, then an absolute `stateDir` is used as-is, then
`projectRoot / stateDir`. If `projectRoot` is empty or relative, `stateDirOf`
raises `CrisolError(cekConfig)` instead of joining against cwd. Making `""` an
error was rejected: it would break every zero-valued `Config` that already has
a real `projectRoot`, for no soundness gain. No signature changed and no
defaulted parameter was added.

- **Behaviour change for library callers:** a bare `Config()` passed to
  `plan()` or `execute()` now raises instead of writing `bin/` and `cache/`
  into cwd. That is intended. `test_plan` and `test_m3_compile_view` relied on
  the old behaviour and were updated.
- **`runEntrypoint`:** uses a private temp state dir, removed on return. It
  records nothing (cache off, empty graph), so concurrent callers cannot
  collide. `CRISOL_STATE_DIR` still wins. The `ledgerActive` guard is removed,
  since the state dir can no longer be `""`.
- **Tests:** new `tests/support/statedir.nim` provides `freshStateDir`,
  `processStateDir` (one per process, removed at exit only by its creator) and
  `redirectStateDir`/`restoreStateDir`. The files given their own state dir
  are the run_many execute suite, B4 quarantine, protocol wire, scheduler,
  signal, a1f (six configs), r66, r5 drain, composition s7, failfast phantom,
  all seven timing files, `test_plan` and `test_m3_compile_view`. The
  `runMain` callers with no `--config` are isolated per test through
  `CRISOL_STATE_DIR`: `test_cli_run` (A5, B7), `test_cli_group`,
  `test_cli_list` (B6), a1b, a1f's CLI suite, and `test_jsonout`'s `--json`
  suite. The reviewers' list missed `test_jsonout`, and it was the one still
  leaving `.crisol` at the tree root. `test_statedirof` now pins `""` to
  `<projectRoot>/.crisol` from a different cwd, and pins the raise.
- **Repro** (scratchpad `r8d3/`, `par2.sh`: the reviewer's `par.sh` plus a
  barrier and a root-state wipe per round, so each round compiles cold. It
  runs 4 tests in two containers on one shared copy). Before the fix, failures
  appeared in all 3 rounds: 17 exit-3 lock errors, 16 `{ expected` parse errors,
  promote failures, `oSpawnError` and the `FieldDefect`, with state left at
  the tree root. After the fix, all 24 runs gave rc 0 and nothing was left at
  the tree root.

### Lane A's two decisions

- **`presentButFailed` tests `output.len == 0`, not `output.strip.len == 0`.**
  Under the `RunProc` contract only `""` means "did not run". Whitespace-only
  output therefore means the process ran, so a driver that prints only
  whitespace and exits non-zero is now refused rather than read as absent.
  A `crWrapper` (`vccexe`) that prints only whitespace still reads as absent,
  because it relays neither a banner nor a diagnostic code. The change can
  only refuse more, which is the direction this code is meant to lean.
- **Refusing a failing `cl` on its exit status is a stopgap tied to R7-S6.**
  `bannerLine`'s rule judges only the output of drivers that exited 0.
  `ccIdentity` refuses a present, failing `cl` "whatever it printed, banner
  included", because `CL` reaches the compile but not the key. Both doc
  comments now say this. Once the R7-S6/R8-S1 issue puts the compile
  environment into the key, a `cl` that prints its real banner and exits 2
  could be believed again. That would also remove R8-D1's cost (no caching at
  all while `CL` is set). The issue should carry this as an explicit
  follow-up.

### R8-S1 and R7-S6: one issue, one design

Both Criticals have one root: **inputs the toolchain reads, and often
reports, that never reach the key.** R7-S6 is the environment (`CPATH`, `CL`,
`INCLUDE`, `LIB`, …). R8-S1 is files (user and global `nim.cfg`). The proposed
design, to be filed as **one** issue once Corey says yes:

1. **Scrub the compile environment to an allowlist, and hash what passes
   through** (the Bazel `strict_action_env` model). A passthrough entry feeds
   the key. The allowlist gains `CPLUS_INCLUDE_PATH` and `OBJC_INCLUDE_PATH`
   for the C++ route.
2. **Hash every input the toolchain reports, with no tracked-root filter.**
   That means gcc `-M` (not `-MM`) and MSVC `/sourceDependencies`, already
   derived and parsed per translation unit in `ccprobe.nim`
   (`deriveDepInvocation`, `parseCcMDeps`, `parseMsvcSourceDeps`). It also
   means Nim's own manifest `depfiles`, which list the `nim.cfg`/`config.nims`
   files. This part closes R8-S1 and R7-S6's out-of-root header gap.
3. **One `CompileInputs` record**, read by both `decideCompile` and the key.
   This closes R7-S6's second defect (a stale binary reused under a changed
   environment).
4. **Linker-input tracing** (`-Wl,--trace`, `link /VERBOSE`). This is
   **required** for C++, whose runtimes (`libstdc++`, `libc++`, `libcpmt`,
   `msvcprt`) are link inputs, not headers.
5. **Optional: rebuild verification.**

**C++ route requirements** (Corey: "we want the cpp route to still work
too"). Per-TU compile commands come from the nimcache manifest, including the
`.nim.cpp` units from `{.importcpp.}` modules. `ccFamilyOfDriver` classifies
`g++`/`clang++` as GNU (`-M`) and `cl`/`vccexe`/`clang-cl` as MSVC
(`/sourceDependencies`). Toolchain identity is C-only today (`gcc`/`clang`/`cl`
banners, the C runtime), so part 4 is what covers the C++ standard library.
Precompiled headers (`.pch`, `.gch`) and C++20 modules (`.pcm`, `.ifc`) must
**fail closed**: if a probe reports module imports or PCH use that crisol does
not hash, refuse to publish. MSVC's `/sourceDependencies` already reports
`ImportedModules`/`ImportedHeaderUnits`. Header hashing needs a per-run memo
(path, size, mtime → content hash), because a C++ TU pulls in hundreds of STL
headers.

**Unverified:** whether `--backend:cpp` in an entrypoint's flags yields a C++
build through `compiledriver.nimCompileArgs`, which hard-codes
`@["c", "--mm:orc", "--hints:off"]`. The `{.importcpp.}` route under `nim c`
is handled end to end. The check is to run before filing, so the issue does
not assume a route that does not work today.

**Proof scripts to copy into the issue** (the scratchpad is temporary):
`r7-s6/poc2.sh` (CPATH) and `r8-sec/poc_cfg.sh` / `poc_cfg_head.sh`
(`nim.cfg`, run with `-v r7-s6:/h -v r8-sec:/s`).

### Deferred

- **R8-S3** (Low, per mandate): a wedged driver warns but does not refuse.
  Unproven, and the runtime half still varies with the VC toolset.
- **Lane D leftovers**, outside its file list and not review findings:
  - `.gitignore`'s `/cache/`, `/bin/` and `/depgraph` lines, and their
    "stateDir defaulting to cwd" comment, are now obsolete. The old
    gitignored `bin/`, `cache/` and `depgraph` at the repo root are safe to
    delete.
  - The `ResolvedSettings.stateDir` comment at `api.nim` ~424 could mention
    the new `""` default.
  - `test_clean`'s lock tests run `list` and `run --dry-run` against the repo.
    They are read-only and do not take the lock.
  - Several CLI tests capture output to fixed `/tmp` file names (for example
    `crisol_b7_dryrun.txt`). This is harmless across containers but could
    collide between two runs on one host.
- Carried from earlier rounds, unchanged: R7-L6 (`test_toolchainfp_producer_chain`
  never runs on windows/macos) and R7-S7 (with Corey).

### Verification state at the end of round 8

Per lane, as reported (each lane ran in the Linux container on a copy of the
tree unless noted):

- **Lane A** (warnings and cc docs): `test_cc_banner_selection` 46 OK,
  `test_ccprobe` 106 OK, `test_r7_toolchain_warning_ladder` 2 OK (both
  multi-block tests), `test_cachedispatch` 96 OK and
  `test_r5_10_toolchain_unsound_wire` 5 OK. The census exits 0 with 231
  records. All **14 mutants** were red, each confirmed applied by grep and
  md5. Lane A had first added a defaulted parameter
  (`ccUnavailable answeredUnidentified = false`); the census caught it, and it
  was removed.
- **Lane B** (census): the self-test's **34 cases** pass under busybox awk,
  mawk and gawk, and all **13 mutants** are red. The real tree gives 231
  records over 1131 routine keywords (all resolved), with 114 anonymous
  routines, 157 object types, 127 + 1 tuple types and 34 field defaults. That
  matches the round-7 baseline. The self-test's own mutations were applied to a
  `src/` copy and run with `nim r`, and every default applied.
- **Lane C** (CI): `test_r8_real_cl_refusal` ran its real body on the MSVC
  Windows container (`cl` at `C:\msvc\vc\bin\cl.exe`): both tests passed,
  exit 0. The presence-contract test passed 3/3 there and on Linux, and the
  new test self-skipped on Linux with both markers. The audit script accepted
  logs built from those real outputs and failed correctly on a windows skip, a
  missing r7 file and a failing r8 test. The windows `cl`-import step and the
  meta-test were dry-run under `bash -eo pipefail` with stubs. `ci.yml` parses
  (host `python`) to `['cgroup','macos','test','timing','windows']`, with no
  `always()` outside comments. **None of the new steps has run on GitHub
  Actions yet.**
- **Lane D** (stateDir): the two-container repro failed in every round
  before the fix and passed 24/24 after it. A six-way parallel full run on a
  copy (261 files, by Lane D's count) failed only `test_fallback` (fold
  policy) and `test_plan`, `test_m3_compile_view` and `test_statedirof`.
  Those three were fixed afterwards and passed on a fresh copy together with
  `test_api`, all `test_cli_*`, `test_B0`, `test_jsonout` and the
  path-identity gate. The seven timing files then passed serially with
  `CRISOL_TIMING_TESTS=1`. No `bin`, `cache`, `depgraph` or `.crisol` was
  created at the tree root. `nim check --hints:off --path:src src/crisol.nim`
  is clean. The real repo root's ignored paths were unchanged before and
  after.
- **Entrypoints now: 264** (263 plus `test_r8_real_cl_refusal.nim`;
  `tests/support/statedir.nim` is a helper, not an entrypoint). Re-derive;
  do not restate.

**Full sweep (after Lane D), 4 parallel slices on the shared tree: 264 entrypoints, 263 pass, 1 fail.** The one failure is `tests/unit/test_fallback.nim` (`a.fold == b.fold` assertion, `paths.nim:275`), the known local bind-mount fold-policy case that never fails on CI. None of the round-7 parallel-collision failures recurred.

## Open for Corey

Five items. R2-7 came off this list in round 3 and R3-8 came off it in round 5;
both are recorded under "Resolved, previously escalated". R4-11 is new in round 4
and is the only one that is not about this workstream at all. R7-S6 and R7-S7
are new in round 7. R8-S1 is new in round 8 and is merged into the R7-S6 item,
so the count stays five. That item is first because it holds the only two
Criticals this loop has found.

- **R7-S6 + R8-S1: filed as #24 on 2026-09-25** (both
  **Critical**, both pre-existing at `630ecc6`; R7-S6 was SPLIT OUT as a
  separate issue by Corey on 2026-09-25, and R8-S1 is proposed to fold into
  it). Filed with both proofs, the design, the C++ requirements and the
  `--backend:cpp` findings (entry-unit basename hardcodes `.nim.c`; toolchain
  identity is C-only). Stays listed until the design lands.
  - **R7-S6:** the compile child inherits the whole parent environment while
    the key hashes only the test child's allowlist, so
    `CPATH`/`CL`/`INCLUDE`/`LIB` and the like change the binary without
    changing the key. Proven end to end: a host was served another host's
    cached PASS while its own binary fails. `decideCompile` ignores the
    compile environment too, and headers outside the tracked roots are not
    content-hashed.
  - **R8-S1:** user and global Nim config (`~/.config/nim/nim.cfg`,
    `<nim>/config/nim.cfg`, `/etc/nim`) changes the compile (`cc = clang`,
    `define:X`) but not the key. Proven the same way. Nim's manifest
    `depfiles` already lists these files, and crisol discards them as outside
    the tracked roots.
  - **The design** is in "R8-S1 and R7-S6: one issue, one design" under round
    8: env scrub plus hash, hash every toolchain-reported input with no
    tracked-root filter, one `CompileInputs` record, linker-input tracing
    (required for C++), and optional rebuild verification. It also lists the
    C++ route requirements. The issue should also say that R7-S1's blanket
    refusal of a failing `cl` is a stopgap to remove once `CL` is in the key.
  - **Before filing:** check whether `--backend:cpp` in an entrypoint's flags
    gives a C++ build through `compiledriver.nimCompileArgs`, and copy the
    proof scripts out of the temporary scratchpad (`r7-s6/poc2.sh`,
    `r8-sec/poc_cfg.sh`, `r8-sec/poc_cfg_head.sh`).
  - Not fixed in this loop, by that decision.

- **R7-S7** (new, round 7 — Low, DEFERRED, needs your eye).
  `types.nim`: `TrustConfig.policy` defaults to `"none"`, the non-verifying
  policy, on a trust-gate input. Safe today: `config.nim` sets it explicitly,
  `api.nim:1799` builds a config with no remotes, and `configuredCache` rejects
  unsigned `s3://` and `http://`. But a `file://` or `https://` remote in a
  `TrustConfig` built in code without `policy` would be read unverified. The
  candidate remedy is R3-7's: no default plus a `{.deprecated.}` companion.
  Since round 8 (R8-D7), the census record for this field is marked
  `PENDING COREY (R7-S7)` rather than filed in a bucket.

- **R4-11** (new, round 4 — a scope decision, not a technical fork)
  `tests/unit/test_api.nim:2926` is an intermittent failure, measured at one in
  three identical fresh containers, and the shape says correctness rather than
  noise: the C6 verdict reports `regressed == true` while `perfBaselineUs == 0`,
  so with `sample-floor 1` the sample count was satisfied while the median came
  back 0. It is PRE-EXISTING and unrelated to #21/#22/#23 — round 4 only found
  it, by sweeping. Left unfixed because the C6 perf ledger is a different
  subsystem and this loop fixes findings in the surface it reviewed; your call
  whether the review loop should take it. Worth noting it is not cosmetic:
  `tests/unit/` is swept on all three legs, so it is an intermittent red
  everywhere, and that is how a gate ends up switched off. See the R4-11 section
  above.

- **W9c** (still open, and **sharpened by R3-9**) — giving
  `--measure-compile-reuse` a CI producer needs a CI job plus a
  `MeasurePlan`/`workerplan` wire-format extension carrying dep-root specs
  (today `planRoots` builds a project-only `TrackedRoots`). Feature-sized work
  on a diagnostic-only path with no correctness consequence.

  What round 3 added: the Linux producer as scoped **cannot** discharge R3-9.
  `cpeSourceMismatch` (`artifactid.nim:547`) is unit-live but has zero producers
  on any leg, and its `dscMismatch` arm is reachable only where the artifact
  carries an MSVC descriptor — so a Linux-only producer leaves exactly the arm
  that matters for this workstream dark. Sizing W9c as "one Linux job" therefore
  understates it; covering R3-9 means a windows/MSVC producer.

  Recommendation unchanged in kind: convert to an open `[[item]]` with an
  `owner`, now carrying both legs, rather than build it inside a review loop.

- **R2-8** (still open, needs a Windows-capable check — unchanged by round 3) —
  wiring `tests/integration/test_closure_searchpath.nim` on the windows leg
  requires seven `CRISOL-SKIP-TEST` labels for its `symlinksAvailable()` skips
  plus seven pinned entries in `ci/assert-subset-honesty.sh`. The pin cannot be
  verified from this host, and getting it wrong turns CI red in both directions.
  (Contrast R3-5, which *was* fixed in round 3: `/proc` absence is a
  deterministic platform fact, so that pin cannot flap. R2-8's skips depend on
  Windows symlink *privilege*, which varies by runner and user — that is the
  difference, and it is why one was safe to land blind and the other is not.)

## Resolved, previously escalated

- **R3-8 — "remove `decideCompile`'s redundant version parameters?"** — escalated
  at the end of round 3 as a genuine fork: the diagnosis was agreed (the two
  staleness arms cannot fire, because `loadDepGraph` discards a header-mismatched
  graph and re-stamps the header on the success path), and the disagreement was
  purely about the remedy. Round 5 found it is **not a fork at all**, and the
  deciding input was a document, not a preference.

  The escalation rested on one premise: that a `doAssert` — or removal — "would
  crash a library consumer who legitimately hands `plan` a raw stored graph".
  **RFC-0003** (`docs/rfc/0003-library-facade-and-onboarding.md:93-94`, `:136`)
  declares `crisol/api` to be *the* documented, stable library surface and
  everything else an implementation detail; RFC-0001:933 adds only
  `crisol/report` and `crisol/unittest_shim`. `crisol/planner` is on neither
  list, so the legitimate consumer the premise depends on does not exist, and
  `README.md:15` records the whole surface as unstable pre-1.0 besides.

  Both internal callers were then checked rather than assumed:
  `pipeline.nim:282` receives a graph from `loadDepGraph` (`pipeline.nim:174`),
  so the invariant holds; `runner.nim:3098` passes `emptyDepGraph()` —
  `initDepGraph("", "")` — together with an explicit `nimVersion = ""` and
  `ccVersion = ""`, so the comparisons are `"" == ""` and neither arm fires.
  Dead on every reachable path, supported or internal. Removed; the two
  `test_freshness.nim` cases moved onto the loader's own `dgdNimVersion`/
  `dgdCcVersion` coverage, where the mechanism that actually fires lives.

  Worth keeping for the next reader, because it is what made this look like a
  tie: the two values are NOT inherently redundant. `graph.header.nimVersion`
  means "what this graph was built under" and the parameter means "what we are
  building under now" — different facts, and comparing them is the conceptually
  right check. They are redundant only GIVEN the loader invariant, which is
  exactly what the dead code would have verified if it could run. That is why it
  read as defence in depth. But a guard that cannot fire is not defence in
  depth; it is a safety net that invites reliance while holding nothing, and the
  check belongs at the boundary, where it already is and is mutation-proven.

  One consequence the fix surfaced, recorded because the brief predicted the
  opposite. I had briefed the lane that `plan` must keep both parameters
  "because it needs them for `toolchainFingerprint`" — it does not.
  `toolchainFingerprint` is called from `runner.nim` and `clean.nim`, never from
  `plan`, and `decideCompile` was `plan`'s ONLY read of `nimVersion`/`ccVersion`.
  So both are now unused inside `plan`'s body, and Nim does not warn on an
  unused parameter, so no gate catches it. The signature was left intact on
  purpose: R4-4's call-shape census is an independent reason to keep it, and
  changing it is a many-site signature change outside R3-8's scope. What was NOT
  left intact is the prose — `plan`'s `##` doc no longer claims that omitting
  them "disables the nim/cc-version staleness branch" (a phrase that was not
  accurate at the live gate either: passing `""` to `loadDepGraph` discards a
  graph stamped with a real toolchain identity and accepts only a `""`-stamped
  one unchecked — corrected in `loadDepGraph`'s deprecated messages and
  `pipeline.buildRunPlan`'s doc under R5-25, round 6), and the R3-6 soundness
  warning on `plan` now carries a NARROWED paragraph saying the omission can no
  longer flip a decision *at this site*, while the still-unsound-on-omission
  site is `runner.execute`/`toolchainFingerprint`. Whether `plan` should shed
  two now-vestigial parameters is a live question, deliberately not answered
  here.

  The removal was mutation-proven at the destination rather than assumed: with
  `loadDepGraph`'s two discard arms neutered, all three new discard-reason
  blocks in `test_depgraph.nim` go red (`got dgdNone`), the pre-existing
  `entries.len == 0` block goes red, and `test_w3_cc_liveness.nim` goes red —
  while `test_freshness.nim` stays GREEN at exit 0, which is the whole point:
  the arms that were deleted never mattered. The re-stamp invariant is by
  construction insensitive to that mutation, so it was proved against its own
  mechanism instead. The pre-existing loader coverage turned out to be thinner
  than the move assumed — it asserted `entries.len == 0` and nothing else, never
  observing the discard reason at all, because it used the 3-arg overload — so
  the destination gained 19 assertions rather than merely inheriting 4.

  What DOES remain a question for Corey, and it is a different and larger one:
  whether `crisol/planner` should BECOME supported surface. If so, the parameters
  should come back and RFC-0003's boundary needs amending. This resolution
  assumes RFC-0003 stands.

- **`versionLine`'s no-version-token fallback** — escalated at the end of round 1
  as a genuine fork between two deliberate decisions (issue #23 slice 3's
  locale-proofing vs W4's `toolchainUnsound` semantics), with no way to pick a
  side from the repo's stated goals. Round 2 (R2-1) showed it is NOT a fork. The
  exemption in `toolchainUnsound` was justified by the premise that a known
  half's text "still varies by real compiler identity" — and that premise is
  simply false on the fallback path, where nothing established the text
  describes a compiler at all. The two decisions reconcile once the missing bit
  (*was this a fallback?*) is consulted at the decision point, which costs a
  cache miss on genuinely unidentifiable toolchains only and moves no serialized
  key bytes. Fixed; see R2-1.

- **R2-7 — the defaulted-soundness-parameter inventory** — escalated at the end
  of round 2 as a churn/benefit judgement: removing the defaults on the four
  remaining soundness-governing parameters was 527 call sites, ~450 of them in
  tests. Round 3 (R3-7) found a remedy that costs neither: drop the default and
  add a `{.deprecated.}` companion overload with the old signature. Existing call
  sites keep compiling, every omission warns **at the call site with file:line**,
  and no test output changes because every test invocation already passes
  `--warnings:off` while `./dev check` does not. Landed on five of the six procs;
  `runner.execute` was deliberately left out (14 parameters with expression
  defaults — two signatures that must stay in sync is the drift hazard the
  treatment is supposed to prevent), and `./dev check` now runs
  `--warningAsError:Deprecated:on` so `src/` is provably zero-deprecation and a
  new omission produces exactly one error. Off Corey's plate; see R3-6/R3-7.
