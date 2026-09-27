## test_locate_driver_relative.nim -- R11-S3 / R12-L1: a RELATIVE search
## path entry resolves against the build's nim's cwd, never this process's.
##
## nim runs the C compiler with its own cwd (the project root, `site.nimCwd`):
## `posix_spawnp`/`sh -c` and `CreateProcess` resolve a relative PATH entry
## against it. `ccprobe.locateDriver` resolved only the EMPTY entry there; any
## other relative entry (`wbin`, `./wbin`, `.`) was answered as the relative
## path `wbin/gcc`, looked up against crisol's own cwd. That identified a
## different file than nim runs when crisol ran from elsewhere (R11-S3), and
## handed the probe a relative driver path that does not resolve from the
## probe's scratch dir, whose failed spawn stranded crisol there (R12-L1).
##
## Pinned: every answer is an absolute path; a relative entry resolves
## against `nimCwd` (POSIX and Windows); a file that exists only relative to
## this process's cwd is never the answer; an unknown `nimCwd` refuses a
## relative entry reached before the driver is found, as any other search
## step that cannot be taken does; `siteResolver` answers the same.
##
## Also pinned: on Windows an unknown nim directory or cwd refuses instead of
## being skipped (R13-D7); on POSIX the real search passes over a directory
## or a non-executable file, as execvp does, while the Windows rule still
## stops at any existing name (R13-S4).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_locate_driver_relative.nim

import std/[os, sets, strutils, unittest]
import crisol/[ccprobe, headerprobe]

proc existsIn(files: openArray[string]): proc(path: string): bool =
  let s = toHashSet(files)
  result = proc(path: string): bool = path in s

proc posixSite(pathVar: string; nimCwd = "/proj"): DriverSite =
  DriverSite(known: true, nimCwd: nimCwd, search: dsPosix, pathVar: pathVar)

proc windowsSite(pathVar: string): DriverSite =
  DriverSite(known: true, nimExe: "C:\\nim\\bin\\nim.exe", nimCwd: "C:\\proj",
             search: dsWindows, pathVar: pathVar, systemRoot: "C:\\Windows")

suite "a relative PATH entry is nim's cwd's, not crisol's (R11-S3)":

  test "POSIX: `wbin` resolves under nim's cwd and wins over a later entry":
    let found = locateDriver("gcc", posixSite("wbin:/usr/bin"),
                             existsIn(["/proj/wbin/gcc", "/usr/bin/gcc"]))
    check found.found
    check found.path == "/proj/wbin/gcc"

  test "POSIX: `./wbin` and `.` resolve under nim's cwd":
    let a = locateDriver("gcc", posixSite("./wbin:/usr/bin"),
                         existsIn(["/proj/./wbin/gcc", "/usr/bin/gcc"]))
    check a.found and a.path == "/proj/./wbin/gcc"
    let b = locateDriver("gcc", posixSite(".:/usr/bin"),
                         existsIn(["/proj/./gcc", "/usr/bin/gcc"]))
    check b.found and b.path == "/proj/./gcc"

  test "POSIX: a copy only under crisol's cwd (the bare relative path) is never the answer":
    # `wbin/gcc` names a file relative to THIS process's cwd; nim, in /proj,
    # has no /proj/wbin/gcc and runs /usr/bin/gcc.
    let r = locateDriver("gcc", posixSite("wbin:/usr/bin"),
                         existsIn(["wbin/gcc", "/usr/bin/gcc"]))
    check r.found
    check r.path == "/usr/bin/gcc"

  test "POSIX: every answer is absolute, so it runs the same file from any cwd":
    for pathVar in ["wbin:/usr/bin", "./wbin:/usr/bin", ".:/usr/bin", ":/usr/bin",
                    "a/b/../wbin:/usr/bin"]:
      checkpoint pathVar
      let exists = proc(path: string): bool = path.len > 0 and path[^4 .. ^1] == "/gcc"
      let r = locateDriver("gcc", posixSite(pathVar), exists)
      check r.found
      check r.path.len > 0 and r.path[0] == '/'

  test "POSIX: an unknown nim cwd refuses a relative entry reached before the driver":
    for entry in ["wbin", "", "."]:
      checkpoint "entry '" & entry & "'"
      let r = locateDriver("gcc", posixSite(entry & ":/usr/bin", nimCwd = ""),
                           existsIn(["/usr/bin/gcc"]))
      check not r.found
    # An absolute entry that holds the driver first is still an answer.
    let hit = locateDriver("gcc", posixSite("/usr/bin:wbin", nimCwd = ""),
                           existsIn(["/usr/bin/gcc"]))
    check hit.found and hit.path == "/usr/bin/gcc"

  test "Windows: a relative PATH entry resolves under nim's cwd":
    let r = locateDriver("gcc", windowsSite("tools;C:\\mingw\\bin"),
                         existsIn(["C:\\proj\\tools\\gcc.exe", "C:\\mingw\\bin\\gcc.exe",
                                   "tools\\gcc.exe"]))
    check r.found
    check r.path == "C:\\proj\\tools\\gcc.exe"
    let s = locateDriver("gcc", windowsSite("tools;C:\\mingw\\bin"),
                         existsIn(["tools\\gcc.exe", "C:\\mingw\\bin\\gcc.exe"]))
    check s.found
    check s.path == "C:\\mingw\\bin\\gcc.exe"

  test "siteResolver answers the same absolute file":
    let resolve = siteResolver(posixSite("wbin:/usr/bin"),
                               existsIn(["/proj/wbin/g++", "/usr/bin/g++", "wbin/g++"]))
    let r = resolve("g++")
    check r.found
    check r.path == "/proj/wbin/g++"

