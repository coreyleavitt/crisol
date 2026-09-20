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
| **#22** | `readAll()` truncates child stdout on Windows; undrained stderr deadlocks | **DONE, green both platforms, UNCOMMITTED** |
| **#23** | `ccVersion` is toolchain-blind on Windows | **NEXT** |
| **#21** | MSVC dep extraction (`/sourceDependencies`) — the actual capability | **AFTER #23** |

**Resume:**

```
# 1. land #22 (nine new files + six modified, see "What #22 landed")
git add -A && git commit        # message drafted below
# 2. then -- #23's plan is WRITTEN AND AWAITING APPROVAL (see "#23" below);
#    resume at slice 1, the container tracer.
/tdd issue #23 docs/handoff/msvc-selection-layer.md
```

**Slices done / remaining on #23:** 0 of 6 done. Plan approved: NOT YET.

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

## #23 — NEXT

### The problem

`ccprobe.ccVersion()` is the C-toolchain half of the soundness key, built from
`cc --version` and `ldd --version`. Neither exists on Windows under any
toolchain, so the fingerprint is the constant

```
<cc-unavailable>|<ldd-unavailable>
```

on every Windows host. A cache entry produced by mingw-gcc and one produced by
MSVC fold to the **same key**. Measured in
`ghcr.io/coreyleavitt/nim:2.2.10-windows`: `where cc`, `where gcc` and
`where ldd` all fail. The `-mingw` sibling image has gcc but still no `cc` and
no `ldd`, so it lands on the same constant.

Issue #21's description asserts the opposite ("key apart by construction"). True
on Linux; false on Windows. That is why #23 goes first.

### Measured, 2026-09-20, `ghcr.io/coreyleavitt/nim:2.2.10-windows` (cl 19.44.35228)

| Probe | stdout | stderr | rc |
|---|---|---|---|
| `where cl` / `where vccexe` | both ON PATH — `C:\msvc\vc\bin\cl.exe`, `C:\nim\2.2.10-patched\bin\vccexe.exe` | — | 0 |
| `where cc` / `gcc` / `ldd` | — | not found | 1 |
| `cl` (no args) | `usage: cl [ option... ] filename... [ /link linkoption... ]` | `Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64` | **0** |
| `cl /nologo` (no args) | *(empty)* | `cl : Command line error D8003 : missing source filename` | 0 |
| `vccexe` (no args) | `usage: cl ...` | **the same banner** | 0 |

