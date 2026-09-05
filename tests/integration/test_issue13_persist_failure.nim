## test_issue13_persist_failure.nim — issue #13.3: a depgraph persist
## failure after a successful compile must never leave the OLD depgraph
## entry on disk next to the NEW stable binary.
##
## Sequence that used to go wrong: `runner.execute` copies the freshly
## compiled per-slot binary to the stable slug-keyed path BEFORE
## `recordClosure` persists the depgraph, and `saveDepGraph` used to swallow
## write errors silently (no return value at all). If the persist failed,
## disk held the OLD depgraph entry (old closure content hash) sitting next
## to the NEW binary. Reverting the edit that triggered the recompile then
## made `planner.decideCompile` hash the reverted source back to the OLD
## value, find the (now-stale-provenance) stable binary, and serve a binary
## that was actually built from the EDITED sources — silently wrong output,
## not merely a stale-but-honest one.
##
## The fix (issue #13.3): `saveDepGraph` now
## returns `bool` (true iff persisted), and `recordClosure` reports
## `ok: false` when the persist itself fails; the runner discards the
## just-promoted stable binary in that case so the next run starts from
## `cdNeverBuilt` instead of trusting a binary the depgraph does not
## describe.
##
## Fault injection: `createDir(depgraphPath(cfg))`. `saveDepGraph` (via
## `ioutils.atomicPublish` as of RFC-0007 A3) writes to a PID-suffixed temp
## file first — unpredictable from outside the subprocess, so this fault
## cannot target it directly — then `rename(2)`s that temp file onto
## `depgraphPath(cfg)`. `rename(2)` reliably fails with `EISDIR` when the
## destination is an existing directory and the source is a regular file,
## so the final commit step fails deterministically without needing to
## predict the subprocess's PID or filesystem permissions (the container
## runs as root, so a chmod-based fault would not work).
##
## `--no-cache` on every `run` invocation (RFC-0005 A2c-ii): this test's
## ONLY signal for "which binary actually ran" is an out-of-band marker
## file the fixture writes as a side effect -- a proxy that is meaningless
## once a run can be legitimately CACHE-SERVED (a hit never spawns the
## binary, so the marker is never rewritten, even though the recompile
## step 3 checks for still genuinely happened). Step 3 reverts the source
## back to its step-1 content, which the depgraph's own persist-failure
## fix (this test's actual target) correctly forces to RECOMPILE rather
## than trust a stale entry -- but that recompiled content is, by
## construction, identical to step 1's, so RFC-0005 A2c-ii's post-compile
## consult then correctly finds step 1's own cache entry and serves it
## instead of re-running. That is caching working exactly as designed; it
## is simply orthogonal to issue #13.3's provenance invariant, which this
## test isolates by disabling the cache entirely.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_issue13_persist_failure.nim

import std/[os, osproc, strutils, times, unittest]
import std/posix as posix_mod
import crisol
import crisol/[config, depgraph, planner, types]

# ---------------------------------------------------------------------------
# Helpers (shapes copied from tests/integration/test_issue11_closure_inputs.nim
# and test_issue11_externals.nim's captureBoth — not imported, so this file
# has no test-to-test dependency).
# ---------------------------------------------------------------------------

proc captureStdout(args: seq[string]): tuple[code: int; output: string] =
  ## Run runMain with stdout redirected to a temp file; return code + text.
  let outPath = getTempDir() / ("crisol_issue13_cap_" & $getpid() & "_" &
                                $epochTime().int64 & ".txt")
  let f = open(outPath, fmWrite)
  let fileFd: cint  = f.getFileHandle.cint
  let savedFd: cint = posix_mod.dup(1.cint)
  discard posix_mod.dup2(fileFd, 1.cint)
  f.close()
  let code = runMain(args)
  flushFile(stdout)
  discard posix_mod.dup2(savedFd, 1.cint)
  discard posix_mod.close(savedFd)
  let text = readFile(outPath)
  removeFile(outPath)
  (code: code, output: text)

proc captureBoth(args: seq[string]): tuple[code: int; stdout: string; stderr: string] =
  ## Like `captureStdout`, but also captures stderr (fd 2) separately —
  ## needed to assert on the runner's persist-failure warning without
  ## losing the ability to also assert on stdout's JSON.
  let tag = $getpid() & "_" & $epochTime().int64
  let outPath = getTempDir() / ("crisol_issue13_capout_" & tag & ".txt")
  let errPath = getTempDir() / ("crisol_issue13_caperr_" & tag & ".txt")
  let outF = open(outPath, fmWrite)
  let errF = open(errPath, fmWrite)
  let outFd: cint = outF.getFileHandle.cint
  let errFd: cint = errF.getFileHandle.cint
  let savedOutFd: cint = posix_mod.dup(1.cint)
  let savedErrFd: cint = posix_mod.dup(2.cint)
  discard posix_mod.dup2(outFd, 1.cint)
  discard posix_mod.dup2(errFd, 2.cint)
  outF.close()
  errF.close()
  let code = runMain(args)
  flushFile(stdout)
  flushFile(stderr)
  discard posix_mod.dup2(savedOutFd, 1.cint)
  discard posix_mod.dup2(savedErrFd, 2.cint)
  discard posix_mod.close(savedOutFd)
  discard posix_mod.close(savedErrFd)
  let outText = readFile(outPath)
  let errText = readFile(errPath)
  removeFile(outPath)
  removeFile(errPath)
  (code: code, stdout: outText, stderr: errText)

