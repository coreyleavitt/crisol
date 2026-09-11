## test_rfc9_a2_config.nim — RFC-0009 A2 unit tests: config.nim's TrackedRoots
## wiring and dep-root naming (round-3 R3-8).
##
## Covers:
##   - Config.trackedRoots is populated by loadConfig (project root, real
##     probed fold policy).
##   - dep-root name defaults to the configured path's basename.
##   - explicit `name=` overrides the basename default.
##   - fold-aware name collision (two dep roots whose names collide
##     case-insensitively) -> CrisolError(cekConfig).
##   - two dep roots that alias one physical directory (via a symlink) ->
##     CrisolError(cekConfig).
##   - a dep-root name containing '/' or ':' -> CrisolError(cekConfig).
##   - a relative dep-root path resolves against projectRoot, NOT cwd.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_rfc9_a2_config.nim

import std/[os, unittest, tempfiles]
import crisol/[types, config, paths]

proc writeFile(dir, name, content: string): string =
  result = dir / name
  writeFile(result, content)

proc makeTmpDir(): string =
  createTempDir("crisol_rfc9_a2_", "")

# ---------------------------------------------------------------------------
# TrackedRoots wiring
# ---------------------------------------------------------------------------

suite "config — RFC-0009 A2: TrackedRoots wiring":

  test "loadConfig populates cfg.trackedRoots.project from a real probe":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let cfgPath = writeFile(tmp, "crisol.kdl",
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")
    let (cfg, _) = loadConfig(configPath = cfgPath)
    # Every file under `tmp` (a plain tmpfs/ext4 dir on Linux CI) is
    # case-sensitive -- fpNone -- a real, deterministic probed value.
    check cfg.trackedRoots.project.foldPolicy == fpNone
    check cfg.trackedRoots.deps.len == 0

  test "convention-fallback config (no crisol.kdl) also populates trackedRoots":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let (cfg, _) = loadConfig(startDir = tmp)
    check cfg.trackedRoots.project.foldPolicy == fpNone

# ---------------------------------------------------------------------------
# Dep-root naming (R3-8)
# ---------------------------------------------------------------------------

suite "config — RFC-0009 A2: dep-root naming (R3-8)":

  test "dep-root name defaults to the configured path's basename":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    let depDir = depParent / "mydep"
    createDir(depDir)

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & depDir & "\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check cfg.depRoots == @[depDir]
    check cfg.trackedRoots.deps.len == 1
    check cfg.trackedRoots.deps[0].name == "mydep"

  test "explicit name= overrides the basename default":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    let depDir = depParent / "mydep"
    createDir(depDir)

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & depDir & "\" name=\"custom\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")
    let (cfg, _) = loadConfig(configPath = cfgPath)

    check cfg.trackedRoots.deps.len == 1
    check cfg.trackedRoots.deps[0].name == "custom"

  test "fold-aware name collision -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    createDir(depParent / "MyDep")
    createDir(depParent / "mydep")

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & (depParent / "MyDep") & "\"\n" &
      "dep-roots \"" & (depParent / "mydep") & "\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "two dep roots aliasing one physical directory (via symlink) -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    let real = depParent / "real"
    createDir(real)
    let alias = depParent / "alias"
    createSymlink(real, alias)

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & real & "\" name=\"one\"\n" &
      "dep-roots \"" & alias & "\" name=\"two\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "dep-root name containing '/' -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    let depDir = depParent / "mydep"
    createDir(depDir)

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & depDir & "\" name=\"bad/name\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "dep-root name containing ':' -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    let depDir = depParent / "mydep"
    createDir(depDir)

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & depDir & "\" name=\"bad:name\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "name= with more than one path in the same node -> cekConfig":
    let tmp = makeTmpDir()
    defer: removeDir(tmp)
    let depParent = makeTmpDir()
    defer: removeDir(depParent)
    createDir(depParent / "a")
    createDir(depParent / "b")

    let cfgPath = writeFile(tmp, "crisol.kdl",
      "dep-roots \"" & (depParent / "a") & "\" \"" & (depParent / "b") &
      "\" name=\"ambiguous\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    check caught
    check kind == cekConfig

  test "relative dep-root resolves against projectRoot, not cwd":
    # outer/proj is the project root (crisol.kdl lives there); outer/sibling/src
    # is the dep root, reached via "../sibling/src" -- relative to PROJECT
    # ROOT, not whatever the process cwd happens to be.
    let outer = makeTmpDir()
    defer: removeDir(outer)
    let projectRoot = outer / "proj"
    createDir(projectRoot)
    let siblingSrc = outer / "sibling" / "src"
    createDir(siblingSrc)

    # An unrelated cwd, deliberately NOT projectRoot and NOT outer -- if the
    # relative dep-root path were (wrongly) joined against cwd instead of
    # projectRoot, it would resolve to a different, non-aliasing directory
    # and this config would load WITHOUT error.
    let elsewhere = makeTmpDir()
    defer: removeDir(elsewhere)
    let origCwd = getCurrentDir()
    setCurrentDir(elsewhere)

    let cfgPath = writeFile(projectRoot, "crisol.kdl",
      "dep-roots \"" & siblingSrc & "\" name=\"abs\"\n" &
      "dep-roots \"../sibling/src\" name=\"rel\"\n" &
      "group \"unit\" { globs \"tests/unit/*.nim\" }\n")

    var caught = false
    var kind: CrisolErrorKind
    try:
      discard loadConfig(configPath = cfgPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
    finally:
      setCurrentDir(origCwd)
    # The absolute dep root and the relative one both resolve to the SAME
    # physical directory (outer/sibling/src) IFF the relative one was
    # correctly joined against projectRoot -- which then trips the
    # realAbs-alias check above, proving the base was projectRoot, not cwd.
    check caught
    check kind == cekConfig

when isMainModule:
  echo "All rfc9_a2_config tests passed."
