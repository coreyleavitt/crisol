## test_cachetelemetry.nim — RFC-0005 B2a: aggregateCacheStats (pure fold).
##
## Coverage:
##   1. empty input -> every count 0, hitPct 0.0 (not NaN).
##   2. mixed decisions -> l1Hits/total/notConsulted/misses/hitPct.
##   3. tekHit events -> wallSavedMs sums durationMs.
##   4. tekRemoteErr/tekPublish/tekVerifyFail -> remoteErrors/published/verifyFails counts.
##   5. RFC-0005 C-dep rider: l1Hits/remoteHits are tier-granular, keyed off
##      each hit's authoritative `cacheTier` (DecisionTier.tier) -- an
##      "l1"-tier hit counts toward l1Hits, any OTHER (remote-cache) tier
##      counts toward remoteHits, and a mixed run splits correctly.
##   6. a full mixed event+decision set together (the "run-shaped" vector).
##   7. RFC-0005 B2b: erroredTiers/tierErrorWarning -- the per-tier
##      100%-error diagnostic ("a tier that rejects 100% of reads is as
##      dead as one that times out").
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src tests/unit/test_cachetelemetry.nim

import std/[options, strutils, unittest]
import crisol/cachetelemetry

suite "aggregateCacheStats — empty input":

  test "no events, no decisions -> all zero, hitPct 0.0 not NaN":
    let s = aggregateCacheStats(@[], @[])
    check s.l1Hits == 0
    check s.remoteHits == 0
    check s.misses == 0
    check s.remoteErrors == 0
    check s.localErrors == 0
    check s.total == 0
    check s.notConsulted == 0
    check s.hitPct == 0.0
    check s.wallSavedMs == 0
    check s.published == 0
    check s.verifyFails == 0

suite "aggregateCacheStats — decision-sourced counts":

  test "mixed decisions -> l1Hits/total/notConsulted/misses/hitPct":
    let decisions: seq[DecisionTier] = @[
      (cdmHit, "l1"), (cdmHit, "l1"), (cdmHit, "l1"),   # 3 hits
      (cdmKeyMiss, ""), (cdmStored, ""),                # 2 misses (consulted, not served)
      (cdmNotEligible, ""), (cdmGroupOptOut, ""), (cdmPolicyDisabled, ""),  # 3 not-consulted
    ]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 3
    check s.remoteHits == 0
    check s.notConsulted == 3
    check s.total == 5           # 8 decisions - 3 notConsulted
    check s.misses == 2          # total - l1Hits - remoteHits
    check s.hitPct == 60.0       # 3 / 5 * 100

  test "every RFC-0005 'consulted' decision variant counts toward total, never notConsulted":
    let decisions: seq[DecisionTier] = @[
      (cdmHit, "l1"), (cdmStored, ""), (cdmKeyMiss, ""), (cdmHermeticityDeg, ""),
      (cdmFlaky, ""), (cdmClosureUnrecorded, ""), (cdmRecomputeMiss, ""),
    ]
    let s = aggregateCacheStats(@[], decisions)
    check s.total == decisions.len
    check s.notConsulted == 0
    check s.l1Hits == 1   # only cdmHit

  test "every notConsulted decision variant is excluded from total":
    let decisions: seq[DecisionTier] =
      @[(cdmNotEligible, ""), (cdmGroupOptOut, ""), (cdmPolicyDisabled, "")]
    let s = aggregateCacheStats(@[], decisions)
    check s.total == 0
    check s.notConsulted == 3
    check s.hitPct == 0.0   # zero consulted -> 0, not NaN

suite "aggregateCacheStats — RFC-0005 C-dep rider: tier-granular l1Hits/remoteHits":

  test "an l1-tier hit counts as l1Hits, not remoteHits":
    let decisions: seq[DecisionTier] = @[(cdmHit, "l1")]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 1
    check s.remoteHits == 0

  test "a mirror-tier hit counts as remoteHits, not l1Hits":
    let decisions: seq[DecisionTier] = @[(cdmHit, "mirror")]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 0
    check s.remoteHits == 1

  test "any non-l1 tier name counts as remoteHits (not a hardcoded remote-cache name)":
    let decisions: seq[DecisionTier] = @[(cdmHit, "l2"), (cdmHit, "some-other-remote")]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 0
    check s.remoteHits == 2

  test "a mixed run splits correctly and hitPct/misses still sum both":
    let decisions: seq[DecisionTier] = @[
      (cdmHit, "l1"), (cdmHit, "l1"), (cdmHit, "mirror"),  # 2 l1 + 1 remote hit
      (cdmKeyMiss, ""),                                     # 1 miss
    ]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 2
    check s.remoteHits == 1
    check s.total == 4
    check s.misses == 1              # total - l1Hits - remoteHits
    check s.hitPct == 75.0           # (2 + 1) / 4 * 100

  test "a non-hit decision's tier is never inspected (miss/stored carry an empty tier honestly)":
    let decisions: seq[DecisionTier] = @[(cdmKeyMiss, "mirror"), (cdmStored, "l1")]
    let s = aggregateCacheStats(@[], decisions)
    check s.l1Hits == 0
    check s.remoteHits == 0
    check s.misses == 2

