## tests/support/testep.nim — RFC-0009 A-final-i test-site Entrypoint helper.
##
## Derives a REAL tag-0 `tp` for a test-built Entrypoint via the fixture
## roots below, mirroring the producer obligation `discover` owns in
## production, so tests exercise the same tp identity production does.
## `Entrypoint.path` and the planner's zero-tp epSlug fallback were removed
## in A-final-ii; this constructor now sets only `tp` (and group/flags/
## runTimeoutSecs) on the returned Entrypoint.

import std/[options, os]
import crisol/[types, paths]

let testRoots* = initTrackedRoots(getCurrentDir(), @[], "")
  ## Module fixture roots. Fold policy is HOST-DERIVED (real probe), so a
  ## testEp's tp folds exactly as a production discover-built ep does on the
  ## same host -- never a bare fpNone constant, which would compare unequal
  ## against a production fpAsciiLower path on windows-latest (RFC-0009 R3-21).
  ## getCurrentDir() at import = repo root under ci/run-tests.sh (captured once,
  ## before any test chdir).

proc testEp*(path: string; group = "unit"; flags: seq[string] = @[];
             runTimeoutSecs = 0): Entrypoint =
  ## Test-only Entrypoint constructor: derives a real tag-0 tp from `path`
  ## via the fixture roots, mirroring discover's producer obligation so
  ## tests exercise the same tp identity production does.
  ##
  ## Routes through `tracked` (== `classify`), NOT `fromCanonical`, so BOTH a
  ## relative path ("tests/fixtures/x.nim") and an absolute path under the
  ## root (fixtureDir()/"x.nim") yield the same valid tag-0 tp — matching how
  ## production's discover classifies. `fromCanonical` accepts only a relative
  ## spelling and silently returned a zero tp for an absolute fixture path,
  ## which after the A-final-ii removal made `toNative(ep.tp, roots)` resolve
  ## to garbage and the runner oSpawnError (it bit tests/integration and then
  ## tests/timing). Falls back to a zero tp only for a path genuinely OUTSIDE
  ## every root (rare, and never a real fixture).
  let tp = tracked(path, testRoots)
  Entrypoint(
    tp: (if tp.isSome: tp.get else: default(TrackedPath)),
    group: group, flags: flags, runTimeoutSecs: runTimeoutSecs)
