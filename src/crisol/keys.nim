## keys.nim — A2: IdentityKey and SoundnessKey derivation (RFC-0004).
##
## Sits BELOW the planner and ABOVE the stores.  Imports only `types` and
## `depgraph` (for `fnv1a64`, `toHex16`).  No import cycle is introduced.
##
## Both derivations are PURE — all effectful inputs are injected as params.
##
## Key designs:
##   IdentityKey  = fnv1a64 chain over (path, flagHash); stable locator.
##   SoundnessKey = chained FNV-1a fold over 9 components in fixed order with
##                  NUL separator between components, and each variable-length
##                  component placed LAST within its own per-component fnv1a64
##                  call (RFC-0004 round-2 rule: prevents embedded NUL bytes in
##                  binary fixture content from aliasing the inter-component NUL
##                  separator).

import std/options
import std/strutils
import std/tables
import std/algorithm
import crisol/types
import crisol/depgraph   # re-uses fnv1a64, toHex16, fnvOffset64; never reimplement
from crisol/process/types as ptypes import nil  ## qualified access to the
  ## §1 Limits/LimitKind shape (rfc-0007 A2a-iii) — house convention (see
  ## runner.nim/jsonout.nim/api.nim); NOT re-exported from crisol/types.

# ---------------------------------------------------------------------------
# Sentinel for an empty fixture glob set (no files → deterministic constant).
# Exported so consumers can document/test against it without knowing the impl.
# ---------------------------------------------------------------------------

const EmptyFixtureSentinel* = "crisol:empty-fixtures:v1"
  ## Used in the SoundnessKey chain when `fixtureHash` is empty ("").
  ## A test group with no fixtures glob set gets this deterministic constant
  ## rather than a hash of zero bytes, so "no fixtures" and "fixtures of empty
  ## content" cannot collide.

# ---------------------------------------------------------------------------
# KeyInputs — the single record bundling all 9 soundness inputs.
#
# Passing a record (not 9 positional args) is cleaner at the call site and
# makes adding a 10th input a non-breaking change at every call site.
# ---------------------------------------------------------------------------

type KeyInputs* = object
  closureContentHash*: string
    ## 64-bit chained-FNV-1a over the source closure (read from
    ## DepGraphEntry.closureHash; do NOT recompute in the key path).
  flagHash*:           string
    ## Compile flags hash (flagHash proc from depgraph).
  nimVersion*:         string
    ## Nim compiler version string (e.g. "2.2.10").
  ccVersion*:          string
    ## C compiler + libc fingerprint from ccprobe (injected; not called here).
  fixtureHash*:        string
    ## Content-hash of per-group fixtures glob set.
    ## Empty string ⇒ EmptyFixtureSentinel is substituted.
  argv*:               seq[string]
    ## Exact argv the test binary is invoked with.
  limits*:             ptypes.Limits
    ## Config-declared resource limit REQUESTS (NOT kernel-achieved limits) —
    ## the §1 enum-indexed shape (rfc-0007 A2a-iii; formerly `rlimitConfig:
    ## RlimitConfig`, folded into the single `Limits` home SandboxSpec now
    ## carries). The re-homing changes this fold-input's shape deliberately —
    ## free under the `resultCacheFormatVersion` bump (§5), which discards
    ## every existing cache entry regardless.
  hermeticEnvHash*:    string
    ## Hash of the names+values of every env var that actually reaches the
    ## hermetic child (post-allowlist-filter), computed by
    ## sandbox.hermeticEnvHash(filterEnv(parentEnv, spec, @[])).
    ## TMPDIR value is excluded (per-run random suffix; name is included).
    ## CRISOL_SINK and CRISOL_ATTEMPT are excluded entirely (per-run injections).
    ## WHY values: an allowlisted var is one tests are *allowed to depend on*,
    ## so its value is a real input; soundness (equal key ⇒ equal result)
    ## requires it in the key.  (RFC-0004 §Keys; cf. Bazel --action_env.)
  protocolMajor*:      int
    ## NDJSON protocol major version.

# ---------------------------------------------------------------------------
# Internal: chain a single component into a running FNV-1a state.
#
# RFC-0004 round-2 rule: "each variable-length component placed LAST within
# its own per-component fnv1a64 call".
#
# Strategy: we wrap each component value in one fnv1a64 call — the component
# value is the entire input to that call — then mix its 16-hex-char digest plus
# a NUL separator into the running chain:
#
#   running = fnv1a64(toHex16(running) & "\x00" & fnv1a64(component))
#
# The per-component fnv1a64 call binds the component's NUL bytes into the hash
# BEFORE the inter-component NUL separator is emitted, so an embedded NUL in
# the component cannot split across the separator boundary and alias a different
# split.
# ---------------------------------------------------------------------------

