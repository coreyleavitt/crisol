## test_rfc0007_r69_signal_restore.nim — rfc-0007 code-review finding r69
## (posix half): `destroyPosixCore` never restored the prior SIGINT/SIGTERM
## disposition.
##
## `initPosixCore(installSignals = true)` installs `sigaction(SIGINT/
## SIGTERM)` handlers without ever saving what was installed before it —
## `destroyPosixCore` cleared `gShutdownWriteFd` (so the self-pipe wakeup
## stops firing) but left the HANDLERS themselves installed. An embedding
## host's own SIGINT/SIGTERM handler (or SIG_DFL) was silently replaced
## FOREVER: after `destroyPosixCore` returns, a later SIGINT only stamps
## `gShutdownSignum` — a process-global nothing reads once the Supervisor
## that installed the handler is gone — instead of reaching whatever the
## host had installed before crisol ever ran.
##
## The fix: `initPosixCore` saves the disposition in effect at that moment
## (`PosixCore.prevSigint`/`prevSigterm`, via a pure C `sigaction(sig,
## NULL, &old)` query — `sigactionRaw`, since std/posix's own `sigaction`
## overloads cannot express a query-without-install); `destroyPosixCore`
## restores it, guarded by `installedSignals` the same way `subreaperSet`
## already guards the subreaper-bit clear (only ever true when THIS core
## did the installing).
##
## This is the POSIX half only (Linux/macOS `sigaction`) — the Windows
## half (`SetConsoleCtrlHandler`, windows.nim) is a DIFFERENT agent's and
## is not touched or tested here.
##
## Runs the whole init/destroy/query cycle directly in THIS test process
## (never forked) — deliberate, matching
## tests/conformance/test_rfc0007_r3_library_embedding.nim's own
## precedent for a process-WIDE mechanism (that file asserts
## PR_SET_CHILD_SUBREAPER readback directly in the test process; this one
## asserts sigaction disposition the same way). No signal is ever RAISED
## here — only queried/installed — so there is no risk of this test
## process actually being interrupted mid-run.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r69_signal_restore.nim

