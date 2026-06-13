## test_depdecode.nim — regression-anchored unit tests for decodeMangledPath.
##
## Test vectors use the LITERAL mangled strings observed in the Nim 2.2.10
## nimcache JSON during spike D1a.  Changing these strings means the compiler
## changed its encoding — that is a deliberate regression guard.

import std/unittest
import crisol/depparse

suite "decodeMangledPath — D1a verified vectors":

  # -------------------------------------------------------------------------
  # @p entries → excluded (return "")
  # -------------------------------------------------------------------------

  test "@p stdlib system.nim is excluded":
    let cpath = "/workspace/tmp/dc/@psystem.nim.c"
    let ep    = "/workspace/tests/fixtures/deptest_main.nim"
    check decodeMangledPath(cpath, ep) == ""

  test "@p stdlib with subdirs is excluded":
    let cpath = "/workspace/tmp/dc/@pstd@sprivate@sdigitsutils.nim.c"
    let ep    = "/workspace/tests/fixtures/deptest_main.nim"
    check decodeMangledPath(cpath, ep) == ""

  test "@p package path (crisol via --path:src) is excluded":
    let cpath = "/workspace/tmp/dc/@pcrisol@sdiscover.nim.c"
    let ep    = "/workspace/tests/unit/test_discover.nim"
    check decodeMangledPath(cpath, ep) == ""

  # -------------------------------------------------------------------------
  # @m entries in same directory as entrypoint
  # (observed: deptest_main.nim imports ./deptest_dep which imports ./deptest_dep2)
  # -------------------------------------------------------------------------

  test "@m basename resolves relative to entrypoint dir (same dir)":
    let cpath = "/workspace/tmp/dc/@mdeptest_dep.nim.c"
    let ep    = "/workspace/tests/fixtures/deptest_main.nim"
    check decodeMangledPath(cpath, ep) == "/workspace/tests/fixtures/deptest_dep.nim"

  test "@m dep2 basename resolves relative to entrypoint dir (same dir, 3-level chain)":
    let cpath = "/workspace/tmp/dc/@mdeptest_dep2.nim.c"
    let ep    = "/workspace/tests/fixtures/deptest_main.nim"
    check decodeMangledPath(cpath, ep) == "/workspace/tests/fixtures/deptest_dep2.nim"

  test "@m entrypoint itself resolves correctly":
    let cpath = "/workspace/tmp/dc/@mdeptest_main.nim.c"
    let ep    = "/workspace/tests/fixtures/deptest_main.nim"
    check decodeMangledPath(cpath, ep) == "/workspace/tests/fixtures/deptest_main.nim"

  # -------------------------------------------------------------------------
  # @m entries with cross-directory path (observed: tests/main.nim → ../src/mylib.nim)
  # Mangled: @m..@ssrc@smylib.nim.c
  # -------------------------------------------------------------------------

  test "@m cross-dir path with @s separator resolves via entrypoint dir":
    let cpath = "/workspace/tmp/dc/@m..@ssrc@smylib.nim.c"
    let ep    = "/workspace/tmp_spike/proj/tests/main.nim"
    check decodeMangledPath(cpath, ep) == "/workspace/tmp_spike/proj/src/mylib.nim"

  # -------------------------------------------------------------------------
  # classifyMangled helper
  # -------------------------------------------------------------------------

  test "classifyMangled: @p → mkLibrary":
    check classifyMangled("/some/dir/@psystem.nim.c") == mkLibrary

  test "classifyMangled: @m → mkProject":
    check classifyMangled("/some/dir/@mdeptest_main.nim.c") == mkProject

  test "classifyMangled: unknown prefix → mkUnknown":
    check classifyMangled("/some/dir/somefile.nim.c") == mkUnknown
