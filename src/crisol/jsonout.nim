## jsonout.nim — B5 JSON serialization + lastrun.json persistence
##              B7 loadLastRun: read back failed (path,group) keys
##              rfc-0007 A1d-i: the wire — crisol/run/v1 -> crisol/run/v2
##
## Public API:
##
##   toJson*(results: seq[EntrypointResult]; summary: Summary;
##           filterTag: string = ""): JsonNode
##     Pure: produce the crisol/run/v2 JSON object.
##     C3: when filterTag is non-empty, each entrypoint's records array
##     contains ONLY records whose tags include the tag.  This keeps
##     --filter-tag consistent between human and machine output.
##     The summary object is always the FULL-RUN summary (never re-counted
##     from filtered records) so the JSON verdict is not distorted.
##
##   toJsonString*(results: seq[EntrypointResult]; summary: Summary;
##                 filterTag: string = ""): string
##     Pure: compact JSON string (calls `$` on the JsonNode).
##
##   persistLastRun*(results: seq[EntrypointResult]; summary: Summary; config: Config)
##     Effectful: write <config.projectRoot>/<config.stateDir>/lastrun.json
##     atomically (temp file + rename).  Creates the state dir if absent.
##     On any write failure: warns to stderr and continues -- never crashes.
##
##   loadLastRun*(config: Config): tuple[found: bool; failed: HashSet[tuple[path,group: string]]]
##     Effectful: read <projectRoot>/<stateDir>/lastrun.json and return the set
##     of (path, group) pairs whose outcome is a failure (not "passed" and not
##     "noTestsRan" — specifically: "exitNonZero", "compileFailed", "timedOut",
##     "signaled", "spawnError", "killed", "crashed").
##     found=false means the file is ABSENT (caller should exit 3).
##     A file written by the PRIOR schema ("crisol/run/v1") is ALSO treated as
##     found=false — cold start, no error, no partial parse.  A schema change
##     is not something a byte-compatible reader can partially trust; the
##     honest posture is "we have no data", exactly like a missing file (A1d-i).
##     If the file is present but malformed or carries some OTHER unrecognized
##     schema string, raises CrisolError(cekEnvironment) — caller also exits 3.
##
## Schema (crisol/run/v2):
##   {
##     "schema":      "crisol/run/v2",
##     "schemaRevision": <int>,
##     "interrupted": bool,          // rev 16: true iff this run was cut short
##                                   // by Ctrl-C; ALWAYS false on the normal
##                                   // path in this slice — real values are
##                                   // A1e-ii's (rfc-0007 §2 interrupt bullet).
##     "summary": {
##       total, counts: { passed, exitNonZero, compileFailed, timedOut,
##                        signaled, spawnError, killed, crashed },
##       flaky, quarantined, noTestsRan, notStarted
##     },
##     "entrypoints": [
##       { path, group, flags, outcome (string, advisory),
##         compile: <PhaseNode>, run: <PhaseNode>,
##         compileSkipped, cached, inputHash, cacheDecision, flaky, attempts,
##         quarantined, peakRssBytes, regressed,
##         records: [{ name, status (string), durationUs (int),
##                     msg (string|null), tags ([string]) }] }
##     ],
##     "compileStats": {   // OPTIONAL (rev 7); present only when telemetry exists
##       "segments": [
##         { groupId, configHash, rTime, rSize, ccPct, codegenPct, linkPct,
##           reproducible (bool), artifactsTotal, artifactsShared,
##           bytesTotal, bytesShared }
##       ],
##       "ambientCcacheDetected": bool,  // rev 8
##       "topUnits": [ { basename, sizeBytes, ccTimeUs }, ... ],  // rev 8, top-10
##       "compileRegressions": [   // rev 9: ALWAYS PRESENT (once compileStats exists); empty by default
##         { entrypointIdentity, groupId, configHash, currentUs, baselineUs, thresholdUs }
##       ]
##     },
##     "reuseAlerts": [   // rev 8: ALWAYS PRESENT; empty when reuse-check disabled
##       { groupId, configHash, rTime, alertBelow }
##     ]
##     // NO "substrate" key: absent until A7 lands the substrate-identity
##     // block.  Absence IS the honest placeholder — no null, no stub object.
##   }
##
##   <PhaseNode> (rfc-0007 §2's Phase, one shape shared by "compile" and "run"):
##     {
##       "kind": "skipped" | "spawnFailed" | "ran" | "cached",
##       "spawnError": string | null,   // non-null only when kind=="spawnFailed"
##       "exit": <Exit> | null, "cause": <Cause> | null,
##       "evidence": <Evidence> | null, "rusage": <Rusage> | null,
##       "durationUs": int | null       // non-null only when kind ran/cached;
##     }                                // exit/cause/evidence/rusage/durationUs
##                                       // are process/resultjson.toJson's own
##                                       // wire (the ONE owner — see that
##                                       // module) — jsonout never re-derives
##                                       // their shape.
##
## Outcome string values (stable):
##   oPassed        -> "passed"
##   oFailed        -> "exitNonZero"
##   oCompileFailed -> "compileFailed"
##   oTimeout       -> "timedOut"
##   oSignal        -> "signaled"
##   oSpawnError    -> "spawnError"
##   oKilled        -> "killed"
##   oCrashed       -> "crashed"
##
## RecordStatus string values (stable):
##   rsPass -> "pass"
##   rsFail -> "fail"
##   rsSkip -> "skip"
##
## ---------------------------------------------------------------------------
## run/v1 -> run/v2 COMPLETE field-mapping table (rfc-0007 A1d-i)
## ---------------------------------------------------------------------------
## Every v1 field, and its v2 disposition.  "derived-now" = the value is
## computable from a v2 field rather than carried as its own key; "dropped"
## = the v1 key does not exist on the v2 wire at all (with no successor).
##
## TOP LEVEL
##   schema            RENAMED VALUE   "crisol/run/v1" -> "crisol/run/v2"
##   schemaRevision    KEPT            integer scheme continues; v1's last
##                                     value (15) -> v2 starts at 16.
##   summary           KEPT (RESHAPED) see SUMMARY OBJECT below
##   entrypoints       KEPT            per-entry shape changes; see below
##   memThrottledSlots KEPT            unchanged
##   warnings          KEPT            unchanged
##   regressions       KEPT            unchanged
##   compile           RENAMED KEY     -> "compileStats" (frees "compile" for
##                                     the per-entrypoint Phase node)
##   reuseAlerts       KEPT            unchanged
##   (new) interrupted ADDED           top-level bool; false on the normal
##                                     path this slice; A1e-ii wires real
##                                     interrupt values (rfc-0007 §2)
##   (new) substrate   NOT ADDED       deliberately absent until A7 — no key,
##                                     not even null; the honest placeholder
##
## SUMMARY OBJECT (v1: total, passed, failed, compileFailed, timedOut,
##                 signaled, spawnErrors, quarantined, noTestsRan)
##   total          KEPT
##   passed         DROPPED   superseded by summary.counts["passed"]
##   failed         DROPPED   superseded by summary.counts["exitNonZero"]
##   compileFailed  DROPPED   superseded by summary.counts["compileFailed"]
##   timedOut       DROPPED   superseded by summary.counts["timedOut"] (always
##                            0 — deriveOutcome never produces the legacy value)
##   signaled       DROPPED   superseded by summary.counts["signaled"] (always
##                            0, same reason)
##   spawnErrors    DROPPED   superseded by summary.counts["spawnError"]
##   quarantined    KEPT      moved under summary; unchanged meaning
##   noTestsRan     KEPT      unchanged
##   (new) counts      ADDED  object keyed by outcomeString(o) for every
##                            Outcome o, sourced from Summary.counts (rfc-0007
##                            A1c's array) — "killed"/"crashed" are now real,
##                            first-class keys, not just advisory
##   (new) flaky       ADDED  Summary.flaky (count of flaky passes) was never
##                            surfaced in v1's summary node; it is now
##   (new) notStarted  ADDED  count of entries omitted from the emission set
##                            on interrupt (rfc-0007 §2); always 0 until
##                            A1e-ii, an honest placeholder like `interrupted`
##
## PER-ENTRYPOINT (v1: path, group, flags, outcome, exitCode, signal,
##                 durationMs, compileSkipped, cached, inputHash,
##                 cacheDecision, flaky, attempts, quarantined, peakRssBytes,
##                 regressed, records, exit [rev15 advisory], cause [rev15 advisory])
##   path            KEPT
##   group           KEPT
##   flags           KEPT
##   outcome         KEPT (RE-SOURCED)  same advisory string; now produced by
##                            deriveOutcome(r) (rfc-0007 §2's total recomputation)
##                            instead of the legacy stored field — the wire
##                            cutover itself.  For a real runner-authored kill
##                            this now reads "killed", not "timedOut" — the
##                            load-bearing honesty property A1b introduced
##                            finally reaches the primary outcome string.
##   exitCode        DROPPED   derived-now from run.exit.code when
##                            run.kind in {ran, cached} and run.exit.kind=="exited"
##   signal          DROPPED   derived-now from run.exit.sig when
##                            run.exit.kind=="signaled"
##   durationMs      DROPPED   superseded by the per-phase, authoritative
##                            compile.durationUs / run.durationUs (§2's real
##                            ProcessResult.durationUs, microsecond precision) —
##                            a combined wall-clock figure can be derived by
##                            summing the two when both are present
##   compileSkipped  KEPT      unchanged
##   cached          KEPT      unchanged
##   inputHash       KEPT      unchanged — the soundness-key fingerprint is a
##                            caching concern (RFC-0004/0005), orthogonal to
##                            §2's process-result model; §2 is silent on it,
##                            which is not a reason to drop an actively-used
##                            cache-diagnostic field
##   cacheDecision   KEPT      "carried under its real name" — unchanged
##   flaky           KEPT (RE-SOURCED)  now serialized as the DERIVED value
##                            (deriveOutcome(r)==oPassed and r.attempts > 1)
##                            rather than the stored field — a stored bool
##                            over a policy-dependent quantity would
##                            contradict recomputation (rfc-0007 §2)
##   attempts        KEPT      unchanged (an observation, stored — not derived)
##   quarantined     KEPT      unchanged (stays STORED: deriving it needs the
##                            Config overlay, not the result — §2's one
##                            deliberate exemption from the derived-field rule)
##   peakRssBytes    KEPT      unchanged
##   regressed       KEPT      unchanged
##   records         KEPT      unchanged (name/status/durationUs/msg/tags)
##   exit (rev15)    RENAMED   absorbed into the nested "run" Phase node's
##                            "exit" — real (non-null) whenever run.kind is
##                            ran/cached, matching the node's own "kind"
##   cause (rev15)   RENAMED   absorbed into the nested "run" Phase node's
##                            "cause", same rule
##   (new) compile   ADDED    the compile phase's own Phase node — entirely
##                            absent from v1; §2 gives compile and run the
##                            SAME shape (a ProcessResult under a Phase), and
##                            v1 only ever exposed the run phase's advisory
##                            half.  A compile timeout/kill is now visible on
##                            the wire exactly like a run timeout/kill.
##   (new) run       ADDED    the run phase's Phase node — supersedes v1
##                            rev15's flat advisory exit/cause with the FULL
##                            §2 observation (adds evidence, rusage,
##                            durationUs; real not advisory)
## ---------------------------------------------------------------------------

