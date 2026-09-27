## process/tooltrees.nim — the process-global registry of live bounded tool
## trees, and the one SIGINT/SIGTERM handler that ends them (R11-L4, R12-D3).
##
## A bounded tool (`toolexec.runTool` with a deadline) runs in a tree of its
## own: its own process group on POSIX, a Job Object on Windows. That is what
## lets the deadline end the whole tree, but it also takes the tool out of
## the terminal's foreground group, so a Ctrl-C (or a SIGTERM to crisol)
## no longer reaches it. Left alone, an interrupted crisol exits and the tool
## runs on to its own end, or crisol waits the tool's whole deadline out
## before it notices.
##
## So every live bounded tree is registered here, and ONE handler owns
## SIGINT/SIGTERM (a console Ctrl-C/Ctrl-Break on Windows) for as long as an
## interrupt scope is open (`enterInterruptScope`/`leaveInterruptScope`,
## nestable). The handler:
##
## - records the signal for the open scope. `shutdownRequested()` is the one
##   reader of that record (R14-D5): `crisol/signals` re-exports it, and the
##   Supervisors' `weShutdown` reads it too. It is a fact about the scope,
##   not the process: the outermost scope clears it when it opens, and its
##   closing `leaveInterruptScope` takes it out and hands it to the scope's
##   owner, so a library host's next run starts clean (R13-D2, R14-S1);
## - kills every registered tree (`killLiveTools`), and from then on, for the
##   rest of the scope, `registerTool` kills a new tree the moment it is
##   registered, so a run winding down never waits out a fresh tool;
## - wakes the Supervisor attached to the scope, if one is
##   (`attachInterruptWake`): a byte on its self-pipe (POSIX) or its event
##   (Windows), which drives the Supervisor's graceful shutdown. A signal that
##   lands before any Supervisor is attached is replayed to the next one
##   attached in the same scope, so a signal between planning and execution is
##   not lost. One Supervisor at a time: `attachInterruptWake` refuses a
##   second, and that refusal is the "one live `installSignals` Supervisor"
##   rule both backends enforce (R13-D4: the wake here is the one record of
##   who owns the wake-up).
##
## It does not exit the process on the first signal. Whoever opened the scope
## takes the verdict from the outermost `leaveInterruptScope`, which swaps the
## scope's signal out and returns it (R14-S1): `runcore.runTestsWith` (with
## `RunOptions.installSignals`) returns `rsInterrupted`, and the CLI, which
## opens a scope around its whole `runMain`, exits 128 + the signal (130
## SIGINT, 143 SIGTERM; Ctrl-C and Ctrl-Break map to the same numbers). The
## outermost `leaveInterruptScope` puts back the dispositions (POSIX) that
## were in effect when the outermost scope opened, or removes the console
## handler (Windows), so a library host gets its own handlers back.
##
## A signal beyond the ones the scope's owner handles is the escape (R13-D5):
## the handler kills every live tool and ends the process at once with 128 +
## the signal (`_exit(2)` on POSIX, `ExitProcess` on Windows), for a main path
## blocked where it never reads the interrupt (an open(2) of a FIFO, a hung
## filesystem, a slow hook). With no Supervisor attached that is the scope's
## second signal. With one attached the second belongs to the Supervisor
## (its skip-grace force-kill of every live test, rfc-0007 r5(b)), and the
## third is the escape. The escape skips every unwind, so what it must end
## it ends itself (R15-S2): on POSIX every live Supervisor child (a compile
## or a test, each leading a process group of its own) is registered here
## (`registerChildGroup`), and the escape SIGKILLs each registered group
## before `_exit`; on Windows they are in the Supervisor's KILL_ON_JOB_CLOSE
## job, which the exit closes. Otherwise they would outlive crisol, and the
## state lock its exit releases.
##
## Async-signal-safety (POSIX): the handler touches only fixed-size globals,
## with atomic loads/stores and compare-and-swap (lock-free on every target
## crisol builds for), `killpg(2)`, `write(2)` and `_exit(2)`. No allocation,
## no locks, no Nim runtime. On Windows the console control handler runs on a
## thread of its own, and the same compare-and-swap decides who owns a slot's
## job handle: whichever side swaps it to zero. The handler never closes a
## handle it took (the owner leaks one handle rather than race it). The
## attached wake is the other handle the handler uses: it counts itself in
## while it holds it, and `detachInterruptWake` waits it out, so the owner
## never closes a wake under it (R15-S6).
##
## A slot is cleared BEFORE its tool is reaped (POSIX): an unreaped leader
## pins its pid, and with it the group id, so a `killpg` on a registered
## group can never reach a group that has since been recycled. The same
## holds for a Supervisor child's group entry (R15-S2).
##
## A leaf over std and `crisol/process/types` (for `ShutdownSignal`; it
## imports std only): `crisol/toolexec`, `crisol/signals`, both process
## backends and `runcore` import it. It sits under `crisol/process/` because
## installing a signal (console control) handler and killing process groups
## is process-layer work: RFC-0007 A4 gives signal ownership to the process
## backends, which is also why it may import `std/posix` directly
## (tests/unit/test_rfc7_a3_ioutils_ownership).

