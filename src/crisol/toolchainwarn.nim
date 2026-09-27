## toolchainwarn.nim -- what this host's C toolchain identity means for a run:
## the warning line a person reads when it cannot be identified, the string
## that stands for it wherever it is compared across runs, and whether the
## result cache runs at all.
##
## Pure, but for the nonce an unidentified toolchain draws, through the
## caller's `NonceProc`. `runcore.runTestsWith` is the production consumer: it
## applies `cacheGate` (building no cache runtime when the gate is off,
## stamping each result with the gate's reason, printing its warning on
## stderr) and keys the depgraph header and the persistent nimcache on the
## `RunToolchain` its plan built (`runToolchain`).
##
## The warning text is for a person at a terminal: what happened (nothing is
## cached or reused this run), the observed cause (the half's `why`, when the
## probe recorded one), and what restores caching. It names no internal
## identifier.

import std/options
import crisol/[ccidentity, types]

const NotCached =
  "nothing is cached for this run: no result is stored or looked up, in " &
  "the local cache or a shared one, so every test runs, and nothing an " &
  "earlier run compiled is reused, so every test is recompiled."

proc cause(h: CcHalf): string =
  let w = why(h)
  if w.len > 0: " (" & w & ")" else: ""

proc toolchainWarning*(fp: CcFingerprint): Option[string] =
  ## `none` iff `fp` can key the result cache (`toolchainVerdict(fp)` is
  ## `tvIdentified`); otherwise the warning line, with no "crisol: " prefix
  ## and no trailing newline. Decided by a single `toolchainVerdict` call, so
  ## the caching decision and the message cannot disagree.
  let v = toolchainVerdict(fp)
  case v.kind
  of tvIdentified:
    return none(string)
  of tvUnidentified: discard
  case v.part
  of upCompiler:
    some("warning: the C compiler Nim is configured to use could not be " &
         "identified" & cause(fp.compiler) & " -- " & NotCached &
         " Caching resumes once the configured compiler answers its " &
         "identity probe.")
  of upRuntime:
    some("warning: the C runtime library the configured compiler links " &
         "could not be identified" & cause(fp.runtime) & " -- " & NotCached &
         " Caching resumes once the runtime library can be identified.")
  of upBoth:
    # Both halves usually share one cause (discovery failed); name it once.
    let c = cause(fp.compiler)
    some("warning: the C toolchain could not be identified at all" &
         (if c.len > 0: c else: cause(fp.runtime)) & " -- " & NotCached &
         " Caching resumes once the C compiler Nim is configured to use " &
         "and its runtime library can both be identified.")

type
  NonceProc* = proc(): string {.closure.}
    ## Draws a value no earlier run drew (`runcore.freshRunNonce`). Called
    ## only for an unidentified toolchain, and must return a non-empty string.

proc toolchainIdentity*(fp: CcFingerprint; drawNonce: NonceProc): string =
  ## The string that stands for this host's C toolchain wherever a later run
  ## compares against it: the depgraph header (`depgraph.loadDepGraph`'s
  ## `dgdCcVersion` check) and the persistent nimcache path
  ## (`planner.toolchainFingerprint`).
  ##
  ## An identified toolchain is its serialized fingerprint, `$fp`, so two
  ## runs under it compare equal and reuse each other's work.
  ##
  ## An unidentified one is `$fp` followed by a nonce, drawn here from
  ## `drawNonce` for every run. Its serialized form is a constant that two
  ## different toolchains share whenever both fail identification, so it
  ## must never compare equal to anything a run stored earlier, including an
  ## earlier run on the same host: the graph recorded under it is discarded
  ## (every entrypoint recompiles and `--changed` reselects everything) and
  ## the compile lands in a nimcache directory no earlier run wrote. The
  ## directories this leaves behind are orphans a later `crisol clean`
  ## removes once the toolchain is identified again (`clean.cleanOrphans`
  ## prunes nothing by an unidentified one, R14-D4).
  ##
  ## One `toolchainVerdict` call decides both the identity and whether a
  ## nonce is drawn (R11-D5): a caller cannot draw one for an identified
  ## toolchain, nor forget one for an unidentified toolchain.
  case toolchainVerdict(fp).kind
  of tvIdentified:
    $fp
  of tvUnidentified:
    let nonce = drawNonce()
    doAssert nonce.len > 0, "toolchainIdentity: the nonce drawn was empty"
    $fp & " (unidentified; run " & nonce & ")"