suite "aggregateCacheStats — event-sourced counts":

  test "tekHit events sum into wallSavedMs":
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 100),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 250),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 7),
    ]
    let decisions: seq[DecisionTier] = @[(cdmHit, "l1"), (cdmHit, "l1"), (cdmHit, "l1")]
    let s = aggregateCacheStats(events, decisions)
    check s.wallSavedMs == 357

  test "tekMiss events contribute nothing beyond decision-sourced misses":
    let events = @[
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss)]),
      TelemetryEvent(kind: tekMiss, verdicts: @[]),
    ]
    let decisions: seq[DecisionTier] = @[(cdmKeyMiss, ""), (cdmKeyMiss, "")]
    let s = aggregateCacheStats(events, decisions)
    check s.misses == 2
    check s.total == 2
    check s.l1Hits == 0

  test "tekRemoteErr events -> remoteErrors, carrying putTier/putVerdict":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "mirror", putVerdict: cvOffline),
      TelemetryEvent(kind: tekRemoteErr, putTier: "mirror", putVerdict: cvUnauthorized),
    ]
    let s = aggregateCacheStats(events, @[(cdmKeyMiss, ""), (cdmKeyMiss, "")])
    check s.remoteErrors == 2
    check s.localErrors == 0

  test "RFC-0005 code-review D1: a tekRemoteErr with putTier == l1 -> localErrors, NOT remoteErrors":
    ## A local-fs write failure (unwritable cache root, full disk) is not a
    ## "remote" error just because the run has zero remote tiers -- keyed
    ## off the FAILING tier, mirroring the l1Hits/remoteHits split.
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvUnauthorized),
    ]
    let s = aggregateCacheStats(events, @[(cdmKeyMiss, ""), (cdmKeyMiss, "")])
    check s.localErrors == 2
    check s.remoteErrors == 0

  test "tekPublish events -> published":
    let events = @[
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
    ]
    let s = aggregateCacheStats(events, @[(cdmStored, ""), (cdmStored, ""), (cdmStored, "")])
    check s.published == 3

  test "tekVerifyFail events -> verifyFails, carrying path":
    let events = @[
      TelemetryEvent(kind: tekVerifyFail, path: "tests/unit/test_a.nim"),
    ]
    let s = aggregateCacheStats(events, @[(cdmHit, "l1")])
    check s.verifyFails == 1
    check events[0].path == "tests/unit/test_a.nim"

  test "tekBackfillErr events -> remoteErrors, carrying putTier/putVerdict (RFC-0005 A3a)":
    let events = @[
      TelemetryEvent(kind: tekBackfillErr, putTier: "mirror", putVerdict: cvOffline),
      TelemetryEvent(kind: tekBackfillErr, putTier: "mirror", putVerdict: cvTimeout),
    ]
    let s = aggregateCacheStats(events, @[(cdmHit, "l1"), (cdmHit, "l1")])
    check s.remoteErrors == 2
    check s.localErrors == 0

  test "RFC-0005 code-review D1: a tekBackfillErr with putTier == l1 -> localErrors, NOT remoteErrors":
    let events = @[
      TelemetryEvent(kind: tekBackfillErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekBackfillErr, putTier: "l1", putVerdict: cvTimeout),
    ]
    let s = aggregateCacheStats(events, @[(cdmHit, "l1"), (cdmHit, "l1")])
    check s.localErrors == 2
    check s.remoteErrors == 0

  test "tekRemoteErr and tekBackfillErr pool into the SAME remoteErrors count":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "mirror", putVerdict: cvOffline),
      TelemetryEvent(kind: tekBackfillErr, putTier: "mirror", putVerdict: cvOffline),
    ]
    let s = aggregateCacheStats(events, @[(cdmHit, "l1")])
    check s.remoteErrors == 2
    check s.localErrors == 0

  test "tekRemoteErr and tekBackfillErr pool into the SAME localErrors count when putTier == l1":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekBackfillErr, putTier: "l1", putVerdict: cvOffline),
    ]
    let s = aggregateCacheStats(events, @[(cdmHit, "l1")])
    check s.localErrors == 2
    check s.remoteErrors == 0

  test "a mixed run: an l1 put failure and a mirror put failure attribute independently":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekRemoteErr, putTier: "mirror", putVerdict: cvOffline),
    ]
    let s = aggregateCacheStats(events, @[(cdmStored, ""), (cdmStored, "")])
    check s.localErrors == 1
    check s.remoteErrors == 1

