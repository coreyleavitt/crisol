## fake_git.nim — fixture for issue #22's `--changed` completeness gate.
##
## Impersonates the four git invocations `gitdiff.changedFiles` makes, and
## emits the diff's NUL-separated `--raw` records in TWO bursts — a short
## first flush, a pause, then the rest. Real `git` cannot be asked to chunk its
## output on demand, so this is how the truncation becomes deterministic at
## the level that actually matters: the changed-file set crisol selects tests
## from.
##
## Installed by prepending its directory to `PATH` under the name `git`
## (`git.exe` on Windows), so `gitdiff`'s own `startProcess("git", …,
## {poUsePath})` finds it with no seam, no injection, and no change to the
## production call path.
##
## Env knobs:
##   CRISOL_FAKE_GIT_NAMES     how many changed names to report (default 50)
##   CRISOL_FAKE_GIT_DELAY_MS  pause between the two bursts      (default 150)
##   CRISOL_FAKE_GIT_STDERR_BYTES
##       when > 0, `diff` writes this many bytes to STDERR and exits 1 instead
##       of reporting names. Models the real case gitdiff's own comment waved
##       away — `core.autocrlf` emits one warning line PER FILE, so a few
##       thousand files is far past the pipe buffer. A caller that does not
##       drain stderr concurrently with stdout wedges here.
##   CRISOL_FAKE_GIT_HANG_SUBCOMMAND
##       when set to a subcommand name (e.g. "rev-parse"), that subcommand
##       hangs forever — writes NOTHING, on either stream, and never exits —
##       instead of answering. Models CR4: "a `git` blocked on an SSH/
##       credential prompt" is indistinguishable, from `gitdiff`'s side, from
##       a `git` that simply never writes anything and never returns. Checked
##       before any output is produced, so this exercises the case where
##       NEITHER pipe ever has data — the `poll(-1)` / unbounded-spin path
##       the drain itself blocks in, not merely a slow finish.
##   CRISOL_FAKE_GIT_UNTRACKED
##       how many untracked names `ls-files` reports (default 0), drawn from
##       `fakeGitUntrackedNames` so the test's expected set cannot drift.
##   CRISOL_FAKE_GIT_LS_FILES_EXIT
##       when non-zero, `ls-files` still writes its untracked names to stdout,
##       then a diagnostic to stderr, and exits with this code. Models a git
##       that answered but did not vouch for its answer (a corrupt index, a
##       lock it could not take): the names it DID print are no promise that
##       they are all of them, so a caller must not treat the run as a
##       complete untracked-file scan.
##
## Sizing: see `two_burst_output.nim`'s header — the whole list must stay under
## the ~4 KB pipe buffer or a truncating caller wedges instead of failing. One
## `--raw` record (header + name) is ~61 bytes, so 50 names is ~3.1 KB.

import std/[os, strutils]

const
  FakeGitNamePrefix* = "tests/unit/test_gen_"
  FakeGitNameSuffix* = ".nim"

proc fakeGitNames*(n: int): seq[string] =
  ## The exact names this fixture reports, shared with the test so the
  ## expected set can never drift from the produced one.
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = FakeGitNamePrefix & align($i, 3, '0') & FakeGitNameSuffix

const FakeGitUntrackedPrefix* = "src/untracked_new_"

proc fakeGitUntrackedNames*(n: int): seq[string] =
  ## The exact untracked names `ls-files` reports.
  result = newSeq[string](n)
  for i in 0 ..< n:
    result[i] = FakeGitUntrackedPrefix & align($i, 3, '0') & FakeGitNameSuffix

proc envInt(name: string; fallback: int): int =
  try: parseInt(getEnv(name, $fallback))
  except ValueError: fallback

when isMainModule:
  let sub = if paramCount() >= 1: paramStr(1) else: ""
  if getEnv("CRISOL_FAKE_GIT_HANG_SUBCOMMAND", "") == sub and sub.len > 0:
    while true:
      sleep(1000)
  case sub
  of "rev-parse":
    # `rev-parse --verify ... <base>^{commit}` resolves the diff base to a
    # commit id; `rev-parse --is-inside-work-tree` is changedFiles' "is this a
    # work tree?" probe. Both are short enough that they are unaffected by the
    # truncation either way.
    var verify = false
    for i in 2 .. paramCount():
      if paramStr(i) == "--verify": verify = true
    if verify:
      stdout.write(repeat('0', 40) & "\n")
    else:
      stdout.write("true\n")
  of "diff":
    let errBytes = envInt("CRISOL_FAKE_GIT_STDERR_BYTES", 0)
    if errBytes > 0:
      var payload = newString(errBytes)
      for i in 0 ..< errBytes:
        payload[i] = char(ord('a') + (i mod 26))
      stderr.write(payload)
      stderr.flushFile()
      quit(1)
    # `diff -z --raw`: per name, a `:<old mode> <new mode> <old sha> <new
    # sha> <status>` header then the name, each NUL-terminated.
    const rawHeader = ":100644 100644 0000000 0000000 M"
    let names = fakeGitNames(envInt("CRISOL_FAKE_GIT_NAMES", 50))
    doAssert names.len >= 2, "fake_git: need at least two names to burst"
    stdout.write(rawHeader & '\0' & names[0] & '\0')
    stdout.flushFile()
    sleep(envInt("CRISOL_FAKE_GIT_DELAY_MS", 150))
    for n in names[1 .. ^1]:
      stdout.write(rawHeader & '\0' & n & '\0')
    stdout.flushFile()
  of "ls-files":
    var stage = false
    for i in 2 .. paramCount():
      if paramStr(i) == "--stage": stage = true
    if stage:
      # `ls-files -z --stage` — the index's gitlinks (R13-S3). This index
      # holds none.
      quit(0)
    # `ls-files -z --others --exclude-standard` — the untracked-files scan.
    for n in fakeGitUntrackedNames(envInt("CRISOL_FAKE_GIT_UNTRACKED", 0)):
      stdout.write(n & '\0')
    stdout.flushFile()
    let lsExit = envInt("CRISOL_FAKE_GIT_LS_FILES_EXIT", 0)
    if lsExit != 0:
      stderr.write("fatal: fake_git: index file corrupt\n")
      stderr.flushFile()
      quit(lsExit)
  else:
    stderr.write("fake_git: unexpected subcommand '" & sub & "'\n")
    quit(1)
  quit(0)
