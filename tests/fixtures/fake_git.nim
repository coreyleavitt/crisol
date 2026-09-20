## fake_git.nim — fixture for issue #22's `--changed` completeness gate.
##
## Impersonates the three git invocations `gitdiff.changedFiles` makes, and
## emits the diff's NUL-separated name list in TWO bursts — a short first
## flush, a pause, then the rest. Real `git` cannot be asked to chunk its
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
##   CRISOL_FAKE_GIT_NAMES     how many changed names to report (default 100)
##   CRISOL_FAKE_GIT_DELAY_MS  pause between the two bursts      (default 150)
##   CRISOL_FAKE_GIT_STDERR_BYTES
##       when > 0, `diff` writes this many bytes to STDERR and exits 1 instead
##       of reporting names. Models the real case gitdiff's own comment waved
##       away — `core.autocrlf` emits one warning line PER FILE, so a few
##       thousand files is far past the pipe buffer. A caller that does not
##       drain stderr concurrently with stdout wedges here.
##
## Sizing: see `two_burst_output.nim`'s header — the whole list must stay under
## the ~4 KB pipe buffer or a truncating caller wedges instead of failing. 100
## names is ~2.8 KB.

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

proc envInt(name: string; fallback: int): int =
  try: parseInt(getEnv(name, $fallback))
  except ValueError: fallback

when isMainModule:
  let sub = if paramCount() >= 1: paramStr(1) else: ""
  case sub
  of "rev-parse":
    # `rev-parse --is-inside-work-tree` — changedFiles' "is this a work tree?"
    # probe. Short enough that it is unaffected by the truncation either way.
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
    let names = fakeGitNames(envInt("CRISOL_FAKE_GIT_NAMES", 100))
    doAssert names.len >= 2, "fake_git: need at least two names to burst"
    stdout.write(names[0] & '\0')
    stdout.flushFile()
    sleep(envInt("CRISOL_FAKE_GIT_DELAY_MS", 150))
    for n in names[1 .. ^1]:
      stdout.write(n & '\0')
    stdout.flushFile()
  of "ls-files":
    # `ls-files -z --others --exclude-standard` — the untracked-files scan.
    # No untracked files in this scenario.
    discard
  else:
    stderr.write("fake_git: unexpected subcommand '" & sub & "'\n")
    quit(1)
  quit(0)
