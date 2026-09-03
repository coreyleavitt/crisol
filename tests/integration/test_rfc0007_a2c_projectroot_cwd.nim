## test_rfc0007_a2c_projectroot_cwd.nim — RFC-0007 slice A2c (issue #17):
## every ChildSpec.cwd (compile AND run children) must be `projectRoot`,
## regardless of the invoking process's own current working directory.
##
## The bug: `runner.spawnCompileStable`'s ChildSpec (the `nim c` compile
## child) and `runner.buildRunChildSpec`'s ChildSpec (the run child, absent
## `chdirIntoScratch`) both left `cwd` empty, which the process backends
## treat as "inherit the parent's cwd" (see `process/posixcore.nim`'s
## `doChdir = spec.cwd.len > 0`). A root-relative compile flag such as
## `--path:src` is then resolved by `nim` against WHATEVER directory the
## crisol process itself happened to be invoked from — not the project
## root the config was loaded from — so the exact same group compiles
## successfully from the project root and fails from any other directory.
##
## This file drives the REAL entry points (the library `execute()` API and
## the CLI's `runMain()`) against a fixture whose only group flag is a
## root-relative `--path:src`, so a correct fix is the only way every leg
## below can pass:
##
##   1. [TRACER] library API (`plan`+`execute()`), invoked with the
##      process cwd set to an UNRELATED directory — RFC-0007's acceptance
##      leg 3 ("through the library API with an unrelated cwd").
##   2. CLI (`runMain`), invoked from the project root itself — acceptance
##      leg 1.
##   3. CLI (`runMain`), invoked from a SUBDIRECTORY via
##      `--config ../crisol.kdl` — acceptance leg 2.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_rfc0007_a2c_projectroot_cwd.nim

import std/[os, times, unittest]
import std/posix as posix_mod
import crisol            # imports runMain
import crisol/[types, runner, depgraph, planner]

proc makeTempRoot(tag: string): string =
  result = getTempDir() / ("crisol_a2c_" & tag & "_" &
                           $posix_mod.getpid() & "_" &
                           $int64(epochTime() * 1_000_000))
  createDir(result)

proc writeFixtureProject(root: string) =
  ## src/helper.nim + tests/unit/test_uses_helper.nim, the latter importing
  ## the former ONLY resolvable via a root-relative `--path:src`.
  createDir(root / "src")
  createDir(root / "tests" / "unit")
  writeFile(root / "src" / "helper.nim", "proc helperValue*(): int = 42\n")
  writeFile(root / "tests" / "unit" / "test_uses_helper.nim", """
import helper
doAssert helperValue() == 42
""")

proc makeCfg(root: string): Config =
  Config(projectRoot: root, stateDir: ".crisol", jobs: 1,
         timeoutSecs: 60, compileTimeoutSecs: 120, maxOutputBytes: 65_536)

suite "rfc-0007 A2c — compile child cwd is projectRoot regardless of the invoking process's cwd":

  test "[TRACER] library API: --path:src compiles from an UNRELATED process cwd (acceptance leg 3)":
    let root = makeTempRoot("tracer")
    defer: removeDir(root)
    let elsewhere = makeTempRoot("tracer_elsewhere")
    defer: removeDir(elsewhere)

    writeFixtureProject(root)

    let cfg = makeCfg(root)
    let ep = Entrypoint(path: "tests/unit/test_uses_helper.nim", group: "default",
                        flags: @["--path:src"])

    let savedCwd = getCurrentDir()
    setCurrentDir(elsewhere)
    defer: setCurrentDir(savedCwd)

    var graph = initDepGraph("")
    let p = plan(cfg, @[ep], graph, nimVersion = "")
    let results = execute(p, config = cfg, graph = graph,
                          nimVersion = "", showProgress = false)

    check results.len == 1
    if results[0].outcome != oPassed:
      echo "tracer compile/run output:\n", results[0].output
    check results[0].outcome == oPassed

  test "CLI: --path:src compiles from the project root itself (acceptance leg 1)":
    let root = makeTempRoot("cli_root")
    defer: removeDir(root)
    writeFixtureProject(root)
    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
    flags "--path:src"
}
""")

    let savedCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(savedCwd)

    let code = runMain(@["run", "--jobs", "1"])
    check code == 0

  test "CLI: --path:src compiles from a SUBDIRECTORY via --config ../crisol.kdl (acceptance leg 2)":
    let root = makeTempRoot("cli_subdir")
    defer: removeDir(root)
    writeFixtureProject(root)
    writeFile(root / "crisol.kdl", """
group "unit" {
    globs "tests/unit/test_*.nim"
    flags "--path:src"
}
""")
    let subdir = root / "sub"
    createDir(subdir)

    let savedCwd = getCurrentDir()
    setCurrentDir(subdir)
    defer: setCurrentDir(savedCwd)

    let code = runMain(@["run", "--config", "../crisol.kdl", "--jobs", "1"])
    check code == 0

when isMainModule:
  echo "test_rfc0007_a2c_projectroot_cwd done"