import std/[json, options, os, sets]
import std/posix as posix_mod
import crisol/types
import crisol/config  # for stateDirOf
import crisol/render  # for filterRecordsByTag
import crisol/planview  # for warningsToJsonArray
import crisol/outcomestrings  # re-exports FailureOutcomeStrings (the only symbol
                              # used from this module); imported separately from
                              # types so the dependency on the wire-string set is
                              # explicit rather than hidden inside a bulk import.
import crisol/ioutils  # R2-a: writeAllFd replaces bare write() (EINTR/short-write safe)
# rfc-0007 A1b: advisory `exit`/`cause` nodes (§2) — `import nil` so nothing
# unqualified leaks into this module's own Outcome/etc namespace.
from crisol/process/types as ptypes import nil
import crisol/process/resultjson  # resultjson.toJson(ProcessResult): the ONE wire format owner

# ---------------------------------------------------------------------------
# Schema-version constant (single source of truth)
# ---------------------------------------------------------------------------

const LegacyRunV1Schema = "crisol/run/v1"
  ## The PRIOR schema string (rfc-0007 A1d-i).  Not exported: the only
  ## consumer is loadLastRun's cold-start check below — nothing should ever
  ## emit this value again.

const RunSchema* = "crisol/run/v2"
  ## Stable schema identifier embedded in every crisol/run/v2 JSON document.
  ## Import crisol/api (or crisol/jsonout directly) to reference this constant
  ## rather than duplicating the string literal.  Named without a trailing
  ## version number deliberately (rfc-0007 A1d-i): RFC-0008 EXTENDS v2, not
  ## v3 — a versioned identifier would need renaming for no reason the day
  ## rev 17 lands.

