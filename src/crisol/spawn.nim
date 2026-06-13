## spawn.nim — low-level fork+exec supervisor for crisol A2b.
##
## Invariants (RFC Implementation Decisions):
##   • Between fork() and execvp() the child executes ONLY async-signal-safe
##     primitives: setpgid, dup2, close, execvp, _exit.  No Nim GC, no heap
##     allocation, no string construction, no exceptions.
##   • The cstring argv array is pre-built BEFORE fork so the child path is
##     a plain pointer dereference.
##   • The output fd is opened BEFORE fork; the child just dup2s it.
##   • The executor is single-threaded before the spawn loop (no Nim threads
##     before this code runs), satisfying the sound-use prerequisite.
##
## Public surface:
##   forkExec*(args, outputFd)      → Pid   (< 0 on fork failure)
##   supervise*(pid, timeoutMs)     → (exitCode, signal, timedOut)

import std/[os, monotimes, times, tables, envvars]
import std/posix

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc devNull(): cint =
  ## Open /dev/null O_RDONLY; returns fd or -1 on error.
  ## Called before fork — result passed to child via closure.
  posix.open("/dev/null".cstring, O_RDONLY)

proc execvpe(path: cstring; argv: cstringArray; envp: cstringArray): cint
  {.importc: "execvpe", header: "<unistd.h>".}
  ## Linux execvpe(3): exec path with explicit argv + envp arrays.
  ## Async-signal-safe: safe to call in the child after fork.


# ---------------------------------------------------------------------------
# forkExec
# ---------------------------------------------------------------------------

proc forkExec*(args: openArray[string]; outputFd: cint): Pid =
  ## Fork a child, place it in its own process group (setpgid(0,0)), redirect
  ## stdin from /dev/null and stdout+stderr to outputFd, then execvp the given
  ## argv.  Returns child Pid (== pgid) on success, or -1 on fork failure.
  ##
  ## SAFETY: the child path (between fork and execvp) is async-signal-safe.
  ## The argv cstring array and /dev/null fd are built/opened BEFORE fork.
  ##
  ## R9: The PARENT also calls setpgid(childPid, childPid) after fork.  This is
  ## the race-free idiom: both parent and child call setpgid targeting the same
  ## outcome; whichever runs first wins, and EACCES/EPERM from the other is
  ## harmless (the child may have already exec'd).

  if args.len == 0:
    return Pid(-1)

  # Pre-build cstring argv BEFORE fork — no allocation in child path.
  var cargs = newSeq[cstring](args.len + 1)
  for i, s in args:
    cargs[i] = s.cstring          # points into Nim string; ORC never moves heap
                                  # memory, so this is valid as long as args[i] is live
  cargs[args.len] = nil            # execvp sentinel

  # Open /dev/null for stdin BEFORE fork.
  let nullFd = devNull()
  if nullFd < 0:
    return Pid(-1)

  let childPid = fork()
  if childPid < 0:
    discard posix.close(nullFd)
    return Pid(-1)

  if childPid == 0:
    # =========================================================================
    # CHILD — only async-signal-safe operations from here to execvp/_exit.
    # =========================================================================

    # 1. Own process group (pgid == pid after this call).
    discard setpgid(Pid(0), Pid(0))

    # 2. Stdin ← /dev/null.
    discard dup2(nullFd, cint(STDIN_FILENO))
    discard posix.close(nullFd)

    # 3. Stdout + stderr → outputFd.
    discard dup2(outputFd, cint(STDOUT_FILENO))
    discard dup2(outputFd, cint(STDERR_FILENO))
    # Don't close outputFd here — it may == STDOUT/STDERR already after dup2,
    # and closing it would break the redirected fd.  The O_CLOEXEC flag (set
    # by the caller via open) will close it across execvp automatically.

    # 4. exec — replaces image; argv[0] is the program path.
    discard posix.execvp(cargs[0], cast[cstringArray](addr cargs[0]))

    # execvp returns only on error.
    discard posix.write(cint(STDERR_FILENO), "_exit(127)\n".cstring, 11)
    exitnow(127)
    # =========================================================================

  # Parent: close /dev/null fd we opened (child has its own copy after dup2).
  discard posix.close(nullFd)

  # R9: parent also calls setpgid to be race-free.  If the child already exec'd
  # and changed pgid itself, EACCES/EPERM is returned — harmless, ignore it.
  discard setpgid(childPid, childPid)

  result = childPid

# ---------------------------------------------------------------------------
# forkExecEnv — fork+exec with additional env vars injected (R1)
# ---------------------------------------------------------------------------