proc chainComponent(running: uint64; component: string): uint64 {.inline.} =
  ## Fold `component` into `running` using the per-component wrapping rule.
  let compDigest = toHex16(fnv1a64(component))
  fnv1a64(toHex16(running) & "\x00" & compDigest)

# ---------------------------------------------------------------------------
# limitsFoldString — stable string serialisation of `Limits`, shared by
# `soundnessKey` (folded into the chain) and `explainMiss` (carried verbatim
# as a KeyDiff.prev/curr value for the kcLimits component).
#
# rfc-0007 A2a-iii: LOOP-DRIVEN over LimitKind (no five copied stanzas) —
# format "<kindName>=<v>|..." in enum order, each value rendered as a decimal
# or the literal "-" when none.  Adding a LimitKind (B3's lkMemory) is
# therefore a compiler-forced, automatic addition to this fold, never a
# silently-missed sixth stanza.
# ---------------------------------------------------------------------------

proc limitsFoldString(limits: ptypes.Limits): string =
  proc optStr(o: Option[int64]): string =
    if o.isSome: $o.get else: "-"
  result = ""
  for kind in ptypes.LimitKind:
    if result.len > 0: result.add("|")
    result.add($kind & "=" & optStr(limits.req[kind]))

# ---------------------------------------------------------------------------
# IdentityKey derivation
# ---------------------------------------------------------------------------

proc identityKey*(path: string; flagHash: string): IdentityKey =
  ## Derive the stable identity locator for a test entrypoint.
  ## ``path`` is the project-root-relative entrypoint path.
  ## ``flagHash`` is the 16-hex-char flag set hash.
  ##
  ## The key is a stable hex string; it does NOT change when env, toolchain
  ## version, or fixture content changes — only when the entrypoint path or
  ## its compile flags change.  This makes it safe to use as the RunLedger
  ## primary key across env/toolchain upgrades.
  var h = fnv1a64("\x00" & path & "\x00" & flagHash)
  result = IdentityKey(toHex16(h))

# ---------------------------------------------------------------------------
# SoundnessKey derivation
# ---------------------------------------------------------------------------

proc soundnessKey*(inp: KeyInputs): SoundnessKey =
  ## Derive the soundness (cache) key for a test entrypoint.
  ##
  ## All 9 components are folded in FIXED ORDER via chained FNV-1a.  Each
  ## component is wrapped in its own per-component fnv1a64 call before being
  ## mixed into the running chain (RFC-0004 round-2 NUL-aliasing guard).
  ##
  ## An empty ``fixtureHash`` is replaced by ``EmptyFixtureSentinel`` before
  ## hashing so "no fixtures" and "fixtures of empty content" cannot collide.
  let fixH = if inp.fixtureHash == "": EmptyFixtureSentinel
             else:                     inp.fixtureHash

  # Derive a stable serialisation of `Limits` so it participates cleanly.
  let rlStr = limitsFoldString(inp.limits)

  # Argv is serialised as NUL-joined elements so per-element boundaries are
  # captured within the component value before the per-component wrapping.
  let argvStr = inp.argv.join("\x00")

  # Seed from FNV offset (not zero) for a non-trivial empty-component case.
  var running: uint64 = fnvOffset64   # re-use exported const from depgraph

  # 1. closureContentHash
  running = chainComponent(running, inp.closureContentHash)
  # 2. flagHash
  running = chainComponent(running, inp.flagHash)
  # 3. nimVersion
  running = chainComponent(running, inp.nimVersion)
  # 4. ccVersion
  running = chainComponent(running, inp.ccVersion)
  # 5. fixtureHash (sentinel-substituted)
  running = chainComponent(running, fixH)
  # 6. argvHash (derived inline from argv seq)
  running = chainComponent(running, argvStr)
  # 7. rlimitHash (derived inline from Limits, loop-driven over LimitKind)
  running = chainComponent(running, rlStr)
  # 8. hermeticEnvHash
  running = chainComponent(running, inp.hermeticEnvHash)
  # 9. protocolMajor
  running = chainComponent(running, $inp.protocolMajor)

  result = SoundnessKey(toHex16(running))