const RunSchemaRevision* = 17
  ## Integer minor revision of the crisol/run/v2 schema (A8).  Additive only:
  ## the `schema` STRING stays "crisol/run/v2"; this integer is bumped each time
  ## additive optional fields land, so a consumer can gate on feature presence
  ## (`schemaRevision >= 6`) without substring-parsing the string.
  ##   rev 1 (implicit) — B5/S2a fields (compileSkipped, memThrottledSlots, …).
  ##   rev 2           — per-entrypoint cached / inputHash / cacheDecision (A6).
  ##   rev 3 (B3)      — per-entrypoint quarantined (bool), flaky (bool), attempts (int);
  ##                     summary quarantined (int).
  ##   rev 4 (C5)      — per-entrypoint peakRssBytes (int64); 0 for cached/unmeasured.
  ##   rev 5 (C6)      — top-level regressions array (path, currentUs, baselineUs,
  ##                     thresholdUs); per-entrypoint regressed (bool). Empty when
  ##                     perf-check is disabled (additive default).
  ##   rev 6 (M8)      — cacheDecision vocabulary expanded: "stored" (miss+stored),
  ##                     "groupOptOut" (cacheable #false config), legacy "keyMiss"
  ##                     now means ran-but-not-stored; "policyDisabled" is --no-cache only.
  ##   rev 7 (M-report a) — top-level `compile` object: segmented per
  ##                     (groupId, configHash) reuse/cost-split summary
  ##                     (segments[].{groupId, configHash, rTime, rSize, ccPct,
  ##                     codegenPct, linkPct, reproducible, artifactsTotal,
  ##                     artifactsShared, bytesTotal, bytesShared}).  FIELD IS
  ##                     ABSENT (not merely empty) when measureCompileReuse is
  ##                     off — additive/back-compat with pre-rev-7 documents.
  ##   rev 8 (M-report b1) — top-level `reuseAlerts` array (groupId, configHash,
  ##                     rTime, alertBelow); ALWAYS PRESENT, empty when
  ##                     reuse-check is disabled (default) or no segment
  ##                     qualifies — mirrors the `regressions` array's
  ##                     present-but-possibly-empty convention (unlike
  ##                     `compile`, which is absent entirely when there is no
  ##                     telemetry). Also: `compile.ambientCcacheDetected`
  ##                     (bool) and `compile.topUnits` (top-10 per-basename
  ##                     {basename, sizeBytes, ccTimeUs}, both additive
  ##                     siblings of `compile.segments`.
  ##   rev 9 (M-report b2) — `compile.compileRegressions` array (entrypointIdentity,
  ##                     groupId, configHash, currentUs, baselineUs,
  ##                     thresholdUs): the compile-wall-time analog of the
  ##                     top-level `regressions` array, but nested inside
  ##                     `compile` (only meaningful when measureCompileReuse
  ##                     is on). ALWAYS PRESENT once `compile` exists, empty
  ##                     when no entrypoint regressed or history is
  ##                     insufficient — mirrors `regressions`' own
  ##                     present-but-possibly-empty convention.
  ##   rev 10 (Stage R R5b, REMOVED in rev 12) — formerly `compile.objcache`,
  ##                     realized object-cache hit/miss/store telemetry. The
  ##                     RFC-0006 Stage R object cache was removed after an
  ##                     end-to-end A/B showed it didn't pay off on the target
  ##                     consumer (codegen-bound, not cc-bound; cold runs were
  ##                     slower) — see rev 12.
  ##   rev 11 (code review R7) — each `compile.segments[]` entry gains
  ##                     `currentRunEntrypoints` (int: distinct entrypoints
  ##                     THIS run itself contributed artifact rows for to
  ##                     this segment), `sampleEntrypoints` (int: distinct
  ##                     entrypoints contributing ANY row, all history
  ##                     included), and `lowConfidence` (bool: true iff
  ##                     `currentRunEntrypoints` is below
  ##                     compilereport.LowConfidenceMinEntrypoints). A
  ##                     `--changed`-narrowed run touching only 1-2
  ##                     entrypoints now marks its segments low-confidence,
  ##                     and `reuseAlerts` SKIPS low-confidence segments
  ##                     regardless of rTime (matches the RFC's own "marked
  ##                     low-confidence (and reuse-check suppressed)"
  ##                     commitment). Purely additive per-segment fields —
  ##                     no existing field's meaning changes.
  ##   rev 12 — RFC-0006 Stage R (the object cache) removed entirely: the
  ##                     `compile.objcache` sub-block (rev 10) no longer
  ##                     appears in any document. Stage M (measurement:
  ##                     `compile.segments`, `topUnits`, `compileRegressions`,
  ##                     `ambientCcacheDetected`) and the RFC-0004 result
  ##                     cache are UNCHANGED. A reader that only reads
  ##                     `compile.objcache` optionally (as rev 10 always
  ##                     documented it) is unaffected by its permanent
  ##                     absence.
  ##   rev 13 (#5)     — cacheDecision vocabulary: "closureUnrecorded" (fresh run;
  ##                     store refused because the source closure could not be
  ##                     recorded — see depgraph.recordClosure).
  ##   rev 14 (#10)    — per-entrypoint `flags` (string array): the EFFECTIVE,
  ##                     ordered compile-flag list (global then group) that
  ##                     identifies this leg — the same path under two groups
  ##                     with different flags is two rows.  Always present;
  ##                     empty array when no flags.  Mirrors plan/v1 rev 3.
  ##   rev 15 (rfc-0007 A1b) — ADVISORY per-entrypoint `exit`/`cause` nodes
  ##                     (process/types.nim §2: Exit is the lossless OS
  ##                     observation; Cause is runner-asserted authorship).
  ##                     Populated only for entrypoints with a captured
  ##                     run-phase ProcessResult (a live run this invocation);
  ##                     `null` otherwise (e.g. a cache hit — real cache-
  ##                     replay dual-write is A1d-ii). Recomputed observation,
  ##                     NOT the source of truth — `outcome` stays the
  ##                     authoritative verdict string until run/v2 (A1d-i).
  ##                     Readers are unknown-tolerant by design (§2).
  ##   rev 16 (rfc-0007 A1d-i) — THE WIRE CUTOVER.  `schema` becomes
  ##                     "crisol/run/v2".  Per-entrypoint `exit`/`cause`
  ##                     (rev 15, advisory, run-phase-only, flat) are replaced
  ##                     by real nested `compile`/`run` Phase nodes (kind +
  ##                     exit/cause/evidence/rusage/durationUs, sourced from
  ##                     process/resultjson — the one wire owner); `outcome`
  ##                     is now produced by deriveOutcome(r) instead of the
  ##                     legacy stored field (a genuine kill now reads
  ##                     "killed", not "timedOut"); per-entrypoint `exitCode`/
  ##                     `signal`/`durationMs` are dropped (derivable from
  ##                     `run.exit`/`run.durationUs`); `flaky` is now the
  ##                     derived value, not the stored field; `summary`
  ##                     drops its hand-maintained pass/fail/etc counters for
  ##                     a `counts` object (keyed by outcomeString, from
  ##                     Summary.counts) plus `flaky`/`notStarted`; top-level
  ##                     `interrupted` is added (always false this slice);
  ##                     top-level `compile` (telemetry) is renamed
  ##                     `compileStats` (the name `compile` now names the
  ##                     per-entrypoint phase node); NO `substrate` key until
  ##                     A7.  See the field-mapping table above for the full,
  ##                     per-field disposition.
  ##   rev 17 (rfc-0007 A1d-ii) — cacheDecision vocabulary gains
  ##                     "recomputeMiss": a cache entry EXISTED, but its
  ##                     recomputed outcome (deriveOutcome, recomputed at the
  ##                     trust boundary) is not oPassed — treated as a miss
  ##                     and rerun (§2); distinct from "keyMiss" (no entry
  ##                     found at all).  Also: cache hits now replay the REAL
  ##                     stored `run` Phase node (cause/evidence/rusage
  ##                     byte-equal to what was originally observed), not the
  ##                     A1c interim's minimal Exit/Cause-only fabrication —
  ##                     no new field, an existing field's CONTENT changes.
  ## A reader seeing `schemaRevision > RunSchemaRevision` treats the file as
  ## no-data (safe cold-start) — it was written by a newer crisol.  A reader
  ## seeing `schema == "crisol/run/v1"` ALSO treats the file as no-data — see
  ## loadLastRun's doc comment above.