proc forkExecEnv*(args: openArray[string]; outputFd: cint;
                  extraEnv: openArray[(string, string)]): Pid =
  ## Like forkExec but injects extra key=value pairs into the child environment.
  ##
  ## Strategy (R1): build the envp array BEFORE fork by copying the parent
  ## environ and appending/overriding the extra pairs.  The child calls execvpe
  ## with this explicit envp — no putenv/setenv in the child path (not
  ## async-signal-safe and would mutate the parent under a shared-memory model).
  ##
  ## The envp cstring array points into Nim strings that remain live until after
  ## execvpe replaces the image (or we _exit), so no lifetime issues arise.

  if args.len == 0:
    return Pid(-1)

  # Pre-build cstring argv BEFORE fork.
  var cargs = newSeq[cstring](args.len + 1)
  for i, s in args:
    cargs[i] = s.cstring
  cargs[args.len] = nil

  # Build the merged environment: start with current process environ (via
  # std/envvars.envPairs which reads the live environment), then override/
  # append the extra pairs.  We keep Nim strings alive in a seq.
  var envMap: OrderedTable[string, string]
  for k, v in envPairs():
    envMap[k] = v
  for (k, v) in extraEnv:
    envMap[k] = v

  # Build the envp strings BEFORE fork — safe in parent, pre-allocated.
  # IMPORTANT: cenv[j] must point into envStrings[j] data (NOT a local copy).
  # Use index-based iteration so cstring pointers remain live into envStrings.
  var envStrings: seq[string] = @[]
  for k, v in envMap:
    envStrings.add(k & "=" & v)
  var cenv = newSeq[cstring](envStrings.len + 1)
  for j in 0 ..< envStrings.len:
    cenv[j] = envStrings[j].cstring   # points into envStrings[j], not a copy
  cenv[envStrings.len] = nil

  # Open /dev/null for stdin BEFORE fork.
  let nullFd = devNull()
  if nullFd < 0:
    return Pid(-1)

  let childPid = fork()
  if childPid < 0:
    discard posix.close(nullFd)
    return Pid(-1)

  if childPid == 0:
    # CHILD — only async-signal-safe operations from here to execvpe/_exit.
    discard setpgid(Pid(0), Pid(0))
    discard dup2(nullFd, cint(STDIN_FILENO))
    discard posix.close(nullFd)
    discard dup2(outputFd, cint(STDOUT_FILENO))
    discard dup2(outputFd, cint(STDERR_FILENO))
    # exec with explicit envp — does NOT inherit or modify parent env.
    discard execvpe(cargs[0], cast[cstringArray](addr cargs[0]),
                    cast[cstringArray](addr cenv[0]))
    discard posix.write(cint(STDERR_FILENO), "_exit(127)\n".cstring, 11)
    exitnow(127)

  discard posix.close(nullFd)
  discard setpgid(childPid, childPid)
  result = childPid

# ---------------------------------------------------------------------------
# supervise
# ---------------------------------------------------------------------------

const GracePeriodMs* = 400
  ## Time (ms) to wait after SIGTERM before escalating to SIGKILL.
  ## Reused by the execute handleInterrupt template.

proc supervise*(pid: Pid; timeoutMs: int): tuple[exitCode: int; signal: int; timedOut: bool] =
  ## Poll waitpid(WNOHANG) every ~25 ms until the child exits or the deadline
  ## is reached.  On timeout: SIGTERM → grace period → SIGKILL if still alive.
  ##
  ## R10: waitpid returning EINTR is retried (not treated as child exit).
  ## R11: deadline computed with monotonic time; wall clock used only for
  ##      human-facing durationMs (handled by the caller).
  ## M11: SIGTERM → 400 ms grace → SIGKILL escalation on timeout.
  ##
  ## Returns:
  ##   exitCode  — WEXITSTATUS when exited normally; 0 otherwise
  ##   signal    — WTERMSIG when killed by signal; 0 otherwise
  ##   timedOut  — true when timeout expired and we killed the group

  let stepMs   = 25
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)

  while true:
    var wstatus: cint = 0
    var r: Pid

    # R10: retry on EINTR.
    while true:
      r = waitpid(pid, wstatus, WNOHANG)
      if r >= Pid(0) or errno != EINTR:
        break

    if r == pid:
      # Child has exited.
      if WIFEXITED(wstatus):
        return (exitCode: int(WEXITSTATUS(wstatus)), signal: 0, timedOut: false)
      elif WIFSIGNALED(wstatus):
        return (exitCode: 0, signal: int(WTERMSIG(wstatus)), timedOut: false)
      else:
        # Stopped or continued — should not happen in our usage; keep polling.
        discard
    elif r < Pid(0):
      # ECHILD (truly no child) — treat as exit 1.
      return (exitCode: 1, signal: 0, timedOut: false)

    # Check deadline AFTER the waitpid so we always attempt at least one poll.
    if getMonoTime() >= deadline:
      # M11: SIGTERM → grace period → SIGKILL escalation.
      discard killpg(pid, SIGTERM)
      # Drain up to GracePeriodMs with WNOHANG polls.
      let graceDeadline = getMonoTime() + initDuration(milliseconds = GracePeriodMs)
      while getMonoTime() < graceDeadline:
        var ws2: cint = 0
        var r2: Pid
        while true:
          r2 = waitpid(pid, ws2, WNOHANG)
          if r2 >= Pid(0) or errno != EINTR:
            break
        if r2 == pid:
          # Exited during grace.
          return (exitCode: 0, signal: int(SIGTERM), timedOut: true)
        os.sleep(20)
      # Still alive — escalate to SIGKILL and reap (EINTR-guarded like elsewhere).
      discard killpg(pid, SIGKILL)
      var ws2: cint = 0
      while true:
        let rk = waitpid(pid, ws2, 0)
        if rk >= Pid(0) or errno != EINTR:
          break
      return (exitCode: 0, signal: int(SIGKILL), timedOut: true)

    os.sleep(stepMs)
