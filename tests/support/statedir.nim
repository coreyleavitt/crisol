## tests/support/statedir.nim — R8-D3 test isolation for crisol's state dir.
##
## Every compile crisol performs lands under `stateDirOf(cfg)`: `bin/<slug>`,
## `cache/<slug>` (the per-entrypoint nimcache), `depgraph`, the ledger, the
## lock. A test that runs crisol against the REPO ROOT (a `Config` with
## `projectRoot: getCurrentDir()`, or `runMain(@["run", ...])` with no
## `--config`) therefore shares that state with every other crisol run in the
## same tree -- a second `./dev test`, a parallel sweep, the developer's own
## `crisol run` -- and they delete each other's slot binaries and nimcache JSON
## mid-compile (oSpawnError: "could not promote its compiled binary", "failed
## to parse nimcache JSON") or trip each other's lock (exit 3, "another crisol
## run is in progress").
##
## Three tools, for the ways a test reaches crisol:
##
##   * `freshStateDir(tag)` -- a unique, ABSOLUTE temp dir to put in
##     `Config.stateDir` (an absolute stateDir is used as-is by `stateDirOf`).
##     The caller removes it (`defer: removeDir(sd)`).
##
##   * `processStateDir(tag)` -- the same, but ONE per test process, removed
##     at process exit: for a module-level `makeCfg`-style helper whose tests
##     all share one Config shape. Tests within one process run serially, so
##     sharing inside the process is safe; what matters is that no OTHER
##     process (a concurrent run in the same tree) can ever see it.
##
##   * `redirectStateDir(dir)` / `restoreStateDir(saved)` -- point
##     `CRISOL_STATE_DIR` (which `stateDirOf` honours ahead of everything else)
##     at `dir` for a `runMain` call whose Config the test does not build, then
##     put the previous value back. Meant for a suite's `setup:`/`teardown:`.

import std/[exitprocs, os, tempfiles]

const StateDirEnv = "CRISOL_STATE_DIR"

proc freshStateDir*(tag: string): string =
  ## A unique, absolute, already-created temp dir for one test's crisol state.
  createTempDir("crisol_state_" & tag & "_", "")

proc processStateDir*(tag: string): string =
  ## A unique, absolute temp dir shared by this test process's crisol runs,
  ## removed when the process exits.
  ## Only the creating process removes it: a forked test child that exits
  ## through `quit` runs the same exit procs and must not delete the
  ## parent's state out from under it.
  let dir = freshStateDir(tag)
  let owner = getCurrentProcessId()
  addExitProc(proc () =
    if getCurrentProcessId() == owner:
      try: removeDir(dir)
      except OSError: discard)
  dir

type SavedStateDirEnv* = object
  wasSet: bool
  prev:   string

proc redirectStateDir*(dir: string): SavedStateDirEnv =
  ## Point CRISOL_STATE_DIR at `dir`, returning what to restore.
  result = SavedStateDirEnv(wasSet: existsEnv(StateDirEnv), prev: getEnv(StateDirEnv))
  putEnv(StateDirEnv, dir)

proc restoreStateDir*(saved: SavedStateDirEnv) =
  ## Undo `redirectStateDir`: restore the prior value, or unset it.
  if saved.wasSet: putEnv(StateDirEnv, saved.prev)
  else: delEnv(StateDirEnv)