# ---------------------------------------------------------------------------
# Stable string mappings
# ---------------------------------------------------------------------------

proc outcomeString*(o: Outcome): string {.inline.} =
  ## Returns the stable JSON wire string for an Outcome enum value.
  ## Delegates to types.outcomeString — single source of truth lives there.
  types.outcomeString(o)

proc recordStatusString*(s: RecordStatus): string =
  ## Returns the stable JSON string for a RecordStatus enum value.
  case s
  of rsPass: "pass"
  of rsFail: "fail"
  of rsSkip: "skip"

proc cacheDecisionString*(d: CacheDecision): string =
  ## Returns the stable JSON string for a CacheDecision enum value (A8).
  ## These answer "why did this entrypoint cache or not?" in run/v1 output.
  ## M8 additions (rev 6):
  ##   "stored"      — cdmStored: fresh run on a miss; result written to cache.
  ##   "groupOptOut" — cdmGroupOptOut: per-group cacheable #false config opt-out.
  ## M8 refined meanings:
  ##   "keyMiss"           — ran live on a miss but was NOT stored, for a reason
  ##                        not covered by one of the other, more specific
  ##                        variants (see cdmHermeticityDeg, cdmFlaky,
  ##                        cdmClosureUnrecorded).
  ##   "policyDisabled"    — invocation --no-cache flag only (not config cacheable #false).
  ##   "closureUnrecorded" — fresh run; store refused because the entrypoint's
  ##                        source closure could not be recorded.
  ## rfc-0007 A1d-ii (rev 17):
  ##   "recomputeMiss"     — cdmRecomputeMiss: a cache entry EXISTED but its
  ##                        recomputed outcome is not oPassed; treated as a
  ##                        miss and rerun (§2) — distinct from "keyMiss"
  ##                        (no entry was found at all).
  case d
  of cdmNotEligible:       "notEligible"
  of cdmHit:               "hit"
  of cdmStored:            "stored"
  of cdmKeyMiss:           "keyMiss"
  of cdmHermeticityDeg:    "hermeticityDegraded"
  of cdmGroupOptOut:       "groupOptOut"
  of cdmPolicyDisabled:    "policyDisabled"
  of cdmFlaky:             "flaky"
  of cdmClosureUnrecorded: "closureUnrecorded"
  of cdmRecomputeMiss:     "recomputeMiss"