when defined(posix):
  import std/[posix, unittest]
  import crisol/process/posixcore

  # rfc-0007 r69: a duplicate `importc` of the same C `sigaction(2)` symbol
  # posixcore.nim's own (non-exported) `sigactionRaw` uses — the standard
  # "duplicate importc is safe/idiomatic" idiom this codebase already
  # relies on elsewhere (see posixcore.nim's RLIMIT_* constants). `ptr`
  # (not `var`) parameters so the test can pass a real NULL for either
  # argument: `act = nil` is a pure query, `oact = nil` is install-only.
  proc sigactionRawTest(signum: cint; act: ptr Sigaction; oact: ptr Sigaction): cint
    {.importc: "sigaction", header: "<signal.h>".}

  proc currentDisposition(signum: cint): pointer =
    var cur: Sigaction
    discard sigactionRawTest(signum, nil, addr cur)
    cast[pointer](cur.sa_handler)

  proc installDisposition(signum: cint; handler: proc (x: cint) {.noconv.}) =
    var sa: Sigaction
    sa.sa_handler = handler
    discard sigemptyset(sa.sa_mask)
    sa.sa_flags = 0
    discard sigactionRawTest(signum, addr sa, nil)

  var markerFired {.global.} = false
  proc markerHandler(signum: cint) {.noconv.} =
    markerFired = true

  suite "rfc-0007 r69 — destroyPosixCore restores the prior SIGINT/SIGTERM disposition":

    test "SIG_DFL prior -> installSignals=true replaces it -> destroy restores SIG_DFL":
      # Pin a known starting disposition regardless of whatever this test
      # runner process may already have installed for SIGINT/SIGTERM.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) == cast[pointer](SIG_DFL)

      var core = initPosixCore(installSignals = true)
      # Sanity: prove init really did install something else first — a
      # false-positive "restore" of a no-op would otherwise pass trivially.
      check currentDisposition(SIGINT) != cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) != cast[pointer](SIG_DFL)

      destroyPosixCore(core)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) == cast[pointer](SIG_DFL)

    test "a pre-installed marker handler is restored VERBATIM after destroy (the r69 regression)":
      markerFired = false
      installDisposition(SIGINT, markerHandler)
      let markerPtr = currentDisposition(SIGINT)
      check markerPtr == cast[pointer](markerHandler)

      var core = initPosixCore(installSignals = true)
      # While the Supervisor is live, the marker must be genuinely
      # replaced (crisol's own shutdownSigHandler, not the host's).
      check currentDisposition(SIGINT) != markerPtr

      destroyPosixCore(core)
      # THE regression: pre-fix, this would still read crisol's own
      # handler (or whatever the LAST Supervisor installed) — never the
      # host's marker — because destroyPosixCore never restored anything.
      check currentDisposition(SIGINT) == markerPtr

      # Cleanup: never leave a real signal handler installed in this test
      # process past this test.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))

    test "installSignals=false never touches the disposition at all, and destroy is a no-op on it":
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      var core = initPosixCore(installSignals = false)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      destroyPosixCore(core)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)

    test "r73: non-LIFO destroy of two live cores -- destroying the OLDER (non-owning) core must not clobber the disposition the NEWER core still needs":
      ## rfc-0007 code-review r73: `destroyPosixCore` restored
      ## `prevSigint`/`prevSigterm` guarded only by `core.installedSignals`
      ## -- NOT by the same ownership token
      ## (`gShutdownWriteFd == core.pipeWrite`) the write-fd clear one line
      ## above already uses. `initPosixCore` is not a process-wide
      ## singleton -- nothing stops two live `PosixCore`s in one process
      ## (this codebase's supported configuration is ONE at a time, but
      ## nothing enforces it) -- so a non-LIFO destroy (the OLDER core
      ## torn down while a NEWER one is still live) is constructible
      ## in-process, exactly as done here.
      ##
      ## Sequence: coreA installs (saving whatever was there before it --
      ## SIG_DFL, pinned below); coreB installs next (saving whatever
      ## coreA just installed -- crisol's OWN `shutdownSigHandler`).
      ## `gShutdownWriteFd` now names coreB's pipe (the LAST installer
      ## always wins that global -- see `initPosixCore`'s own comment).
      ## Destroying coreA (the older, NON-owning core) first is the
      ## regression scenario: pre-fix, coreA unconditionally restores
      ## ITS OWN `prevSigint`/`prevSigterm` (SIG_DFL) -- overwriting the
      ## disposition coreB's still-live SIGINT/SIGTERM handling depends
      ## on with SIG_DFL, silently killing coreB's shutdown path. Fixed:
      ## coreA is not the `gShutdownWriteFd` owner, so its restore must
      ## be skipped entirely -- the disposition must still read as
      ## crisol's installed handler after coreA's destroy returns.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))

      var coreA = initPosixCore(installSignals = true)
      let installedByCrisol = currentDisposition(SIGINT)
      check installedByCrisol != cast[pointer](SIG_DFL)

      var coreB = initPosixCore(installSignals = true)
      # coreB installed the SAME crisol handler over coreA's -- the
      # observable disposition is unchanged (both install the identical
      # `shutdownSigHandler` function pointer), so this check just pins
      # that nothing went sideways at coreB's own init.
      check currentDisposition(SIGINT) == installedByCrisol

      # THE regression: destroy the OLDER, non-owning core first.
      destroyPosixCore(coreA)
      check currentDisposition(SIGINT) == installedByCrisol
      check currentDisposition(SIGTERM) == installedByCrisol

      # The NEWER core is still live and still functionally installed --
      # destroying it (the actual `gShutdownWriteFd` owner) restores
      # whatever WAS in effect at ITS OWN init, which is coreA's install
      # (crisol's handler again, not the original host SIG_DFL) -- an
      # accepted residual of stacking two cores in one process (never the
      # supported configuration), documented here rather than silently
      # assumed away.
      destroyPosixCore(coreB)
      check currentDisposition(SIGINT) == installedByCrisol
      check currentDisposition(SIGTERM) == installedByCrisol

      # Cleanup: never leave a real signal handler installed in this test
      # process past this test.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))

  when isMainModule:
    echo "test_rfc0007_r69_signal_restore: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r69_signal_restore.nim"
    echo "test_rfc0007_r69_signal_restore: skipped (POSIX-only backend test)"
