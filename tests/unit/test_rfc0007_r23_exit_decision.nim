## test_rfc0007_r23_exit_decision.nim — code-review r23: decideExit is a
## pure decision proc, unit-testable without a Supervisor.
##
## `handleChildExited` used to inline the retry/ledger/promotion/store-gate
## POLICY directly into execute()'s event loop — a ~300-line template only
## exercisable E2E (compile + run + reap a real child). `decideExit`
## (runner.nim) pulls that policy out into a pure proc: given the observed
## facts of one completed attempt, it returns an `ExitDecision` — whether to
## retry, whether to promote/discard the compiled binary, whether to attempt
## a cache store, and what CacheDecision to stamp when it doesn't. No I/O,
## no Supervisor, no filesystem, no subprocess.
##
## This suite pins the decision table at, at minimum, the arms the review
## called out: a clean pass, a final (exhausted-retries) failure, a
## retry-eligible failure, a compiled-and-promoted binary, and a store-gate
## refusal (closure never recorded).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r23_exit_decision.nim

import std/unittest
import crisol/[types, runner, cachedispatch]

suite "r23: decideExit — pure retry/promotion/store-gate decision table":

  test "pass arm: attempt 1 passes, cache active — finalize, promote, store":
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = true,
      cacheActive             = true,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.retry == false
    check d.recordAsFailure == false
    check d.promoteBinary == true
    check d.discardOnUnrecordedClosure == false
    check d.stampCacheKeyInfo == true
    check d.attemptStore == true

  test "fail arm: attempts exhausted, cache active — finalize, no retry, nothing stored":
    let d = decideExit(
      completedOutcome      = oFailed,
      slotAttempt           = 2,
      maxAttempts           = 2,   # exhausted: slotAttempt == maxAttempts
      failFast              = true,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = true,
      cacheActive             = true,
      verdict                 = StoreVerdict(store: false, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.retry == false
    check d.recordAsFailure == true   # failFast + a genuinely FINAL failure
    check d.promoteBinary == true     # oFailed still produced a real binary
    check d.attemptStore == false     # shouldStore's own verdict said no
    check d.cacheDecisionIfNotStored == cdmKeyMiss

  test "retry-eligible arm: a run failure with attempts remaining re-dispatches, not finalizes":
    let d = decideExit(
      completedOutcome      = oFailed,
      slotAttempt           = 1,
      maxAttempts           = 3,   # 1 < 3: eligible
      failFast              = true,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = true,
      cacheActive             = true,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.retry == true
    # Nothing below is ever consulted by the executor on a retry, but it
    # must still be honestly "no": the finalize-only policy (promotion,
    # failFast latch, store) has not run yet for this attempt.
    check d.recordAsFailure == false
    check d.promoteBinary == false
    check d.attemptStore == false

  test "oCompileFailed/oSpawnError are NEVER retried even with attempts remaining":
    let compileFailed = decideExit(
      completedOutcome = oCompileFailed, slotAttempt = 1, maxAttempts = 3,
      failFast = false, compiledThisRun = true, hasCacheDir = true,
      slotClosureRecorded = true, cacheActive = false,
      verdict = StoreVerdict(), planTimeCacheDecision = cdmKeyMiss,
    )
    check compileFailed.retry == false
    check compileFailed.promoteBinary == false   # no binary to promote

    let spawnError = decideExit(
      completedOutcome = oSpawnError, slotAttempt = 1, maxAttempts = 3,
      failFast = false, compiledThisRun = true, hasCacheDir = true,
      slotClosureRecorded = true, cacheActive = false,
      verdict = StoreVerdict(), planTimeCacheDecision = cdmKeyMiss,
    )
    check spawnError.retry == false
    check spawnError.promoteBinary == false

  test "cached-promotion arm: a compiled-this-run pass promotes its binary":
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = true,
      cacheActive             = false,  # promotion is independent of caching
      verdict                 = StoreVerdict(),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.promoteBinary == true
    check d.discardOnUnrecordedClosure == false  # closure DID record

  test "a cdSkipFresh (not compiled this run) pass never attempts promotion":
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = false,   # cdSkipFresh
      hasCacheDir            = false,
      slotClosureRecorded    = false,  # irrelevant: never consulted
      cacheActive             = true,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.promoteBinary == false
    check d.discardOnUnrecordedClosure == false
    # A skip-fresh pass is still eligible for a fresh store attempt — caching
    # a cdSkipFresh RE-run is legitimate (e.g. after a plan-time miss).
    check d.attemptStore == true

  test "store-gate-refusal arm: R9 — closure failed to record, promoted binary discarded, never stored":
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = false,  # R9: recordClosure failed
      cacheActive             = true,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.promoteBinary == true               # still copies the binary...
    check d.discardOnUnrecordedClosure == true   # ...then discards it right back out
    check d.attemptStore == false                # never stored: dead cache write otherwise
    check d.cacheDecisionIfNotStored == cdmClosureUnrecorded

  test "cdmClosureUnrecorded is correct on its own terms even when attemptStore is true (r23 hardening)":
    # Regression pin: cacheDecisionIfNotStored must not merely be "harmless
    # because unread" when attemptStore is true — it must be RIGHT. A pass
    # with the closure genuinely recorded must never compute
    # cdmClosureUnrecorded, whether or not the executor ever looks at it.
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = true,
      hasCacheDir            = true,
      slotClosureRecorded    = true,
      cacheActive             = true,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmKeyMiss,
    )
    check d.attemptStore == true
    check d.cacheDecisionIfNotStored != cdmClosureUnrecorded
    check d.cacheDecisionIfNotStored == cdmKeyMiss

  test "r17 recompute-miss passthrough: a recompute-invalidated hit whose rerun fails keeps cdmRecomputeMiss":
    let d = decideExit(
      completedOutcome      = oFailed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = false,
      hasCacheDir            = false,
      slotClosureRecorded    = true,
      cacheActive             = true,
      verdict                 = StoreVerdict(store: false, decision: cdmKeyMiss),
      planTimeCacheDecision   = cdmRecomputeMiss,
    )
    check d.cacheDecisionIfNotStored == cdmRecomputeMiss

  test "cache inactive: stamps the plan-time structural reason, never attempts a store":
    let d = decideExit(
      completedOutcome      = oPassed,
      slotAttempt           = 1,
      maxAttempts           = 1,
      failFast              = false,
      compiledThisRun       = false,
      hasCacheDir            = false,
      slotClosureRecorded    = true,
      cacheActive             = false,
      verdict                 = StoreVerdict(store: true, decision: cdmKeyMiss),  # ignored
      planTimeCacheDecision   = cdmPolicyDisabled,
    )
    check d.stampCacheKeyInfo == false
    check d.attemptStore == false
    check d.cacheDecisionIfNotStored == cdmPolicyDisabled
