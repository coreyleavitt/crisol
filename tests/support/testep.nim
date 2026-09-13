## tests/support/testep.nim — RFC-0009 A-final-i test-site Entrypoint helper.
##
## Derives a REAL tag-0 `tp` for a test-built Entrypoint via the fixture
## roots below, mirroring the producer obligation `discover` owns in
## production, so tests exercise the same tp identity production does.
## Purely additive: `Entrypoint.path` and the planner's zero-tp epSlug
## fallback are untouched (both removed in A-final-ii).

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
  ## Test-only Entrypoint constructor (A-final-i): derives a real tag-0 tp from
  ## `path` via the fixture roots, mirroring discover's producer obligation so
  ## tests exercise the same tp identity production does. Falls back to a zero
  ## tp only for a path that is not a valid canonical rel (rare) -- that path
  ## then still works via epSlug's fallback until A-final-ii.
  let tp = fromCanonical(path, testRoots)
  Entrypoint(
    path: path,
    tp: (if tp.isSome: tp.get else: default(TrackedPath)),
    group: group, flags: flags, runTimeoutSecs: runTimeoutSecs)