type
  RunToolchain* = object
    ## One run's C toolchain, as one value (R12-D4): the probe its plan took
    ## (the fingerprint, and the driver site every header probe resolves
    ## against) and the identity keyed on that fingerprint, which loads the
    ## depgraph, stamps its header and names the persistent nimcache. The
    ## fields are private and there is no default: a value is built by
    ## `runToolchain`, which derives the identity from the probe, or by
    ## `unkeyed`, which keys nothing -- so a key is never paired with
    ## another discovery's site, nor a site with a hand-written key.
    ##
    ## R15-D4: the zero value (`RunToolchain()`, `default`, a bare `var`)
    ## still compiles anywhere, and read as a value it was `unkeyed` with an
    ## unknown site: a nimcache path with no toolchain suffix that no caller
    ## chose. So it is marked unbuilt, and every reader refuses it
    ## (`checked`). `{.requiresInit.}` would refuse it at compile time, but it
    ## spreads to every object that holds one, and `runcore`'s
    ## `PlanImplResult` is declared before the plan assigns it.
    built: bool  ## set by the two constructors only
    probe: ToolchainProbe
    identity: string

proc runToolchain*(probe: ToolchainProbe; drawNonce: NonceProc): RunToolchain =
  ## THE production constructor: `probe` and `toolchainIdentity(probe.fp,
  ## drawNonce)`.
  RunToolchain(built: true, probe: probe,
               identity: toolchainIdentity(probe.fp, drawNonce))

proc unkeyed*(site: DriverSite): RunToolchain =
  ## A run keyed on no toolchain: identity "", so the persistent nimcache
  ## path carries no toolchain suffix (`planner.toolchainFingerprint`), and
  ## no fingerprint (the zero, unidentified one). For a caller that probed
  ## nothing to key by -- `runner.runEntrypoint`, and tests -- and still
  ## needs a driver site for its header probes (`known: false` refuses them).
  RunToolchain(built: true, probe: ToolchainProbe(site: site), identity: "")

proc checked(t: RunToolchain): lent RunToolchain =
  ## `t`, once it is known to come from `runToolchain` or `unkeyed`; its
  ## zero value is a defect (R15-D4).
  doAssert t.built, "a RunToolchain built by neither runToolchain nor " &
    "unkeyed (its zero value) keys nothing a run may use"
  t

proc probe*(t: RunToolchain): ToolchainProbe = checked(t).probe
proc identity*(t: RunToolchain): string =
  ## What the run keys on: `toolchainIdentity` of the probe's fingerprint,
  ## or "" for `unkeyed`.
  checked(t).identity
proc site*(t: RunToolchain): DriverSite = checked(t).probe.site

type
  CacheGateKind* = enum
    cgOn   ## the result cache is built, consulted and stored to
    cgOff  ## the result cache is bypassed for the whole run: no runtime is
           ## built, no tier is consulted, nothing is stored

  CacheGate* = object
    ## Whether a run uses the result cache, and why not when it does not.
    warning*: Option[string]
      ## The toolchain warning line (`toolchainWarning`), whatever the gate
      ## decided: an unidentified toolchain is worth saying even when
      ## `--no-cache` already turned the cache off. Always `none` when the
      ## gate is on, since an on gate needs an identified toolchain.
    case kind*: CacheGateKind
    of cgOn: discard
    of cgOff:
      reason*: CacheDecision
        ## The `CacheDecision` a cache-eligible result is stamped with (one of
        ## `cachedispatch.inactiveReasons`).

proc cacheGate*(noCache: bool; rootsDegraded: bool;
                toolchain: CcFingerprint): CacheGate =
  ## The run's cache decision. Off, first matching reason wins:
  ##
  ##   noCache                 -> cdmPolicyDisabled: the invocation asked
  ##                              for no cache (`--no-cache`).
  ##   toolchain unidentified  -> cdmToolchainUnidentified: a key built from
  ##                              it carries a constant no host stores under,
  ##                              so consulting any tier could never hit.
  ##   rootsDegraded           -> cdmRootsDegraded: a tracked root's fold
  ##                              policy could not be probed (RFC-0009 §3), so
  ##                              the key's path identity is unresolved.
  ##
  ## On otherwise. The toolchain verdict is read once, from
  ## `toolchainVerdict`, never from whether a warning string exists.
  let unidentified = toolchainVerdict(toolchain).kind == tvUnidentified
  let warning = toolchainWarning(toolchain)
  if noCache:
    CacheGate(kind: cgOff, reason: cdmPolicyDisabled, warning: warning)
  elif unidentified:
    CacheGate(kind: cgOff, reason: cdmToolchainUnidentified, warning: warning)
  elif rootsDegraded:
    CacheGate(kind: cgOff, reason: cdmRootsDegraded, warning: warning)
  else:
    CacheGate(kind: cgOn, warning: warning)