# ---------------------------------------------------------------------------
# phaseToJson -- the ONE place a Phase (compile OR run) becomes a wire node
# ---------------------------------------------------------------------------

proc phaseToJson(p: ptypes.Phase): JsonNode =
  ## rfc-0007 A1d-i: serialize a Phase to its <PhaseNode> shape (see the
  ## module doc comment).  `exit`/`cause`/`evidence`/`rusage`/`durationUs`
  ## come from process/resultjson.toJson (the one wire owner for
  ## ProcessResult) -- this proc never re-derives their shape, only merges
  ## it in alongside `kind`/`spawnError`.
  result = newJObject()
  case p.kind
  of ptypes.pkSkipped:
    result["kind"] = newJString("skipped")
  of ptypes.pkSpawnFailed:
    result["kind"] = newJString("spawnFailed")
    result["spawnError"] = newJString(p.spawnError)
  of ptypes.pkRan, ptypes.pkCached:
    result["kind"] = newJString(if p.kind == ptypes.pkRan: "ran" else: "cached")
    let inner = resultjson.toJson(p.res)  # {exit, cause, evidence, rusage, durationUs}
    for k, v in inner.pairs:
      result[k] = v

# ---------------------------------------------------------------------------
# toJson -- pure serializer
# ---------------------------------------------------------------------------

