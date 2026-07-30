## objkey.nim — RFC-0006 Stage R, R2a: the FULL Stage-R soundness key.
##
## `objcache.nim` (R1) stores `(keyHash, keyPreimage) -> cached .o bytes` but
## takes both as GIVEN inputs — it deliberately does not compute the key
## (see its module doc). This module is that computation.
##
## ## Why this key is RICHER than Stage-M's `artifactKeyHash`
##
## `artifactid.artifactKeyHash` (Stage M) is keyed on `normalized .c content
## ⊕ full cc -M #include-closure content-hash` — enough to DETECT reuse
## candidates for the M-report's r_time/r_size ratios, where a false miss
## only costs a slightly-pessimistic ratio.
##
## The object CACHE has a stronger soundness bar: serving a `.o` built with
## different cc flags (optimization level, `-D` defines, target arch) or a
## different toolchain (`nim`/`cc` version) as a hit for THIS compile would
## silently substitute a binary-incompatible object — a correctness bug, not
## a missed-optimization. So `stageRKey` folds in two more components Stage M
## deliberately left out: the (normalized) cc COMMAND itself, and the
## `nimVersion`/`ccVersion` toolchain fingerprint.
##
## Key material (RFC-0006 §Soundness): **normalize(ccCommand) ⊕
## normalize(cContent) ⊕ ccDashM_IncludeClosure ⊕ nimVersion ⊕ ccVersion**.
##
## This module computes the DERIVATION only; it does no I/O of its own —
## `normalize`/`ccIncludeClosure` (both reused verbatim from `artifactid.nim`,
## never reimplemented) take the real `cc -M` run seam and file-reader seam as
## injected params, so this module stays pure and its tests never shell out.
##
## ## Preimage framing — length-delimited (netstring-style), collision-free
##
## `objcache.storeObject`/`lookupObject` persist `keyPreimage` verbatim and
## re-derive it on every lookup to CONFIRM a digest hit (R1's collision
## defense: a digest match with a preimage mismatch is `ocdCollisionReject`,
## never served). That confirmation is only sound if the preimage string is
## an UNAMBIGUOUS encoding of the five components — two distinct component
## tuples must never serialize to the same preimage string, or a genuine
## input change could silently confirm-match a stale cached object.
##
## A plain separator-joined concatenation (e.g. NUL-joined) does not
## guarantee this: a component boundary can alias across two different
## splits if a component's own content happens to contain the separator byte
## at the right offset (e.g. `("a", "b\x00c")` vs `("a\x00b", "c")` NUL-join
## to the identical string `"a\x00b\x00c"`).
##
## `stageRKey` instead uses **length-delimited framing** — each component is
## written as `<decimal byte length>":"<raw component bytes>`, and the five
## frames are concatenated in FIXED order (ccCmd, cContent, includeClosure,
## nimVersion, ccVersion). This is the netstring/bencode idiom: a reader can
## always recover the exact component boundaries by reading the decimal
## length prefix up to the next `:`, then consuming exactly that many raw
## bytes — regardless of what bytes (including digits, `:`, or NUL) appear
## inside the component. Two distinct 5-tuples of components therefore
## ALWAYS serialize to two distinct preimage strings: the framing is
## injective, not merely "unlikely to collide" like a bare separator join.
##
## `keyHash` is then simply `toHex16(fnv1a64(preimage))` — hashing the
## already-injective preimage directly is sufficient (no need for a
## per-component chained fold on top of an already-unambiguous string); the
## fold idiom `keys.chainComponent`/`artifactid.chainComponent` earns its
## keep specifically where a chained per-component wrap is what MAKES the
## preimage unambiguous, which here is already provided by the framing.

import crisol/depgraph    # re-uses fnv1a64, toHex16; never reimplement the hash
import crisol/artifactid  # re-uses normalize, ccIncludeClosure, FileReaderProc, RunProc

export artifactid.FileReaderProc
export artifactid.RunProc

# ---------------------------------------------------------------------------
# Preimage framing
# ---------------------------------------------------------------------------

proc frame(component: string): string {.inline.} =
  ## Netstring-style length-delimited frame: `<byte length>":"<raw bytes>`.
  ## Injective across arbitrary byte content — see module doc §Preimage framing.
  $component.len & ":" & component

# ---------------------------------------------------------------------------
# Public: stageRKey
# ---------------------------------------------------------------------------

proc stageRKey*(cContent, ccCmd: string; knownStrings: seq[string];
                nimVersion, ccVersion: string;
                ccMRun: RunProc = artifactid.realRun;
                readFile: FileReaderProc = artifactid.realFileReader):
    tuple[keyHash: string; preimage: string; ok: bool] =
  ## The full Stage-R object-cache key (see module doc §Key material).
  ##
  ## Computes, via `artifactid.nim`'s reused primitives:
  ##   - `ncmd` = `normalize(ccCmd, knownStrings, readFile)`
  ##   - `nc`   = `normalize(cContent, knownStrings, readFile)`
  ##   - `inc`  = `ccIncludeClosure(ccCmd, ccMRun, readFile)`
  ## then frames `(ncmd, nc, inc.contentHash, nimVersion, ccVersion)` — in
  ## that fixed order — into `preimage` (§Preimage framing), and `keyHash =
  ## toHex16(fnv1a64(preimage))`.
  ##
  ## **R1 (soundness-critical) — `ok` propagates the include-closure probe's
  ## own `ok` flag.** `ccIncludeClosure.ok = false` means the `cc -M` probe
  ## itself failed (or, per R1b/R4, couldn't even be cleanly derived) — the
  ## closure component is UNKNOWN, not empty. Previously this proc read only
  ## `.contentHash` (empty on failure) and folded that empty string into an
  ## otherwise-NORMAL, non-empty key: two units with genuinely different real
  ## header closures but identical `.c` + cc command would both collapse to
  ## `inc=""`, produce IDENTICAL preimages, and the preimage-confirmation
  ## defense would PASS — a `.o` built against different headers served as a
  ## confirmed hit. `ok` is now `false` (with `keyHash`/`preimage` BOTH "")
  ## whenever the closure probe failed, so a caller (`measureworker.
  ## buildCacheKeyOf`) can — and must — treat this exactly like its other
  ## degrade branches (entry unit / no `-o` / unreadable `.c`): empty
  ## `keyHash` signals NON-CACHEABLE to `compiledriver.newCacheDriver`, never
  ## a real key that could confirm-match a stale/wrong cached object.
  ##
  ## PURE: every effect (the real `cc -M`, real `readFile`) arrives only via
  ## the injected `ccMRun`/`readFile` seams — this proc itself does no I/O.
  let ncmd = artifactid.normalize(ccCmd, knownStrings, readFile)
  let nc   = artifactid.normalize(cContent, knownStrings, readFile)
  let closureRes = artifactid.ccIncludeClosure(ccCmd, ccMRun, readFile)
  if not closureRes.ok:
    return (keyHash: "", preimage: "", ok: false)
  let inc = closureRes.contentHash

  let preimage = frame(ncmd) & frame(nc) & frame(inc) &
                 frame(nimVersion) & frame(ccVersion)
  let keyHash = toHex16(fnv1a64(preimage))
  result = (keyHash: keyHash, preimage: preimage, ok: true)
