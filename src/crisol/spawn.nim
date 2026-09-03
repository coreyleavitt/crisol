## spawn.nim — low-level fork+exec supervisor for crisol A2b/A4a/A4b/A4c.
##
## Invariants (RFC Implementation Decisions):
##   • Between fork() and exec the child executes ONLY async-signal-safe
##     primitives: setpgid, dup2, close, chdir, setrlimit, execvp/execve, _exit.  No
##     Nim GC, no heap allocation, no string construction, no exceptions.
##   • The cstring argv array is pre-built BEFORE fork so the child path is
##     a plain pointer dereference.
##   • The output fd is opened BEFORE fork; the child just dup2s it.
##   • The executor is single-threaded before the spawn loop (no Nim threads
##     before this code runs), satisfying the sound-use prerequisite.
##
## Public surface (post-A6 consolidation — exactly two spawn entries):
##   forkExec*(args, outputFd)                               → Pid   (< 0 on fork failure)
##       The COMPILE path only: no env injection, no sandbox.
##   forkExecEnvScratch*(args, outputFd, extraEnv, spec,
##                       outScratchDir)        → (pid, achieved)     (A4a+A4b+A4d, A2a-iii)
##       The SINGLE spec-driven RUN entry: env scrub + isolated TMPDIR (achieved
##       BY CONSTRUCTION, rfc-0007 §5 — no IPC needed for either) + per-limit
##       readback over a shrunk pre-fork pipe (rfc-0007 A2a-iii: one status
##       byte per LimitKind, replacing the old single aggregate rlimitsApplied
##       bit + SandboxAchieved, which is deleted).  A6 threaded this into the
##       live runner dispatch (spawnRunDirect / spawnRun); the legacy
##       `forkExecEnv` overloads were retired (forkExecEnvScratch with a
##       hlNone/no-scratch spec subsumes them).
##   supervise*(pid, timeoutMs)                              → (exitCode, signal, timedOut)

import std/[os, envvars, sequtils, options]
import std/posix
import crisol/[types, sandbox]
from crisol/process/types as ptypes import nil  ## qualified access to the
  ## §1 Limits/LimitKind/LimitStatus/LimitsAchieved shape (rfc-0007 A2a-iii).
  ## Deliberately NOT `import crisol/process` — this module stays
  ## dependency-free of the Supervisor contract until A2b folds the runner
  ## onto it (see the GracePeriodMs note at the bottom of this file).

proc mkdtemp(tmpl: cstring): cstring
  {.importc: "mkdtemp", header: "<stdlib.h>".}
  ## POSIX mkdtemp(3): create a secure temp dir from a template ending in XXXXXX.
  ## Modifies the template in-place and returns it on success, or nil on error.
  ## Async-signal-safe: safe to call before fork (called in parent only here).

proc cloexecPipe(fds: var array[2, cint]): bool =
  ## Portable stand-in for Linux pipe2(O_CLOEXEC): pipe(2) then FD_CLOEXEC on
  ## both ends.  Darwin has no pipe2.  The atomicity pipe2 buys only matters if
  ## another thread can fork between the two calls; crisol's executor is
  ## single-threaded by invariant (see module doc), so this is equivalent.
  ## Both ends stay usable in the child between fork and exec; they auto-close
  ## at exec.  Returns false (fds closed) on any failure.
  if posix.pipe(fds) != 0:
    return false
  for fd in fds:
    if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
      return false
  true

# ---------------------------------------------------------------------------
# A4b: rlimit constants — importc the ones missing from Nim's std/posix
# ---------------------------------------------------------------------------
# Nim 2.2 std/posix (Linux/amd64) provides: RLIMIT_NOFILE, setrlimit, getrlimit,
# RLimit.  Missing: RLIMIT_CORE, RLIMIT_FSIZE, RLIMIT_AS, RLIMIT_CPU.
# All four are importc'd from <sys/resource.h>.
# A4b introduced RLIMIT_CORE + RLIMIT_FSIZE; A4c adds RLIMIT_AS + RLIMIT_CPU.

var RLIMIT_CORE* {.importc: "RLIMIT_CORE", header: "<sys/resource.h>".}: cint
  ## Resource limit resource ID for core dump file size.
  ## Linux: 4.  Set to 0 to suppress core dumps in sandboxed children.

