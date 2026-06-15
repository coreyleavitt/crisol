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
import crisol/types
import crisol/depgraph   # re-uses fnv1a64, toHex16, fnvOffset64; never reimplement

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
  rlimitConfig*:       RlimitConfig
    ## Config-declared resource limit constants (NOT kernel-achieved limits).
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

  # Derive a stable serialisation of RlimitConfig so it participates cleanly.
  # Format: "as=<v>|cpu=<v>|fsize=<v>|nofile=<v>|core=<v>" with each field
  # rendered as a decimal or the literal "-" when none.
  proc optStr(o: Option[int64]): string =
    if o.isSome: $o.get else: "-"
  let rlStr = "as=" & optStr(inp.rlimitConfig.limitAs) & "|" &
              "cpu=" & optStr(inp.rlimitConfig.limitCpu) & "|" &
              "fsize=" & optStr(inp.rlimitConfig.limitFsize) & "|" &
              "nofile=" & optStr(inp.rlimitConfig.limitNofile) & "|" &
              "core=" & optStr(inp.rlimitConfig.limitCore)

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
  # 7. rlimitHash (derived inline from RlimitConfig)
  running = chainComponent(running, rlStr)
  # 8. hermeticEnvHash
  running = chainComponent(running, inp.hermeticEnvHash)
  # 9. protocolMajor
  running = chainComponent(running, $inp.protocolMajor)

  result = SoundnessKey(toHex16(running))
