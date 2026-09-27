## test_probe_spawn_cwd.nim -- R12-L1 / R11-S3: the real C toolchain probe
## survives a tool it cannot start, and finds a driver on a RELATIVE PATH
## entry where the build's nim finds it.
##
## THE FINDINGS.
##   * R12-L1. The probe runs its tools in a `ccprobe_*` scratch directory it
##     deletes afterwards. On POSIX, `osproc.startProcess` moved crisol's OWN
##     cwd into that directory for the spawn and moved it back only when the
##     spawn succeeded, so a tool that could not be started left crisol in a
##     directory about to be deleted, and every command then died on its
##     next `getCurrentDir` (`crisol run` exit 2, "unexpected error during
##     plan"; `crisol list` exit 1). Two real triggers: no `ldd` on PATH (the
##     runtime label's documented fallback was unreachable), and a relative
##     PATH entry holding the driver (`PATH=wbin:$PATH`, or a `config.nims`
##     `putEnv("PATH", "wbin:" & ...)`): the driver search answered the
##     relative path `wbin/gcc`, which does not resolve from the scratch dir.
##   * R11-S3. The driver search resolved a relative PATH entry against
##     crisol's cwd, while nim resolves it against its own (the project
##     root). With crisol started elsewhere, a `config.nims` that puts a
##     relative `wbin` first made nim run `wbin/gcc` while the probe
##     identified, and keyed by, the PATH's real `gcc`.
##
## WHAT THIS FILE PINS (POSIX; Windows passes the directory to
## `CreateProcess` and never moved the parent's cwd):
##   1. no `ldd` on PATH: the probe returns, crisol's cwd intact, and the
##      runtime half is identified with the fallback label (the resolved
##      library names) instead of `ldd --version`'s line;
##   2. CONTROL no C compiler on PATH: both halves unidentified, cwd intact;
##   3. crisol's PATH has a relative `wbin` holding a wrapper gcc, crisol's cwd
##      the project root: the wrapper is identified, and the key moves when
##      only the wrapper changes;
##   4. a `config.nims` puts a relative `wbin` first and crisol runs from
##      elsewhere: the identity is the wrapper nim runs, not the PATH's gcc;
##   5. the `crisol` CLI: `list` and `run` exit 0 under (1) and (3).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/integration/test_probe_spawn_cwd.nim

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

