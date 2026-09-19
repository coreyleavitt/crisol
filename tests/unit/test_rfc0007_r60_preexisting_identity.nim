## test_rfc0007_r60_preexisting_identity.nim — rfc-0007 code-review finding
## r60: `PosixCore.preExisting` was pid-only, not identity-safe under pid
## reuse.
##
## The snapshot (`initPosixCore`, Linux only) is taken BEFORE the subreaper
## bit is set, to protect a library-embedding host's own pre-existing
## children from ever being killed/consumed by this Supervisor — but it
## stored bare pids. The escapee KILL path (`discoverAndReapEscapees`) has
## starttime identity (a pidfd_open + `/proc/<pid>/stat` re-read, exactly
## to guard against pid reuse); the snapshot did not, so a pid reused by
## an UNRELATED later process (long-lived embedding host, many
## fork/reap cycles over its life) was silently treated as still the same
## pre-existing host child:
##   (a) a genuine escapee landing on a reused snapshot pid was skipped at
##       `discoverAndReapEscapees`'s guard forever — an unkillable phantom
##       "escapee" while `tree=toComplete` was still vouched.
##   (b) `sweepAdoptedOrphan` refused to consume the zombie forever —
##       permanent orphan-reporting deadness for that pid, plus a leaked
##       zombie (`waitid(P_ALL, WNOWAIT)` keeps re-finding the same zombie
##       without ever reaping it).
##
## The fix: `preExisting` is now `pid -> starttime`, and
## `isPreExistingIdentity(preExisting, pid, starttime)` (posixcore.nim) is
## the pure identity predicate both guard sites consult — true only when
## BOTH the pid AND the starttime match. Both call sites additionally
## self-prune a stale entry the moment a mismatch (or a reap) proves the
## original process is gone (covered by inspection/code review, not
## re-proven here — see posixcore.nim's own comments at the two prune
## sites); this file pins the PREDICATE itself, per the finding's own
## scope note: "unit-test the identity predicate ... the full embedding
## scenario needs pid wraparound — pin the predicate + guard wiring, not
## the wraparound." Pid wraparound is not reproducible in any test
## environment on demand.
##
## rfc-0007 code-review r72 extends this file with a SECOND suite pinning
## `preExistingSweepAction` — `sweepAdoptedOrphan`'s own guard, not just
## the bare `isPreExistingIdentity` predicate above. Pre-r72,
## `sweepAdoptedOrphan` treated an UNREADABLE starttime (a transient
## `/proc` read failure — realistic under `--jobs` fd pressure) on a pid
## THIS snapshot was protecting the SAME as a confirmed mismatch: both
## fell through into the prune-and-reap branch, so a single bad read
## permanently consumed and unprotected a genuine pre-existing host
## child's zombie. `preExistingSweepAction` keeps "unreadable" and
## "confirmed mismatch" as distinct outcomes so the sweep call site can
## skip-without-pruning on the former — see its own doc comment
## (posixcore.nim) for why the escapee-KILL call site
## (`discoverAndReapEscapees`) does not need this distinction and is left
## on the bare predicate.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r60_preexisting_identity.nim