var RLIMIT_FSIZE* {.importc: "RLIMIT_FSIZE", header: "<sys/resource.h>".}: cint
  ## Resource limit resource ID for maximum file size (bytes).
  ## Linux: 1.  Used to cap output file writes in sandboxed children.

# ---------------------------------------------------------------------------
# A4c: rlimit constants — importc the ones missing from Nim's std/posix
# ---------------------------------------------------------------------------
# Nim 2.2 std/posix (Linux/amd64) does NOT provide RLIMIT_AS or RLIMIT_CPU.
# We importc them directly from <sys/resource.h>.
# Linux values: RLIMIT_CPU = 0, RLIMIT_AS = 9.

var RLIMIT_CPU* {.importc: "RLIMIT_CPU", header: "<sys/resource.h>".}: cint
  ## Resource limit resource ID for CPU time (seconds).
  ## Linux: 0.  When the soft limit is exceeded the kernel sends SIGXCPU
  ## (signal 24 on Linux); when the hard limit is hit the process is killed.
  ## Applied in the child async-signal-safe window when spec.limits.req[lkCpu]
  ## is some(n).

var RLIMIT_AS* {.importc: "RLIMIT_AS", header: "<sys/resource.h>".}: cint
  ## Resource limit resource ID for virtual address space size (bytes).
  ## Linux: 9.  mmap/brk requests that would push total virtual AS past the
  ## limit are refused with ENOMEM, causing Nim's ORC allocator to raise
  ## OutOfMemDefect or the kernel to deliver SIGSEGV.
  ##
  ## SAFETY: never set below MinSafeRlimitAs (see sandbox.nim).  A ceiling
  ## below ORC's startup virtual-address cost will SIGSEGV the child before
  ## main() returns — not a test failure, but a crash the runner cannot interpret.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc devNull(): cint =
  ## Open /dev/null O_RDONLY; returns fd or -1 on error.
  ## Called before fork — result passed to child via closure.
  posix.open("/dev/null".cstring, O_RDONLY)

# Exec with an explicit envp is done with POSIX execve(2) on a path resolved
# in the PARENT (std/os findExe: PATH search iff the name has no '/', exactly
# execvp's rule).  glibc's execvpe(3) — which does the PATH walk in the child —
# is absent on Darwin; resolving before fork also keeps the async-signal-safe
# child window free of any PATH walking.  argv[0] stays as the caller gave it.


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
# A6 spawn consolidation: the only spawn entries are now
#   • forkExec            — compile path (no env injection, no sandbox).
#   • forkExecEnvScratch  — the SINGLE spec-driven run entry (env scrub +
#                           isolated TMPDIR by construction + per-limit
#                           readback IPC, rfc-0007 A2a-iii).
# The legacy `forkExecEnv` overloads (R1 plain-env, A5 spec-env without scratch)
# were retired in A6: `forkExecEnvScratch` subsumes both (a hlNone spec with no
# scratch reduces to the plain behavior).  No production or test code calls them.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# forkExecEnvScratch — A4a: isolated tmpdir + TMPDIR injection + opt-in chdir
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# rfc-0007 A2a-iii: per-limit status-byte encoding (child → parent over a
# pre-fork pipe) — replaces the old single aggregate rlimitsApplied bit AND
# the env/tmpdir bits (env/tmpdir are achieved BY CONSTRUCTION, §5: the
# parent resolves the filtered envp and mkdtemp's the scratch dir BEFORE
# fork, deterministically, so there is nothing left for the child to report).
# The child writes ONE byte per ``LimitKind`` (its ordinal offset, in enum
# order) BEFORE execve; the parent reads all of them post-fork and decodes
# directly into ``LimitsAchieved``.  EOF (fewer than nLimits bytes read) ⇒
# child died before finishing the write ⇒ every REQUESTED kind reads
# ``lsFailed`` (never fabricated as applied, never silently downgraded to
# ``lsNotRequested`` — the ord-0 house rule, §2).
#
# Mirrors process/posixcore.nim's ``applyLimitsChildSide``/readback loop
# (duplicated, not imported — this module stays dependency-free of
# crisol/process until A2b folds the runner onto the Supervisor and this
# whole file retires; see the GracePeriodMs note at the bottom).
# ---------------------------------------------------------------------------

const nLimits = ord(ptypes.LimitKind.high) + 1
  ## Cardinality of LimitKind — the fixed size of the child→parent readback
  ## byte buffer (one byte per kind, at its ordinal offset).

