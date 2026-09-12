## test_rfc9_a3bii_fold_selection.nim — RFC-0009 A3b-ii LOAD-BEARING E2E.
##
## Proves narrow.nim's folded `TrackedPath` closure-membership selection
## LIVE, end-to-end, through the real product entry point
## (`pipeline.buildRunPlan`, the same shared plan phase `runTests`/the CLI
## use) against a REAL git repository. This is the first RFC-0009 slice
## that proves the *selection* half of the load-bearing property (docs/rfc/
## 0009-path-identity.md, "Load-bearing property" + the A3b-ii bullet).
##
## ## Dispatch (three modes)
##
##   1. `CRISOL_FOLD_POLICY` set (R3-18.2, the ubuntu `test` job's Linux
##      gate) — parsed and INJECTED via `initTrackedRoots`'s `probe`
##      parameter, forcing this genuinely case-sensitive ext4 volume to
##      behave as the given policy for selection. Production itself stays
##      completely env-free: the injection happens only at this test's own
##      boundary, never inside `crisol/*`.
##   2. `CRISOL_EXPECT_FOLD` set (R3-18.4, the windows/macos legs) — NO
##      injection. The REAL probe is hard-asserted to answer the given
##      policy (both directly, via `probeFoldPolicy`, and via the run's own
##      evidence, `RunReport.trackedRoots`) before the E2E body runs — a
##      leg mis-pinned to the wrong policy fails loudly instead of silently
##      halving the "proven on two case-insensitive legs" claim.
##   3. Neither set — belt-and-suspenders, matching test_fold_probe.nim's
##      own volume-not-platform philosophy: runs the real-probe body anyway
##      if THIS volume happens to be genuinely case-insensitive; otherwise
##      self-skips (never silently vacuous).
##
## ## The recipe (implemented exactly)
##
## A real git repo with two entrypoints: `test_dependent.nim` (imports
## `helper.nim`, which imports `widget.nim` — a TRANSITIVE dependency) and
## `test_independent.nim` (imports nothing shared). RUN 1 (no `--changed`,
## the real `runTests` facade) builds and PERSISTS the dep graph via a
## genuine compile (`depgraph.recordClosure`). The dependency is then
## case-renamed via a COMMITTED `git mv`: `git mv widget.nim tmp.nim && git
## mv tmp.nim Widget.nim`, single commit — then `Widget.nim`'s CONTENT is
## edited (uncommitted). RUN 2 diffs the rename commit against the working
## tree (`changedFiles(..., renameRev)`) — the diff base is chosen so ONLY
## `Widget.nim` (new spelling) appears: `widget.nim` (old spelling) exists
## in NEITHER the rename commit nor the working tree, so it cannot appear
## in this diff at all, unlike diffing from the PRE-rename commit (which
## would show both a delete of `widget.nim` and an add of `Widget.nim` under
## `--no-renames` — vacuous, since the deleted side raw-matches the
## persisted graph). The diff names the DEPENDENCY (`Widget.nim`), never
## either entrypoint's own file, so a hit can only come from the
## closure-membership fold (Rule 5, `srClosureHit`), never Rule 2's direct
## own-file match.
##
## The MANDATORY negative control (asserted BEFORE the selection assertion):
## the persisted graph's closure member is raw-string `tests/unit/widget.nim`
## and the diff's changed-set member is raw-string `tests/unit/Widget.nim` —
## these differ as raw strings, and the OLD spelling does not appear in the
## changed set at all. Only the fold makes them the same identity.
##
## ## Two things this test's fixture works around, and why (found empirically
## — see the PART 2 handoff report for the reproduction)
##
## 1. **`depgraph.isEntryStale` is a raw, fold-unaware `fileExists`.** It is
##    not retyped by this slice (only narrow's own membership test is). On a
##    volume that is GENUINELY case-insensitive (the real windows-latest/
##    macos-latest legs), a case-only rename leaves the OLD spelling
##    resolvable for free (the OS itself folds the lookup) — so
##    `isEntryStale` naturally sees every closure member as present, and
##    Rule 5 (the fold) is what determines inclusion. On a genuinely
##    case-SENSITIVE volume (this container, even under a FORCED crisol-side
##    policy), a real `git mv` physically removes the old spelling — so
##    without help, `isEntryStale` would flag the entry stale (Rule 4,
##    conservative include) on EVERY policy, forced or not, making the test
##    pass vacuously regardless of whether the fold works at all (confirmed
##    empirically). Under `CRISOL_FOLD_POLICY` (mode 1 only), this test
##    recreates the OLD spelling as an untracked, gitignored decoy file
##    immediately after the rename — the faithful LOCAL simulation, at the
##    filesystem level, of what a genuinely case-insensitive volume already
##    gives mode 2/3 for free. It is never created under the real-probe
##    modes (2/3), where it is unnecessary.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_rfc9_a3bii_fold_selection.nim
## Forced-policy Linux gate (R3-18.2):
##   CRISOL_FOLD_POLICY=fpAsciiLower ./dev run nim r --hints:off --warnings:off \
##         --path:src tests/conformance/test_rfc9_a3bii_fold_selection.nim

