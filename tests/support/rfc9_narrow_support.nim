## tests/support/rfc9_narrow_support.nim — RFC-0009 A3b-ii shared test
## helpers for narrow.nim's TrackedPath-typed `changed` parameter.
##
## `selectByDiff`/`narrowByDiff` take `changed: HashSet[TrackedPath]` and a
## `roots: TrackedRoots`. These two helpers exist so the ~20 call sites
## across test_narrow.nim/test_fallback.nim/test_closure_searchpath.nim do
## not each hand-roll the same `fromCanonical(...).get` boilerplate.
##
## `fromCanonical` only consults the tag's fold POLICY (probed once, at
## `TrackedRoots` construction time) -- it never touches `roots.project.abs`
## or the filesystem. A zero-value / bogus-directory `TrackedRoots` (e.g.
## `mkRoots("")`) is therefore safe for tests that pass a bogus projectRoot:
## the resulting TrackedPath still folds/compares exactly as a real one
## would, it is just not meaningfully "rooted" anywhere on disk.

import std/[options, sets]
import crisol/types

proc mkRoots*(projectRoot: string): TrackedRoots =
  initTrackedRoots(projectRoot, @[], "")

proc changedTp*(roots: TrackedRoots; paths: varargs[string]): HashSet[TrackedPath] =
  ## Builds a `HashSet[TrackedPath]` out of project-root-relative strings via
  ## `fromCanonical`. Every `path` must be a well-formed relative, canonical
  ## (forward-slash, no `.`/`..` segments) spelling -- `fromCanonical` REJECTS
  ## absolute input, so `.get` is safe here only for that reason.
  result = initHashSet[TrackedPath]()
  for p in paths:
    result.incl fromCanonical(p, roots).get