proc rlimitReadbackOk(res: cint; want: int64): bool =
  ## Async-signal-safe: after setrlimit, getrlimit and check the soft limit read
  ## back equal to the requested value.  getrlimit(2) is async-signal-safe.
  ## Returns true iff getrlimit succeeded AND rlim_cur == want.
  ##
  ## Residual limit (documented): a cgroup ceiling BELOW the rlimit (e.g. podman
  ## --memory) is invisible to getrlimit and therefore undetectable here; such
  ## environments need `cacheable #false` for memory-sensitive groups.
  var rl: RLimit
  if getrlimit(res, rl) != 0:
    return false
  rl.rlim_cur == clong(want)

proc applyLimitsChildSide(limits: ptypes.Limits; achieved: var array[nLimits, uint8]) =
  ## Async-signal-safe: setrlimit + getrlimit read-back only, no heap.
  ## rfc-0007 A2a-iii: LOOP-DRIVEN over LimitKind — replaces the five
  ## copied per-field stanzas this proc's predecessor hand-rolled inline.
  ## Order: RLIMIT_AS last (see the ORDER note this replaces) so earlier
  ## setrlimit calls are never constrained by the AS ceiling.
  template applyOne(kind: ptypes.LimitKind; rlimitConst: cint; hardBumpSecs: int64) =
    if limits.req[kind].isSome:
      let want = limits.req[kind].get()
      var rl: RLimit
      rl.rlim_cur = clong(want)
      rl.rlim_max = clong(want + hardBumpSecs)
      if setrlimit(rlimitConst, rl) == 0 and rlimitReadbackOk(rlimitConst, want):
        achieved[ord(kind)] = uint8(ptypes.lsApplied)
      else:
        achieved[ord(kind)] = uint8(ptypes.lsFailed)
    else:
      achieved[ord(kind)] = uint8(ptypes.lsNotRequested)

  # A4b: RLIMIT_CORE, RLIMIT_NOFILE, RLIMIT_FSIZE — safe deterministic defaults.
  # A4c: RLIMIT_CPU, RLIMIT_AS — timing/privilege-sensitive; applied when set.
  # RLIMIT_CPU's hard limit is set 1s above the soft limit so SIGXCPU fires
  # first (at the soft limit), giving the caller a distinguishable signal
  # instead of an immediate/implementation-defined SIGKILL.
  applyOne(ptypes.lkCore, RLIMIT_CORE, 0)
  applyOne(ptypes.lkOpenFiles, RLIMIT_NOFILE, 0)
  applyOne(ptypes.lkFileSize, RLIMIT_FSIZE, 0)
  applyOne(ptypes.lkCpu, RLIMIT_CPU, 1)
  applyOne(ptypes.lkAddressSpace, RLIMIT_AS, 0)