import std/[monotimes, options, os, osproc, sequtils, sets, strutils, tables, unittest]
import crisol/types
import crisol/config
import crisol/discover
import crisol/pipeline
import crisol/depgraph
import crisol/narrow
import crisol/gitdiff
import crisol/api
import crisol/nimprobe

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc uniqueTmpDir(tag: string): string =
  let mono = getMonoTime()
  result = getTempDir() / ("crisol_a3bii_" & tag & "_" & $mono.ticks)
  createDir(result)

proc git(repo: string; args: string): tuple[output: string; exitCode: int] =
  execCmdEx("git " & args, workingDir = repo)

proc initRepo(repo: string) =
  discard git(repo, "init -q")
  discard git(repo, "config user.email crisol@test.local")
  discard git(repo, "config user.name crisol-test")
  discard git(repo, "config commit.gpgsign false")

proc writeF(repo, rel, content: string) =
  let p = repo / rel
  createDir(p.parentDir)
  writeFile(p, content)

proc parseFoldPolicy(s: string): FoldPolicy =
  case s
  of "fpAsciiLower": fpAsciiLower
  of "fpNone":       fpNone
  else:
    raise newException(ValueError,
      "test_rfc9_a3bii_fold_selection: unrecognized FoldPolicy env value '" & s & "'")

proc isCaseInsensitiveVolume(dir: string): bool =
  ## Same technique as test_fold_probe.nim / test_spike_import_case.nim.
  let lowerPath = dir / "a3bii_casetest.tmp"
  let upperPath = dir / "A3BII_CASETEST.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)
  removeFile(lowerPath)

const DependentBody = """
import std/unittest
import helper
suite "dependent":
  test "ok": check helperValue() == 43
"""

const IndependentBody = """
import std/unittest
suite "independent":
  test "ok": check true
"""

# ---------------------------------------------------------------------------
# The E2E body — shared by every live mode (1/2/3).
# ---------------------------------------------------------------------------

