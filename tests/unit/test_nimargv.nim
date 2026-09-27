## test_nimargv.nim -- the one `nim c` argv builder (R10-D13). The compile
## paths (`runner`, `compiledriver`) and the C toolchain probe's discovery
## compile (`ccidentity`) all call it, so its shape is pinned once, here.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_nimargv.nim

import std/unittest
import crisol/nimargv
import crisol/compiledriver

suite "nimCompileArgs":

  test "a full compile: flags between the fixed options and the entrypoint":
    check nimCompileArgs("/p/t.nim", @["-d:release", "--passC:-m32"], "/nc", "/nc/out",
                         compileOnly = false) ==
          @["c", "--mm:orc", "--hints:off", "--nimcache:/nc", "-o:/nc/out",
            "-d:nimBetterRun", "-d:release", "--passC:-m32", "/p/t.nim"]

  test "compile-only adds --compileOnly and nothing else":
    check nimCompileArgs("-", @[], "/nc", "/nc/stdinfile", compileOnly = true) ==
          @["c", "--mm:orc", "--hints:off", "--compileOnly", "--nimcache:/nc",
            "-o:/nc/stdinfile", "-d:nimBetterRun", "-"]

  test "compiledriver re-exports the same builder":
    check compiledriver.nimCompileArgs("/p/t.nim", @[], "/nc", "/o", compileOnly = true) ==
          nimargv.nimCompileArgs("/p/t.nim", @[], "/nc", "/o", compileOnly = true)