proc toJson*(results: seq[EntrypointResult]; summary: Summary;
             filterTag: string = "";
             warnings: seq[ConfigWarning] = @[];
             memThrottledSlots: int = 0;
             compileBlock: JsonNode = nil;
             reuseAlerts: JsonNode = nil): JsonNode =
  ## Pure: serialize to the crisol/run/v2 JsonNode.
  ## No I/O.
  ## C3: when filterTag is non-empty, each entrypoint's records array contains
  ## only records whose tags include filterTag.  The summary block always
  ## reflects the full unfiltered run (no re-counting from filtered records).
  ## warnings: config warnings (unknown keys) threaded from loadConfig.
  ## memThrottledSlots: count of slots that were memory-blocked (S2a schema
  ## field; populated by AdmissionController in S6b).  Defaults to 0. # S6b
  ## compileBlock: M-report pass (a) segmented compile-reuse/cost-split block
  ## (crisol/compilereport.readCompileBlock), or nil when no telemetry exists
  ## (measureCompileReuse off). nil -> the "compileStats" field is OMITTED
  ## entirely (additive/back-compat) rather than emitted as an empty object.
  ## reuseAlerts: M-report pass (b1) alert array
  ## (crisol/compilereport.buildReuseAlerts). Unlike compileBlock, this field
  ## is ALWAYS PRESENT (mirrors `regressions`) -- nil/omitted is treated as an
  ## empty JArray, never omitted from the document.
  ## rfc-0007 A1d-i: `outcome`/`flaky` are now sourced from deriveOutcome(r)
  ## (§2's total recomputation), not the legacy stored fields; `compile`/
  ## `run` are real Phase nodes read directly off each EntrypointResult.

  # Build summary object (counts array + scalars; see the field-mapping table)
  let summaryNode = newJObject()
  summaryNode["total"] = newJInt(summary.total)
  let countsNode = newJObject()
  for o in Outcome:
    countsNode[outcomeString(o)] = newJInt(summary.counts[o])
  summaryNode["counts"]       = countsNode
  summaryNode["flaky"]        = newJInt(summary.flaky)
  # B3: quarantined failure count — failures excluded from exit-1 decision.
  summaryNode["quarantined"]  = newJInt(summary.quarantined)
  summaryNode["noTestsRan"]   = newJBool(summary.noTestsRan)
  summaryNode["notStarted"]   = newJInt(summary.notStarted)

  # Build entrypoints array
  let entrypointsNode = newJArray()
  for i, r in results:
    # C3: filter records if a tag was supplied
    let displayRecords =
      if filterTag.len > 0: filterRecordsByTag(r.records, filterTag)
      else: r.records

    # Build records array for this entrypoint
    let recordsNode = newJArray()
    for rec in displayRecords:
      let recNode = newJObject()
      recNode["name"]       = newJString(rec.name)
      recNode["status"]     = newJString(recordStatusString(rec.status))
      recNode["durationUs"] = newJInt(rec.durationUs)
      if rec.msg.isSome:
        recNode["msg"] = newJString(rec.msg.get)
      else:
        recNode["msg"] = newJNull()
      let tagsNode = newJArray()
      for t in rec.tags:
        tagsNode.add newJString(t)
      recNode["tags"] = tagsNode
      recordsNode.add recNode

    let derived = deriveOutcome(r)

    # Build entrypoint object
    let epNode = newJObject()
    epNode["path"]          = newJString(r.ep.path)
    epNode["group"]         = newJString(r.ep.group)
    # rev 14 (issue #10): effective flags identify the leg (see plan/v1 rev 3).
    let flagsNode = newJArray()
    for f in r.ep.flags: flagsNode.add newJString(f)
    epNode["flags"]         = flagsNode
    # rev 16: advisory `outcome` is now deriveOutcome(r), not the legacy
    # stored field -- the wire cutover itself (see the field-mapping table).
    epNode["outcome"]       = newJString(outcomeString(derived))
    epNode["compileSkipped"] = newJBool(r.compileSkipped)  # S2a: complete the schema
    # A8 (rev 2): cache observability.  `cached` absence-default false;
    # `inputHash` is the soundnessKey string ("" when caching not consulted);
    # `cacheDecision` is the stable string form of the always-populated enum.
    epNode["cached"]        = newJBool(r.cached)
    epNode["inputHash"]     = newJString(r.inputHash)
    epNode["cacheDecision"] = newJString(cacheDecisionString(r.cacheDecision))
    # B1 (rev 3, rev 16): per-entrypoint retry observability.  `flaky` is now
    # the DERIVED value (deriveOutcome==oPassed and attempts>1), not the
    # stored field -- see the field-mapping table.  `attempts` stays stored:
    # 0 for cached results (no live run), 1 for a clean first-pass, >1 if retried.
    epNode["flaky"]         = newJBool(derived == oPassed and r.attempts > 1)
    epNode["attempts"]      = newJInt(r.attempts)
    # B3 (rev 3): quarantine overlay — true iff ep.path ∈ Config.quarantine.
    # Absence-default false; only quarantined entrypoints carry true.
    epNode["quarantined"]   = newJBool(r.quarantined)
    # C5 (rev 4): per-entrypoint peak RSS in bytes.  0 for cached results or
    # when RSS sampling was unavailable.  Absence-default 0.
    epNode["peakRssBytes"]  = newJInt(r.peakRssBytes)
    # C6 (rev 5): per-entrypoint regression flag.  Absence-default false.
    # Only true when perf-check is enabled AND this run exceeded median+k·MAD.
    epNode["regressed"]     = newJBool(r.regressed)
    epNode["records"]       = recordsNode
    # rev 16: real, nested compile/run Phase nodes -- supersede rev 15's flat
    # advisory exit/cause (run-phase-only).  See the field-mapping table.
    epNode["compile"]       = phaseToJson(r.compile)
    epNode["run"]           = phaseToJson(r.run)
    entrypointsNode.add epNode

  # C6 (rev 5): build the regressions array from regressed results.
  # Each entry: { path, currentUs (durationMs*1000), baselineUs, thresholdUs }.
  # Array is always present; empty when perf-check is disabled or no regressions.
  let regressionsNode = newJArray()
  for r in results:
    if r.regressed:
      let rn = newJObject()
      rn["path"]        = newJString(r.ep.path)
      rn["currentUs"]   = newJInt(r.durationMs * 1000)
      rn["baselineUs"]  = newJInt(r.perfBaselineUs)
      rn["thresholdUs"] = newJInt(r.perfThresholdUs)
      regressionsNode.add rn

  # Assemble top-level object
  result = newJObject()
  result["schema"]           = newJString(RunSchema)
  result["schemaRevision"]   = newJInt(RunSchemaRevision)  # A8: additive minor revision
  # rev 16: always false on the normal path -- A1e-ii wires real interrupt values.
  result["interrupted"]      = newJBool(false)
  result["summary"]          = summaryNode
  result["entrypoints"]      = entrypointsNode
  result["memThrottledSlots"] = newJInt(memThrottledSlots)  # S2a schema field; S6b populates
  result["warnings"]         = warningsToJsonArray(warnings)
  result["regressions"]      = regressionsNode  # C6: empty when perf-check disabled
  if compileBlock != nil:
    result["compileStats"] = compileBlock  # M-report pass (a): additive; absent when nil;
                                            # renamed from "compile" (rev 16) -- that name
                                            # now belongs to the per-entrypoint phase node.
  # M-report pass (b1): always present, empty by default (mirrors `regressions`).
  result["reuseAlerts"] = if reuseAlerts != nil: reuseAlerts else: newJArray()
  # rev 16: deliberately NO "substrate" key -- absence is the honest
  # placeholder until A7 lands the substrate-identity block.