when defined(posix):
  import crisol/ccidentity
  import "../support/ccprobes"

  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir

  proc shadowPath(dir: string; without: openArray[string]): string =
    ## A directory of symlinks to every file on this process's PATH (first
    ## entry wins, as the search does), minus the names in `without`; its
    ## path is the PATH to use.
    createDir(dir)
    for entry in getEnv("PATH").split(':'):
      if entry.len == 0 or not dirExists(entry): continue
      for kind, f in walkDir(entry):
        let name = f.extractFilename
        if name in without or symlinkExists(dir / name) or fileExists(dir / name):
          continue
        try: createSymlink(f, dir / name)
        except OSError: discard
    dir

  template withPath(value: string; body: untyped) =
    let saved = getEnv("PATH")
    putEnv("PATH", value)
    try:
      body
    finally:
      putEnv("PATH", saved)

  template withCwd(dir: string; body: untyped) =
    let savedCwd = getCurrentDir()
    setCurrentDir(dir)
    try:
      body
    finally:
      setCurrentDir(savedCwd)

  proc ctxOf(root: string): CcProbeContext =
    CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])

  proc writeWrapper(path, tag: string) =
    ## A POSIX-shell gcc wrapper; `tag` changes the file, and only the file.
    let real = findExe("gcc")
    doAssert real.len > 0, "no gcc on PATH"
    createDir(path.parentDir)
    writeFile(path, "#!/bin/sh\n# wrapper " & tag & "\nexec " & real &
                    " \"$@\"\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

  proc newProject(): string =
    result = createTempDir("r12l1_probe_", "")
    createDir(result / ".crisol")
    createDir(result / "tests" / "unit")
    writeFile(result / "crisol.kdl",
              "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
    writeFile(result / "tests" / "unit" / "test_a.nim", "echo \"a\"\n")

  let haveGcc = findExe("gcc").len > 0
  let haveLdd = findExe("ldd").len > 0
  let home = getCurrentDir()

  suite "R12-L1 -- the real probe survives a tool it cannot start":

    setup:
      setCurrentDir(home)   # a failed test must not strand the next in a deleted dir

    test "no ldd on PATH: the runtime half takes the fallback label; cwd intact":
      if not haveGcc or not haveLdd:
        echo "(no gcc or no ldd on this host: the premise does not hold)"
        skip()
      else:
        let root = newProject()
        defer: removeDir(root)
        let nb = shadowPath(root / "nb", ["ldd"])
        let before = getCurrentDir()
        let control = ccFingerprint(ctxOf(root))
        var noLdd: CcFingerprint
        withPath(nb):
          noLdd = ccFingerprint(ctxOf(root))
        check getCurrentDir() == before        # raised before the fix
        checkpoint $noLdd & " / " & noLdd.runtime.why
        check toolchainVerdict(noLdd).kind == tvIdentified
        check noLdd.runtime.state == cfsKnown
        check noLdd.runtime.text == "libc.so.6"     # the resolved-names fallback
        check control.runtime.text != "libc.so.6"   # ldd --version labels it
        check noLdd.compiler == control.compiler

    test "CONTROL no C compiler on PATH: unidentified, fail closed; cwd intact":
      if not haveGcc:
        echo "(no gcc on this host)"
        skip()
      else:
        let root = newProject()
        defer: removeDir(root)
        let nb = shadowPath(root / "nb", ["gcc", "cc", "ldd"])
        let before = getCurrentDir()
        var fp: CcFingerprint
        withPath(nb):
          fp = ccFingerprint(ctxOf(root))
        check getCurrentDir() == before
        check toolchainVerdict(fp) == ToolchainVerdict(kind: tvUnidentified, part: upBoth)

  suite "R12-L1 / R11-S3 -- a relative PATH entry resolves where nim's does":

    setup:
      setCurrentDir(home)   # a failed test must not strand the next in a deleted dir

    test "crisol's PATH has a relative wbin with a wrapper gcc: the wrapper is identified":
      if not haveGcc:
        echo "(no gcc on this host)"
        skip()
      else:
        let root = newProject()
        defer: removeDir(root)
        writeWrapper(root / "wbin" / "gcc", "v1")
        let plain = ccFingerprint(ctxOf(root))
        var v1, v2: CcFingerprint
        withCwd(root):
          withPath("wbin:" & getEnv("PATH")):
            v1 = ccFingerprint(ctxOf(root))
            writeWrapper(root / "wbin" / "gcc", "v2")
            v2 = ccFingerprint(ctxOf(root))
          check getCurrentDir() == root        # raised before the fix
        checkpoint $v1 & " / " & v1.compiler.why
        check toolchainVerdict(v1).kind == tvIdentified
        check v1.compiler != plain.compiler      # the wrapper, not the PATH's gcc
        check v2.compiler != v1.compiler         # only the wrapper changed

    test "a config.nims puts a relative wbin first, crisol runs elsewhere: nim's wrapper is the identity":
      if not haveGcc:
        echo "(no gcc on this host)"
        skip()
      else:
        let root = newProject()
        defer: removeDir(root)
        let plain = ccFingerprint(ctxOf(root))
        writeWrapper(root / "wbin" / "gcc", "v1")
        writeFile(root / "config.nims",
                  "putEnv(\"PATH\", \"wbin:\" & getEnv(\"PATH\"))\n")
        let elsewhere = createTempDir("r12l1_elsewhere_", "")
        defer: removeDir(elsewhere)
        var v1, v2: CcFingerprint
        withCwd(elsewhere):
          v1 = ccFingerprint(ctxOf(root))
          writeWrapper(root / "wbin" / "gcc", "v2")
          v2 = ccFingerprint(ctxOf(root))
          check getCurrentDir() == elsewhere
        checkpoint $v1 & " / " & v1.compiler.why
        check toolchainVerdict(v1).kind == tvIdentified
        check v1.compiler != plain.compiler      # nim runs root/wbin/gcc
        check v2.compiler != v1.compiler         # and the key follows it

  proc buildCrisolBinary(): string =
    ## A private output path, so a concurrently-running test never races
    ## this build.
    result = getTempDir() / "crisol_test_r12l1_probe_cwd_bin" / "crisol"
    createDir(result.parentDir)
    let cmd = "nim c --hints:off --warnings:off --mm:orc -o:" &
              result.quoteShell & " " & (repoRoot / "src" / "crisol.nim").quoteShell
    let (output, code) = execCmdEx(cmd)
    doAssert code == 0, "failed to build crisol binary: " & output

  suite "R12-L1 -- the crisol CLI under the two triggers":

    test "no ldd on PATH, and a relative wbin with the driver: list and run exit 0":
      if not haveGcc or not haveLdd:
        echo "(no gcc or no ldd on this host: the premise does not hold)"
        skip()
      else:
        let bin = buildCrisolBinary()
        let root = newProject()
        defer: removeDir(root)
        let nb = shadowPath(root / "nb", ["ldd"])
        writeWrapper(root / "wbin" / "gcc", "v1")
        proc crisol(path: string; args: varargs[string]): tuple[output: string; exitCode: int] =
          let env = newStringTable(modeCaseSensitive)
          for k, v in envPairs(): env[k] = v
          env["PATH"] = path
          var cmd = bin.quoteShell
          for a in args: cmd.add " " & a.quoteShell
          execCmdEx(cmd, env = env, workingDir = root)
        for (label, path) in [("no ldd", nb), ("relative wbin", "wbin:" & getEnv("PATH"))]:
          checkpoint label
          let l = crisol(path, "list")
          checkpoint l.output
          check l.exitCode == 0
          let r = crisol(path, "run", "--jobs", "1")
          checkpoint r.output
          check r.exitCode == 0
          check "PASSED" in r.output
else:
  echo "test_probe_spawn_cwd: POSIX only (Windows passes the directory to CreateProcess)"

echo "test_probe_spawn_cwd done"
