## test_cachetelemetry.nim — RFC-0005 B2a: aggregateCacheStats (pure fold).
##
## Coverage:
##   1. empty input -> every count 0, hitPct 0.0 (not NaN).
##   2. mixed decisions -> l1Hits/total/notConsulted/misses/hitPct.
##   3. tekHit events -> wallSavedMs sums durationMs.
##   4. tekRemoteErr/tekPublish/tekVerifyFail -> remoteErrors/published/verifyFails counts.
##   5. remoteHits is always 0, regardless of input.
##   6. a full mixed event+decision set together (the "run-shaped" vector).
##   7. RFC-0005 B2b: erroredTiers/tierErrorWarning -- the per-tier
##      100%-error diagnostic ("a tier that rejects 100% of reads is as
##      dead as one that times out").
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cachetelemetry.nim

import std/[strutils, unittest]
import crisol/cachetelemetry

suite "aggregateCacheStats — empty input":

  test "no events, no decisions -> all zero, hitPct 0.0 not NaN":
    let s = aggregateCacheStats(@[], @[])
    check s.l1Hits == 0
    check s.remoteHits == 0
    check s.misses == 0
    check s.remoteErrors == 0
    check s.total == 0
    check s.notConsulted == 0
    check s.hitPct == 0.0
    check s.wallSavedMs == 0
    check s.published == 0
    check s.verifyFails == 0

suite "aggregateCacheStats — decision-sourced counts":

  test "mixed decisions -> l1Hits/total/notConsulted/misses/hitPct":
    let decisions = @[
      cdmHit, cdmHit, cdmHit,             # 3 hits
      cdmKeyMiss, cdmStored,              # 2 misses (consulted, not served)
      cdmNotEligible, cdmGroupOptOut, cdmPolicyDisabled,  # 3 not-consulted
    ]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 3
    check s.remoteHits == 0
    check s.notConsulted == 3
    check s.total == 5           # 8 decisions - 3 notConsulted
    check s.misses == 2          # total - l1Hits - remoteHits
    check s.hitPct == 60.0       # 3 / 5 * 100

  test "every RFC-0005 'consulted' decision variant counts toward total, never notConsulted":
    let decisions = @[
      cdmHit, cdmStored, cdmKeyMiss, cdmHermeticityDeg, cdmFlaky,
      cdmClosureUnrecorded, cdmRecomputeMiss,
    ]
    let s = aggregateCacheStats(@[], decisions)
    check s.total == decisions.len
    check s.notConsulted == 0
    check s.l1Hits == 1   # only cdmHit

  test "every notConsulted decision variant is excluded from total":
    let decisions = @[cdmNotEligible, cdmGroupOptOut, cdmPolicyDisabled]
    let s = aggregateCacheStats(@[], decisions)
    check s.total == 0
    check s.notConsulted == 3
    check s.hitPct == 0.0   # zero consulted -> 0, not NaN

  test "remoteHits stays 0 regardless of input":
    let decisions = @[cdmHit, cdmHit, cdmKeyMiss]
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 5),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
    ]
    let s = aggregateCacheStats(events, decisions)
    check s.remoteHits == 0

suite "aggregateCacheStats — event-sourced counts":

  test "tekHit events sum into wallSavedMs":
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 100),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 250),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 7),
    ]
    let decisions = @[cdmHit, cdmHit, cdmHit]
    let s = aggregateCacheStats(events, decisions)
    check s.wallSavedMs == 357

  test "tekMiss events contribute nothing beyond decision-sourced misses":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[]),
    ]
    let decisions = @[cdmKeyMiss, cdmKeyMiss]
    let s = aggregateCacheStats(events, decisions)
    check s.misses == 2
    check s.total == 2
    check s.l1Hits == 0

  test "tekRemoteErr events -> remoteErrors, carrying putTier/putVerdict":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvUnauthorized),
    ]
    let s = aggregateCacheStats(events, @[cdmKeyMiss, cdmKeyMiss])
    check s.remoteErrors == 2

  test "tekPublish events -> published":
    let events = @[
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
    ]
    let s = aggregateCacheStats(events, @[cdmStored, cdmStored, cdmStored])
    check s.published == 3

  test "tekVerifyFail events -> verifyFails, carrying path":
    let events = @[
      TelemetryEvent(kind: tekVerifyFail, path: "tests/unit/test_a.nim"),
    ]
    let s = aggregateCacheStats(events, @[cdmHit])
    check s.verifyFails == 1
    check events[0].path == "tests/unit/test_a.nim"

suite "aggregateCacheStats — a full run-shaped mixed vector":

  test "a plausible run: hits, a miss-then-store, a not-eligible entry, one remote-err, one verifyFail":
    # 5 entrypoints: 2 served from cache, 1 ran live and stored, 1 not
    # eligible (edNeverBuilt), 1 ran live but its store attempt hit an
    # unwritable root (remote-err).
    let decisions = @[cdmHit, cdmHit, cdmStored, cdmNotEligible, cdmKeyMiss]
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 40),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 60),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekVerifyFail, path: "tests/unit/test_flaky.nim"),
    ]
    let s = aggregateCacheStats(events, decisions)
    check s.l1Hits == 2
    check s.remoteHits == 0
    check s.notConsulted == 1
    check s.total == 4            # 5 decisions - 1 notConsulted
    check s.misses == 2           # total - l1Hits - remoteHits
    check s.hitPct == 50.0        # 2 / 4 * 100
    check s.wallSavedMs == 100
    check s.published == 1
    check s.remoteErrors == 1
    check s.verifyFails == 1

suite "erroredTiers — the per-tier 100%-error diagnostic":

  test "empty input -> no errored tiers":
    check erroredTiers(@[]).len == 0

  test "a tier with only hits is never errored":
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 5),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 7),
    ]
    check erroredTiers(events).len == 0

  test "a tier with only cvMiss (a normal cold cache) is never errored":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
    ]
    check erroredTiers(events).len == 0

  test "a tier with 100% cvOffline reads is errored":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvOffline)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvOffline)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvOffline)]),
    ]
    let errored = erroredTiers(events)
    check errored.len == 1
    check errored[0].tier == "l1"
    check errored[0].calls == 3

  test "a single non-error read among errors keeps the tier out of the report":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvOffline)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvOffline)]),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 1),  # one real success
    ]
    check erroredTiers(events).len == 0

  test "every RFC-listed error class counts: transport + trust codes + cvCorrupt":
    for v in [cvOffline, cvTimeout, cvUnauthorized, cvCorrupt,
              cvTrustNoAttestation, cvTrustUnknownAlg, cvTrustUnpinnedSigner,
              cvTrustSignerMismatch, cvTrustBadSignature]:
      let events = @[TelemetryEvent(kind: tekMiss, verdicts: @[("l1", v)])]
      let errored = erroredTiers(events)
      check errored.len == 1
      check errored[0].tier == "l1"

  test "cvVersionSkew is NOT in the RFC's error list -- does not trip the warning":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvVersionSkew)]),
    ]
    check erroredTiers(events).len == 0

  test "store-side events (tekPublish/tekRemoteErr/tekVerifyFail) never contribute":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekVerifyFail, path: "x.nim"),
    ]
    check erroredTiers(events).len == 0

  test "tierErrorWarning names the tier and the call count":
    let msg = tierErrorWarning(TierErrorReport(tier: "l1", calls: 4))
    check "l1" in msg
    check "4/4" in msg

echo "test_cachetelemetry: done"