import std/options
import crisol/process/types  # ShutdownSignal: the one reader's answer

when defined(windows):
  import std/winlean

  proc terminateJobObject(hJob: Handle; uExitCode: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}
  proc exitProcessNow(uExitCode: uint32)
    {.stdcall, dynlib: "kernel32", importc: "ExitProcess", noreturn.}
    ## The escape (R13-D5), from the console handler's own thread.

  const
    CtrlCEvent = 0'i32      # CTRL_C_EVENT; winlean does not export it
    CtrlBreakEvent = 1'i32  # CTRL_BREAK_EVENT

  type CtrlHandler = proc (dwCtrlType: int32): WINBOOL {.stdcall.}
  proc setConsoleCtrlHandler(handlerRoutine: CtrlHandler; add: WINBOOL): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleCtrlHandler".}
else:
  import std/posix  # killpg(2), write(2), sigaction(2) and _exit(2) only

  proc sigactionRaw(signum: cint; act: ptr Sigaction; oact: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
    ## A duplicate `importc` of C's `sigaction(2)` with `ptr` parameters, so
    ## a NULL `act` is a pure query and a NULL `oact` a pure install: the two
    ## forms std/posix's own `var` overloads cannot express. Saving the
    ## dispositions in effect before the outermost scope opens, and putting
    ## them back when that scope closes, is rfc-0007 code-review r69's
    ## embedding-host rule (tests/unit/test_rfc0007_r69_signal_restore).

const
  MaxLiveTools* = 16
    ## Registry capacity. `src/` has no threading model and runs one tool
    ## at a time per process, so this is far above any real occupancy; a
    ## tool that finds it full is not registered, and is then ended by its
    ## own deadline only.
  MaxChildGroups* = 1024
    ## R15-S2: capacity of the escape's registry of Supervisor child groups
    ## (POSIX), one per live compile or test child; far above any `--jobs`.
    ## A child that finds it full is not registered, and the escape does not
    ## reach it.

type
  RegistrationKind* = enum
    rkUnregistered
      ## Not registered (the registry is full): the caller keeps the tree
      ## and its handle, and an interrupt does not reach it. First, so it is
      ## the zero value (R15-D4): a `Registration()` no `registerTool`
      ## answered claims no slot.
    rkOwned
      ## The tree holds a registry slot. `unregisterTool` settles who owns
      ## it afterwards: still the caller, or (an interrupt took the slot
      ## first) the interrupt path.
    rkKilledNow
      ## An interrupt was pending in the open scope: the tree was killed at
      ## once, on the caller's thread, and holds no slot. The caller still
      ## owns the tree's handle (Windows: it closes the job).
  Registration* = object
    ## `registerTool`'s answer. R13-D3: a bare slot number with two negative
    ## sentinels made `unregisterTool`'s false mean both "the interrupt owns
    ## the handle now" and "killed at registration, the handle is still
    ## yours", and the second leaked a job handle on Windows.
    ## R15-D4: its zero value is `rkUnregistered`. It was `rkOwned` slot 0,
    ## a slot another tree may hold: `unregisterTool` on it answered false,
    ## "the interrupt took your handle", for a tree nothing had touched.
    case kind*: RegistrationKind
    of rkOwned: slot*: int
    of rkUnregistered, rkKilledNow: discard

var gLiveTools {.global.}: array[MaxLiveTools, int]
  ## 0 is an empty slot; otherwise a process group id (POSIX) or a Job
  ## Object handle (Windows).
var gScopeSignum {.global.}: int
  ## The signal the handler observed in the open scope; 0 for none. Cleared
  ## when the outermost scope opens, and swapped out (to its owner) when it
  ## closes. Read only through `scopeSignal`, which ignores it outside a
  ## scope: a Windows console handler still running after its removal can
  ## stamp it late (R14-S1).
var gScopeSignals {.global.}: int
  ## How many signals the handler has taken in the open scope; the one past
  ## what the scope's owner handles is the escape (R13-D5).
var gUndelivered {.global.}: int
  ## A signal that landed while no Supervisor wake was attached; the next
  ## `attachInterruptWake` in the same scope replays it.
var gScopeDepth {.global.}: int
  ## Open interrupt scopes (main path only; the handler never reads it).
when defined(windows):
  var gWake {.global.}: int
    ## The attached Supervisor's shutdown event handle; 0 for none.
else:
  var gWake {.global.}: int = -1
    ## The attached Supervisor's self-pipe write end; -1 for none.
  var gPrevSigint {.global.}: Sigaction
  var gPrevSigterm {.global.}: Sigaction
  var gChildGroups {.global.}: array[MaxChildGroups, int]
    ## R15-S2: the process group of every live Supervisor child (a compile
    ## or a test), 0 for an empty slot. Only the escape reads it: the
    ## scope's first signals leave those children to the Supervisor's own
    ## graceful and forced stops.
var gWakers {.global.}: int
  ## R15-S6: handler bodies between reading `gWake` and their last use of
  ## it. `detachInterruptWake` waits for none before it returns, so the
  ## Supervisor never closes a wake a handler still holds.

when defined(crisolWakeRaceProbe):
  import std/os
  var gWakeProbePauseMs* {.global.}: int
    ## R15-S6 test seam (tests/unit/test_r15_wake_detach): how long `wake`
    ## pauses between reading the attached wake and using it; 0 for none.
  var gWakeProbePaused* {.global.}: int
    ## Set to 1 when `wake` enters that pause.

  proc probePause() {.raises: [], gcsafe.} =
    let ms = atomicLoadN(addr gWakeProbePauseMs, ATOMIC_SEQ_CST)
    if ms > 0:
      atomicStoreN(addr gWakeProbePaused, 1, ATOMIC_SEQ_CST)
      sleep(ms)

{.push stackTrace: off, checks: off.}
  # Signal-handler code: no frame bookkeeping, no raising checks (every
  # index below is in range by construction).

proc killTree(tree: int) {.raises: [], gcsafe.} =
  when defined(windows):
    discard terminateJobObject(Handle(tree), 1)
  else:
    discard killpg(Pid(tree), SIGKILL)

proc killLiveTools*() {.raises: [], gcsafe.} =
  ## End every registered tool tree at once: SIGKILL to each process group,
  ## `TerminateJobObject` on each job. Async-signal-safe; see the module doc.
  ## Each slot is swapped to zero first, so its owner learns the tree was
  ## interrupted, and (Windows) that the job handle is no longer its own
  ## (`unregisterTool` answers false).
  for i in 0 ..< MaxLiveTools:
    let tree = atomicLoadN(addr gLiveTools[i], ATOMIC_SEQ_CST)
    if tree != 0 and cas(addr gLiveTools[i], tree, 0):
      killTree(tree)

when not defined(windows):
  proc killChildGroups() {.raises: [], gcsafe.} =
    ## R15-S2: SIGKILL every registered Supervisor child group, for the
    ## escape. Async-signal-safe: atomic loads and `killpg(2)`. A slot is
    ## cleared before its leader is reaped (`unregisterChildGroup`), so a
    ## registered group id is pinned, never a recycled one.
    for i in 0 ..< MaxChildGroups:
      let g = atomicLoadN(addr gChildGroups[i], ATOMIC_SEQ_CST)
      if g != 0: discard killpg(Pid(g), SIGKILL)

proc addWakers(d: int) {.raises: [], gcsafe.} =
  ## `gWakers += d`. A compare-and-swap loop: the vcc backend's atomic
  ## read-modify-write procs take pointers only.
  while true:
    let n = atomicLoadN(addr gWakers, ATOMIC_SEQ_CST)
    if cas(addr gWakers, n, n + d): return

proc wakeAttached(): bool {.raises: [], gcsafe.} =
  let w = atomicLoadN(addr gWake, ATOMIC_SEQ_CST)
  when defined(windows): w != 0
  else: w >= 0

proc wake(signum: int) {.raises: [], gcsafe.} =
  ## Wake the attached Supervisor with `signum`, or keep it for the next one.
  ## R15-S6: counted in `gWakers` from before it reads the wake until after
  ## its last use, so a detach that races it waits for the use to land
  ## rather than let the owner close the handle (or fd) under it: a
  ## `SetEvent` on a closed handle, or on whatever the value names by then.
  ## Both sides are sequentially consistent: a wake that read the handle
  ## counted itself before the detach cleared it, and the detach sees it.
  addWakers(1)
  let w = atomicLoadN(addr gWake, ATOMIC_SEQ_CST)
  when defined(crisolWakeRaceProbe): probePause()
  when defined(windows):
    if w != 0: discard setEvent(Handle(w))
    else: atomicStoreN(addr gUndelivered, signum, ATOMIC_SEQ_CST)
  else:
    if w >= 0:
      var b = uint8(signum)
      discard posix.write(cint(w), addr b, 1)
    else:
      atomicStoreN(addr gUndelivered, signum, ATOMIC_SEQ_CST)
  addWakers(-1)

proc countSignal(): int {.raises: [], gcsafe.} =
  ## Count one more signal in the scope; answers the count before it. A
  ## compare-and-swap loop: the vcc backend's atomic read-modify-write
  ## procs take pointers only.
  while true:
    result = atomicLoadN(addr gScopeSignals, ATOMIC_SEQ_CST)
    if cas(addr gScopeSignals, result, result + 1): return

proc onInterrupt(signum: int) {.raises: [], gcsafe.} =
  ## The one handler body. The scope's signal is stamped BEFORE the kill, so
  ## a `registerTool` racing it (Windows: the handler runs on a thread of
  ## its own) either sees the stamp and kills its own tree, or filled its
  ## slot before the sweep and is killed by it. A signal past the ones the
  ## scope's owner handles ends the process at once (see the module doc).
  let before = countSignal()
  atomicStoreN(addr gScopeSignum, signum, ATOMIC_SEQ_CST)
  killLiveTools()
  if before >= (if wakeAttached(): 2 else: 1):
    when defined(windows):
      # A Supervisor's children are in its KILL_ON_JOB_CLOSE job, which
      # the process's exit closes.
      exitProcessNow(uint32(128 + signum))
    else:
      # R15-S2: a Supervisor's children lead groups of their own, which
      # `_exit` does not reach; left alone they outlive crisol and the
      # state lock its exit releases.
      killChildGroups()
      exitnow(cint(128 + signum))
  wake(signum)

when defined(windows):
  proc interruptCtrlHandler(dwCtrlType: int32): WINBOOL {.stdcall.} =
    ## Ctrl-C reports as SIGINT (2) and Ctrl-Break as SIGTERM (15), the
    ## numbers the exit-code rule (128 + n) uses; anything else goes to the
    ## next handler.
    case dwCtrlType
    of CtrlCEvent: onInterrupt(2)
    of CtrlBreakEvent: onInterrupt(15)
    else: return 0'i32
    1'i32
else:
  proc interruptSigHandler(signum: cint) {.noconv.} =
    onInterrupt(int(signum))

{.pop.}

proc scopeSignal(): int =
  ## The open scope's signal, or 0; always 0 outside a scope, whatever a late
  ## Windows console handler stamped after the outermost scope closed
  ## (R14-S1). Main path only.
  if gScopeDepth == 0: 0
  else: atomicLoadN(addr gScopeSignum, ATOMIC_SEQ_CST)

proc asSignal(signum: int): Option[ShutdownSignal] =
  if signum != 0: some(ShutdownSignal(signum: signum))
  else: none(ShutdownSignal)

proc shutdownRequested*(): Option[ShutdownSignal] =
  ## The one reader of the interrupt record (R14-D5): `some` with the signal
  ## (2 SIGINT, 15 SIGTERM; the real number RFC-0003's 128+n needs) once the
  ## handler has observed one in the open interrupt scope; `none` otherwise,
  ## and always outside a scope. Level-triggered within the scope.
  ## `crisol/signals` re-exports it; the Supervisors' `weShutdown` and every
  ## early exit on a main path read it. The scope's owner takes its final
  ## verdict from `leaveInterruptScope` instead. Main path only.
  asSignal(scopeSignal())

proc registerTool*(tree: int): Registration =
  ## Register a live tool tree (`tree` != 0): its process group id on POSIX,
  ## its Job Object handle on Windows. `rkOwned` with its slot;
  ## `rkUnregistered` when the registry is full; `rkKilledNow` when an
  ## interrupt has already landed in the open scope (the tree is killed at
  ## once: a run that is winding down never waits a fresh tool out). Outside
  ## a scope no interrupt is pending. On POSIX the caller holds SIGINT/SIGTERM
  ## blocked from before the spawn until this returns, so no interrupt falls
  ## between the tool starting and its registration.
  doAssert tree != 0
  if scopeSignal() != 0:
    killTree(tree)
    return Registration(kind: rkKilledNow)
  for i in 0 ..< MaxLiveTools:
    if cas(addr gLiveTools[i], 0, tree):
      # A handler that stamped the scope after the check above may have
      # swept the registry before this slot was filled (Windows). When this
      # swap back fails the sweep has taken the slot, and the slot is an
      # owned one the interrupt now holds: `unregisterTool` reports it.
      if scopeSignal() != 0 and cas(addr gLiveTools[i], tree, 0):
        killTree(tree)
        return Registration(kind: rkKilledNow)
      return Registration(kind: rkOwned, slot: i)
  Registration(kind: rkUnregistered)

proc unregisterTool*(slot: int; tree: int): bool =
  ## Clear an `rkOwned` registration's `slot` (holding `tree`). True: the
  ## caller owned it until now, and keeps the tree and its handle. False: an
  ## interrupt took the slot first, has killed the tree, and (Windows) owns
  ## the job handle from then on, so the caller must not close it. That is
  ## the only case in which a caller gives the handle up.
  doAssert slot in 0 ..< MaxLiveTools
  cas(addr gLiveTools[slot], tree, 0)

proc enterInterruptScope*() =
  ## Open an interrupt scope; scopes nest. The outermost one clears the
  ## scope's signal and installs the handler for SIGINT and SIGTERM (POSIX:
  ## saving the dispositions in effect so `leaveInterruptScope` can put them
  ## back; Windows: a console control handler above any the host has). Main
  ## path only.
  if gScopeDepth == 0:
    atomicStoreN(addr gScopeSignum, 0, ATOMIC_SEQ_CST)
    atomicStoreN(addr gScopeSignals, 0, ATOMIC_SEQ_CST)
    atomicStoreN(addr gUndelivered, 0, ATOMIC_SEQ_CST)
    when defined(windows):
      discard setConsoleCtrlHandler(interruptCtrlHandler, 1'i32)
    else:
      discard sigactionRaw(SIGINT, nil, addr gPrevSigint)
      discard sigactionRaw(SIGTERM, nil, addr gPrevSigterm)
      var sa: Sigaction
      sa.sa_handler = interruptSigHandler
      discard sigemptyset(sa.sa_mask)
      sa.sa_flags = SA_RESTART
      discard sigaction(SIGINT, sa, nil)
      discard sigaction(SIGTERM, sa, nil)
  inc gScopeDepth

proc takeScopeSignal(): int =
  ## Swap the scope's signal out, leaving 0. A compare-and-swap loop: the vcc
  ## backend's `atomicExchangeN` takes pointers only.
  result = atomicLoadN(addr gScopeSignum, ATOMIC_SEQ_CST)
  while result != 0 and not cas(addr gScopeSignum, result, 0):
    result = atomicLoadN(addr gScopeSignum, ATOMIC_SEQ_CST)

proc leaveInterruptScope*(): Option[ShutdownSignal] =
  ## Close the innermost scope and answer its signal. An inner scope answers
  ## what `shutdownRequested()` reads and leaves the record alone. The
  ## outermost one first puts the host's handling back (the saved
  ## dispositions; Windows: removes the console handler), then swaps the
  ## record out and answers it (R14-S1). On POSIX a signal lands either
  ## before the restore, and is in the answer, or after it, and goes to the
  ## host's own disposition: none is lost between a last read and the clear.
  ## A Windows console handler still running after its removal can stamp the
  ## record late; nothing reads it outside a scope, and the next outermost
  ## scope clears it when it opens. The scope's owner takes its verdict from
  ## this answer. Main path only.
  doAssert gScopeDepth > 0, "leaveInterruptScope without a matching enter"
  if gScopeDepth > 1:
    dec gScopeDepth
    return shutdownRequested()
  when defined(windows):
    discard setConsoleCtrlHandler(interruptCtrlHandler, 0'i32)
  else:
    discard sigactionRaw(SIGINT, addr gPrevSigint, nil)
    discard sigactionRaw(SIGTERM, addr gPrevSigterm, nil)
  result = asSignal(takeScopeSignal())
  atomicStoreN(addr gScopeSignals, 0, ATOMIC_SEQ_CST)
  atomicStoreN(addr gUndelivered, 0, ATOMIC_SEQ_CST)
  dec gScopeDepth

proc deliverInterrupt*(signum: int) =
  ## Run the handler's body for `signum` on the calling thread, as the POSIX
  ## handler (on the main thread) or the Windows console handler (on a thread
  ## of its own) would. For tests that play a signal, or a late Windows
  ## console handler, without a real one. The escape applies: a signal past
  ## the ones the scope's owner handles ends the process.
  onInterrupt(signum)

proc takeUndelivered(): int =
  ## Take the undelivered signal, leaving 0. A compare-and-swap loop: the vcc
  ## backend's `atomicExchangeN` takes pointers only.
  result = atomicLoadN(addr gUndelivered, ATOMIC_SEQ_CST)
  while result != 0 and not cas(addr gUndelivered, result, 0):
    result = atomicLoadN(addr gUndelivered, ATOMIC_SEQ_CST)

when defined(windows):
  proc attachInterruptWake*(event: Handle): bool =
    ## Make `event` (a Supervisor's manual-reset shutdown event) the one the
    ## handler sets, and set it now for a signal that landed in this scope
    ## before any Supervisor was attached. False, attaching nothing, when a
    ## wake is attached already: one live `installSignals` Supervisor per
    ## process (R13-D4). Requires an open scope.
    doAssert gScopeDepth > 0, "attachInterruptWake outside an interrupt scope"
    doAssert event != 0
    if not cas(addr gWake, 0, int(event)): return false
    if takeUndelivered() != 0:
      discard setEvent(event)
    true

  proc detachInterruptWake*() =
    ## Stop setting the attached Supervisor's event; call before closing it.
    ## Returns once no handler still holds the event (R15-S6): the console
    ## handler runs on a thread of its own, and one that read the event
    ## just before the detach would set it after the owner closed it.
    atomicStoreN(addr gWake, 0, ATOMIC_SEQ_CST)
    while atomicLoadN(addr gWakers, ATOMIC_SEQ_CST) != 0:
      winlean.sleep(0)
else:
  proc attachInterruptWake*(fd: cint): bool =
    ## Make `fd` (a Supervisor's self-pipe write end) the one the handler
    ## writes the signal number to, and write one now for a signal that
    ## landed in this scope before any Supervisor was attached. False,
    ## attaching nothing, when a wake is attached already: one live
    ## `installSignals` Supervisor per process (R13-D4). Requires an open
    ## scope.
    doAssert gScopeDepth > 0, "attachInterruptWake outside an interrupt scope"
    doAssert fd >= 0
    if not cas(addr gWake, -1, int(fd)): return false
    let pending = takeUndelivered()
    if pending != 0:
      var b = uint8(pending)
      discard posix.write(fd, addr b, 1)
    true

  proc detachInterruptWake*() =
    ## Stop waking the attached Supervisor; call before closing its fd.
    ## Returns once no handler still holds the fd (R15-S6): a handler on
    ## another thread of a threaded host that read it just before the
    ## detach would write to it after the owner closed it (or to the file a
    ## recycled fd names by then). A handler on this thread completes
    ## before the detach resumes, so it never waits on itself.
    atomicStoreN(addr gWake, -1, ATOMIC_SEQ_CST)
    while atomicLoadN(addr gWakers, ATOMIC_SEQ_CST) != 0:
      discard sched_yield()

  proc registerChildGroup*(pgid: int): bool =
    ## R15-S2: enter a Supervisor child's process group (`pgid` > 0, the
    ## child's own pid, which leads it) for the escape to kill before it
    ## exits the process. False when the registry is full. The caller calls
    ## `unregisterChildGroup` before it reaps the leader, whose unreaped pid
    ## pins the group id until then.
    doAssert pgid > 0
    for i in 0 ..< MaxChildGroups:
      if cas(addr gChildGroups[i], 0, pgid): return true
    false

  proc unregisterChildGroup*(pgid: int) =
    ## R15-S2: clear `pgid`'s entry, if it has one. Call before the leader
    ## is reaped (see `registerChildGroup`).
    doAssert pgid > 0
    for i in 0 ..< MaxChildGroups:
      if cas(addr gChildGroups[i], pgid, 0): return