proc toJsonString*(results: seq[EntrypointResult]; summary: Summary;
                   filterTag: string = "";
                   warnings: seq[ConfigWarning] = @[];
                   memThrottledSlots: int = 0;
                   compileBlock: JsonNode = nil;
                   reuseAlerts: JsonNode = nil): string =
  ## Pure: compact JSON string of the crisol/run/v2 document.
  ## C3: filterTag threads through to toJson.
  $toJson(results, summary, filterTag, warnings, memThrottledSlots, compileBlock,
         reuseAlerts)

# ---------------------------------------------------------------------------
# persistLastRun -- effectful
# ---------------------------------------------------------------------------

proc persistLastRun*(results: seq[EntrypointResult]; summary: Summary;
                     config: Config;
                     warnings: seq[ConfigWarning] = @[];
                     memThrottledSlots: int = 0;
                     compileBlock: JsonNode = nil;
                     reuseAlerts: JsonNode = nil) =
  ## Write lastrun.json atomically to <projectRoot>/<stateDir>/lastrun.json.
  ## Creates the state directory if it does not exist.
  ## On any failure: prints a warning to stderr and returns -- never raises.
  ##
  ## warnings and memThrottledSlots are threaded through to toJsonString so
  ## the persisted file matches the stdout JSON path exactly (M3 fix).
  ## compileBlock: M-report pass (a) segmented compile block, or nil (default)
  ## when there is no telemetry to report -- threads through unchanged.
  ## reuseAlerts: M-report pass (b1) alert array, or nil (default; persisted
  ## as an empty array) -- threads through unchanged.
  let stateDir = stateDirOf(config)
  let finalPath = stateDir / "lastrun.json"

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return

  # Write to a temp file in the same directory, then rename (atomic on POSIX).
  # Use O_CREAT|O_EXCL|O_WRONLY so the open fails if a file (or symlink) already
  # exists at the temp path — prevents a pre-planted symlink from redirecting our
  # write to an attacker-chosen path (symlink write-through attack on shared fs).
  # If a stale .tmp from a previous crashed run exists, we remove it first.
  let tmpPath = finalPath & ".tmp"
  try: removeFile(tmpPath) except: discard
  let jsonStr = toJsonString(results, summary, warnings = warnings,
                             memThrottledSlots = memThrottledSlots,
                             compileBlock = compileBlock,
                             reuseAlerts = reuseAlerts)
  var tmpFd: cint = -1
  try:
    let flags = O_CREAT or O_EXCL or O_WRONLY or O_CLOEXEC
    tmpFd = posix_mod.open(tmpPath.cstring, flags, Mode(0o600))
    if tmpFd < 0:
      let err = $strerror(errno)
      stderr.write("crisol: warning: could not create temp file for lastrun.json: " &
                   err & "\n")
      return
    # R2-a: use writeAllFd (EINTR-safe, short-write-retry loop) instead of a
    # bare write() call — matches the same pattern used in resultcache/ledger.
    let ok = writeAllFd(tmpFd, jsonStr)
    discard posix_mod.close(tmpFd)
    tmpFd = -1
    if not ok:
      stderr.write("crisol: warning: short write to lastrun.json temp file\n")
      try: removeFile(tmpPath) except: discard
      return
    moveFile(tmpPath, finalPath)
  except OSError as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: could not write lastrun.json: " & e.msg & "\n")
    try: removeFile(tmpPath) except: discard
  except Exception as e:
    if tmpFd >= 0:
      discard posix_mod.close(tmpFd)
    stderr.write("crisol: warning: unexpected error writing lastrun.json: " &
                 e.msg & "\n")
    try: removeFile(tmpPath) except: discard

# ---------------------------------------------------------------------------
# loadLastRun -- B7: read back the failed (path,group) set
# ---------------------------------------------------------------------------

const FailureOutcomeStrings* = failureOutcomeStrings
  ## The set of outcome JSON strings that count as "failed" for --failed.
  ## "passed" and "noTestsRan" are NOT in this set (noTestsRan is a summary
  ## flag, not an outcome string; outcome "passed" is success).
  ## Re-exported from crisol/outcomestrings for backward compatibility.

