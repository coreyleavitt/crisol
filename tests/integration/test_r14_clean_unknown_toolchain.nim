## test_r14_clean_unknown_toolchain.nim -- R14-D4 / R14-L1: `crisol clean`
## with a toolchain it cannot identify prunes nothing by that toolchain.
##
## The persistent nimcache directories are named after the toolchain
## (`<slug>-<toolchainFingerprint(nim, cc)>`), and `clean` keeps only the ones
## named after the CURRENT toolchain. When `nim` or the C compiler is missing
## from PATH the probes answer a placeholder, which names no directory any
## run wrote, so every nimcache directory -- and every binary, which clean
## keeps only next to a current-toolchain nimcache -- was pruned. The next
## run then recompiled everything. The same happened when an interrupt
## refused the probes, which a special case in the CLI covered on its own.
##
## Fixed: the probes carry whether they identified the toolchain, and an
## unknown identity skips the toolchain-suffixed prune, with a warning,
## while the rest of clean still runs. This file drives the real CLI binary
## under each cause: nim absent, the C compiler absent, and an interrupt in
## the nim probe (SIGTERM: exit 143, nothing pruned).
##
## POSIX-only: the PATH shadowing uses symlinks and the interrupt a signal
## (`osproc.terminate`, so the file needs no `std/posix` import).

import std/[os, osproc, streams, strtabs, strutils, unittest]

when defined(posix):
  let repoRoot = currentSourcePath().parentDir.parentDir.parentDir

  proc buildCrisolBinary(): string =
    ## A private output path, so a concurrently-running test never races
    ## this build.
    result = getTempDir() / "crisol_test_r14_clean_unknown_bin" / "crisol"
    createDir(result.parentDir)
    let cmd = "nim c --hints:off --warnings:off --mm:orc -o:" &
              result.quoteShell & " " & (repoRoot / "src" / "crisol.nim").quoteShell
    let (output, code) = execCmdEx(cmd)
    doAssert code == 0, "failed to build crisol binary: " & output

  proc shadowPath(dir: string; without: openArray[string]): string =
    ## A directory of symlinks to every file on this process's PATH (first
    ## entry wins, as the search does), minus the names in `without`.
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

  proc git(root, args: string) =
    let (o, rc) = execCmdEx("git -C " & root.quoteShell & " " & args)
    doAssert rc == 0, "git " & args & " failed: " & o

  proc newProject(): string =
    result = getTempDir() / ("crisol_r14_clean_" & $getCurrentProcessId())
    removeDir(result)
    createDir(result / "tests" / "unit")
    writeFile(result / "crisol.kdl", "group \"unit\" {\n    globs \"tests/unit/test_*.nim\"\n}\n")
    writeFile(result / "tests" / "unit" / "test_a.nim", "echo \"a\"\n")
    writeFile(result / "tests" / "unit" / "test_b.nim", "echo \"b\"\n")
    writeFile(result / ".gitignore", ".crisol/\n")
    git(result, "init -q")
    git(result, "-c user.email=a@b -c user.name=n -c commit.gpgsign=false add -A")
    git(result, "-c user.email=a@b -c user.name=n -c commit.gpgsign=false commit -qm init")

  proc envWith(path: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): result[k] = v
    result["PATH"] = path

  proc crisol(bin, root: string; args: openArray[string];
              path = getEnv("PATH")): tuple[output: string; code: int] =
    let p = startProcess(bin, workingDir = root, args = args, env = envWith(path),
                         options = {poStdErrToStdOut})
    let output = p.outputStream.readAll
    let code = p.waitForExit
    p.close
    (output, code)

  proc stateCounts(root: string): tuple[cache, bin: int] =
    ## The per-entrypoint nimcache directories (not the result cache's
    ## `v<N>` root) and the binaries.
    for kind, p in walkDir(root / ".crisol" / "cache"):
      let name = p.extractFilename
      if kind == pcDir and not (name.len > 1 and name[0] == 'v' and
                                name[1 .. ^1].allCharsInSet(Digits)):
        inc result.cache
    for kind, p in walkDir(root / ".crisol" / "bin"): inc result.bin

  let bin = buildCrisolBinary()

  suite "R14-D4 / R14-L1 -- crisol clean under an unidentified toolchain":

    let root = newProject()
    let r1 = crisol(bin, root, ["run", "--jobs", "1"])
    let r2 = crisol(bin, root, ["run", "--jobs", "1"])
    doAssert r1.code == 0 and r2.code == 0, r1.output & r2.output
    let before = stateCounts(root)

    test "precondition: two runs left a nimcache and a binary per entrypoint":
      check before.cache == 2
      check before.bin == 2

    test "nim absent from PATH: clean warns and prunes nothing live":
      let path = shadowPath(root / ".." / ("r14_nonim_" & $getCurrentProcessId()), ["nim"])
      defer: removeDir(path)
      let r = crisol(bin, root, ["clean"], path)
      checkpoint r.output
      check r.code == 0
      check "warning" in r.output
      check stateCounts(root) == before

    test "the C compiler absent from PATH: clean warns and prunes nothing live":
      let path = shadowPath(root / ".." / ("r14_nocc_" & $getCurrentProcessId()),
                            ["gcc", "cc", "clang"])
      defer: removeDir(path)
      let r = crisol(bin, root, ["clean"], path)
      checkpoint r.output
      check r.code == 0
      check "warning" in r.output
      check stateCounts(root) == before

    test "an interrupt in the nim probe: clean exits 128+n and prunes nothing":
      let hw = root / ".." / ("r14_hw_" & $getCurrentProcessId())
      createDir(hw)
      defer: removeDir(hw)
      let marker = hw / "reached"
      writeFile(hw / "nim", "#!/bin/sh\n" &
        "case \"$*\" in *--version*) : > " & marker.quoteShell & "; exec sleep 30 ;; esac\n" &
        "exec " & findExe("nim").quoteShell & " \"$@\"\n")
      setFilePermissions(hw / "nim", {fpUserRead, fpUserWrite, fpUserExec})
      let p = startProcess(bin, workingDir = root, args = ["clean"],
                           env = envWith(hw & ":" & getEnv("PATH")),
                           options = {poStdErrToStdOut})
      var waited = 0
      while not fileExists(marker) and waited < 20_000:
        sleep(50); waited += 50
      check fileExists(marker)
      sleep(200)
      p.terminate()   # SIGTERM
      let output = p.outputStream.readAll
      let code = p.waitForExit
      p.close
      checkpoint output
      check code == 128 + 15
      check stateCounts(root) == before

    test "with the toolchain back: clean keeps every live nimcache and binary":
      let r = crisol(bin, root, ["clean"])
      checkpoint r.output
      check r.code == 0
      check "warning" notin r.output
      check stateCounts(root) == before

    removeDir(root)
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/integration/test_r14_clean_unknown_toolchain.nim"
    echo "test_r14_clean_unknown_toolchain: skipped (POSIX-only)"