Two findings drive the design. The banner is on **stderr**, which the current
`RunProc` seam does not return. And **`vccexe` yields it without `cl` being on
PATH** — on a real dev box `cl` is on PATH only inside a Developer Command
Prompt, while `vccexe` (Nim's own wrapper, always beside `nim`) locates it
regardless.

### The three open questions — ANSWERED

1. **No key/format version bump.** `ccVersion` is a *key input* folded into
   `soundnessKey` (`keys.nim` component 4), not a schema field. A value change
   self-invalidates — stale entries MISS. `resultCacheFormatVersion` (4) and
   `storageFormatVersion` (2) govern on-disk shape and are coupled by a
   `doAssert` at `cachewire.nim:78`; leaving both alone keeps that intact.
2. **No golden pins move.** `test_rfc9_golden_pin.nim`'s `soundnessKey` pin
   feeds SYNTHETIC `nimVersion: "2.2.10-golden-fixture"` /
   `ccVersion: "gcc-golden-fixture-13.2.0-golden-fixture"` and never calls the
   probe — its own module doc (lines 54-67) states the pin is
   toolchain-independent by construction. Nothing else pins a real fingerprint
   value. Hypothesis confirmed: small slice.
3. **Driver discovery resolved** — a fixed candidate list, no manifest and no
   hint. See below.

### Design (planned 2026-09-20, NOT YET APPROVED, no code written)

- **`RunProc` is NOT widened.** It is re-exported by
  `artifactid`/`closure`/`nimprobe` and destructured at ~10 sites plus ~8 test
  fakes; carrying stderr through all of that serves one caller. Instead a second
  *implementation* of the same type: `realRunMerged` (`poStdErrToStdOut` +
  `toolexec.drainToEof`) — a version banner is whatever the tool prints, on
  whichever stream it picks. Default seam for `ccVersion` only; `cc -M` keeps
  `realRun`, where merging would corrupt the parse. Every existing fake compiles
  verbatim. This also stops #22's `drainBoth` stderr half being discarded.
- **Extraction is content-selected, never position-selected** — merged output
  can interleave `usage: cl ...` ahead of the banner, and resting on flush
  ordering is how #22 happened. New `versionLine(s)`: first non-empty line
  bearing a dotted version token, falling back to the first non-empty line.
  Locale-proof by construction (a localized cl banner still carries
  `19.44.35228` — the same trap `/showIncludes` walks into in #21), and a strict
  superset of today's `firstLine` on Linux, where gcc/clang/ldd all put the
  version on line 1.
- **Enumerate a candidate list and fold EVERY distinct answer**, rather than
  first-match-wins. Windows `["cl","vccexe","gcc","clang","cc"]`, POSIX `["cc"]`.
  First-match-wins is unsound: on a box with both mingw and VS it reports `cl`
  while nim builds with gcc, so a gcc upgrade does not invalidate.
  **Under-invalidation is the bug class #23 exists to kill; over-invalidation is
  only a miss.**
- **Dedupe on BANNER TEXT, not driver name.** `cl` and `vccexe` return
  byte-identical banners, so folding by text gives the same fingerprint whether
  or not crisol was launched from a Developer Command Prompt. Keying on the
  driver name would fingerprint one toolchain two ways depending on the shell.
  Distinct answers join with `"; "` in candidate order — never PATH order.
- **Libc half on Windows = `<no-libc-probe:windows>`**, a distinct documented
  sentinel meaning "this platform has no libc probe by design", as against
  `<ldd-unavailable>` = "the probe failed". That is the disambiguation the issue
  asked to be *stated*. A real per-CRT identity (`ucrtbase.dll` version or
  content hash — precedent exists, `nimVersion` content-hashes the nim binary)
  was considered and rejected: it costs `ccprobe`'s std-only leaf status, and the
  cheap proxy (`cmd /c ver`) would invalidate the whole cache on every monthly
  cumulative update. **Open fork for Corey** — say the word and the real CRT
  probe becomes a sixth slice.
- **Platform profile, so the Windows arm is testable on Linux.** The only
  `when defined(windows)` is one line:

  ```nim
  type LibcProbe* = enum lpLdd, lpNone
  type CcProbeProfile* = object
    ccCandidates*: seq[string]
    libc*: LibcProbe
  const PosixCcProfile*, WindowsCcProfile*   # both live, both produced this slice
  proc hostCcProfile*(): CcProbeProfile      # the single `when defined(windows)`
  proc ccVersion*(run: RunProc = realRunMerged;
                  profile: CcProbeProfile = hostCcProfile()): string
  ```

  Without it the whole Windows behaviour is exercisable only in the container —
  the #22 trap repeated. With it only the tracer needs the container.

Result on the MSVC image:
`Microsoft (R) C/C++ Optimizing Compiler Version 19.44.35228 for x64|<no-libc-probe:windows>`;
on mingw the gcc banner; on Linux `cc (GCC) 13.2.0|ldd (GNU libc) 2.38`,
unchanged. `render.splitFirstPipe` still sees two segments, so `--explain-miss`
keeps its readable cc/libc diff instead of degrading to the opaque form
(`render.nim:390-441`, pinned by `test_render.nim:680-717`).

### Slices — load-bearing producer first, 0 of 6 done

| # | Behaviour | Where | RED taken |
|---|---|---|---|
| **1** | **Tracer.** `cachedCcVersion()` — real production accessor, real runner, no seam — names the C compiler actually installed on this host | `tests/integration/test_issue23_cc_identity.nim` (new) | **MSVC container**; RED = `<cc-unavailable>` |
| 2 | An MSVC host and a mingw host produce DIFFERENT fingerprints, neither the all-sentinel constant — the premise #21 rests on | `tests/unit/test_ccprobe.nim`, `WindowsCcProfile` + fakes | Linux |
| 3 | The version survives a merged capture where the usage line arrives first, and survives a localized banner | same | Linux |
| 4 | Windows libc half distinct from the failure sentinel; no-driver-answers still yields a stable non-empty two-segment string; never raises | same | Linux |
| 5 | POSIX fingerprint unchanged for real gcc/clang/ldd banner shapes; existing suites green | same | Linux |
| 6 | Whole-file `when defined(posix)` gate narrowed to just the real-binary suites + integration test wired into the windows CI job | `tests/unit/test_ccprobe.nim`, `.github/workflows/ci.yml` | — |

**Slice 6 is not cosmetic.** `tests/unit/test_ccprobe.nim` is gated
`when defined(posix)` for its ENTIRE body (lines 11, 208-210), so it runs **zero
assertions on Windows today** — part of why this shipped broken. The seam-driven
suites spawn nothing and are portable as-is; only the `realRun`/`realRunIn`
suites (`/bin/sh`, `/bin/echo`, `/bin/pwd`) need to stay POSIX-gated.

### Surfaces this touches

`src/crisol/ccprobe.nim` (only production file), `tests/unit/test_ccprobe.nim`,
`tests/integration/test_issue23_cc_identity.nim` (new),
`.github/workflows/ci.yml`. No other module changes — `RunProc`'s type is
deliberately untouched, which is what keeps the blast radius to one module.

---

## #21 — AFTER #23

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

1. **Commit #22.** Nine new files, six modified, uncommitted. Message drafted
   above. Nothing else should start until this lands — #23 edits
   `ccprobe.nim`, which #22 already modified.
2. **#23's plan needs approval** before any code (TDD step 1.4). Design and the
   six slices are recorded above.
3. **#23's libc half: documented sentinel, or a real per-CRT identity?**
   Recommended: the sentinel (reasoning above). The alternative costs
   `ccprobe`'s std-only leaf status.
4. **`./dev` / podman networking is broken on this host.** Out of scope for
   these issues; flagged because every contributor workflow in `CLAUDE.md`
   assumes `./dev` works.
5. **RFC-0007 addendum** recording the `/Zs`-dominance, stream-routing and
   locale findings — agreed in principle, not yet written.

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