proc loadLastRun*(config: Config):
    tuple[found: bool; failed: HashSet[tuple[path, group: string]]] =
  ## Read <projectRoot>/<stateDir>/lastrun.json.
  ##
  ## Returns:
  ##   (found: false, failed: {})  — file does not exist (caller → exit 3).
  ##   (found: true,  failed: S)   — file parsed; S is the set of (path,group)
  ##                                 pairs whose outcome is a failure string.
  ##
  ## rfc-0007 A1d-i: a file written by the PRIOR schema ("crisol/run/v1") is
  ## ALSO treated as (found: false, failed: {}) -- cold start, not an error.
  ##
  ## Raises CrisolError(cekEnvironment) if the file exists but is malformed
  ## or carries some OTHER unrecognized schema version.
  let path = stateDirOf(config) / "lastrun.json"

  if not fileExists(path):
    return (found: false, failed: initHashSet[tuple[path, group: string]]())

  var raw: string
  try:
    raw = readFile(path)
  except OSError as e:
    raise newCrisolError(cekEnvironment,
      "could not read lastrun.json: " & e.msg)

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    raise newCrisolError(cekEnvironment,
      "lastrun.json is malformed JSON: " & e.msg &
      " — run `crisol run` first")

  # Validate schema version.
  if node.kind != JObject or not node.hasKey("schema"):
    raise newCrisolError(cekEnvironment,
      "lastrun.json is missing 'schema' field — run `crisol run` first")
  let schemaVal = node["schema"].getStr("")
  if schemaVal == LegacyRunV1Schema:
    # rfc-0007 A1d-i: a schema CHANGE is not something a byte-compatible
    # reader can partially trust -- the honest posture is "no data", exactly
    # like a missing file.  No error, no partial parse of v1's shape.
    return (found: false, failed: initHashSet[tuple[path, group: string]]())
  if schemaVal != RunSchema:
    raise newCrisolError(cekEnvironment,
      "stale lastrun.json (schema '" & schemaVal &
      "') — run `crisol run` first")

  # A8 forward tolerance: an absent schemaRevision is an old (rev-1) document and
  # is fully readable.  A revision GREATER than what we know is from a future
  # crisol whose additive fields we cannot interpret — treat as no-data (safe
  # cold-start), symmetric with loadLastPlan.  Caller handles found=false (exit 3).
  let rev = node.getOrDefault("schemaRevision").getInt(0)
  if rev > RunSchemaRevision:
    stderr.write("crisol: warning: lastrun.json schemaRevision " & $rev &
                 " is newer than this crisol understands (max " &
                 $RunSchemaRevision & "); ignoring it as cold-start\n")
    return (found: false, failed: initHashSet[tuple[path, group: string]]())

  # Parse entrypoints array.
  if not node.hasKey("entrypoints") or node["entrypoints"].kind != JArray:
    raise newCrisolError(cekEnvironment,
      "lastrun.json is missing 'entrypoints' array — run `crisol run` first")

  var failedSet = initHashSet[tuple[path, group: string]]()
  for ep in node["entrypoints"]:
    if ep.kind != JObject: continue
    let epPath    = ep.getOrDefault("path").getStr("")
    let epGroup   = ep.getOrDefault("group").getStr("")
    let epOutcome = ep.getOrDefault("outcome").getStr("")
    if epOutcome in FailureOutcomeStrings:
      failedSet.incl((path: epPath, group: epGroup))

  result = (found: true, failed: failedSet)

# ---------------------------------------------------------------------------
# closureToJsonString — issue #9 slice A: crisol/closure/v1
# ---------------------------------------------------------------------------

const ClosureV1Schema* = "crisol/closure/v1"
  ## Stable schema identifier embedded in every crisol/closure/v1 JSON document.

const ClosureV1Revision* = 2
  ## Integer minor revision of the crisol/closure/v1 schema (A8 convention).
  ##   rev 1 (implicit) — entries[]/warnings, as issue #9 slice A shipped it.
  ##   rev 2           — top-level `gatedOut` array (path, group, reason):
  ##                     mirrors crisol/plan/v1's own `gatedOut` field, now
  ##                     that a positional path whose only match is gated
  ##                     out is distinguishable from "no entrypoints matched"
  ##                     (see api.closureReport / ClosureReport.gatedOut).

proc closureToJson*(r: ClosureReport): JsonNode =
  ## Pure: serialize a ClosureReport to the crisol/closure/v1 JsonNode.  No I/O.
  ## Deterministic ordering: entries in plan order (as received); each
  ## entry's `closure` array is already sorted by api.closureReport().
  ##
  ## Each entry's `closure` array holds paths exactly as recorded in the
  ## depgraph: project-root-relative with forward slashes for files inside
  ## the project root, ABSOLUTE for files under a configured dep-root (see
  ## types.ClosureEntry.closure).
  ##
  ## `ClosureReport.adHocPaths` is deliberately NOT
  ## serialized here — crisol/plan/v1's planToJson (planview.nim) does not
  ## serialize DiscoveredSet's equivalent fields either; the CLI prints them
  ## as stderr text (render.pathFlagsWarnings) instead, for both `run`/`list`
  ## and `closure`.  Kept symmetric with plan/v1 rather than introducing a
  ## one-off JSON surface; revisit both schemas together if a machine-
  ## readable form is ever needed.  `gatedOut` (rev 2) IS serialized because
  ## plan/v1 already serializes its own `gatedOut` field — see planview.nim's
  ## planToJson.
  let entriesNode = newJArray()
  for e in r.entries:
    let eNode = newJObject()
    eNode["path"]        = newJString(e.path)
    eNode["group"]       = newJString(e.group)
    eNode["flagHash"]    = newJString(e.flagHash)
    eNode["recorded"]    = newJBool(e.recorded)
    let closureNode = newJArray()
    for f in e.closure:
      closureNode.add newJString(f)
    eNode["closure"]     = closureNode
    eNode["closureHash"] = newJString(e.closureHash)
    entriesNode.add eNode

  let gatedNode = newJArray()
  for g in r.gatedOut:
    let gNode = newJObject()
    gNode["path"]   = newJString(g.path)
    gNode["group"]  = newJString(g.group)
    gNode["reason"] = newJString(g.reason)
    gatedNode.add gNode

  result = newJObject()
  result["schema"]         = newJString(ClosureV1Schema)
  result["schemaRevision"] = newJInt(ClosureV1Revision)
  result["entries"]        = entriesNode
  result["gatedOut"]       = gatedNode
  result["warnings"]       = warningsToJsonArray(r.warnings)

proc closureToJsonString*(r: ClosureReport): string =
  ## Pure: compact JSON string of the crisol/closure/v1 document.
  $closureToJson(r)
