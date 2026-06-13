## pathimport_main.nim — @p soundness fixture for D1 closure test.
##
## Imports a real crisol library module via its package path (as `import
## crisol/depparse`), which — when compiled with `--path:<projectRoot>/src`
## — produces `@p`-mangled entries in the nimcache JSON.  This exercises the
## D1a soundness fix: `@p` project sources must appear in the closure when
## they resolve to a file under a tracked root.
##
## Compiled with:
##   nim c --mm:orc --path:<projectRoot>/src --nimcache:<dir> -o:<bin> <this>
##
## NOT compiled by tests/fixtures/build.nim (requires --path:src and is an
## integration fixture; see test_closure.nim).

import crisol/depparse

when isMainModule:
  # Reference a symbol from depparse so the import is not optimised away.
  let k = classifyMangled("/tmp/fake/@mdep.nim.c")
  assert k == mkProject, "unexpected kind: " & $k
