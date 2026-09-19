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
## rfc-0007 code-review r73 extended this file with a non-LIFO destroy
## test: `destroyPosixCore`'s restore was gated only by
## `core.installedSignals`, not by ownership of `gShutdownWriteFd`, so
## destroying an OLDER, non-owning core first (while a NEWER core was
## still live) clobbered the newer core's live disposition. r73 fixed it
## by gating the restore on `gShutdownWriteFd == core.pipeWrite`
## ownership.
##
## rfc-0007 code-review r80 found that r73's OWN fix regressed the
## complementary LIFO order: with core A installing then core B
## installing while A is still live, B's `initPosixCore` call saves
## whatever is CURRENTLY installed as ITS OWN `prevSigint`/`prevSigterm`
## — crisol's own `shutdownSigHandler` (A's install), never the host's
## true original disposition. Destroying in LIFO order (B, the owner,
## then A) then leaves crisol's handler installed FOREVER: B's destroy
## "restores" what it saved (crisol's own handler again), and A's
## subsequent destroy is a no-op (A is not the `gShutdownWriteFd` owner).
## `gShutdownWriteFd` is a single last-installer slot — it cannot express
## a prev-chain across more than one live installer, so there is no
## destroy ORDER that makes both cores' non-LIFO AND LIFO cases correct
## at once. r80's fix is structural instead: `initPosixCore` now RAISES
## `OSError` when `installSignals` is requested while another live core
## already owns signal delivery (`gShutdownWriteFd != -1`) — refusing the
## SECOND concurrent install outright, mirroring `initSupervisor`'s
## (windows.nim) `jobObjectNesting` precedent (a fatal, no-half-loop
## `OSError` at init time). The old r73 non-LIFO test below is REPLACED
## (a non-LIFO destroy of two concurrently-live cores is no longer a
## constructible scenario at all — the second `initPosixCore` call never
## returns a core to destroy non-LIFO) by: a pin that the second
## concurrent install RAISES, and a pin that ordinary SEQUENTIAL reuse
## (install, destroy, install again, destroy again — e.g. api.nim's r74
## main-run-then-verify-sub-run flow) is entirely unaffected.
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

    test "r80: a concurrent second signal-installing core is REFUSED -- initPosixCore raises OSError while another live core still owns signal delivery":
      ## rfc-0007 code-review r80 (THE fix this row pins, RED against
      ## pre-r80 code): `initPosixCore(installSignals = true)` must raise
      ## `OSError` when `gShutdownWriteFd != -1` -- i.e. another live core
      ## already owns signal delivery. Pre-fix, this silently SUCCEEDED
      ## (coreB installed over coreA without complaint); see this file's
      ## header comment for why that silent success is the root of the
      ## r73/r80 LIFO-vs-non-LIFO bind that no destroy-order fix can
      ## resolve for BOTH orders at once. coreA itself must be entirely
      ## unaffected by the refused second install: still live, still
      ## installed, and still cleanly destroyable afterward.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))

      var coreA = initPosixCore(installSignals = true)
      let installedByCrisol = currentDisposition(SIGINT)
      check installedByCrisol != cast[pointer](SIG_DFL)

      expect OSError:
        discard initPosixCore(installSignals = true)

      # coreA is untouched by the refused attempt.
      check currentDisposition(SIGINT) == installedByCrisol

      destroyPosixCore(coreA)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) == cast[pointer](SIG_DFL)

    test "r80: sequential install-destroy-install-destroy is entirely unaffected -- both restores correct":
      ## Ordinary sequential reuse (e.g. api.nim's r74 main-run-then-
      ## verify-sub-run flow: one core installs, tears down completely,
      ## THEN a later core installs) never has two live installers at
      ## once, so r80's concurrency refusal never engages -- each
      ## `initPosixCore` call here sees `gShutdownWriteFd == -1` (the
      ## prior core's `destroyPosixCore` cleared it) and proceeds
      ## normally, exactly as before r80.
      installDisposition(SIGINT, cast[proc (x: cint) {.noconv.}](SIG_DFL))
      installDisposition(SIGTERM, cast[proc (x: cint) {.noconv.}](SIG_DFL))

      var coreA = initPosixCore(installSignals = true)
      check currentDisposition(SIGINT) != cast[pointer](SIG_DFL)
      destroyPosixCore(coreA)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) == cast[pointer](SIG_DFL)

      var coreB = initPosixCore(installSignals = true)
      check currentDisposition(SIGINT) != cast[pointer](SIG_DFL)
      destroyPosixCore(coreB)
      check currentDisposition(SIGINT) == cast[pointer](SIG_DFL)
      check currentDisposition(SIGTERM) == cast[pointer](SIG_DFL)

  when isMainModule:
    echo "test_rfc0007_r69_signal_restore: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_r69_signal_restore.nim"
    echo "test_rfc0007_r69_signal_restore: skipped (POSIX-only backend test)"