proc newProject(tag: string): string =
  result = getTempDir() / ("crisol_issue13_" & tag & "_" & $getpid())
  removeDir(result)
  createDir(result / "tests" / "unit")
  createDir(result / ".crisol")

proc git(root: string; args: string) =
  let (o, rc) = execCmdEx("git -C " & quoteShell(root) & " " & args)
  doAssert rc == 0, "git " & args & " failed: " & o

const ProjectKdl = """
group "unit" {
    globs "tests/unit/t_*.nim"
}
"""

proc markerBody(root: string; value: string): string =
  ## The marker path is baked into the generated source as an absolute
  ## path, so the test can tell WHICH binary actually ran regardless of
  ## which nimcache/bin slot produced it.
  "import std/os\n" &
  "writeFile(" & escape(root / "marker.txt") & ", " & escape(value) & ")\n" &
  "quit(0)\n"

# ---------------------------------------------------------------------------
# End-to-end proof
# ---------------------------------------------------------------------------

suite "issue #13.3 — a depgraph persist failure must not let a reverted source serve a stale-but-wrong binary":

  test "persist failure after recompile discards the stable binary; a later revert recompiles instead of serving the wrong build":
    let root = newProject("main")
    defer: removeDir(root)
    writeFile(root / "crisol.kdl", ProjectKdl)
    writeFile(root / ".gitignore", ".crisol/\n*.txt\n")
    let epPath = root / "tests" / "unit" / "t_marker.nim"
    writeFile(epPath, markerBody(root, "1"))

    git(root, "init -q")
    git(root, "config user.email crisol@test.local")
    git(root, "config user.name crisol-test")
    git(root, "config commit.gpgsign false")
    git(root, "add -A")
    git(root, "commit -q -m baseline")

    let markerPath = root / "marker.txt"

    # Step 1: full run, marker == "1".
    let full = captureStdout(@["run", "--config", root / "crisol.kdl", "--json", "--no-cache"])
    check full.code == 0
    check fileExists(markerPath)
    check readFile(markerPath).strip == "1"

    let (cfg, cfgErrs) = loadConfig(root / "crisol.kdl")
    doAssert cfgErrs.len == 0, "loadConfig failed: " & $cfgErrs
    let stableBin = binPath(Entrypoint(path: "tests/unit/t_marker.nim", group: "unit"), cfg) /
                    binName(Entrypoint(path: "tests/unit/t_marker.nim", group: "unit"))
    check fileExists(stableBin)

    # Step 2: edit source to write "2"; plant the persist-failure fault;
    # run again. The new binary MUST still run (it already compiled
    # successfully — the failure is in persisting the depgraph AFTER the
    # compile, not in the compile itself), but the runner must warn and
    # must discard the stable binary so its provenance is never
    # mismatched against what the depgraph records.
    writeFile(epPath, markerBody(root, "2"))
    let tmpFaultDir = depgraphPath(cfg)
    # Step 1's successful run already persisted a real depgraph FILE at this
    # exact path — remove it first (createDir raises if a non-directory
    # already occupies the path) before occupying it with a directory.
    removeFile(tmpFaultDir)
    createDir(tmpFaultDir)

    let broken = captureBoth(@["run", "--config", root / "crisol.kdl", "--json", "--no-cache"])
    check readFile(markerPath).strip == "2"
    check "could not record its source closure" in broken.stderr
    check "dependency graph could not be persisted" in broken.stderr
    check "its binary was discarded" in broken.stderr

    # The stable binary must be gone — nothing on disk describes its
    # provenance now (the depgraph entry still names the OLD closure hash).
    check not fileExists(stableBin)

    # Step 3: remove the fault, revert the source to "1", run again.
    # RED (pre-fix) behavior: the stale on-disk depgraph entry (never
    # updated by step 2's failed persist) hashes back to the reverted "1"
    # source, decideCompile finds a stable binary present, and skips the
    # recompile — serving the STEP 2 "2" binary. GREEN (post-fix): step 2
    # already discarded the stable binary, so decideCompile sees
    # cdNeverBuilt regardless of hash, forcing a real recompile of the
    # reverted "1" source.
    removeDir(tmpFaultDir)
    writeFile(epPath, markerBody(root, "1"))

    let reverted = captureStdout(@["run", "--config", root / "crisol.kdl", "--json", "--no-cache"])
    check reverted.code == 0
    check readFile(markerPath).strip == "1"