proc runE2EBody(useForcedProbe: bool; forcedPolicy: FoldPolicy;
                 hardAssertRealPolicy: bool; expectedPolicy: FoldPolicy) =
  let repo = uniqueTmpDir("e2e")
  defer: removeDir(repo)
  initRepo(repo)

  # .crisol/ is untracked run-state (cache/bin/lock/depgraph/ledger) --
  # gitignored so gitdiff's untracked-file scan (R3-24's second git
  # invocation, `git ls-files -z --others --exclude-standard`) never lets it
  # pollute the changed set. widget.nim is NOT ignored here: it must be
  # TRACKED so the committed case-rename below can actually rename it (a
  # `.gitignore` entry would leave it un-added, and `git mv` would fail
  # "not under version control" -- the exact bug an earlier revision shipped,
  # masked on case-sensitive Linux by the untracked scan). The forced-mode
  # decoy is instead kept out of the untracked scan via `.git/info/exclude`,
  # applied only after the rename un-tracks the old spelling (below).
  writeF(repo, ".gitignore", ".crisol/\n")
  writeF(repo, "tests/unit/widget.nim", "proc widgetValue*(): int = 42\n")
  writeF(repo, "tests/unit/helper.nim",
         "import widget\nproc helperValue*(): int = widgetValue() + 1\n")
  writeF(repo, "tests/unit/test_dependent.nim", DependentBody)
  writeF(repo, "tests/unit/test_independent.nim", IndependentBody)
  discard git(repo, "add -A")
  discard git(repo, "commit -q -m initial")

  proc forcedProbe(rootAbs, stateDir: string): FoldPolicy = forcedPolicy

  # No memo pre-warm needed: paths.memoizedProbe bypasses its per-process memo
  # for any explicitly-injected non-default probe, so RUN 2's forced-probe
  # override below is honored even though RUN 1's `runTests` facade probes this
  # same root first with the real (default) probe.

  # RUN 1: a real run (compile + execute) — the public `runTests` facade,
  # not a hand-rolled compile — with NO `--changed`, so the dep graph is
  # built and PERSISTED to disk via a genuine `recordClosure`/`saveDepGraph`
  # (depgraph.nim ~791).
  let r1 = runTests(RunOptions(startDir: repo, jobs: 1))
  check r1.status == rsOk
  check r1.summary.total == 2
  check r1.summary.failed == 0

  if hardAssertRealPolicy:
    # R3-18.4 (mode 2): NO injection anywhere in this branch. Hard-assert
    # the REAL probe answers the expected (non-default) policy, both
    # directly and via this run's own evidence (RunReport.trackedRoots) —
    # fail loudly rather than silently halving the "proven on two
    # case-insensitive legs" claim.
    let stateDirAbs = repo / ".crisol"
    let realAnswer = probeFoldPolicy(repo, stateDirAbs)
    check realAnswer == expectedPolicy
    check r1.trackedRoots.project.foldPolicy == expectedPolicy

  # Case-divergence: a COMMITTED rename (git mv X tmp && git mv tmp Y, one
  # commit) — never an uncommitted staged rename, which would emit BOTH the
  # delete of the old spelling and the add of the new one in the same diff
  # (the deleted side raw-matches the persisted graph — vacuous).
  # The two-step (via tmp.nim) is the standard case-only-rename dance that
  # works on both case-sensitive and case-insensitive volumes. Assert each
  # step succeeded: a silently-failing `git mv` (e.g. the source un-tracked)
  # would leave the rename un-done and the whole proof vacuous.
  let mv1 = git(repo, "mv tests/unit/widget.nim tests/unit/tmp.nim")
  let mv2 = git(repo, "mv tests/unit/tmp.nim tests/unit/Widget.nim")
  let cmt = git(repo, "commit -q -m rename-widget-to-Widget")
  check mv1.exitCode == 0
  check mv2.exitCode == 0
  check cmt.exitCode == 0
  let renameRev = git(repo, "rev-parse HEAD").output.strip()

  if useForcedProbe:
    # See module doc point 1. Recreate the OLD spelling as a decoy so
    # `depgraph.isEntryStale`'s raw `fileExists` doesn't force-include the
    # dependent via Rule 4 ahead of Rule 5 (the fold). The rename above left
    # `widget.nim` un-tracked, so exclude it via `.git/info/exclude` FIRST
    # (never `.gitignore`, which would also un-track the original before the
    # rename) — otherwise R3-24's untracked scan would pull the OLD spelling
    # into the changed set and break the negative control. Content is
    # irrelevant — isEntryStale only checks existence.
    writeF(repo, ".git/info/exclude", "tests/unit/widget.nim\n")
    writeF(repo, "tests/unit/widget.nim",
           "-- decoy: kept present only so isEntryStale's raw fileExists\n" &
           "-- doesn't force-include ahead of narrow's closure-membership fold.\n")

  # Edit Widget.nim's CONTENT — uncommitted working-tree edit.
  writeF(repo, "tests/unit/Widget.nim", "proc widgetValue*(): int = 4242\n")

  # RUN 2's cfg: fresh load, then the documented injection —
  # `cfg.trackedRoots` overridden via `initTrackedRoots(..., probe = forced)`
  # — which (thanks to the pre-warm above) agrees with what RUN 1 already
  # saw, under useForcedProbe. A plain re-load under real-probe modes.
  var (cfg, _) = loadConfig(startDir = repo)
  if useForcedProbe:
    cfg.trackedRoots = initTrackedRoots(cfg.projectRoot, @[], cfg.stateDir, forcedProbe)

  let nimVersion = cachedNimFingerprint()

  # The diff base is the POST-rename commit vs the working tree (which holds
  # the content edit) — so only `Widget.nim` (new spelling) can appear;
  # `widget.nim` (old spelling) exists in neither side of this diff.
  let changed = changedFiles(cfg.projectRoot, cfg.trackedRoots, renameRev)

  var discarded: DepGraphDiscard
  let graph = loadDepGraph(cfg, nimVersion, discarded)
  check discarded.kind == dgdNone

  let depKey = ("tests/unit/test_dependent.nim", flagHash(@[]))
  check depKey in graph.entries
  let persistedClosure = graph.entries[depKey].closure
  check "tests/unit/widget.nim" in persistedClosure

  var changedDisplays = initHashSet[string]()
  for c in changed: changedDisplays.incl c.display

  # --- MANDATORY NEGATIVE CONTROL — asserted BEFORE the selection assertion ---
  echo "RFC9-A3BII NEGATIVE CONTROL: persisted graph closure member (raw) = 'tests/unit/widget.nim'"
  echo "RFC9-A3BII NEGATIVE CONTROL: diff changed-set member (raw)        = ",
       (if "tests/unit/Widget.nim" in changedDisplays: "'tests/unit/Widget.nim'" else: "<ABSENT — test is broken>")
  echo "RFC9-A3BII NEGATIVE CONTROL: full changed set = ", $changedDisplays
  check "tests/unit/Widget.nim" in changedDisplays        # the new spelling IS the diff
  check "tests/unit/widget.nim" notin changedDisplays     # the OLD (persisted) spelling is NOT
  check not isEntryStale(graph, depKey, cfg.projectRoot)  # confirms Rule 4 cannot be why it's selected

  # --- Selection, via the REAL shared plan phase (buildRunPlan) ---
  let pv = buildRunPlan(cfg = cfg, selection = GroupSelection(kind: gskDefault),
                        useChanged = true, changed = changed,
                        nimVersion = nimVersion)
  let selectedPaths = pv.plan.entrypoints.mapIt(it.ep.path)
  check "tests/unit/test_dependent.nim" in selectedPaths
  check "tests/unit/test_independent.nim" notin selectedPaths

  # Corroborating detail: replay buildRunPlan's own discover -> gate ->
  # narrow steps (the identical production procs it calls internally, not a
  # hand-rolled duplicate) to name the EXACT selection reason — proving the
  # inclusion is srClosureHit (the fold), not some other rule.
  let discovered = discover(cfg, GroupSelection(kind: gskDefault))
  let gateState  = loadGateState(cfg)
  let gated      = applyGates(discovered, cfg, gateState)
  let detailed   = selectByDiff(gated.run, changed, graph, cfg.trackedRoots, cfg.projectRoot)

  var depReason = none(SelectionReason)
  for d in detailed:
    if d.ep.path == "tests/unit/test_dependent.nim":
      depReason = some(d.reason)
  check depReason.isSome and depReason.get == srClosureHit
  check not detailed.anyIt(it.ep.path == "tests/unit/test_independent.nim")