proc forkExecEnvScratch*(
  args:         openArray[string];
  outputFd:     cint;
  extraEnv:     openArray[(string, string)];
  spec:         SandboxSpec;
  outScratchDir: var string;
): tuple[pid: Pid; achieved: ptypes.LimitsAchieved] =
  ## Like the spec-based forkExecEnv but additionally implements A4a:
  ##
  ## When ``spec.tmpdir == true`` (hlIsolated / hlNetwork):
  ##   - Creates a per-invocation scratch directory using mkdtemp(3) with the
  ##     prefix ``crisol_scratch_``.  Its path is written to ``outScratchDir``
  ##     so the caller can verify and clean it up on ALL exit paths.
  ##   - Injects ``TMPDIR=<scratchDir>`` into the child env (appended after the
  ##     allowlist filter, overriding any parent TMPDIR value that survived).
  ##
  ## When ``spec.chdirIntoScratch == true``:
  ##   - The child calls ``chdir(2)`` into the scratch dir in the
  ##     async-signal-safe window (after setpgid, before execve).  This is
  ##     opt-in (default off) because a default chdir silently breaks tests
  ##     that open fixtures at compile-time-relative paths.
  ##
  ## When ``spec.tmpdir == false`` (hlNone):
  ##   - No scratch dir is created; ``outScratchDir`` is set to ``""``.
  ##   - Behaves identically to the three-argument forkExecEnv overload.
  ##
  ## CALLER RESPONSIBILITY: remove ``outScratchDir`` on ALL exit paths
  ## (success, failure, timeout, signal).  In runner.nim this is handled via
  ## ``slot.testScratchDir`` cleaned in cleanupSlotTmp + handleInterrupt.

  outScratchDir = ""
  result = (pid: Pid(-1), achieved: default(ptypes.LimitsAchieved))

  if args.len == 0:
    return

  # Pre-build cstring argv BEFORE fork.
  var cargs = newSeq[cstring](args.len + 1)
  for i, s in args:
    cargs[i] = s.cstring
  cargs[args.len] = nil

  # Resolve the executable in the parent (see the execve note above).  An
  # unresolvable program is a spawn error here rather than a 127 in the child.
  let exePath = findExe(args[0])
  if exePath.len == 0:
    return
  let exeCstr = exePath.cstring   # points into exePath; live until after fork

  # A4a: create the scratch tmpdir BEFORE fork when spec.tmpdir is true.
  # We build the injected list with TMPDIR included so filterEnv can append it.
  var allExtra: seq[(string, string)] = @[]
  for pair in extraEnv:
    allExtra.add(pair)

  var scratchCstr: cstring = nil  # kept alive until after fork

  if spec.tmpdir:
    # Build mkdtemp template: must end in exactly 6 'X' characters.
    var tmpl = getTempDir() / "crisol_scratch_XXXXXX"
    # mkdtemp modifies the template in-place; we need a mutable buffer.
    var buf = newString(tmpl.len + 1)
    copyMem(addr buf[0], tmpl.cstring, tmpl.len + 1)
    let r = mkdtemp(buf.cstring)
    if r == nil:
      return
    outScratchDir = $cast[cstring](r)
    # Inject TMPDIR=<scratchDir> — appended last so it overrides any parent TMPDIR.
    allExtra.add(("TMPDIR", outScratchDir))
    # Keep scratchCstr alive for the child chdir (points into outScratchDir data).
    scratchCstr = outScratchDir.cstring

  # Apply filterEnv in the parent — pure, no I/O.
  let filteredPairs = filterEnv(toSeq(envPairs()), spec, allExtra)

  # Build the envp strings BEFORE fork.
  var envStrings: seq[string] = @[]
  for (k, v) in filteredPairs:
    envStrings.add(k & "=" & v)
  var cenv = newSeq[cstring](envStrings.len + 1)
  for j in 0 ..< envStrings.len:
    cenv[j] = envStrings[j].cstring
  cenv[envStrings.len] = nil

  # Open /dev/null for stdin BEFORE fork.
  let nullFd = devNull()
  if nullFd < 0:
    if outScratchDir.len > 0:
      try: removeDir(outScratchDir) except: discard
      outScratchDir = ""
    return

  # A2a-iii: pre-fork status pipe.  The child write(2)s one per-limit status
  # byte per LimitKind before exec; the parent reads them post-fork.  Both
  # ends are inherited across fork.  We mark BOTH ends FD_CLOEXEC (cloexecPipe):
  #   - FD_CLOEXEC closes fds at EXEC (not at fork), so the child can STILL
  #     write pipeWrite post-fork/pre-exec.
  #   - At execve the write end auto-closes, so the parent's blocking read()
  #     observes EOF cleanly — making the manual close(pipeWrite) below
  #     redundant-but-harmless (kept for defence-in-depth).
  #   - The read end in the parent is closed explicitly after reading.
  var statusPipe: array[2, cint]
  if not cloexecPipe(statusPipe):
    discard posix.close(nullFd)
    if outScratchDir.len > 0:
      try: removeDir(outScratchDir) except: discard
      outScratchDir = ""
    return
  let pipeRead  = statusPipe[0]
  let pipeWrite = statusPipe[1]

  # A4a: for chdirIntoScratch we need the path as a cstring in the child path.
  # scratchCstr is already set above (points into outScratchDir which is live).
  let doChdirIntoScratch = spec.chdirIntoScratch and scratchCstr != nil

  let childPid = fork()
  if childPid < 0:
    discard posix.close(nullFd)
    discard posix.close(pipeRead)
    discard posix.close(pipeWrite)
    if outScratchDir.len > 0:
      try: removeDir(outScratchDir) except: discard
      outScratchDir = ""
    return

  if childPid == 0:
    # CHILD — only async-signal-safe operations from here to execve/_exit.

    # Close the read end in the child immediately — child only writes.
    discard posix.close(pipeRead)

    discard setpgid(Pid(0), Pid(0))
    discard dup2(nullFd, cint(STDIN_FILENO))
    discard posix.close(nullFd)
    discard dup2(outputFd, cint(STDOUT_FILENO))
    discard dup2(outputFd, cint(STDERR_FILENO))

    # rfc-0007 §5: env scrub and tmpdir isolation were performed by the
    # PARENT before fork (the filtered envp and the mkdtemp scratch dir) —
    # achieved BY CONSTRUCTION, nothing to report back for either.

    # A4a: opt-in chdir into the scratch dir (async-signal-safe chdir(2)).
    # chdir(2) is listed in POSIX as async-signal-safe.
    if doChdirIntoScratch:
      discard posix.chdir(scratchCstr)

    # A2a-iii: apply every config-declared limit, loop-driven, one per-limit
    # readback byte each — replaces the old single `if spec.rlimits:` gate +
    # aggregate bit (a kind not requested reads lsNotRequested regardless of
    # `spec.rlimits`; hlNone's all-none Limits therefore needs no separate
    # gate at all). setrlimit(2)/getrlimit(2) are async-signal-safe.
    var achieved: array[nLimits, uint8]
    applyLimitsChildSide(spec.limits, achieved)

    # netIso is NEVER wired in spawn (no unshare(CLONE_NEWNET)) — never-goal,
    # §5/§6 — so a hlNetwork request always degrades isFullyAchieved to false.

    # A2a-iii: write the per-limit status bytes to the pipe BEFORE execve
    # (partial-write loop). write(2) is async-signal-safe. After this the
    # write-end is closed so the parent's read observes EOF cleanly even if
    # execve somehow leaves the fd open.
    var off = 0
    while off < achieved.len:
      let n = posix.write(pipeWrite, addr achieved[off], achieved.len - off)
      if n > 0:
        off += int(n)
      elif n < 0 and errno == EINTR:
        continue
      else:
        break
    discard posix.close(pipeWrite)

    discard execve(exeCstr, cast[cstringArray](addr cargs[0]),
                   cast[cstringArray](addr cenv[0]))
    discard posix.write(cint(STDERR_FILENO), "_exit(127)\n".cstring, 11)
    exitnow(127)

  # PARENT.
  discard posix.close(nullFd)
  # Close the write end so our read() sees EOF when the child closes its copy.
  discard posix.close(pipeWrite)
  discard setpgid(childPid, childPid)

  # A2a-iii: blocking read of the per-limit status bytes. A short read (incl.
  # EOF at 0 bytes) ⇒ child died before finishing the write ⇒ honest
  # degradation below. EINTR is retried.
  var rbuf: array[nLimits, uint8]
  var got = 0
  while got < rbuf.len:
    let n = posix.read(pipeRead, addr rbuf[got], rbuf.len - got)
    if n > 0:
      got += int(n)
    elif n == 0:
      break            # EOF — child died before writing all bytes
    elif n < 0 and errno == EINTR:
      continue
    else:
      break
  discard posix.close(pipeRead)

  var achievedOut: ptypes.LimitsAchieved
  if got == rbuf.len:
    for lk in ptypes.LimitKind:
      achievedOut[lk] = ptypes.LimitStatus(rbuf[ord(lk)])
  else:
    # Honest degradation: a REQUESTED limit whose readback never arrived is
    # `lsFailed` (we cannot vouch it applied), never fabricated as applied
    # and never silently downgraded to `lsNotRequested` (that would claim
    # nothing was ever asked for).
    for lk in ptypes.LimitKind:
      achievedOut[lk] = if spec.limits.req[lk].isSome: ptypes.lsFailed else: ptypes.lsNotRequested

  result = (pid: childPid, achieved: achievedOut)

# ---------------------------------------------------------------------------
# GracePeriodMs
# ---------------------------------------------------------------------------
# rfc-0007 A2a-i: `supervise` (the raw Pid-based poll/kill/reap helper) is
# DELETED here — it had zero `src/` callers (runner.nim runs its own
# wait4/killpg loops; see runner.nim's teardownLiveSlots/pollSlot) and its
# only callers were five integration test files, which now drive a
# `process.nim` Supervisor directly (process/posix.nim's `next`/requestStop/
# forceKill/reap) instead of this raw Pid polling helper. `GracePeriodMs`
# stays — runner.nim still reads it directly for its own grace-window
# arithmetic (A2b migrates the runner onto the Supervisor and retires it).

const GracePeriodMs* = 400
  ## Time (ms) to wait after SIGTERM before escalating to SIGKILL.
  ## Reused by the execute handleInterrupt template.