suite "a search step that cannot be taken refuses, on Windows too (R13-D7)":

  proc windowsSiteCwd(nimCwd: string; nimExe = "C:\\nim\\bin\\nim.exe"): DriverSite =
    DriverSite(known: true, nimExe: nimExe, nimCwd: nimCwd, search: dsWindows,
               pathVar: "C:\\mingw\\bin", systemRoot: "C:\\Windows")

  test "Windows: an unknown nim cwd refuses rather than skipping nim's cwd step":
    # nim searches its cwd second; with that cwd unknown, a later hit may
    # not be the copy nim runs.
    let r = locateDriver("gcc", windowsSiteCwd(""),
                         existsIn(["C:\\mingw\\bin\\gcc.exe"]))
    check not r.found
    if not r.found:
      check "cwd" in r.why

  test "Windows: a copy in nim's own directory, searched before its cwd, is still found":
    let r = locateDriver("gcc", windowsSiteCwd(""),
                         existsIn(["C:\\nim\\bin\\gcc.exe", "C:\\mingw\\bin\\gcc.exe"]))
    check r.found and r.path == "C:\\nim\\bin\\gcc.exe"

  test "Windows: a nim binary with no directory refuses before any later step":
    let r = locateDriver("gcc", windowsSiteCwd("C:\\proj", nimExe = "nim.exe"),
                         existsIn(["C:\\proj\\gcc.exe", "C:\\mingw\\bin\\gcc.exe"]))
    check not r.found

  test "Windows: a known cwd is searched second, as before":
    let r = locateDriver("gcc", windowsSiteCwd("C:\\proj"),
                         existsIn(["C:\\proj\\gcc.exe", "C:\\mingw\\bin\\gcc.exe"]))
    check r.found and r.path == "C:\\proj\\gcc.exe"

suite "Windows: the search still stops at any existing name (R13-S4)":

  test "dsWindows stops at a directory or a non-executable file; dsPosix at neither":
    let root = getTempDir() / "crisol_lowsC_winrule"
    removeDir(root)
    createDir(root / "gcc.exe")
    writeFile(root / "cl.exe", "")
    defer: removeDir(root)
    check realDriverStop(root / "gcc.exe", dsWindows)
    check realDriverStop(root / "cl.exe", dsWindows)
    check not realDriverStop(root / "none.exe", dsWindows)
    check not realDriverStop(root / "gcc.exe", dsPosix)
    when defined(posix):
      check not realDriverStop(root / "cl.exe", dsPosix)

when defined(posix):
  import std/tempfiles

  suite "POSIX: the search skips what execvp skips (R13-S4)":

    test "a directory and a non-executable file named gcc earlier on PATH are passed over":
      let root = createTempDir("crisol_lowsC_", "_execvp")
      defer: removeDir(root)
      createDir(root / "a" / "gcc")                     # a directory: EACCES
      createDir(root / "b")
      writeFile(root / "b" / "gcc", "#!/bin/sh\n")      # no execute bit: EACCES
      setFilePermissions(root / "b" / "gcc", {fpUserRead, fpUserWrite})
      createDir(root / "c")
      writeFile(root / "c" / "gcc", "#!/bin/sh\n")      # the one execvp runs
      setFilePermissions(root / "c" / "gcc",
                         {fpUserRead, fpUserWrite, fpUserExec, fpGroupExec, fpOthersExec})
      let site = DriverSite(known: true, nimCwd: root, search: dsPosix,
                            pathVar: root / "a" & ":" & root / "b" & ":" & root / "c")
      let r = siteResolver(site)("gcc")
      check r.found
      if r.found:
        check r.path == root / "c" / "gcc"

    test "a symlink to an executable is run; nothing executable anywhere refuses":
      let root = createTempDir("crisol_lowsC_", "_execvp")
      defer: removeDir(root)
      createDir(root / "real")
      writeFile(root / "real" / "cc1", "#!/bin/sh\n")
      setFilePermissions(root / "real" / "cc1", {fpUserRead, fpUserWrite, fpUserExec})
      createDir(root / "l")
      createSymlink(root / "real" / "cc1", root / "l" / "gcc")
      let hit = siteResolver(DriverSite(known: true, nimCwd: root, search: dsPosix,
                                        pathVar: root / "l"))("gcc")
      check hit.found and hit.path == root / "l" / "gcc"
      createDir(root / "d" / "gcc")
      let miss = siteResolver(DriverSite(known: true, nimCwd: root, search: dsPosix,
                                         pathVar: root / "d"))("gcc")
      check not miss.found

    test "a path-named driver is held to the same rule":
      let root = createTempDir("crisol_lowsC_", "_execvp")
      defer: removeDir(root)
      writeFile(root / "gcc", "#!/bin/sh\n")
      setFilePermissions(root / "gcc", {fpUserRead, fpUserWrite})
      let r = siteResolver(DriverSite(known: true, nimCwd: root, search: dsPosix,
                                      pathVar: ""))(root / "gcc")
      check not r.found