# ---------------------------------------------------------------------------
# Suite — mode dispatch
# ---------------------------------------------------------------------------

suite "RFC-0009 A3b-ii — fold-membership selection, live E2E":

  test "dependent selected via folded closure membership; independent is not":
    let foldPolicyEnv = getEnv("CRISOL_FOLD_POLICY")
    let expectFoldEnv = getEnv("CRISOL_EXPECT_FOLD")

    if foldPolicyEnv.len > 0:
      # Mode 1 (R3-18.2): forced-probe injection, the ubuntu `test` job's
      # Linux gate — proves the E2E body green before CI-pacing begins.
      let forced = parseFoldPolicy(foldPolicyEnv)
      echo "RFC9-A3BII MODE 1: CRISOL_FOLD_POLICY=", foldPolicyEnv, " (forced injection)"
      runE2EBody(useForcedProbe = true, forcedPolicy = forced,
                 hardAssertRealPolicy = false, expectedPolicy = forced)

    elif expectFoldEnv.len > 0:
      # Mode 2 (R3-18.4): real probe, hard-asserted — windows-latest/macos-latest.
      let expected = parseFoldPolicy(expectFoldEnv)
      echo "RFC9-A3BII MODE 2: CRISOL_EXPECT_FOLD=", expectFoldEnv, " (real probe, hard-asserted)"
      runE2EBody(useForcedProbe = false, forcedPolicy = fpNone,
                 hardAssertRealPolicy = true, expectedPolicy = expected)

    else:
      # Mode 3: neither set. Belt-and-suspenders (test_fold_probe's own
      # volume-not-platform philosophy) — run for real if THIS volume
      # genuinely is case-insensitive; self-skip only once confirmed it isn't.
      let probeDir = uniqueTmpDir("volprobe")
      let insensitive = isCaseInsensitiveVolume(probeDir)
      removeDir(probeDir)
      if insensitive:
        echo "RFC9-A3BII MODE 3: neither env set, but this volume IS case-insensitive — running the real body"
        runE2EBody(useForcedProbe = false, forcedPolicy = fpNone,
                   hardAssertRealPolicy = false, expectedPolicy = fpNone)
      else:
        echo "RFC9-A3BII SKIPPED: case-sensitive volume and neither CRISOL_FOLD_POLICY " &
             "nor CRISOL_EXPECT_FOLD is set — nothing to prove here"
        skip()

when isMainModule:
  echo "test_rfc9_a3bii_fold_selection done"