suite "aggregateCacheStats — a full run-shaped mixed vector":

  test "a plausible run: hits, a miss-then-store, a not-eligible entry, one LOCAL err (l1), one verifyFail":
    # 5 entrypoints: 2 served from cache, 1 ran live and stored, 1 not
    # eligible (edNeverBuilt), 1 ran live but its store attempt hit an
    # unwritable LOCAL root -- zero remote tier configured, so this must
    # land in localErrors (RFC-0005 code-review D1), never remoteErrors.
    let decisions: seq[DecisionTier] =
      @[(cdmHit, "l1"), (cdmHit, "l1"), (cdmStored, ""), (cdmNotEligible, ""), (cdmKeyMiss, "")]
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
    check s.localErrors == 1
    check s.remoteErrors == 0
    check s.verifyFails == 1

  test "a plausible run WITH a remote tier: l1 hits + a mirror hit -> both counted, hitPct sums both":
    let decisions: seq[DecisionTier] =
      @[(cdmHit, "l1"), (cdmHit, "l1"), (cdmHit, "mirror"), (cdmKeyMiss, "")]
    let events = @[
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 40),
      TelemetryEvent(kind: tekHit, tier: "l1", durationMs: 20),
      TelemetryEvent(kind: tekHit, tier: "mirror", durationMs: 60),
      TelemetryEvent(kind: tekMiss, verdicts: @[("l1", cvMiss), ("mirror", cvMiss)]),
    ]
    let s = aggregateCacheStats(events, decisions)
    check s.l1Hits == 2
    check s.remoteHits == 1
    check s.total == 4
    check s.misses == 1
    check s.hitPct == 75.0        # (2 + 1) / 4 * 100
    check s.wallSavedMs == 120

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

  test "store-side events (tekPublish/tekRemoteErr/tekBackfillErr/tekVerifyFail) never contribute":
    let events = @[
      TelemetryEvent(kind: tekRemoteErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekBackfillErr, putTier: "l1", putVerdict: cvOffline),
      TelemetryEvent(kind: tekPublish, publishedTo: "l1"),
      TelemetryEvent(kind: tekVerifyFail, path: "x.nim"),
    ]
    check erroredTiers(events).len == 0

suite "backfillErrEvents — the tekBackfillErr producer (RFC-0005 A3a)":

  test "empty backfillVerdicts -> no events":
    let l = CacheLookup(hit: none(TierHit), verdicts: @[], backfillVerdicts: @[])
    check backfillErrEvents(l).len == 0

  test "a successful backfill (cvOk) produces no event":
    let l = CacheLookup(hit: none(TierHit), verdicts: @[],
                         backfillVerdicts: @[("l1", cvOk)])
    check backfillErrEvents(l).len == 0

  test "a transport-class backfill verdict produces one tekBackfillErr, carrying tier + verdict":
    let l = CacheLookup(hit: none(TierHit), verdicts: @[],
                         backfillVerdicts: @[("l1", cvOffline)])
    let events = backfillErrEvents(l)
    check events.len == 1
    check events[0].kind == tekBackfillErr
    check events[0].putTier == "l1"
    check events[0].putVerdict == cvOffline

  test "multiple failing backfill tiers each produce their own event":
    let l = CacheLookup(hit: none(TierHit), verdicts: @[],
                         backfillVerdicts: @[("l1", cvOffline), ("l2", cvTimeout), ("l3", cvOk)])
    let events = backfillErrEvents(l)
    check events.len == 2
    check events[0].putTier == "l1"
    check events[1].putTier == "l2"

  test "tierErrorWarning names the tier and the call count":
    let msg = tierErrorWarning(TierErrorReport(tier: "l1", calls: 4))
    check "l1" in msg
    check "4/4" in msg

echo "test_cachetelemetry: done"
