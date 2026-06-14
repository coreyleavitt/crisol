## test_cli_s6.nim — S6 (F3) integration tests: crisol init [path] [--force].
##
## Tests:
##   1. init in empty temp dir creates crisol.kdl (exit 0).
##   2. init when crisol.kdl exists refuses (exit nonzero), file unchanged.
##   3. init --force overwrites (exit 0).
##   4. init <custom-path> writes to the specified path (exit 0).
##   5. init --force with a non-existent file is still exit 0.
##   6. The written config parses with zero warnings (loadConfig sanity check).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_cli_s6.nim

import std/[os, posix, strutils, times, unittest]
import crisol        # runMain
import crisol/config  # loadConfig

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeTmpDir(): string =
  result = getTempDir() / ("crisol_s6_" & $getpid() & "_" & $epochTime().int)
  createDir(result)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "crisol S6 — crisol init":

  test "init in empty dir creates crisol.kdl, exits 0":
    let root = makeTmpDir()
    defer: removeDir(root)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let code = runMain(@["init"])
    check code == 0
    check fileExists(root / "crisol.kdl")

  test "init when crisol.kdl already exists refuses (exit 3), file unchanged":
    let root = makeTmpDir()
    defer: removeDir(root)

    let target = root / "crisol.kdl"
    writeFile(target, "# sentinel\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let code = runMain(@["init"])
    check code == 3
    # File must be unchanged.
    check readFile(target) == "# sentinel\n"

  test "init --force overwrites existing crisol.kdl (exit 0)":
    let root = makeTmpDir()
    defer: removeDir(root)

    let target = root / "crisol.kdl"
    writeFile(target, "# old content\n")

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let code = runMain(@["init", "--force"])
    check code == 0
    # The file must now contain the canonical template, not the old content.
    let content = readFile(target)
    check "# old content" notin content
    check content.len > 0

  test "init <custom-path> writes to the specified path":
    let root = makeTmpDir()
    defer: removeDir(root)

    let customPath = root / "my_crisol.kdl"

    let code = runMain(@["init", customPath])
    check code == 0
    check fileExists(customPath)

  test "init --force on non-existent file still exits 0":
    let root = makeTmpDir()
    defer: removeDir(root)

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    check not fileExists(root / "crisol.kdl")
    let code = runMain(@["init", "--force"])
    check code == 0
    check fileExists(root / "crisol.kdl")

  test "written config parses with zero warnings (loadConfig sanity)":
    let root = makeTmpDir()
    defer: removeDir(root)

    let target = root / "crisol.kdl"

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    let code = runMain(@["init"])
    check code == 0

    let (_, warns) = loadConfig(configPath = target)
    check warns.len == 0

  test "init --force refuses to write through a symlink (M6 TOCTOU/symlink guard)":
    ## Regression: O_NOFOLLOW must prevent write-through on --force.
    ## Even with --force, init must not follow the symlink and overwrite the
    ## sentinel file that the symlink points to.
    let root = makeTmpDir()
    defer: removeDir(root)

    # Create a sentinel file with known contents that must NOT be modified.
    let sentinel = root / "sentinel.txt"
    writeFile(sentinel, "SENTINEL_CONTENTS\n")

    # Create crisol.kdl as a symlink pointing at the sentinel.
    let symlinkPath = root / "crisol.kdl"
    let rc = symlink(sentinel.cstring, symlinkPath.cstring)
    check rc == 0  # symlink created successfully

    let oldCwd = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(oldCwd)

    # init --force must refuse to write through the symlink.
    let code = runMain(@["init", "--force"])

    # (a) Exit code must signal failure (exit 3 — "already exists" path).
    check code == ExitEnvironment

    # (b) Sentinel file contents must be UNCHANGED — symlink was NOT followed.
    check readFile(sentinel) == "SENTINEL_CONTENTS\n"