when defined(posix):
  import std/[tables, unittest]
  import crisol/process/posixcore

  suite "rfc-0007 r60 — isPreExistingIdentity: pid-and-starttime identity predicate":

    test "same pid, same starttime -> pre-existing (the true-positive case)":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check isPreExistingIdentity(snap, 100, 555_555) == true

    test "same pid, DIFFERENT starttime -> NOT pre-existing (THE r60 fix: pid reuse)":
      ## The regression this finding closes: pre-fix, only the pid was
      ## compared — this exact case (a reused pid now naming a totally
      ## different process) was a false positive that silently protected
      ## the WRONG process forever.
      var snap: Table[int, int64]
      snap[100] = 555_555
      check isPreExistingIdentity(snap, 100, 999_999) == false

    test "pid never in the snapshot at all -> not pre-existing":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check isPreExistingIdentity(snap, 200, 555_555) == false

    test "empty snapshot -> never pre-existing":
      var snap: Table[int, int64]
      check isPreExistingIdentity(snap, 100, 555_555) == false

    test "starttime unreadable (-1, an honest read failure) -> never confirmed pre-existing, even for a pid that IS in the snapshot":
      ## Degrades toward "not pre-existing" on an honest failure to read —
      ## never risk silently protecting an unrelated pid off a raced read.
      var snap: Table[int, int64]
      snap[100] = 555_555
      check isPreExistingIdentity(snap, 100, -1) == false

    test "starttime of exactly 0 (a real, valid starttime value) still matches when the snapshot agrees":
      ## Guards against an off-by-one "starttime <= 0 means invalid"
      ## mistake in the predicate — only a NEGATIVE starttime is the
      ## honest-failure sentinel (procscan.parseStatLine's own convention,
      ## int64(-1) on a parse failure); 0 is a legitimate (if unusual)
      ## value and must still compare normally.
      var snap: Table[int, int64]
      snap[100] = 0
      check isPreExistingIdentity(snap, 100, 0) == true
      check isPreExistingIdentity(snap, 100, 1) == false

  suite "rfc-0007 r72 — preExistingSweepAction: sweepAdoptedOrphan's own guard, not just the bare predicate":

    test "same pid, same starttime -> protect (never consume, never prune) -- matches isPreExistingIdentity's true case":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check preExistingSweepAction(snap, 100, 555_555) == peSweepProtect

    test "pid in snapshot, starttime READS as a genuine mismatch -> prune the stale entry and fall through to normal handling":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check preExistingSweepAction(snap, 100, 999_999) == peSweepPruneStale

    test "pid never in the snapshot -> not tracked, normal handling, nothing to prune":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check preExistingSweepAction(snap, 200, 555_555) == peSweepNotTracked

    test "r72 (THE fix): pid in snapshot but starttime is UNREADABLE (-1, a transient /proc read failure) -> skip WITHOUT consuming or pruning":
      ## THE regression this finding closes. `isPreExistingIdentity` alone
      ## degrades an unreadable starttime to "not confirmed pre-existing"
      ## (correct for the escapee-KILL path, which re-verifies via
      ## pidfd_open before ever killing anything) — but pre-fix,
      ## `sweepAdoptedOrphan` treated that same "not confirmed" result as
      ## a green light to fall through into the `pid in preExisting` prune
      ## branch and then REAP (wait4) the zombie: a transient EMFILE-class
      ## read failure (realistic under --jobs fd pressure, per
      ## `initPosixCore`'s own doc) silently consumed a pre-existing HOST
      ## child's zombie and permanently pruned its protection — a single
      ## bad read, not a real pid-reuse mismatch, was enough to do this.
      ## The fix: pid-present + starttime-unreadable is its own outcome,
      ## distinct from both "protect" (identity confirmed) and
      ## "prune-stale" (identity confirmed MISMATCHED) — skip this attempt
      ## with NO consume and NO prune, so a later retry (the WNOWAIT sweep
      ## keeps re-finding the same unconsumed zombie every tick) gets a
      ## fair, freshly-read identity check; genuine pid reuse still prunes
      ## correctly the moment a READABLE mismatched starttime shows up.
      var snap: Table[int, int64]
      snap[100] = 555_555
      check preExistingSweepAction(snap, 100, -1) == peSweepSkipUnreadable

    test "pid never in the snapshot AND starttime unreadable -> still just not tracked (unreadable only matters for a pid we're actually protecting)":
      var snap: Table[int, int64]
      snap[100] = 555_555
      check preExistingSweepAction(snap, 200, -1) == peSweepNotTracked

  when isMainModule:
    echo "test_rfc0007_r60_preexisting_identity: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r60_preexisting_identity.nim"
    echo "test_rfc0007_r60_preexisting_identity: skipped (POSIX-only backend test)"