# ---------------------------------------------------------------------------
# explainMiss — RFC-0005 Stage B (§Miss-explanation), slice B1a.
#
# Pure diffing of two KeyInputs records, one KeyDiff per differing component,
# in fixed KeyComponent (== KeyInputs field) order.  No I/O, no sidecar: the
# path-keyed persistence that supplies `prev`/`prevEnv` from a prior run is
# B1b's concern; the CLI/render surface (`--explain-miss`) is B1c's.
# ---------------------------------------------------------------------------

type KeyComponent* = enum   ## names WHICH of the 9 key inputs differs; one
                             ## arm per KeyInputs field, in field order.
  kcClosure, kcFlags, kcNimVersion, kcCcVersion, kcFixtures, kcArgv,
  kcLimits, kcHermeticEnv, kcProtocol

type KeyDiff* = object
  component*: KeyComponent
  prev*, curr*: string
    ## The two component values, opaque-hash components left opaque and
    ## multi-line version text left as-is — rendering is B1c's job.
  envNames*: seq[string]
    ## kcHermeticEnv ONLY: the variable NAMES whose digest differs or which
    ## are present on only one side, sorted.  NEVER values — `prevEnv`/
    ## `currEnv` are themselves digests already (see `envDigest`), so no
    ## value ever reaches this type.  Empty for every other component.

proc envDigest*(env: seq[(string, string)]): seq[(string, string)] =
  ## Map each `(name, value)` pair to `(name, hash16(value))`.  The value
  ## itself is never retained — this is the exact shape B1b's sidecar
  ## persists (`envDigest → {inputs, envDigest}` per flagHash record), so
  ## a leaked sidecar file can never disclose a hermetic env VALUE, only
  ## which variable NAMES were present and a value fingerprint.
  result = newSeq[(string, string)](env.len)
  for i, pair in env:
    result[i] = (pair[0], toHex16(fnv1a64(pair[1])))

proc diffEnvNames(prevEnv, currEnv: seq[(string, string)]): seq[string] =
  ## Names whose digest differs between `prevEnv` and `currEnv`, or which
  ## are present on only one side.  `prevEnv`/`currEnv` are already digests
  ## (per-name `hash16(value)`, e.g. the output of `envDigest`) — this proc
  ## never sees a raw value.  Sorted; no duplicates.
  var prevMap = initTable[string, string]()
  for (name, digest) in prevEnv: prevMap[name] = digest
  var currMap = initTable[string, string]()
  for (name, digest) in currEnv: currMap[name] = digest

  result = @[]
  for name, digest in prevMap:
    if name notin currMap or currMap[name] != digest:
      result.add name
  for name in currMap.keys:
    if name notin prevMap:
      result.add name
  result.sort()

proc explainMiss*(prev, curr: KeyInputs;
                   prevEnv, currEnv: seq[(string, string)]): seq[KeyDiff] =
  ## PURE.  Diff `prev` against `curr`, one KeyDiff per differing component,
  ## in enum (== KeyInputs field) order.  No difference ⇒ empty seq.
  ##
  ## `prevEnv`/`currEnv` are per-name env DIGESTS (`seq[(name, hash16(value))]`,
  ## see `envDigest`) — never raw values.  They drive `KeyDiff.envNames` for
  ## the `kcHermeticEnv` component only; whether that component itself
  ## differs is still decided from `hermeticEnvHash` like every other
  ## component, so `explainMiss` stays consistent even if a caller passes
  ## envs that disagree with the recorded hash.
  result = @[]

  template addSimple(comp: KeyComponent; p, c: string) =
    if p != c:
      result.add KeyDiff(component: comp, prev: p, curr: c, envNames: @[])

  addSimple(kcClosure,    prev.closureContentHash, curr.closureContentHash)
  addSimple(kcFlags,      prev.flagHash,           curr.flagHash)
  addSimple(kcNimVersion, prev.nimVersion,         curr.nimVersion)
  addSimple(kcCcVersion,  prev.ccVersion,          curr.ccVersion)
  addSimple(kcFixtures,   prev.fixtureHash,        curr.fixtureHash)
  addSimple(kcArgv,       prev.argv.join(" "),     curr.argv.join(" "))
  addSimple(kcLimits,     limitsFoldString(prev.limits),
                          limitsFoldString(curr.limits))

  if prev.hermeticEnvHash != curr.hermeticEnvHash:
    result.add KeyDiff(component: kcHermeticEnv,
                        prev: prev.hermeticEnvHash, curr: curr.hermeticEnvHash,
                        envNames: diffEnvNames(prevEnv, currEnv))

  addSimple(kcProtocol, $prev.protocolMajor, $curr.protocolMajor)
