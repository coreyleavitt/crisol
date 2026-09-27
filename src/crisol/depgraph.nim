## depgraph.nim — D2: persisted source-dependency graph.
##
## Stores and loads the per-(entrypoint, flag-set) source-dependency closures
## that power impact analysis (D3+D4) and compile avoidance (D6).
##
## ## On-disk format
##
## JSON written atomically to `<projectRoot>/<stateDir>/depgraph`.
##
## ```json
## {
##   "header": {
##     "nimVersion":     "<string>",   -- e.g. "2.2.10"
##     "ccVersion":      "<string>",   -- W3: C toolchain identity, shaped
##                                     -- "<cc text> #<hex>|<runtime text>
##                                     -- #<hex>" (toolchainwarn.
##                                     -- toolchainIdentity). OPTIONAL on read
##                                     -- (absent -> ""; see DepGraphHeader.
##                                     -- ccVersion's doc) -- always written.
##     "formatVersion":  <int>,        -- DepGraphFormatVersion
##     "roots": [                      -- RFC-0009 A3c-i: this file's OWN local
##       {                             -- name/foldPolicy table, in TrackedRoots
##         "name":       "<string>",   -- order (project first). "" name =
##         "foldPolicy": "<string>"    -- project root; "fpNone"/"fpAsciiLower"
##       },                            -- = that root's PROBED FoldPolicy at
##       ...                          -- the time this file was last saved.
##     ]                              -- No ordinal tag is persisted here (RFC-
##                                     -- 0009 W1) -- a closure member (below)
##                                     -- already names its root by NAME, so a
##                                     -- header-only tag would be write-only
##                                     -- (nothing ever reads it back).
##   },
##   "entries": [
##     {
##       "path":          "<string>",       -- entrypoint path (project-root-relative)
##       "flagHash":      "<16 hex chars>", -- 64-bit FNV-1a over sorted flags
##       "closure":       ["<string>", ...] -- each member in its keyBytes spelling
##                                           -- (RFC-0009 W1, paths.keyBytes): a
##                                           -- project-root member is project-
##                                           -- root-relative, forward-slashed,
##                                           -- unchanged from before; a dep-root
##                                           -- member is `dep:<name>/<rel>`.
##       "closureHash":   "<16 hex chars>", -- 64-bit chained FNV-1a over sorted closure file CONTENTS
##       "protocolMajor": <int>             -- crisol protocol major at build time
##     },
##     ...
##   ]
## }
## ```
##
## ## Key shape
##
## `(path: string, flagHash: string)` — a `Table[(string, string), DepGraphEntry]`.
## `flagHash` is 64-bit FNV-1a over the sorted, NUL-joined flag list, rendered as
## 16 lower-case hex chars.  `std/hashes` is NOT used (not stable across Nim versions).
##
## ## Invalidation rules
##
## - **Nim-version mismatch** (header): whole graph → empty (treat as absent).
##   This is a FRESHNESS judgment, not a fact about the stored file — see
##   "Two loaders" below for who applies it.
## - **Cc-version mismatch** (header, W3): the SAME treatment as a Nim-version
##   mismatch, for `header.ccVersion` (the C toolchain fingerprint) — whole
##   graph → empty (treat as absent), `loadDepGraph`-only, checked right
##   after the Nim-version check. This loader is the ONLY place the comparison
##   happens: `planner.decideCompile` carried an identical one until round 5
##   (R3-8) removed it as unreachable, since a graph that reaches
##   `decideCompile` has already been through this discard and had its header
##   re-stamped. Before this field existed, a C toolchain upgrade with an
##   unchanged Nim version was invisible — the defect this field closes.
## - **Missing file** in closure: `isEntryStale` returns true.
## - **Absent entry**: `isEntryStale` returns true.
## - **Deleted-entrypoint GC**: `gcDeletedEntrypoints` drops keys absent from the
##   provided current-entrypoint set.
## - **Unknown root name** (header, RFC-0009 A3c-i): a persisted `roots` entry
##   whose `name` does not resolve against the CURRENT `config.trackedRoots`
##   (a renamed/removed dep root) → whole graph → empty (treat as absent).
##   `loadDepGraph`-only, exactly like the nimVersion mismatch above — this is
##   depgraph-HEADER validity, never a cache/ledger version concern (§4).
## - **FoldPolicy mismatch for a name that still resolves** (header,
##   RFC-0009 A3c-i): the persisted `foldPolicy` for a root name differs from
##   that root's CURRENT probed policy → whole graph → empty (treat as
##   absent), never compared cross-policy. `loadDepGraph`-only.
##
## ## Two loaders — stored vs. freshness view (issue #12)
##
## `loadStoredDepGraph*(config; discarded)` loads the graph AS PERSISTED: the
## header's `nimVersion` is preserved verbatim, with no comparison against
## "the current Nim version" at all. It still discards on a formatVersion
## mismatch or a malformed/unreadable file (those are facts about the
## stored bytes, not about freshness), and it still applies the M10
## on-disk-tamper guard to closure paths. A missing file loads as an empty
## graph with header nimVersion `""`.
##
## `loadDepGraph*(config; nimVersion; discarded; ccVersion)` is
## `loadStoredDepGraph` PLUS a freshness view: if the stored header's
## `nimVersion` disagrees with the caller's `nimVersion` (and that
## disagreement is observable — an inert `""`-header graph with zero
## entries, e.g. "no file yet", never counts), the graph is treated as
## absent (`dgdNimVersion`) and an empty graph stamped with the REQUESTED
## `nimVersion`/`ccVersion` is returned instead. The SAME check then runs
## for `ccVersion` (W3) against `header.ccVersion`, `dgdCcVersion` on an
## observable mismatch — checked only once the nimVersion check has already
## passed, so a simultaneous nim+cc change is always reported as
## `dgdNimVersion`.
##
## Callers that make staleness/compile-avoidance decisions (`run`,
## `closure`, `list`, ...) MUST use `loadDepGraph` — a graph recorded by a
## different compiler OR C toolchain cannot be trusted for those decisions.
##
## `crisol clean` MUST use `loadStoredDepGraph` instead: it only GCs the
## on-disk entry set against the discovered entrypoints and re-saves. Using
## the freshness view there was issue #12's bug — a graph written by the
## real pipeline is always stamped with the real probed Nim fingerprint
## (never `""`), so calling the freshness loader with the wrong/absent
## expected version (crisol clean historically passed `""`) discarded the
## WHOLE graph as empty before GC ever ran — so a clean GC'd nothing and
## reported 0 dropped on every real graph. `loadStoredDepGraph` sidesteps
## the whole problem: it never compares versions, so a clean cannot discard
## a real graph, and its save path (see `clean.nim`) never rewrites the
## header — `cleanOrphans` passes `saveDepGraph`'s `preserveHeaderRoots:
## true` for exactly this reason (RFC-0009 wiring-audit fix: this contract
## used to be aspirational only — `saveDepGraph` re-stamped `header.roots`
## from the CURRENT config unconditionally, so a dep-root rename followed
## by a clean that GC'd anything at all silently laundered the rename past
## the next `loadDepGraph`'s `dgdRootUnknown` check; see `saveDepGraph`'s
## own doc for the fix).
##
## ## Atomic writes
##
## `saveDepGraph` writes to `<depgraph>.tmp` in the same directory, then calls
## `moveFile` (rename(2)) for an atomic replacement.  Readers always see either
## the old or the new file, never a torn write.

import std/[algorithm, json, options, os, sequtils, sets, strutils, tables]
import crisol/types
import crisol/config   # for stateDirOf
import crisol/closure  # for extractClosure/extractCompileInputs/SourceIndex/
                        # ExternalSource (recordClosure); no cycle — closure.nim
                        # imports crisol/types, paths, config, ccprobe, toolrun
                        # and fnv — never crisol/depgraph (see closure.nim's
                        # import comment for why: this module importing
                        # crisol/artifactid would have closed that cycle,
                        # issue #16).
import crisol/paths     # RFC-0009 A3c-ii: TrackedPath/TrackedRoots/classify/
                        # fromCanonical/cmpKeyBytes/display/toNative/
                        # PathClass/pcTracked/pcOutside for DepGraphEntry.
                        # closure's TrackedPath retype.
import crisol/toolrun   # for RunProc/realRunIn (recordClosure's ccRun param).
                        # CR7: this module needs only the process-execution
                        # seam, neither cc-identity nor cc-dependency-probing
                        # symbols, so it imports the seam's own module
                        # directly rather than reaching through either half
                        # of the old ccprobe.nim.
from crisol/ccprobe import DriverResolver
                        # recordClosure's `driver` param (R10-S6): the types
                        # alone; ccprobe is a pure leaf, no cycle.
import crisol/ioutils  # sanitizeControlBytes (the shared control/ANSI-byte
                        # sanitization primitive — bottom of the dep graph, no
                        # cycle) and atomicPublish (saveDepGraph's writer,
                        # RFC-0007 A3)
import crisol/fnv       # FNV-1a primitives (fnv1a64/toHex16/fnvOffset64/
                        # fnvPrime64) and chainedContentHash — a leaf module,
                        # re-exported below so every existing
                        # `import crisol/depgraph` call site that uses these
                        # unqualified keeps compiling unchanged.
export fnv

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const DepGraphFormatVersion* = 10
  ## Increment this when the JSON schema changes in an incompatible way.
  ## A loaded file with a different formatVersion is treated as absent.
  ##
  ## NOT bumped for the RFC-0009 wiring-audit `looksLikeDepEscape`
  ## injectivity fix (`paths.nim`): a tag-0 rel whose first segment is
  ## `dep:` with an empty or colon-containing "name" half (e.g. a real
  ## on-disk directory literally named `dep:` or `dep:a:b`) now escapes to
  ## `"./dep:.../..."` instead of the bare, unescaped `"dep:.../..."` v7
  ## wrote for it. That bare spelling was NEVER correctly representable —
  ## v7's `fromKeyBytes` routes any `"dep:"`-prefixed string into its dep-
  ## root arm and rejects an empty/colon-bearing name, so every prior
  ## write of one of these pathological rels already silently DROPPED that
  ## closure member on the very next load (the bug this fix closes), never
  ## round-tripped it. No currently-persisted v7 file can contain a
  ## closure member whose spelling changes meaning under the fix — the
  ## only bytes affected are ones that read back as `none` before AND
  ## would still read back as `none` now if encountered unescaped (see
  ## `fromKeyBytes`'s dep-root-arm doc): the fix only changes what a FRESH
  ## write of such a rel produces going forward. An ordinary `dep:foo/...`
  ## (well-formed name) is byte-identical before and after — untouched.
  ## A discard-and-recompute bump exists to protect against a schema
  ## change altering the MEANING of already-persisted bytes; this fix
  ## alters the meaning of bytes that were never persisted correctly in
  ## the first place, so there is nothing for a bump to protect.
  ##
  ## History:
  ##   10 — issue #25: each entry gains `links` — every symlink its closure
  ##       members may have been reached through (`closure.crossedLinks`),
  ##       with the link's resolved target at record time. Nim records a
  ##       module by its realpath, so a module imported through a link
  ##       (`vend/m`, `vend -> libs/a`) entered the closure as
  ##       `libs/a/m.nim` with `vend` nowhere; repointing `vend` left every
  ##       recorded member unchanged, and `decideCompile` served the stale
  ##       binary as fresh (and, through it, a stale cached result). `links`
  ##       is re-resolved by `decideCompile` and `isEntryStale`
  ##       (`entryDrift`, `dkMoved`). Bump direction: DISCARD. A v9 entry has no `links`
  ##       field and would read back as "crossed no link", exempting exactly
  ##       the entries this fixes from the new check; the bump discards the
  ##       graph once (a one-time full recompile) instead, like every prior
  ##       bump. The result-cache key is unchanged: it is derived from the
  ##       closure a compile actually recorded, which already names the
  ##       files the binary was built from; only the compile-skip decision
  ##       trusted a closure it could not see was out of date.
  ##   9 — W3 (wiring-audit finding, re-verified 2026-09-21): `decideCompile`
  ##       was blind to the C toolchain while its `nimVersion` sibling was
  ##       fully wired -- upgrading cc without changing Nim left
  ##       `decideCompile` returning `cdSkipFresh`, silently serving a stable
  ##       binary linked by the OLD cc under the NEW toolchain's soundness
  ##       key (cross-host cache poisoning by under-invalidation -- see W3's
  ##       handoff note). `DepGraphHeader` gains `ccVersion` -- the
  ##       depgraph-header sibling of `nimVersion` -- and `loadDepGraph`
  ##       gains the matching `dgdCcVersion` freshness discard.
  ##
  ##       Bump direction: DISCARD, not silent misparse. A v8 file has no
  ##       `ccVersion` field at all; `fromJson` treats it as OPTIONAL at the
  ##       shape-validation layer (absent -> "", mirroring `roots`' v6
  ##       precedent above -- NOT `nimVersion`/`formatVersion`'s required
  ##       treatment), so a v8 file would in principle still PARSE under a
  ##       v9 reader without this bump. The bump is taken anyway, for the
  ##       same reason v6 took one for `roots`: a v8 file was written by a
  ##       pipeline that never probed cc at all, so every one of its entries
  ##       is permanently exempt from the new cc-version freshness check
  ##       (an absent header field reads back as `ccVersion == ""`, which
  ##       only ever matches a caller that ALSO passes `ccVersion == ""` --
  ##       i.e. a caller with no real probe, exactly the "" = disable-this-
  ##       check convention this loader already uses for `nimVersion` -- the
  ##       convention was `decideCompile`'s too until R3-8 removed its arms) -- a REAL pre-W3 file, reused verbatim post-fix,
  ##       would need its very next `crisol run` (which DOES pass a real
  ##       probed `ccVersion`) to observe a "" -> real mismatch and discard
  ##       it anyway, so the bump merely makes that one-time discard happen
  ##       at load instead of via a freshness comparison one run later --
  ##       a one-time full recompile either way, never a silent misparse:
  ##       decode of an old (v8) graph under the v9 reader fails cleanly via
  ##       `dgdFormatVersion`, exactly like every prior bump.
  ##   8 — RFC-0009 F13 (wiring-audit finding): `entry.externals[].source`
  ##       and `.headers[]` are now serialized in their `paths.keyBytes`
  ##       spelling (`closure.closureMemberSpelling`), the SAME portable
  ##       grammar W1 (below) already gave `entry.closure` — never a
  ##       machine-local absolute path. A v7 file's dep-root externals
  ##       (`source`/`headers` entries under a configured dep root) are
  ##       exactly the absolute-native spellings this bump retypes: they
  ##       cannot be re-attributed to their root after the fact (an absolute
  ##       path alone no longer round-trips through `fromKeyBytes`, which
  ##       only ever accepts a `dep:<name>/<rel>`/plain-rel/`./`-escaped
  ##       spelling — see that proc's doc), so the graph is discarded once
  ##       — a one-time full recompile — rather than migrated in place,
  ##       exactly like every prior bump below. A v7 file's PROJECT-tagged
  ##       externals are byte-identical (a tag-0 `keyBytes` spelling was
  ##       already the pre-F13 project-relative spelling, `dep:`-escape
  ##       aside), but the bump discards the whole graph anyway — the
  ##       format is versioned as a whole, not per-field.
  ##   7 — RFC-0009 W1 (wiring-audit fix): each closure member is now
  ##       serialized in its `paths.keyBytes` spelling instead of a bare
  ##       `display(tp)` rel, so a dep-root member round-trips back to its
  ##       OWN root tag instead of `classify`'s project-first join
  ##       re-tagging it as a phantom tag-0 project path (the read side now
  ##       uses `paths.fromKeyBytes`, the keyBytes grammar's inverse, in
  ##       place of `classify`). The header's per-root `tag` column is
  ##       dropped — nothing ever read it back, a closure member already
  ##       names its root by NAME. A v6 file's dep-root closure members are
  ##       exactly the phantom tag-0 spellings this bump fixes: they cannot
  ##       be re-attributed to their real root after the fact (the bare rel
  ##       string alone no longer tells you which root it came from), so
  ##       the graph is discarded once — a one-time full recompile — rather
  ##       than migrated in place, exactly like every prior bump below.
  ##   6 — RFC-0009 A3c-i: the header gains `roots` — this file's own local
  ##       tag->name table, and each named root's probed `foldPolicy` at save
  ##       time (`DepGraphHeader.roots`; never a bare ordinal — see the type
  ##       doc). A v5 file has no such table; upgrading it in place would
  ##       leave every one of its entries permanently exempt from the new
  ##       root-name/foldPolicy validity check `loadDepGraph` now performs
  ##       (see "Invalidation rules", above) — indistinguishable from a
  ##       config that genuinely has no dep roots. The bump discards the
  ##       graph once (a one-time full recompile) rather than serve or
  ##       migrate it, exactly like every prior bump below.
  ##   5 — issue #16: a `{.compile.}`d external's `#include`d headers are
  ##       tracked compile inputs. `DepGraphEntry` gains `externals` (one
  ##       `closure.ExternalSource` per single-path external: its source
  ##       path, object basename, and header set), and every header now also
  ##       joins `closure`/`closureHash` itself (`closure.extractCompileInputs`
  ##       replaces `extractClosure` as `recordClosure`'s extraction call).
  ##       Every v4 entry's `closure` is missing whatever headers its
  ##       externals (if any) `#include` — under-selecting exactly like a v3
  ##       entry was missing `{.compile.}`d sources themselves (issue #11) —
  ##       so the graph is discarded once (a one-time full recompile) rather
  ##       than served or migrated in place.
  ##   4 — issue #11: closures also cover non-module compile inputs —
  ##       `include`d files, `staticRead`/`slurp` targets, `nim.cfg`/
  ##       `config.nims` (from the manifest's `depfiles`, written under the
  ##       `-d:nimBetterRun` define crisol now injects), `{.compile.}`d
  ##       C/C++/ObjC sources and `{.link.}`ed prebuilt objects (from the
  ##       `link` array). Every v3 closure is incomplete in a way that
  ##       cannot be healed in place: a closure missing an input
  ##       hash-matches itself forever, so the entrypoint would stay fresh
  ##       across edits to that input, and its stable nimcache manifest
  ##       (compiled without the define) carries no `depfiles` to re-derive
  ##       from. The bump discards the graph once — a one-time full
  ##       recompile under the new define — rather than serve it.
  ##   3 — issue #5: closures are derived from the nimcache `link` array.
  ##       Every v2 entry is suspect (any entry rewritten after a warm
  ##       recompile is truncated or empty — see DepGraphEntry.closure,
  ##       invariant NONEMPTY-CLOSURE — so upgrading alone cannot heal it);
  ##       the bump discards the whole graph once — a one-time full
  ##       recompile — rather than serve it.
  ## v2: added closureHash and protocolMajor fields.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DepGraphHeader* = object
    nimVersion*:    string  ## Nim version string (e.g. "2.2.10")
    formatVersion*: int     ## DepGraphFormatVersion
    ccVersion*:     string
      ## W3: the depgraph-header sibling of `nimVersion` -- the C toolchain
      ## identity (`toolchainwarn.toolchainIdentity`: `$CcFingerprint`,
      ## "<cc text> #<hex>|<runtime text> #<hex>", for an identified
      ## toolchain; that string plus a per-run nonce for an unidentified one,
      ## so an unidentified toolchain never matches any stored header, its
      ## own included) in effect the last time this graph's entries were
      ## recorded. Compared by `loadDepGraph` against the caller's
      ## CURRENT cc fingerprint exactly like `nimVersion` (`dgdCcVersion` on
      ## mismatch). `planner.decideCompile` compared it too until round 5
      ## (R3-8) removed that arm as unreachable -- by the time a graph reaches
      ## `decideCompile` this loader has already discarded a mismatched one and
      ## re-stamped the header, so the comparison could never fire. A cc
      ## upgrade with an unchanged Nim version must discard/recompile exactly
      ## as a Nim upgrade already does; before this field existed nothing could
      ## see a cc change at all (the W3 defect: a stable binary linked by an
      ## OLD cc would be served as fresh under a NEW toolchain's soundness
      ## key).
      ##
      ## OPTIONAL at parse time (`fromJson`, below): absent -> "" (mirrors
      ## `roots`' v6 leniency for a hand-built pre-this-field fixture, NOT
      ## `nimVersion`/`formatVersion`'s required treatment -- see
      ## `DepGraphFormatVersion`'s v9 history entry for why the bump alone
      ## already makes this leniency safe in production: `saveDepGraph`
      ## always writes it, exactly like `nimVersion`).
      ##
      ## Both inputs empty (`nimVersion == "" and ccVersion == ""`) is the
      ## same "no probe available -- test/cold-start caller" sentinel
      ## `nimVersion == ""` alone already was; a caller with a real
      ## `nimVersion` but no cc probe is not a supported combination in
      ## production (the api boundary probes both together, see
      ## `toolchainFingerprint`'s doc) and is treated the same as any other
      ## observable mismatch.
    roots*: seq[tuple[name: string; foldPolicy: FoldPolicy]]
      ## RFC-0009 A3c-i: this FILE's own local name/foldPolicy table, one
      ## record per root tracked when the graph was last saved — project
      ## root first (`name: ""`), then each configured dep root in
      ## `TrackedRoots` order. `foldPolicy` is that root's own PROBED policy
      ## at save time (never re-derived from the in-memory value later — see
      ## `saveDepGraph`, the sole producer).
      ##
      ## No ordinal `tag` column (RFC-0009 W1 — dropped; previously present
      ## but read by nothing): a closure member (`DepGraphEntry.closure`)
      ## already names its own root by NAME via its `paths.keyBytes`
      ## spelling (`dep:<name>/<rel>`), so a tag here would be entirely
      ## write-only. Root identity in this header was ALWAYS resolved by
      ## `name` (see the load-time validation below) — the tag never did
      ## any work even before this bump.
      ##
      ## Populated at SAVE time from `config.trackedRoots` (`saveDepGraph`),
      ## not at construction (`initDepGraph` has no `Config` to source it
      ## from) — every real on-disk file therefore always carries the roots
      ## as of its last write; an in-memory graph between load and save may
      ## carry a stale or empty `roots` inherited from disk, which is
      ## harmless (nothing reads this field except the save path that is
      ## about to overwrite it, and the load-time validation below, which
      ## only ever runs against the just-loaded, on-disk value).
      ##
      ## Consumed at load time by `loadDepGraph` (never `loadStoredDepGraph`
      ## — this is depgraph-header validity, not a cache/ledger version
      ## concern, §4): each entry's `name` is looked up against the CURRENT
      ## `config.trackedRoots`; an unresolvable name (`dgdRootUnknown`) or a
      ## `foldPolicy` that resolves but disagrees with the current probe
      ## (`dgdFoldMismatch`) discards the whole graph as absent, never
      ## compared cross-policy.

  DepGraphEntry* = object
    closure*:       HashSet[TrackedPath]
      ## project-root-relative closure paths.
      ##
      ## Invariant NONEMPTY-CLOSURE: a compiled entrypoint's closure always
      ## contains at least the entrypoint itself, so an empty closure is
      ## never a plausible scan result — it is a crisol defect (manifest
      ## misread, demangle regression, entrypoint outside every tracked
      ## root).  Recording one would make the entry permanently fresh (the
      ## content hash over nothing matches forever), so decideCompile, the
      ## result-cache key, and `--changed` selection could never observe a
      ## change.  `updateEntry` refuses to write an empty closure;
      ## `loadDepGraph` drops any that reach disk anyway (defense in depth).
      ## Every other site that touches this rule is a pointer back here.
    closureHash*:   string           ## 64-bit chained FNV-1a over sorted closure file CONTENTS (16 hex)
    protocolMajor*: int              ## crisol protocol major at build time
    externals*:     seq[ExternalSource]
      ## One entry per single-path `{.compile.}`d external this entrypoint
      ## names (issue #16) — its source path, object basename, and the
      ## header set it `#include`s. Every header here is ALSO a member of
      ## `closure` (closure/`--changed` selection see headers directly);
      ## this field exists so a WARM recompile — where Nim serves the
      ## external's object from its own cache and the manifest carries no
      ## `cc` command to re-probe — can carry the header set FORWARD instead
      ## of losing it (`closure.extractCompileInputs`'s `carried` parameter,
      ## fed from this field on the entry's previous `recordClosure`).
      ##
      ## RFC-0009 F13: `ExternalSource.source`/`.headers` are portable
      ## `paths.keyBytes` spellings (never a machine-local absolute path,
      ## even for a dep-root source/header) — see that type's own doc in
      ## `crisol/closure`.
    links*:         seq[ClosureLink]
      ## Issue #25: every symlink a closure member may have been reached
      ## through, with its resolved target at record time
      ## (`closure.crossedLinks`). Empty for the common entry that crossed
      ## none. With `closure`, it is the entry's WATCHED SET: `entryDrift`
      ## re-resolves each link (`dkMoved`) for `planner.decideCompile` and
      ## `isEntryStale`, and `diffReach` selects the entry under `--changed`
      ## when a changed name reaches one (`narrow.narrowByDiff` rule 5).
      ##
      ## ABSENCE IS LOAD-BEARING. A directory on a member's path that is a
      ## link NOT in this list is drift (`dkUnrecorded`, R13-S1): the entry
      ## is stale until a recompile records it. So an entry recorded without
      ## the links its members were reached through is stale on every run,
      ## and one recorded with a link it never crossed would exempt that
      ## link's subtree from the check. `updateEntry` therefore takes
      ## `links` as a REQUIRED argument (R12-D6, R14-D2): `recordClosure`
      ## passes `closure.crossedLinks` from the same run's `SourceIndex`, and
      ## no record path can leave it out by forgetting a field assignment.

  DriftKind* = enum
    ## What moved on the file system under an entry's watched set since the
    ## record (`entryDrift`). Checked in this order; the first found wins.
    dkMissing     ## a closure member no longer exists
    dkMoved       ## a recorded link no longer leads to its recorded target
                  ## (repointed, deleted, or replaced by a file or directory)
    dkUnrecorded  ## a directory on a member's path is now a link the entry
                  ## did not record (R13-S1)

  Drift* = object
    ## Evidence that an entry is stale (`entryDrift`).
    kind*: DriftKind
    path*: TrackedPath
      ## The missing member (`dkMissing`), the recorded link (`dkMoved`),
      ## or the directory that is now a link (`dkUnrecorded`).

  HitKind* = enum
    ## How a changed set reaches an entry's watched set (`diffReach`).
    ## Checked in this order; the first found wins.
    hkMember      ## a changed name is a closure member
    hkLink        ## a changed name is a recorded link, or a directory above one
    hkUnderLink   ## a changed name lies under a recorded link (git names the
                  ## files it sees through a Windows junction)
    hkAncestor    ## a changed name is a directory above a closure member
                  ## (a directory replaced as a whole, R13-S1)

  Hit* = object
    ## Evidence that a changed set selects an entry (`diffReach`).
    kind*:    HitKind
    name*:    TrackedPath
      ## The changed name, spelled as the changed set holds it.
    watched*: TrackedPath
      ## What it reached, spelled as the entry records it: the member
      ## (`hkMember`, `hkAncestor`) or the recorded link (`hkLink`,
      ## `hkUnderLink`). Under a case fold the two spellings can differ.

  DepGraphDiscardKind* = enum
    ## Why `loadDepGraph` discarded a persisted graph.
    dgdNone           ## no file, or loaded cleanly
    dgdNimVersion     ## header.nimVersion != current compiler fingerprint
    dgdCcVersion      ## W3: header.ccVersion != current C toolchain
                      ## fingerprint -- the cc-version sibling of
                      ## dgdNimVersion, checked the same way (never compared
                      ## when the nimVersion check already discarded first).
    dgdFormatVersion  ## header.formatVersion != DepGraphFormatVersion
    dgdMalformed      ## file present but unreadable, unparseable, or an unexpected shape
    dgdRootUnknown    ## RFC-0009 A3c-i: a persisted header root NAME does not
                      ## resolve against the CURRENT config.trackedRoots (a
                      ## renamed/removed dep root) — `loadDepGraph` only,
                      ## never `loadStoredDepGraph` (depgraph-header
                      ## validity, not a cache/ledger version concern, §4).
    dgdFoldMismatch   ## RFC-0009 A3c-i: a persisted header root NAME still
                      ## resolves, but its persisted `foldPolicy` disagrees
                      ## with that root's CURRENT probed policy — never
                      ## compared cross-policy. `loadDepGraph` only.

  DepGraphDiscard* = object
    ## Load-time provenance of a discard decision: WHY a persisted graph was
    ## discarded (kind == dgdNone when nothing was discarded), and the two
    ## header values that disagreed (dgdNimVersion/dgdFormatVersion/
    ## dgdFoldMismatch) or a short reason (dgdMalformed / dgdRootUnknown's
    ## offending root name, both in `stored`; `current` unused for those
    ## two). Deliberately
    ## NOT a field on `DepGraph` — `DepGraph` is otherwise the exact
    ## persistence mirror of the on-disk JSON, so stapling a load-time-only
    ## fact onto it would leave that fact's validity window (one
    ## `loadDepGraph` call) as a docstring promise instead of something the
    ## type system enforces. Produced by the out-param overload of
    ## `loadDepGraph`; the caller (pipeline.nim's `buildRunPlan`) surfaces a
    ## non-dgdNone discard as a `ConfigWarning` via `key`/`message` below, so
    ## a discarded graph is a visible, structured diagnostic instead of a
    ## silent empty-graph fallback (issue: after a Nim upgrade, or when the
    ## file is corrupt, every entrypoint would otherwise show
    ## `recorded:false` indistinguishable from "never ran").
    kind*:    DepGraphDiscardKind
    stored*:  string  ## the mismatched header field, or the dgdMalformed reason ("" for dgdNone)
    current*: string  ## this run's value for that field, stringified ("" for dgdNone/dgdMalformed)

  DepGraph* = object
    header*:  DepGraphHeader
    entries*: Table[(string, string), DepGraphEntry]
      ## Key: (entrypoint path, flagHash)
      ## Value: DepGraphEntry with closure, content hash, and protocol major

# ---------------------------------------------------------------------------
# Public: DepGraphDiscard formatting (single authority — do not re-derive
# `key`/`message` elsewhere, e.g. with a `case` in pipeline.nim)
# ---------------------------------------------------------------------------

proc sanitizeOneSegment(s: string): string =
  ## Sanitize a single already-extracted segment: replace control/ANSI bytes
  ## via `ioutils.sanitizeControlBytes` (control/ANSI escape bytes cannot
  ## spoof or corrupt the terminal, or a log that captures it), then cap the
  ## length so a pathological value cannot blow up the message. The cap
  ## applies to THIS segment alone — callers that split a value into
  ## multiple segments (see `sanitizeHeaderField`) must cap each segment
  ## independently, or a long leading segment would consume the whole
  ## budget and hide the rest.
  const maxLen = 64
  let truncated = s.len > maxLen
  let clipped = if truncated: s[0 ..< maxLen] else: s
  result = sanitizeControlBytes(clipped)
  if truncated:
    result.add "..."

proc sanitizeHeaderField(s: string; pipeAware: bool = false): string =
  ## `stored`/`current` values may come from an on-disk depgraph file, which
  ## may be foreign, hand-edited, or corrupted, or from the Nim compiler
  ## fingerprint, which is itself MULTI-LINE and pipe-delimited
  ## ("Nim Compiler Version ...\nCompiled at ...\nactive boot switches
  ## ...|<binary hash>" — see nimprobe.cachedNimFingerprint). `message`
  ## below concatenates this text verbatim into a diagnostic that is later
  ## written raw to stderr, so this proc must both keep the diagnostic
  ## short and single-line, and preserve enough of the value to tell two
  ## different fingerprints apart.
  ##
  ## `pipeAware` gates the '|'-tail rendering below — it must be true ONLY
  ## for dgdNimVersion's `stored`/`current` (the Nim fingerprint, whose shape
  ## is documented above), where the text after the FINAL '|' really is a
  ## bare binary hash and reducing it to 12 characters loses nothing.
  ##
  ## It must NOT be used for the cc fingerprint. An earlier revision of this
  ## proc claimed the same rule was "a harmless no-op truncation" for
  ## the cc identity — that was wrong, and observably so: ccVersion is
  ## "<cc text> #<digest>|<runtime text> #<digest>", so the text after the
  ## final '|' is the RUNTIME IDENTITY, not a hash. Truncating it to 12
  ## characters rendered a real discard as
  ##   `... current toolchain is cc (SUSE Linux) 16.2.0 #b0dd4cd034d13600|390a4be6deb6`
  ## — the entire `ldd (GNU libc) 2.43 #542b` half erased. That destroys the
  ## one thing the message exists to say on the path RFC-0004 component 4
  ## added it for: WHICH half of the toolchain moved. A glibc rebuild at an
  ## unchanged version string — precisely the case issue #23 exists to catch
  ## — would report only twelve anonymous hex digits.
  ## `sanitizeCcFingerprintField` below renders that shape correctly.
  ## Every other caller (dgdFormatVersion,
  ## dgdMalformed) passes the default `false`: those values are arbitrary
  ## text — a dgdMalformed reason can be a filesystem path, and a path
  ## containing a literal '|' must render intact rather than being mangled
  ## by a heuristic meant for a completely different value shape (see the
  ## "F3" test below for the fingerprint case this heuristic exists for,
  ## and test_depgraph_guard.nim's "'|' hash heuristic" test for the
  ## dgdMalformed case it must NOT apply to).
  ##
  ## When `pipeAware` and the value contains '|', it is treated as
  ## `<multi-line version text>|<binary hash>`: the part before the FINAL
  ## '|' is reduced to its first line (the human-readable version string);
  ## the part after it is reduced to its last 12 characters (enough of the
  ## hash to distinguish two builds with an identical version line — e.g.
  ## a patched vs. stock compiler at the same reported version — without
  ## reproducing the whole hash). Each part is sanitized and capped
  ## independently (see `sanitizeOneSegment`) so the version-line cap
  ## cannot itself swallow the '|' and hide the hash suffix.
  ##
  ## Otherwise (pipeAware is false, or the value has no '|'): first line
  ## only, sanitized and capped — plain first-line/truncate rendering.
  if pipeAware:
    let pipePos = s.rfind('|')
    if pipePos >= 0:
      let versionSeg = s[0 ..< pipePos]
      let hashSeg     = s[pipePos + 1 .. ^1]
      let vNlPos = versionSeg.find('\n')
      let versionFirstLine = if vNlPos >= 0: versionSeg[0 ..< vNlPos] else: versionSeg
      let hashTail = if hashSeg.len > 12: hashSeg[^12 .. ^1] else: hashSeg
      return sanitizeOneSegment(versionFirstLine) & "|" & sanitizeOneSegment(hashTail)

  let nlPos = s.find('\n')
  let firstLine = if nlPos >= 0: s[0 ..< nlPos] else: s
  sanitizeOneSegment(firstLine)

const NewlineChar = char(10)

proc abbreviateDigest(seg: string): string =
  ## Reduce a trailing ` #<hex>` digest to its last 12 characters, leaving the
  ## legible text before it intact. Enough hash to tell two builds at an
  ## identical version string apart, without reproducing all 16 digits.
  let hashPos = seg.rfind(" #")
  if hashPos < 0: return seg
  let text = seg[0 ..< hashPos]
  let digest = seg[hashPos + 2 .. ^1]
  if digest.len <= 12: return seg
  text & " #" & digest[^12 .. ^1]

proc sanitizeCcFingerprintField(s: string): string =
  ## Render a cc identity (`toolchainwarn.toolchainIdentity`: the serialized
  ## `ccidentity.CcFingerprint`, `$fp`, plus a run nonce when unidentified)
  ## for a discard diagnostic.
  ##
  ## The shape is TWO halves split on the FIRST '|' — compiler and runtime —
  ## each as `serializeCompilerHalf` / `serializeRuntimeHalf` write it:
  ## `<legible text> #<hex digest>`, or that half's sentinel (`CcSentinel` /
  ## `RuntimeSentinel`), which has no ` #` digest and so passes through
  ## `abbreviateDigest` unchanged. Both halves' text is
  ## load-bearing: the message's whole job is to say which half moved. So
  ## each half keeps its first line and abbreviates only its own digest,
  ## and each is capped independently so a long compiler banner cannot eat
  ## the runtime half's budget.
  ##
  ## Deliberately NOT `sanitizeHeaderField(pipeAware = true)`: that splits on
  ## the FINAL '|' and treats everything after it as a hash, which is right
  ## for the Nim fingerprint and wrong here (see that proc's doc).
  let pipePos = s.find('|')
  if pipePos < 0:
    let nl = s.find(NewlineChar)
    return sanitizeOneSegment(abbreviateDigest(if nl >= 0: s[0 ..< nl] else: s))
  proc firstLine(x: string): string =
    let nl = x.find(NewlineChar)
    if nl >= 0: x[0 ..< nl] else: x
  let ccSeg = firstLine(s[0 ..< pipePos])
  let rtSeg = firstLine(s[pipePos + 1 .. ^1])
  sanitizeOneSegment(abbreviateDigest(ccSeg)) & "|" &
    sanitizeOneSegment(abbreviateDigest(rtSeg))

proc key*(d: DepGraphDiscard): string =
  ## ConfigWarning `key` for a discard: "nimVersion" / "formatVersion" /
  ## "malformed" / "rootUnknown" / "foldMismatch" / "" (dgdNone). The single
  ## formatting authority for this fact.
  case d.kind
  of dgdNone:          ""
  of dgdNimVersion:    "nimVersion"
  of dgdCcVersion:     "ccVersion"
  of dgdFormatVersion: "formatVersion"
  of dgdMalformed:     "malformed"
  of dgdRootUnknown:   "rootUnknown"
  of dgdFoldMismatch:  "foldMismatch"

proc message*(d: DepGraphDiscard): string =
  ## Human-readable diagnostic for a discard, or "" for dgdNone. The single
  ## formatting authority for this fact; `stored`/`current` are sanitized
  ## before being embedded (see `sanitizeHeaderField`). Worded neutrally —
  ## this is also printed by subcommands (e.g. `list`, `closure`) that never
  ## compile anything.
  case d.kind
  of dgdNone:
    ""
  of dgdNimVersion:
    "depgraph discarded: recorded for Nim " & sanitizeHeaderField(d.stored, pipeAware = true) &
    ", current compiler is " & sanitizeHeaderField(d.current, pipeAware = true) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"
  of dgdCcVersion:
    "depgraph discarded: recorded for cc toolchain " & sanitizeCcFingerprintField(d.stored) &
    ", current toolchain is " & sanitizeCcFingerprintField(d.current) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"
  of dgdFormatVersion:
    "depgraph discarded: format version " & sanitizeHeaderField(d.stored) &
    ", current is " & sanitizeHeaderField(d.current) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"
  of dgdMalformed:
    "depgraph discarded: unreadable or malformed (" &
    sanitizeHeaderField(d.stored) &
    ") -- the recorded graph is treated as empty"
  of dgdRootUnknown:
    "depgraph discarded: recorded root '" & sanitizeHeaderField(d.stored) &
    "' is unknown to the current tracked roots -- the recorded graph is " &
    "treated as empty (run recompiles and force-selects every entrypoint)"
  of dgdFoldMismatch:
    "depgraph discarded: recorded fold policy " & sanitizeHeaderField(d.stored) &
    ", current probe is " & sanitizeHeaderField(d.current) &
    " -- the recorded graph is treated as empty (run recompiles and " &
    "force-selects every entrypoint)"

# ---------------------------------------------------------------------------
# Public: flagHash
# ---------------------------------------------------------------------------

proc flagHash*(flags: seq[string]): string =
  ## Stable 16-hex-char hash over a flag set.
  ## Flags are sorted before hashing so order does not matter.
  ## Uses 64-bit FNV-1a, not std/hashes (which is not stable across versions).
  var sorted = flags
  sorted.sort()
  let joined = sorted.join("\x00")
  result = toHex16(fnv1a64(joined))

# ---------------------------------------------------------------------------
# Public: entryKey
# ---------------------------------------------------------------------------

proc entryKey*(tp: TrackedPath; flags: seq[string]): tuple[path, flagHash: string] =
  ## The `DepGraph.entries` primary key — `(display(tp), flagHash(flags))`
  ## — factored to ONE place (RFC-0009 F24/F32). Before this, every one of
  ## ~9 call sites across runcore.nim/cachedispatch.nim/clean.nim/depgraph.nim/
  ## narrow.nim/planner.nim/runner.nim hand-built the same tuple from the
  ## same two ingredients; ZERO behavior change here, just one named seam
  ## instead of nine copies re-deciding it. Named fields (`.path`/
  ## `.flagHash`) are purely for readability at call sites — Nim tuples are
  ## structurally typed (field names are not part of the type), so this
  ## return type is interchangeable with the unnamed `(string, string)`
  ## `DepGraph.entries: Table[(string, string), DepGraphEntry]` is keyed on.
  ##
  ## `display(tp)` — not `keyBytes`/`cmpKeyBytes` — is safe as a Table key
  ## ONLY because every `tp` reaching this helper today is TAG-0
  ## (project-root-relative): `Entrypoint.tp` is built exclusively by
  ## `discover()` walking the project root (see that field's own doc
  ## comment; F14 made a dep-root selector a hard `cekConfig` rejection
  ## specifically because entrypoints are never dep-root-domain). A tag-0
  ## `display()` string is already injective within the project root, so it
  ## needs no root-tag qualifier the way a general cross-root comparison
  ## would (F24's ledger note: "invariant re-decided at each boundary
  ## instead of carried by the type"). The day an entrypoint can legitimately
  ## live under a dep root, this helper is the one place that widens —
  ## e.g. to `keyBytes(tp)` — rather than nine.
  (path: string(display(tp)), flagHash: flagHash(flags))

# ---------------------------------------------------------------------------
# Public: closureContentHash
# ---------------------------------------------------------------------------

proc closureContentHash*(pairs: seq[tuple[key: string; nativePath: string]]): string =
  ## Compute a stable 64-bit FNV-1a hash over the CONTENTS of all closure
  ## files.
  ##
  ## RFC-0009 A5a: `pairs` is `closureHashInputs`' output — the PORTABLE
  ## `keyBytes` spelling chained into the hash, content read from the
  ## paired ABSOLUTE native path. A project-only closure hashes
  ## byte-identical to before this change; a dep-root member's hash becomes
  ## host-portable. See `crisol/fnv.chainedContentHash` for the algorithm.
  ##
  ## Delegates to `crisol/fnv.chainedContentHash` — the depgraph-facing name
  ## for the identical fold; `crisol/closure` (which cannot import this
  ## module — see closure.nim's import comment) calls `chainedContentHash`
  ## directly for the same result.
  chainedContentHash(pairs)

proc closureHashInputs*(closure: HashSet[TrackedPath];
    roots: TrackedRoots): seq[tuple[key: string; nativePath: string]] =
  ## RFC-0009 A3c-ii/A5a: the canonical (key, nativePath) pairs fed to
  ## `closureContentHash` for a `TrackedPath` closure. It MUST be derived
  ## identically at record time (`recordClosure`) and at check time
  ## (`planner.decideCompile`), from the SAME (classify-filtered)
  ## `TrackedPath` set — otherwise the warm-load content hash never
  ## reproduces the recorded one and every entry looks stale (the
  ## `test_skipfresh` regression this centralization fixes).
  ##
  ## Per member: `key` is `keyBytes(tp, roots)` — a project (tag-0) member's
  ## `keyBytes` is byte-identical to its `display` (project-relative `rel`,
  ## the pre-A5a spelling); a dep-root member's `keyBytes` is the portable
  ## `"dep:name/rel"` form (never a machine-local absolute path).
  ## `nativePath` is always `toNative(tp, roots)` — the ABSOLUTE native path
  ## to read content from, for either kind of member. `chainedContentHash`
  ## sorts by `key` internally.
  result = newSeqOfCap[tuple[key: string; nativePath: string]](closure.len)
  for tp in closure:
    result.add((key: string(keyBytes(tp, roots)), nativePath: toNative(tp, roots)))

# ---------------------------------------------------------------------------
# Public: constructors
# ---------------------------------------------------------------------------

# SOUNDNESS-PARAMETER WARNING (round-2 review R2-7; ENFORCED round 3, R3-7;
# text corrected round 4, R4-5, 2026-09-24): `ccVersion` below is a soundness
# parameter of the shape that produced defect L1 -- it is the C-toolchain half
# of the header every later freshness comparison is made against, so a graph
# stamped without it is indistinguishable from one built by the current
# toolchain. It no longer carries a default: the compiler now says so at the
# call site, via the deprecated compatibility overload below (a hard error
# under `dev check`'s `--warningAsError:Deprecated:on`). Pass it EXPLICITLY,
# including "" when you mean "no probe available". Full rationale on that
# overload, on `planner.cachePath`'s, and at R2-7/R3-7 in
# docs/handoff/msvc-selection-layer.md.
proc initDepGraph*(nimVersion: string; ccVersion: string): DepGraph =
  ## Construct a new, empty DepGraph with the given Nim/cc versions in the
  ## header.
  ##
  ## PASS `ccVersion` EXPLICITLY (R3-7), including `""` when there is no probe
  ## — see the deprecated overload below for why the default was removed.
  result = DepGraph(
    header:  DepGraphHeader(nimVersion: nimVersion,
                            ccVersion: ccVersion,
                            formatVersion: DepGraphFormatVersion),
    entries: initTable[(string, string), DepGraphEntry]()
  )

proc initDepGraph*(nimVersion: string): DepGraph
    {.deprecated: "R3-7: pass ccVersion explicitly (\"\" when no probe is available) — omitting it silently stamps the header with no C-toolchain identity".} =
  ## Deprecated compatibility overload. `ccVersion` used to default to "" (W3:
  ## mirroring `nimVersion`'s "no probe available — test/cold-start caller"
  ## convention) so every pre-W3 call site kept compiling unchanged; that
  ## default is what made the omission invisible. Full rationale on
  ## `planner.cachePath`'s deprecated overload (R3-7).
  initDepGraph(nimVersion, "")

# ---------------------------------------------------------------------------
# Public: mutation
# ---------------------------------------------------------------------------

proc updateEntry*(graph: var DepGraph;
                  path:          string;
                  fHash:         string;
                  closure:       HashSet[TrackedPath];
                  links:         seq[ClosureLink];
                  closureHash:   string = "";
                  protocolMajor: int = 0;
                  externals:     seq[ExternalSource] = @[]) =
  ## Insert or replace the entry for (path, fHash).
  ##
  ## `links` is required, never defaulted: with `closure` it is the entry's
  ## watched set, and its absence is load-bearing (see
  ## `DepGraphEntry.links`). A caller whose members crossed no link passes
  ## `@[]` explicitly.
  ##
  ## Refuses an EMPTY closure — see `DepGraphEntry.closure`, invariant
  ## NONEMPTY-CLOSURE.  Raises `CrisolError(cekInternal)` and leaves any
  ## existing entry untouched; the caller decides whether to
  ## `invalidateEntry` (`recordClosure`, below, does).
  if closure.len == 0:
    raise newCrisolError(cekInternal,
      "refusing to record an empty source closure (see DepGraphEntry.closure, " &
      "invariant NONEMPTY-CLOSURE)")
  graph.entries[(path, fHash)] = DepGraphEntry(
    closure:       closure,
    closureHash:   closureHash,
    protocolMajor: protocolMajor,
    externals:     externals,
    links:         links,
  )

proc invalidateEntry*(graph: var DepGraph; path: string; fHash: string) =
  ## Drop the entry for (path, fHash) so the next plan sees "no closure
  ## record": decideCompile → cdStale (recompile) and narrowByDiff → unknown
  ## closure (force-included).  Idempotent; absent key is a no-op.
  ##
  ## Used whenever a compile SUCCEEDED but its closure is not recorded, so
  ## the PREVIOUS entry (arbitrarily stale) must not survive to describe a
  ## binary it was not built from: by `recordClosure` (below) when the
  ## closure could not be extracted, and by `runner.retireThenRecordClosure`
  ## when the previous stable binary could not be retired (issue #26) and
  ## recording is therefore never attempted.
  graph.entries.del((path, fHash))

# ---------------------------------------------------------------------------
# Public: the watched set -- drift (the file system) and reach (a diff)
# ---------------------------------------------------------------------------
#
# An entry watches a set W of tracked paths: its closure members
# (`DepGraphEntry.closure`) and the links they were reached through
# (`DepGraphEntry.links`). Two questions are asked of W, and each has exactly
# one answer here:
#
#   * `entryDrift`: has the file system moved under W since the record? The
#     one staleness predicate. `isEntryStale` (narrow rule 4) and
#     `planner.decideCompile` both read it; the content hash stays the
#     planner's.
#   * `diffReach`: does a changed set reach W? The one diff-selection
#     predicate, and pure. Narrow rule 5 reads only it.
#
# Both return typed evidence (a kind and the path), so a caller that wants a
# reason formats it itself. A new link shape is a new kind on one of the two,
# never a new predicate beside them (R14-D1).

proc ancestorsOrSelf(tp: TrackedPath; roots: TrackedRoots): seq[TrackedPath] =
  ## `tp`, then every directory above it on the same tracked root, nearest
  ## first (`libs/a/m.nim`, `libs/a`, `libs`). Built from `keyBytes` and
  ## read back through `fromKeyBytes`, so each one carries `tp`'s root and
  ## folds as it does. The root itself is not a `TrackedPath` and is never
  ## returned. Pure: no file-system access.
  result.add tp
  var kb = string(keyBytes(tp, roots))
  while true:
    let slash = kb.rfind('/')
    if slash <= 0: break
    kb.setLen(slash)
    let up = fromKeyBytes(kb, roots)
    if up.isNone: break
    result.add up.get

proc missingMember(entry: DepGraphEntry; roots: TrackedRoots): Option[TrackedPath] =
  ## The first closure member that no longer exists. RFC-0009 A3c-ii: each
  ## member's native path is `toNative(tp, roots)` (root-tag-aware), so the
  ## answer does not depend on the caller's CWD, for any tracked root.
  for tp in entry.closure:
    if not fileExists(toNative(tp, roots)):
      return some(tp)
  none(TrackedPath)

proc movedLink(entry: DepGraphEntry; roots: TrackedRoots): Option[TrackedPath] =
  ## Issue #25: the first recorded link whose resolved target no longer
  ## matches the one recorded (repointed, deleted, or replaced by a real file
  ## or directory). A deleted link resolves to its own path
  ## (`safeExpandFilename` returns its input unchanged), which never equals a
  ## recorded target, since a recorded link resolved elsewhere.
  for l in entry.links:
    let now = linkTargetSpelling(safeExpandFilename(toNative(l.path, roots)), roots)
    if now != l.target:
      return some(l.path)
  none(TrackedPath)

proc unrecordedLink(entry: DepGraphEntry; roots: TrackedRoots): Option[TrackedPath] =
  ## R13-S1: the first directory on a closure member's path that is now a
  ## link (a symlink, or a Windows junction) the entry did not record. The
  ## counterpart of `movedLink` for a link that did not exist at record time.
  ##
  ## A directory replaced by a link after the record (`rm -r vend; ln -s
  ## libs/a vend`, a submodule checkout swapped for a link, a junction made
  ## where a directory was) leaves every member readable at its recorded
  ## path, so neither the existence probe nor the content hash moves when
  ## the new target holds the same bytes, and `entry.links` has nothing to
  ## re-resolve. The entry would then stay fresh with no link recorded, and
  ## a later repoint of that link would change what the test reads with
  ## nothing to notice it (a compile skip and a cached PASS; under
  ## `--changed` the diff names only the link). Stale instead: the
  ## recompile records the link, and `dkMoved`/`diffReach` watch it from
  ## then on.
  ##
  ## Each member's directories are read from its tracked root downwards
  ## (`ancestorsOrSelf`; the root itself is never tested). The first link
  ## met decides: a recorded one covers everything under it (`movedLink`
  ## re-resolves it; a member reached through it has a lexical path under
  ## it, and the links nested behind it are recorded at their real
  ## locations, never at a spelling through it, so looking further would
  ## call every such entry stale forever); an unrecorded one is the answer.
  ## Nothing a record produces is flagged: `closure.crossedLinks` records
  ## every indexed link a member's path crosses, and a member Nim recorded
  ## by its realpath crosses none.
  ##
  ## Cost: one `symlinkExists` (an lstat; on Windows a file-attribute read)
  ## per distinct directory across the entry's members, memoized within the
  ## call, so it is linear in distinct directories and never more than the
  ## per-member existence probe already pays.
  if entry.closure.len == 0: return none(TrackedPath)
  var recorded = initHashSet[TrackedPath]()
  for l in entry.links: recorded.incl l.path
  type DirState = enum dsClean, dsCovered, dsUnrecorded
  var memo = initTable[TrackedPath, DirState]()
  for tp in entry.closure:
    let up = ancestorsOrSelf(tp, roots)
    # up[0] is the member itself; up[1 ..^ 1] its directories, nearest
    # first. Find the nearest one already decided, then decide the rest
    # from there downwards.
    var i = 1
    var state = dsClean
    while i < up.len:
      if up[i] in memo:
        state = memo[up[i]]
        break
      inc i
    var j = i - 1
    while j >= 1:
      let d = up[j]
      if state == dsClean:
        if d in recorded: state = dsCovered
        elif symlinkExists(toNative(d, roots)): state = dsUnrecorded
      memo[d] = state
      if state == dsUnrecorded: return some(d)
      dec j
  none(TrackedPath)

proc entryDrift*(entry: DepGraphEntry; roots: TrackedRoots): Option[Drift] =
  ## The one file-system staleness predicate over the entry's watched set:
  ## the first drift found, or none when every member exists, every recorded
  ## link still leads where it did, and no directory on a member's path has
  ## become a link the entry did not record. Checked in `DriftKind` order:
  ##
  ##   * `dkMissing`: a closure member no longer exists.
  ##   * `dkMoved` (issue #25): a recorded link was repointed, deleted or
  ##     replaced. Nim records a member reached through a link by its
  ##     realpath, so the repoint changes what a recompile would read while
  ##     every recorded member stays the same, and `git diff` never names an
  ##     untracked link at all.
  ##   * `dkUnrecorded` (R13-S1): a directory replaced by a link since the
  ##     record. On Windows a junction made in place of a directory can be
  ##     invisible to git as well.
  ##
  ## Read by `isEntryStale` (narrow rule 4) and `planner.decideCompile`,
  ## which checks the closure content hash between `dkMissing` and the link
  ## kinds and keeps its own reason strings.
  let missing = missingMember(entry, roots)
  if missing.isSome: return some(Drift(kind: dkMissing, path: missing.get))
  let moved = movedLink(entry, roots)
  if moved.isSome: return some(Drift(kind: dkMoved, path: moved.get))
  let unrecorded = unrecordedLink(entry, roots)
  if unrecorded.isSome: return some(Drift(kind: dkUnrecorded, path: unrecorded.get))
  none(Drift)

proc storedSpelling(s: HashSet[TrackedPath]; x: TrackedPath): TrackedPath =
  ## The element of `s` that equals `x`, in the spelling `s` holds it. Under
  ## a case fold two equal `TrackedPath`s can be spelled differently
  ## (`Widget.nim` in a diff, `widget.nim` in a closure), and `Hit` reports
  ## each side in its own spelling (R15-L1). `std/sets` has no keyed
  ## lookup that returns the stored element, so this scans; `diffReach`
  ## calls it only once, on the hit it returns.
  for e in s:
    if e == x: return e
  x

proc diffReach*(entry: DepGraphEntry; changed: HashSet[TrackedPath];
                roots: TrackedRoots): Option[Hit] =
  ## The one diff-selection predicate: how the changed set reaches the
  ## entry's watched set, or none. Pure: set lookups over `ancestorsOrSelf`
  ## chains, so fold-aware `TrackedPath` comparisons decide every kind. The
  ## `--changed` counterpart of `entryDrift`, which compares the watched set
  ## with the file system instead. Checked in `HitKind` order:
  ##
  ##   * `hkMember`: a changed name is a closure member.
  ##   * `hkLink` (R12-D1): a changed name IS a recorded link, or a directory
  ##     above one. A diff names a tracked symlink by its own path whether it
  ##     was repointed, deleted, or replaced by a file or a real directory,
  ##     and names a directory that was deleted, replaced or added as a whole
  ##     by its own path (a submodule's gitlink that is gone or no longer a
  ##     submodule, a new submodule, an untracked nested repository).
  ##   * `hkUnderLink` (R12-D1): a changed name lies UNDER a recorded link.
  ##     git treats a Windows junction as a plain directory and names the
  ##     files it sees through it (`vend/dep.nim`), never the junction. On
  ##     POSIX git never names a path through a symlink, so this adds nothing
  ##     there.
  ##   * `hkAncestor` (R13-S1): a changed name is a directory above a closure
  ##     member. A submodule turned into a link or a file is named by its
  ##     gitlink path alone (`:160000 120000 T vendor/lib`), and a member
  ##     under it may still be readable at its recorded path, with nothing
  ##     else in the changed set naming it.
  ##
  ## A submodule present on both sides is never named by its own path
  ## (`gitdiff.addChanged`): its own diff names what changed inside it, so
  ## neither `hkLink` nor `hkAncestor` turns an edit inside one into "every
  ## test under it" (R13-L4).
  ##
  ## The link kinds catch a change the diff spans but the record does not:
  ## with `--base HEAD~1` and the graph recorded AFTER a committed repoint,
  ## the recorded target is the current one and `entryDrift` is none, yet the
  ## test ran against the old target at the base.
  ##
  ## Cost: one set lookup per member, per ancestor of each recorded link and
  ## of each changed name, and per distinct directory across the members.
  if changed.len == 0: return none(Hit)
  # hkMember: iterate the smaller set.
  if changed.len <= entry.closure.len:
    for c in changed:
      if c in entry.closure:
        return some(Hit(kind: hkMember, name: c,
                        watched: storedSpelling(entry.closure, c)))
  else:
    for m in entry.closure:
      if m in changed:
        return some(Hit(kind: hkMember, name: storedSpelling(changed, m),
                        watched: m))
  if entry.links.len > 0:
    # hkLink: the link or a directory above it is named.
    for l in entry.links:
      for a in ancestorsOrSelf(l.path, roots):
        if a in changed:
          return some(Hit(kind: hkLink, name: storedSpelling(changed, a),
                          watched: l.path))
    # hkUnderLink: a name below the link.
    for c in changed:
      let up = ancestorsOrSelf(c, roots)
      for i in 1 ..< up.len:
        for l in entry.links:
          if l.path == up[i]:
            return some(Hit(kind: hkUnderLink, name: c, watched: l.path))
  # hkAncestor: a proper ancestor of a member is named.
  var seen = initHashSet[TrackedPath]()
  for tp in entry.closure:
    let up = ancestorsOrSelf(tp, roots)
    for i in 1 ..< up.len:
      if seen.containsOrIncl(up[i]): break
      if up[i] in changed:
        return some(Hit(kind: hkAncestor, name: storedSpelling(changed, up[i]),
                        watched: tp))
  none(Hit)

proc isEntryStale*(graph: DepGraph;
                   key:   (string, string);
                   roots: TrackedRoots): bool =
  ## True iff the entry should be re-scanned: `key` is absent from the
  ## graph, or its watched set has drifted (`entryDrift`: a member is gone,
  ## a recorded link moved, or a directory on a member's path is now a link
  ## the entry did not record).
  if key notin graph.entries:
    return true
  entryDrift(graph.entries[key], roots).isSome

proc staleExternalObjects*(graph: DepGraph; path: string; flags: seq[string];
                           roots: TrackedRoots): seq[string] =
  ## Issue #16 slice 1b: which of this entrypoint's `{.compile.}`d external
  ## objects the RUNNER must delete before spawning `nim c`, so Nim actually
  ## recompiles them.
  ##
  ## RFC-0009 F13: takes `roots: TrackedRoots` (was a bare `projectRoot:
  ## string`) — `ext.headers` are now portable `paths.keyBytes` spellings
  ## (never a machine-local absolute/project-relative-only path, even for a
  ## dep-root header), so recovering the native path to actually read a
  ## header's content needs the full root table, not just the project root.
  ##
  ## Nim's own external-object cache (`extccomp.nim`, verified Nim 2.2.10):
  ## `footprint` is a sha1 of the external source's CONTENT plus OS, CPU, cc
  ## name, and cc command — never the headers it `#include`s — and
  ## `addExternalFileToCompile` marks an external Cached (skips recompiling
  ## it) iff `fileExists(obj)` and that footprint is unchanged. So a
  ## header-only edit never changes the footprint: crisol's OWN closure hash
  ## correctly goes stale and the entrypoint recompiles, but Nim's cache
  ## still considers the external itself unchanged and would happily relink
  ## the STALE object sitting in the persistent nimcache — silently ignoring
  ## the header edit. Deleting that object (no `.sha1`-file surgery needed)
  ## is what forces Nim to recompile it.
  ##
  ## Returns the `obj` BASENAME (`ExternalSource.obj`, as recorded in the
  ## entry's `externals`) of every external whose header set can no longer be
  ## trusted: the header content, hashed NOW via `chainedContentHash`, no
  ## longer matches the `headersHash` recorded at the last successful
  ## `recordClosure`, OR that hash cannot even be computed right now (a
  ## header file missing or unreadable — treated conservatively as
  ## "changed", never raised out of this proc), OR `headersHash == ""` (no
  ## trustworthy prior record to compare against).
  ##
  ## No entry for `(path, flagHash(flags))` -> `@[]` (nothing recorded, so
  ## nothing to bust here — see `bustStaleExternalObjects` in runner.nim for
  ## how the runner handles a warm nimcache with NO matching record at all).
  ##
  ## Pure apart from reading the header files on disk; never raises (a read
  ## failure is treated as "stale", not propagated).
  let key = (path, flagHash(flags))
  if key notin graph.entries: return @[]
  for ext in graph.entries[key].externals:
    var stale = ext.headersHash == ""
    if not stale:
      try:
        # RFC-0009 F13: each header's KEY is its own portable `keyBytes`
        # spelling (host-invariant hash input); `nativePath` is recovered
        # via `fromKeyBytes`->`toNative` at this one point of I/O. A header
        # that fails to resolve (a corrupt record, or a renamed/removed dep
        # root) raises here and is caught below — treated the same as any
        # other unreadable header: conservatively "stale".
        var pairs = newSeq[tuple[key: string; nativePath: string]](ext.headers.len)
        for i, h in ext.headers:
          let hTpOpt = fromKeyBytes(h, roots)
          if hTpOpt.isNone:
            raise newCrisolError(cekEnvironment,
              "cannot resolve header spelling '" & h & "'")
          pairs[i] = (key: h, nativePath: toNative(hTpOpt.get, roots))
        stale = chainedContentHash(pairs) != ext.headersHash
      except CatchableError:
        stale = true
    if stale:
      result.add ext.obj

proc gcDeletedEntrypoints*(graph:               var DepGraph;
                           currentKeys: HashSet[(string, string)]) =
  ## Drop all entries whose key is NOT in `currentKeys`.
  ## Modifies `graph` in place.
  var toDelete: seq[(string, string)]
  for key in graph.entries.keys:
    if key notin currentKeys:
      toDelete.add key
  for key in toDelete:
    graph.entries.del(key)

# ---------------------------------------------------------------------------
# Serialization helpers
# ---------------------------------------------------------------------------

proc toJson(graph: DepGraph; roots: TrackedRoots): JsonNode =
  ## Serialize a DepGraph to a JsonNode.
  ##
  ## RFC-0009 W1: `entry.closure` is `HashSet[TrackedPath]` — each member is
  ## sorted by `cmpKeyBytes(_, _, roots)` (the SOLE ordering over
  ## `TrackedPath`; there is deliberately no `<`) and serialized via its
  ## `keyBytes` spelling (`paths.keyBytes`), not `display`: a tag-0
  ## (project) member's keyBytes is byte-identical to `display` (and to the
  ## project-relative string this file stored before the retype) EXCEPT the
  ## §4 `dep:*` escape (a tag-0 rel that itself looks like `dep:foo/...`
  ## gets a `./` prefix), so the on-disk format for an ordinary project path
  ## is unchanged; a dep-root member is now `dep:<name>/<rel>` instead of
  ## the bare rel `display` would have produced — bare rel lost which root
  ## the member came from on the read side (the defect this bump fixes).
  let headerNode = newJObject()
  headerNode["nimVersion"]    = newJString(graph.header.nimVersion)
  headerNode["ccVersion"]     = newJString(graph.header.ccVersion)
  headerNode["formatVersion"] = newJInt(graph.header.formatVersion)

  let rootsArr = newJArray()
  for r in graph.header.roots:
    let rNode = newJObject()
    rNode["name"]       = newJString(r.name)
    rNode["foldPolicy"] = newJString($r.foldPolicy)  ## "fpNone"/"fpAsciiLower"
    rootsArr.add rNode
  headerNode["roots"] = rootsArr

  let entriesArr = newJArray()
  for (key, entry) in graph.entries.pairs:
    let (path, fHash) = key
    let closureArr = newJArray()
    # Sort for deterministic output. No `<` exists on TrackedPath (R3-3) —
    # `cmpKeyBytes` is the sole ordering; serialize each member's `keyBytes`
    # spelling (RFC-0009 W1 — see the proc doc above for why not `display`).
    var sortedClosure = toSeq(entry.closure)
    sortedClosure.sort(proc(a, b: TrackedPath): int = cmpKeyBytes(a, b, roots))
    for tp in sortedClosure:
      closureArr.add newJString(string(keyBytes(tp, roots)))
    let externalsArr = newJArray()
    var sortedExternals = entry.externals
    # RFC-0009 F13: `ExternalSource.source` IS ALREADY a `paths.keyBytes`
    # spelling (see that type's doc, `crisol/closure`) — the sibling
    # `closureArr` sort above orders by `cmpKeyBytes`, which for two
    # `TrackedPath`s reduces to exactly `cmp` over their `keyBytes` STRINGS
    # (`cmpKeyBytes`'s own body); `a.source`/`b.source` already ARE those
    # strings, so a plain `cmp` here is the identical byte order under a
    # different (but sanctioned, RFC-0009 §4) name, not a second,
    # independently-drifting ordering.
    sortedExternals.sort(proc(a, b: ExternalSource): int = cmp(a.source, b.source))
    for ext in sortedExternals:
      let extNode = newJObject()
      extNode["source"] = newJString(ext.source)
      extNode["obj"]    = newJString(ext.obj)
      let hdrArr = newJArray()
      # Headers are the same `keyBytes` spelling as `source` — a plain
      # string sort is likewise the sanctioned byte order.
      var sortedHeaders = ext.headers
      sortedHeaders.sort()
      for h in sortedHeaders:
        hdrArr.add newJString(h)
      extNode["headers"]     = hdrArr
      extNode["headersHash"] = newJString(ext.headersHash)
      externalsArr.add extNode

    let entryNode = newJObject()
    entryNode["path"]          = newJString(path)
    entryNode["flagHash"]      = newJString(fHash)
    entryNode["closure"]       = closureArr
    entryNode["closureHash"]   = newJString(entry.closureHash)
    entryNode["protocolMajor"] = newJInt(entry.protocolMajor)
    entryNode["externals"]     = externalsArr
    # Issue #25: `path` is the link's `keyBytes` spelling (sorted by
    # `cmpKeyBytes`, like `closure`); `target` is already a comparable
    # spelling (`closure.linkTargetSpelling`).
    var sortedLinks = entry.links
    sortedLinks.sort(proc(a, b: ClosureLink): int = cmpKeyBytes(a.path, b.path, roots))
    let linksArr = newJArray()
    for l in sortedLinks:
      let lNode = newJObject()
      lNode["path"]   = newJString(string(keyBytes(l.path, roots)))
      lNode["target"] = newJString(l.target)
      linksArr.add lNode
    entryNode["links"]         = linksArr
    entriesArr.add entryNode

  result = newJObject()
  result["header"]  = headerNode
  result["entries"] = entriesArr

proc fromJson(node: JsonNode; roots: TrackedRoots; discarded: var DepGraphDiscard): DepGraph =
  ## Deserialize a DepGraph from a JsonNode, preserving the STORED header
  ## verbatim (nimVersion + formatVersion) — this proc has no notion of
  ## "the current Nim version" and performs no nimVersion comparison; that
  ## freshness judgment belongs one layer up, in the public `loadDepGraph`
  ## (see "Two loaders" in the module doc, issue #12), because a
  ## caller like `clean` needs the graph AS PERSISTED — GCing it against the
  ## discovered entrypoint set must never depend on, or silently stamp over,
  ## the fingerprint the pipeline will compare on the next `run`.
  ##
  ## Returns an empty graph, header nimVersion "", on formatVersion mismatch
  ## or on any malformed shape. discarded reports WHY a persisted graph was
  ## discarded: dgdNone when nothing was discarded; dgdFormatVersion for a
  ## formatVersion mismatch; dgdMalformed for every shape/parse problem
  ## (missing/wrong-typed header fields, non-object root, non-array
  ## entries, ...) so a present-but-unusable file is never silently
  ## indistinguishable from dgdNone's "never ran".
  result = initDepGraph("", "")
  discarded = DepGraphDiscard(kind: dgdNone)

  if node.kind != JObject:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root not an object")
    return

  # Validate header
  let headerNode = node{"header"}
  if headerNode == nil or headerNode.kind != JObject:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header not an object")
    return

  let storedNimVer = headerNode{"nimVersion"}
  if storedNimVer == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header missing nimVersion")
    return
  if storedNimVer.kind != JString:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "nimVersion not a string")
    return
  let storedFmtVer = headerNode{"formatVersion"}
  if storedFmtVer == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header missing formatVersion")
    return
  if storedFmtVer.kind != JInt:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "formatVersion not an integer")
    return

  let storedNimVerStr = storedNimVer.getStr("")
  let storedFmtVerInt = storedFmtVer.getInt(-1)

  if storedFmtVerInt != DepGraphFormatVersion:
    discarded = DepGraphDiscard(kind: dgdFormatVersion, stored: $storedFmtVerInt, current: $DepGraphFormatVersion)
    return

  # Preserve the header exactly as stored — no comparison against "the
  # current Nim version" here (see the proc doc above).
  result.header.nimVersion    = storedNimVerStr
  result.header.formatVersion = DepGraphFormatVersion

  # Parse header.ccVersion (W3). OPTIONAL at this shape-validation layer,
  # unlike nimVersion/formatVersion above -- absent (a hand-built fixture
  # predating this field) parses as "" (see DepGraphHeader.ccVersion's doc
  # for why this leniency, mirroring `roots`' v6 precedent, costs nothing in
  # production: the v9 formatVersion bump already discards every REAL v8
  # file above, and every REAL v9+ file, `saveDepGraph`'s the sole producer,
  # always writes this field). If PRESENT, it must be a string -- a
  # non-string value is a fact about the stored bytes (dgdMalformed), not
  # something a freshness judgment should paper over.
  let storedCcVerNode = headerNode{"ccVersion"}
  if storedCcVerNode != nil:
    if storedCcVerNode.kind != JString:
      discarded = DepGraphDiscard(kind: dgdMalformed, stored: "ccVersion not a string")
      return
    result.header.ccVersion = storedCcVerNode.getStr("")

  # Parse header.roots (RFC-0009 A3c-i; no `tag` column since W1 -- nothing
  # ever read it back, see DepGraphHeader.roots' doc). OPTIONAL at this
  # shape-validation layer -- absent (e.g. a hand-built fixture predating
  # this field, or one that never touches the roots mechanism) parses as
  # `@[]`, mirroring how `closureHash`/`protocolMajor`/`externals` are
  # tolerated as absent on an entry, below. Every REAL file (`saveDepGraph`,
  # the sole producer) always writes it non-empty (at minimum the project
  # root) -- an absent array here can only mean a hand-built document,
  # never a genuinely persisted graph, so leniency costs nothing in
  # production. If PRESENT, it must be well-formed: a malformed element is
  # a fact about the stored bytes (dgdMalformed), not something a
  # `loadDepGraph`-layer freshness judgment should paper over.
  let rootsNode = headerNode{"roots"}
  if rootsNode != nil:
    if rootsNode.kind != JArray:
      discarded = DepGraphDiscard(kind: dgdMalformed, stored: "header roots not an array")
      return
    var roots: seq[tuple[name: string; foldPolicy: FoldPolicy]] = @[]
    for rNode in rootsNode:
      if rNode.kind != JObject:
        discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root entry not an object")
        return
      let nameNode = rNode{"name"}
      let fpNode   = rNode{"foldPolicy"}
      if nameNode == nil or nameNode.kind != JString:
        discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root missing/invalid name")
        return
      if fpNode == nil or fpNode.kind != JString:
        discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root missing/invalid foldPolicy")
        return
      var fp: FoldPolicy
      try:
        fp = parseEnum[FoldPolicy](fpNode.getStr(""))
      except ValueError:
        discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root has unrecognized foldPolicy")
        return
      roots.add (name: nameNode.getStr(""), foldPolicy: fp)
    result.header.roots = roots

  # Parse entries
  let entriesArr = node{"entries"}
  if entriesArr == nil:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "root missing entries")
    return
  if entriesArr.kind != JArray:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: "entries not an array")
    return

  for entryNode in entriesArr:
    if entryNode.kind != JObject: continue
    let pathNode         = entryNode{"path"}
    let flagHashNode     = entryNode{"flagHash"}
    let closureNode      = entryNode{"closure"}
    let closureHashNode  = entryNode{"closureHash"}
    let protocolMajNode  = entryNode{"protocolMajor"}
    if pathNode == nil or flagHashNode == nil or closureNode == nil: continue
    if closureNode.kind != JArray: continue

    let path    = pathNode.getStr("")
    let fHash   = flagHashNode.getStr("")
    if path == "" or fHash == "": continue

    # RFC-0009 W1: `fromKeyBytes` (paths.nim) is the keyBytes grammar's
    # inverse — replaces the old `classify(s, roots)` call here. `classify`
    # is the wrong direction for ALREADY-canonical persisted text: its
    # project-first join has no notion of the `dep:<name>/` prefix, so it
    # silently re-tagged every persisted dep-root member as a phantom tag-0
    # project path (the defect this format bump fixes — see History above).
    # `fromKeyBytes` returning `none` drops that member (degrade-never-
    # crash): a renamed/removed dep root's NAME is caught at the HEADER
    # level by `loadDepGraph`'s dgdRootUnknown check (below, in file order),
    # which discards the WHOLE graph before any caller ever sees these
    # entries — so a `none` surviving to a LOADDEPGRAPH caller can only
    # mean the entry's bytes themselves are corrupt, never a legitimate
    # stale-root scenario. This subsumes the old M10 underRootNorm role
    # (dropping any member that doesn't resolve under a tracked root) the
    # same way the pre-W1 classify-at-load conversion did.
    #
    # `fromJson` is ALSO reached from `loadStoredDepGraph` (`crisol clean`'s
    # loader), which never runs the header-level dgdRootUnknown check by
    # design (its doc). A `none` here during a `loadStoredDepGraph` call
    # CAN legitimately mean a renamed/removed dep root — clean tolerates
    # that (it only GCs by entry key, never reads closure members for a
    # decision) precisely because `saveDepGraph`'s `preserveHeaderRoots`
    # (RFC-0009 wiring-audit fix; see `clean.cleanOrphans`) keeps the
    # on-disk header naming the OLD root even after such a clean, so the
    # next `loadDepGraph` still catches the mismatch via dgdRootUnknown and
    # discards the whole (by-then-truncated) graph before any staleness
    # decision ever sees it.
    var closure = initHashSet[TrackedPath]()
    for item in closureNode:
      let s = item.getStr("")
      if s.len == 0: continue
      let tpOpt = fromKeyBytes(s, roots)
      if tpOpt.isSome: closure.incl tpOpt.get

    let closureHash   = if closureHashNode != nil: closureHashNode.getStr("") else: ""
    let protocolMajor = if protocolMajNode != nil: protocolMajNode.getInt(0)  else: 0

    var externals: seq[ExternalSource] = @[]
    let externalsNode = entryNode{"externals"}
    if externalsNode != nil and externalsNode.kind == JArray:
      for extNode in externalsNode:
        if extNode.kind != JObject: continue
        let srcNode = extNode{"source"}
        let objNode = extNode{"obj"}
        if srcNode == nil or objNode == nil: continue
        let src    = srcNode.getStr("")
        let objVal = objNode.getStr("")
        if src == "" or objVal == "": continue
        var headers: seq[string] = @[]
        let hdrNode = extNode{"headers"}
        if hdrNode != nil and hdrNode.kind == JArray:
          for h in hdrNode:
            let hs = h.getStr("")
            if hs != "": headers.add hs
        let hHashNode = extNode{"headersHash"}
        let hHash = if hHashNode != nil: hHashNode.getStr("") else: ""
        externals.add ExternalSource(source: src, obj: objVal, headers: headers,
                                     headersHash: hHash)

    # Issue #25: `links`. Absent (a hand-built fixture) reads as none, like
    # `externals`; every real v10 file writes it. Unlike a closure member,
    # a link that cannot be read back must not be dropped on its own:
    # dropping it would silently exempt the entry from the check that
    # link exists for. The whole ENTRY is dropped instead, so the
    # entrypoint sees "no closure record" and recompiles.
    var links: seq[ClosureLink] = @[]
    var linksOk = true
    let linksNode = entryNode{"links"}
    if linksNode != nil:
      if linksNode.kind != JArray:
        linksOk = false
      else:
        for lNode in linksNode:
          let lp = if lNode.kind == JObject: lNode{"path"} else: nil
          let lt = if lNode.kind == JObject: lNode{"target"} else: nil
          if lp == nil or lt == nil or lp.kind != JString or lt.kind != JString or
             lt.getStr("").len == 0:
            linksOk = false
            break
          let tpOpt = fromKeyBytes(lp.getStr(""), roots)
          if tpOpt.isNone:
            linksOk = false
            break
          links.add ClosureLink(path: tpOpt.get, target: lt.getStr(""))
    if not linksOk: continue

    result.entries[(path, fHash)] = DepGraphEntry(
      closure:       closure,
      closureHash:   closureHash,
      protocolMajor: protocolMajor,
      externals:     externals,
      links:         links,
    )

# ---------------------------------------------------------------------------
# Public: persistence
# ---------------------------------------------------------------------------

proc depgraphPath*(config: Config): string =
  ## Absolute path to the depgraph file.
  stateDirOf(config) / "depgraph"

proc rootsDescriptor(roots: TrackedRoots): seq[tuple[name: string; foldPolicy: FoldPolicy]] =
  ## RFC-0009 A3c-i/W1: this file's own local name/foldPolicy table
  ## (`DepGraphHeader.roots`) — project root first (`name: ""`), then each
  ## configured dep root in `TrackedRoots` order. No ordinal tag (dropped at
  ## W1 — see `DepGraphHeader.roots`'s doc): a closure member already names
  ## its own root by NAME via `paths.keyBytes`.
  result.add (name: roots.project.name, foldPolicy: roots.project.foldPolicy)
  for d in roots.deps:
    result.add (name: d.name, foldPolicy: d.foldPolicy)

proc saveDepGraph*(graph: DepGraph; config: Config;
                    preserveHeaderRoots: bool = false): bool =
  ## Write the graph to `<projectRoot>/<stateDir>/depgraph` atomically.
  ## Creates the state directory if absent.
  ##
  ## Stamps `header.roots` (RFC-0009 A3c-i) from `config.trackedRoots` — THIS
  ## is the sourcing site for the root descriptor (not `initDepGraph`, which
  ## has no `Config` to draw one from, and not `updateEntry`, which never
  ## touches the header): every real save reflects the roots the entries
  ## being written were computed against, exactly once, here. The `graph`
  ## parameter (and whatever `header.roots` it happened to carry in memory,
  ## e.g. inherited from a prior load) is left untouched; only the on-disk
  ## bytes gain the freshly-derived descriptor.
  ##
  ## `preserveHeaderRoots` (RFC-0009 wiring-audit fix): when `true`, the
  ## re-stamp above is SKIPPED — `toWrite.header.roots` keeps exactly
  ## whatever `graph.header.roots` already carried in memory (normally the
  ## STORED value, inherited verbatim from a prior `loadStoredDepGraph`).
  ## This is the GC-only save path's mode (`clean.cleanOrphans`, the sole
  ## caller passing `true`): a clean never recomputes or validates any
  ## entry's closure against the CURRENT `config.trackedRoots` (it uses
  ## `loadStoredDepGraph`, never `loadDepGraph`, precisely so it never
  ## depends on root/version freshness — see that proc's doc), so
  ## re-stamping the header here would silently launder a renamed or
  ## removed dep root past the next `loadDepGraph`'s `dgdRootUnknown`/
  ## `dgdFoldMismatch` check — the exact signal that check exists to catch
  ## — even though this save recomputed nothing against the new roots.
  ## Every OTHER caller (`recordClosure`'s success and failure paths) has
  ## just extracted a fresh closure against the CURRENT roots and must
  ## keep re-stamping (`preserveHeaderRoots` defaults to `false`,
  ## unchanged behavior) so the header always reflects what those entries
  ## were actually computed against.
  ## Returns `true` iff the graph was actually persisted (the final
  ## `moveFile` completed), `false` on ANY failure OR on a degraded run
  ## (RFC-0009 A-degraded D5, `config.trackedRoots.degraded` — see below).
  ## Deliberately NOT
  ## `{.discardable.}` — every caller (issue #13.3) must decide what a
  ## failed persist means for what it just did in memory: `recordClosure`
  ## turns it into a recovery-policy failure so the runner discards the
  ## stable binary rather than leave it paired with a stale on-disk entry;
  ## `clean` must not report entries as dropped from disk when the drop
  ## never made it to disk. On any write failure: still warns to stderr
  ## with the cause (unchanged from before) — the bool lets a caller react
  ## structurally, the stderr line stays for a human watching the run — and
  ## never raises.
  ##
  ## Writes via `ioutils.atomicPublish` (RFC-0007 A3): a PID-suffixed temp
  ## file opened `O_CREAT|O_EXCL|O_WRONLY` (fails if any file or symlink
  ## already exists there — prevents a pre-planted symlink from redirecting
  ## the write to an attacker-chosen target, P5), `writeAllFd`, then
  ## `rename(2)` into place. A stale temp file from a previous crashed run in
  ## THIS process is removed first. Every persist-failure test in the suite
  ## injects its fault by occupying `depgraphPath(config)` itself with a
  ## directory — `rename(2)` reliably fails with EISDIR in that case,
  ## without needing filesystem permissions the container's root user would
  ## bypass anyway.
  # RFC-0009 A-degraded (D5): a degraded run (the fold-policy probe genuinely
  # failed for some root, §3) never persists its dep graph — a graph built
  # under an unresolved policy must never be silently trusted by a later,
  # healthy run. Checked FIRST, before any write (not even createDir): the
  # simplest safe posture is "as if this run never touched the graph at
  # all", not a header.degraded marker on a written-then-discarded file.
  if config.trackedRoots.degraded:
    return false

  let stateDir  = stateDirOf(config)
  let finalPath = depgraphPath(config)

  try:
    createDir(stateDir)
  except OSError as e:
    stderr.write("crisol: warning: could not create state dir '" & stateDir &
                 "': " & e.msg & "\n")
    return false

  var toWrite = graph
  if not preserveHeaderRoots:
    toWrite.header.roots = rootsDescriptor(config.trackedRoots)
  let jsonStr = $toJson(toWrite, config.trackedRoots)
  let (ok, err) = atomicPublish(finalPath, jsonStr)
  if not ok:
    stderr.write("crisol: warning: could not write depgraph: " & err & "\n")
    return false
  true

# ---------------------------------------------------------------------------
# Public: recovery policy (issue #5)
# ---------------------------------------------------------------------------

proc recordClosure*(graph: var DepGraph; config: Config; ep: Entrypoint;
                    nimcacheDir, binaryName: string;
                    protocolMajor: int; index: SourceIndex;
                    driver: DriverResolver;
                    ccRun: RunProc = realRunIn(config.projectRoot.absolutePath.normalizedPath)):  # canon-ok: real compile subprocess cwd
                    tuple[ok: bool, error: string] =
  ## Extract, hash, and persist one entrypoint's source closure after a
  ## successful compile — the single place issue #5's recovery policy lives.
  ##
  ## `index` — a `SourceIndex` (`buildSourceIndex(config)`) used to resolve
  ## `@p`/`@n` closure entries (issue #8).  Built ONCE per run by the caller
  ## (`runner.execute`) and passed through for every entrypoint — never
  ## rebuilt per entrypoint (it is a pure function of the source tree, not
  ## of any single compile).
  ##
  ## `driver` — the run's driver resolution (`headerprobe.siteResolver`
  ## over `ccidentity.ToolchainProbe.site`): the file the build's nim runs for
  ## each compile command's driver token, which that command's header
  ## probe runs (R10-S6); threaded through to `closure.extractCompileInputs`,
  ## which asks it only when a header probe is about to run. Required: a
  ## caller with no resolution passes one answering `DriverLocation(found:
  ## false, ...)`, and every probe refuses.
  ##
  ## `ccRun` — the `cc -M` header-probe seam (issue #16), threaded through to
  ## `closure.extractCompileInputs`; defaults to `toolrun.realRunIn(config.
  ## projectRoot)` (rfc-0007 A2c, issue #17) — replays `cc -M` from
  ## projectRoot, the SAME directory the real compile ran `cc` from,
  ## regardless of the crisol process's own cwd. Tests inject a synthetic
  ## runner; production (`runner.execute`) uses the default.
  ##
  ## Extraction (issue #16) now goes through `closure.extractCompileInputs`,
  ## not `closure.extractClosure` directly: it additionally derives, for
  ## every `{.compile.}`d single-path external this entrypoint names, the
  ## header set it `#include`s (folded into the closure) and the entry's
  ## `externals` list. `carried` is fed the CURRENT entry's `externals` (if
  ## one already exists for this `(path, flagHash)` key) so a warm recompile
  ## — where Nim serves an external's object from its own cache and the
  ## manifest carries no `cc` command to re-probe — carries the header set
  ## FORWARD instead of losing it (see `extractCompileInputs`'s doc comment).
  ##
  ## When it runs: at the compile→run transition, BEFORE the fresh binary is
  ## promoted to the stable path (that happens only after the run), and
  ## only through `runner.retireThenRecordClosure`, which has already
  ## retired the PREVIOUS stable binary. That operation is the issue #26
  ## guard: the entry this persists never sits beside a binary built from
  ## other sources, even when the run is cut short before promotion. The
  ## runner reaches this (through its `recordClosureFn` seam) from that
  ## operation only.
  ##
  ## Policy: a compile whose closure cannot be recorded must not leave the
  ## previous entry in place — a stable binary will be promoted after the
  ## run, so nothing would recompile and the stale record would be served
  ## as fresh. Invalidating instead makes decideCompile see `cdStale` and
  ## narrowByDiff force-include the entrypoint (unknown closure).
  ##
  ## On success: `updateEntry` + `saveDepGraph`, returns `(ok: true, "")` —
  ## UNLESS the save itself fails (issue #13.3), in which case this returns
  ## `(ok: false, "dependency graph could not be persisted")`. The in-memory
  ## graph already holds the new entry at that point (this run's own
  ## selection logic sees it correctly), but nothing describes it on disk;
  ## the caller (the runner) must treat this exactly like an extraction
  ## failure — see below — and never promote the binary this compile built
  ## (`runner.decideExit`'s `bdDiscardUnrecorded`), so the NEXT run starts
  ## from `cdNeverBuilt` rather than trusting a stable binary the on-disk
  ## depgraph does not (yet, or ever) describe. Without that binary-discard
  ## step, a later revert of the source back to whatever the STALE on-disk
  ## entry's hash matches would make decideCompile find that stale entry
  ## AND the (wrongly-provenanced) stable binary, and serve the binary that
  ## was actually built from the edited sources — silently wrong output.
  ##
  ## On ANY `CatchableError` (missing/unparseable manifest, empty `link` —
  ## see `extractClosure` — or `updateEntry`'s NONEMPTY-CLOSURE refusal):
  ## `invalidateEntry` + `saveDepGraph`, returns `(ok: false, e.msg)`. If
  ## THAT save also fails, `e.msg` gains "; dependency graph could not be
  ## persisted" — the in-memory invalidation happened, but it did not reach
  ## disk either, so the caller's binary-discard step applies here too: the
  ## previous stable binary (if any) must not be trusted for the same
  ## reason as the success-path persist failure above.
  ##
  ## The caller only needs to warn on `not ok` and discard the stable
  ## binary; no further recovery step is needed on either path.
  let key = entryKey(ep.tp, ep.flags)
  let fHash = key.flagHash
  let epAbs = toNative(ep.tp, config.trackedRoots)
  try:
    let carried = if key in graph.entries: graph.entries[key].externals else: @[]
    let inputs = extractCompileInputs(nimcacheDir, binaryName, epAbs, config,
                                      index, carried, driver, ccRun)
    # RFC-0009 A4b: `extractCompileInputs` now returns `files` as
    # `HashSet[TrackedPath]` directly — already filtered through
    # `index.tracked`/`classify`'s pcTracked gate inside `closure.nim`
    # (analyzeManifest only ever `incl`s a member after that check), so no
    # re-classify round trip is needed at this boundary any more (the
    # A3c-ii string->TrackedPath conversion this replaces).
    #
    # Content hash is computed over `closureHashInputs(inputs.files, …)` —
    # the SAME derivation `planner.decideCompile` uses at check time, from
    # the SAME classify-filtered set. See `closureHashInputs`.
    let contentHash = closureContentHash(
      closureHashInputs(inputs.files, config.trackedRoots))
    # Issue #25: the links these members may have been reached through,
    # re-resolved by every later freshness check (`entryDrift`). Computed
    # before `updateEntry` so a failure here invalidates like any other
    # extraction failure instead of leaving an entry without its links.
    let links = crossedLinks(index, inputs.files)
    graph.updateEntry(key.path, fHash, inputs.files, links, contentHash,
                      protocolMajor, inputs.externals)
    if saveDepGraph(graph, config):
      result = (ok: true, error: "")
    else:
      result = (ok: false, error: "dependency graph could not be persisted")
  except CatchableError as e:
    graph.invalidateEntry(key.path, fHash)
    if saveDepGraph(graph, config):
      result = (ok: false, error: e.msg)
    else:
      result = (ok: false, error: e.msg & "; dependency graph could not be persisted")

proc loadStoredDepGraph*(config: Config; discarded: var DepGraphDiscard): DepGraph =
  ## Load the graph from `<projectRoot>/<stateDir>/depgraph` exactly AS
  ## PERSISTED — the stored header's `nimVersion` is preserved verbatim, with
  ## NO comparison against "the current Nim version" (that freshness
  ## judgment is `loadDepGraph`, below, which layers it on top of this
  ## proc).
  ##
  ## This is the loader `crisol clean` must use (issue #12): a clean GCs the
  ## graph against the discovered entrypoint set and must never depend on,
  ## or silently stamp over, the fingerprint the pipeline compares on the
  ## next `run` — using the freshness view here loaded every real graph as
  ## empty (its header never equals the `""` a clean could pass), so a clean
  ## GC'd nothing and reported 0 dropped.
  ##
  ## discarded reports WHY a persisted graph was discarded at load (dgdNone
  ## when nothing was discarded):
  ## - Missing file → empty graph (not an error); dgdNone. Header nimVersion
  ##   is "" — there is no stored value to preserve.
  ## - Unreadable file → empty graph, header ""; dgdMalformed with the IO
  ##   error text. No direct stderr write here — the caller surfaces
  ##   `discarded` as a `ConfigWarning` (sanitized by `message`), the single
  ##   report channel; see the `except` clause below for why both `IOError`
  ##   and `OSError` are caught.
  ## - Malformed JSON, or valid JSON with an unexpected shape → empty graph,
  ##   header ""; dgdMalformed with the parse-error text or a short shape
  ##   reason. The caller's `ConfigWarning` (built from discarded) is now
  ##   the sole report for this — no separate stderr write here, to avoid
  ##   double-reporting the same discard.
  ## - Format-version mismatch → empty graph, header ""; dgdFormatVersion.
  ## - Otherwise → the graph as stored, header nimVersion == the value on
  ##   disk (whatever it is — no comparison performed here).
  let path = depgraphPath(config)
  discarded = DepGraphDiscard(kind: dgdNone)

  if not fileExists(path):
    # NOTE: `fileExists` (see std/private/oscommon) returns false for
    # anything that is not a regular file or symlink — a directory, device
    # file, named pipe, or socket at `path` all land here as dgdNone
    # ("missing"), never reach `readFile` below, and therefore can NEVER
    # exercise the dgdMalformed "unreadable" branch. Only a regular file
    # (or symlink to one) that exists but cannot be READ — e.g. permission
    # denied — reaches that branch.
    #
    # TOCTOU: a swap of `path` for a FIFO between this `fileExists` check and
    # the `readFile` below would block the read indefinitely (no reader has
    # attached to unblock `open()` on the FIFO's other end). Accepted: doing
    # so requires write access to crisol's own state dir, at which point an
    # attacker already has far more direct ways to disrupt this process.
    return initDepGraph("", "")

  var raw: string
  try:
    raw = readFile(path)
  except IOError, OSError:
    # `readFile` raises `IOError` (std/syncio), NOT `OSError` — the two are
    # unrelated CatchableError subtypes, so `except OSError` alone never
    # fires and an unreadable-but-present file (EACCES, or a race where the
    # file is removed between `fileExists` and `readFile`) would otherwise
    # propagate as an unhandled exception all the way to the CLI. Catch
    # both explicitly rather than relying on inheritance. (Nim's `except`
    # does not support an `as` binding on a multi-type list, hence
    # `getCurrentException` here instead of `except IOError, OSError as e`.)
    let e = getCurrentException()
    discarded = DepGraphDiscard(kind: dgdMalformed,
                                stored: "unreadable: " & e.msg)
    return initDepGraph("", "")

  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError as e:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: e.msg)
    return initDepGraph("", "")
  except Exception as e:
    discarded = DepGraphDiscard(kind: dgdMalformed, stored: e.msg)
    return initDepGraph("", "")

  result = fromJson(node, config.trackedRoots, discarded)

  # M10 soundness: re-validate closure paths from the on-disk graph.
  #
  # Rule (issue #13.1, historical — describes the ORIGINAL closure-path
  # implementation this section's own doc, below, explains is now SUBSUMED
  # by `fromKeyBytes`-at-parse in `fromJson`; retained for the threat-model
  # rationale, which still applies): one rule for every closure path,
  # absolute or relative alike. Normalize each path to a candidate absolute
  # location — `p` itself if already absolute, else `projectRoot / p` — and
  # keep the path (stored VERBATIM, exactly as read from disk) iff that
  # candidate is projectRoot or a configured depRoot, or lives under one of
  # them (`cand == root or cand.startsWith(root & DirSep)`). Everything else
  # is dropped silently. (RFC-0009 F13: the externals filter, below, now
  # applies the analogous `fromKeyBytes`-based check directly —
  # `validKeySpelling` — rather than this normalize-and-bounds-check form,
  # since `source`/`headers` are `paths.keyBytes` spellings too, not native
  # paths.)
  #
  # Threat model: a tampered or corrupt depgraph file could carry an
  # absolute path like "/etc/shadow", or — the #13.1 gap this closes — a
  # RELATIVE path such as "../../etc/passwd" that `closureContentHash`
  # would resolve via `projectRoot / relPath` to the very same place.
  # Relative paths are project-root-relative BY CONTRACT (see
  # closureContentHash, above, and DepGraphEntry.closure); admitting a
  # relative path without normalizing and bounds-checking it first let a
  # `..`-laden path escape the root exactly like an unchecked absolute one
  # would, and the guard existed to prevent only the latter. A legitimate
  # relative path that simply resolves inside the root (deleted deps
  # included — that staleness is handled by `isEntryStale`, not here) is
  # unaffected: it is still admitted, just via the same normalized
  # bounds-check every path now goes through.
  #
  # Deliberately NOT applied: symlink/realpath resolution. The closure
  # extractor's tracking policy (crisol/closure.underAnyRoot, and its
  # callers' doc comments) is deliberately LEXICAL — a source file reached
  # through a symlink inside a tracked root is recorded at its LEXICAL path
  # and hashed THROUGH the link, by design (see closure.nim's discussion of
  # `realEpDir`/`epDir` around the `@m`/`@p` resolution). Resolving
  # symlinks here, at load time, would silently disagree with that: every
  # legitimately symlinked-outside source would be dropped from the loaded
  # closure, the loaded set would then miss what `closureContentHash` hashed
  # at record time, the stored `closureHash` would never match again, and
  # such a project would recompile on every single run — for no added
  # defense, since a tampered depgraph only ever changes what gets HASHED
  # (a comparison outcome), never what gets DISCLOSED to the caller; there
  # is no channel here that reveals file contents. See
  # tests/unit/test_soundness_m10.nim's symlink-retention blocks (issue
  # #13.2) for the pin proving this stays lexical.
  proc validKeySpelling(s: string): bool =
    ## RFC-0009 F13: M10 guard for `entry.externals[].source`/`.headers[]`,
    ## now that both are `paths.keyBytes` spellings (`closure.
    ## closureMemberSpelling`) rather than a raw absolute/projectRoot-
    ## relative NATIVE path. `fromKeyBytes` is the SAME grammar-inverse
    ## `entry.closure` members already round-trip through in `fromJson`,
    ## above — an unresolvable/escaping spelling means the same thing here
    ## it means there: corrupt/hand-crafted text, or a renamed/removed dep
    ## root (already caught at the HEADER level by `loadDepGraph`'s
    ## dgdRootUnknown check before any caller sees these entries — see
    ## `fromJson`'s doc for why a `none` surviving that far can only mean
    ## corruption).
    ##
    ## SUPERSEDES the pre-F13 `underRootNorm` predicate (removed): that
    ## treated `source`/`headers` as an absolute-or-projectRoot-relative
    ## NATIVE path — correct for the pre-F13 spelling, but not even a valid
    ## READING of a dep-root member's portable `dep:<name>/<rel>` spelling
    ## (joining it onto projectRoot and testing root-membership would
    ## silently fail for essentially every dep-root external, dropping the
    ## record rather than validating it).
    fromKeyBytes(s, config.trackedRoots).isSome

  proc isPlainBasename(s: string): bool =
    ## M10 guard for `entry.externals[].obj` (issue #16): per
    ## `closure.ExternalSource.obj`'s contract, this field is documented as
    ## a bare object BASENAME, never a resolvable path — so the guard here
    ## is "contains no path separator and is not '..'", not a root-boundary
    ## check (there is no directory to resolve it against; it names an
    ## object inside a nimcache dir crisol never persists a rooted path
    ## for).
    if s.len == 0: return false
    if '/' in s or '\\' in s: return false
    if s == "..": return false
    true

  for key in toSeq(result.entries.keys):
    var entry = result.entries[key]
    # RFC-0009 A3c-ii/W1: the closure-path M10 filter that used to run HERE
    # (drop any string member not under a tracked root) is now SUBSUMED by
    # the `fromKeyBytes`-at-parse conversion in `fromJson`, above — every
    # member already surviving into `entry.closure` is a `TrackedPath` that
    # `fromKeyBytes` successfully resolved; an unresolvable/malformed member
    # was already dropped there. `entry.closure` needs no further filtering
    # here.

    # M10, extended (issue #16): `entry.externals[].source` must resolve
    # under a tracked root (same rule/gate as a closure path — an
    # ExternalSource whose `source` escapes is fully untrustworthy, so the
    # WHOLE record is dropped, not just its `source` field) and `.obj` must
    # be a plain basename; `.headers[]` are filtered per-path, mirroring
    # `entry.closure`'s own per-path filtering above (an escaping header is
    # dropped, the rest of the record is kept).
    var filteredExternals: seq[ExternalSource] = @[]
    for ext in entry.externals:
      if not validKeySpelling(ext.source): continue
      if not isPlainBasename(ext.obj): continue
      var keptHeaders: seq[string] = @[]
      for h in ext.headers:
        if validKeySpelling(h):
          keptHeaders.add h    # kept VERBATIM — exactly as read from disk
      var kept = ext
      kept.headers = keptHeaders
      filteredExternals.add kept

    # Defense in depth — see DepGraphEntry.closure, invariant NONEMPTY-CLOSURE:
    # the writer refuses to record an empty closure, but if one reaches disk
    # anyway (or every member was dropped as unresolvable/malformed at
    # fromKeyBytes-parse-time, above), treat it as absent so decideCompile/
    # narrow re-derive it.
    if entry.closure.len == 0:
      result.entries.del(key)
      continue
    entry.externals = filteredExternals
    result.entries[key] = entry
# SOUNDNESS-PARAMETER WARNING (round-2 review R2-7; ENFORCED round 3, R3-7;
# text corrected round 4, R4-5, 2026-09-24): `ccVersion` below is a soundness
# parameter of the shape that produced defect L1 -- it is the C-toolchain half
# of the FRESHNESS view, so the value it carries decides whether a graph
# recorded under a DIFFERENT C toolchain is discarded as stale or accepted as
# fresh. It no longer carries a default: the compiler now says so at the call
# site, via the deprecated compatibility overloads in the R3-7 section below
# (a hard error under `dev check`'s `--warningAsError:Deprecated:on`). Pass it
# EXPLICITLY, including "" when you mean "no probe available". Full rationale
# on those overloads, on `planner.cachePath`'s, and at R2-7/R3-7 in
# docs/handoff/msvc-selection-layer.md.

proc loadDepGraph*(config: Config; nimVersion: string; discarded: var DepGraphDiscard;
                   ccVersion: string): DepGraph =
  ## Load the graph and apply the FRESHNESS view for `nimVersion`/`ccVersion`
  ## (the caller's notion of "the current Nim compiler / C toolchain" —
  ## normally `nimprobe.cachedNimFingerprint()` and
  ## `toolchainwarn.toolchainIdentity` over the probed `CcFingerprint`): loads
  ## the graph as persisted via `loadStoredDepGraph`, then, if its header
  ## nimVersion OR ccVersion does not match, discards it as stale and
  ## returns an empty graph stamped with the REQUESTED `nimVersion`/
  ## `ccVersion` instead of the stored values.
  ##
  ## `ccVersion` (W3) HAS NO DEFAULT (R3-7; this paragraph corrected in round 4,
  ## R4-5, 2026-09-24 — it previously described a `""` default that had already
  ## been removed, contradicting both the signature above and the R3-7 section
  ## below). Passing `""` is still the "no probe available — test/cold-start
  ## caller" convention `nimVersion` uses, and it still behaves exactly as
  ## before: a stored header stamped `""` then matches and is accepted with no
  ## C-toolchain check, while one stamped with a real cc identity mismatches
  ## and is discarded (`ccMismatch` below). But it has to be said out loud —
  ## `loadDepGraph(cfg, nimVersion, discarded, "")`. The pre-W3 3-arg shape
  ## `loadDepGraph(cfg, nimVersion, discarded)` still compiles, via a
  ## `{.deprecated.}` overload (R3-7 section below), so that choosing to
  ## run without a cc probe appears in the diff that chooses it
  ## instead of in whether the author knew the parameter existed.
  ##
  ## This is the loader every consumer OTHER than `clean` must use (the
  ## compile-avoidance/impact-analysis pipeline: `run`, `closure`, `list`,
  ## ...) — a graph recorded under a different Nim compiler OR C toolchain
  ## cannot be trusted for staleness decisions, so it must be treated as
  ## absent. `clean` uses `loadStoredDepGraph` directly instead (see its
  ## doc): GCing the on-disk entry set must not depend on, or silently
  ## overwrite, the recorded fingerprints.
  ##
  ## discarded reports WHY a persisted graph was discarded at load (dgdNone
  ## when nothing was discarded); see `loadStoredDepGraph` for the
  ## dgdMalformed/dgdFormatVersion/missing-file cases, all unchanged here.
  ## On top of those, this proc adds:
  ## - Stored nimVersion present (non-"") and different from `nimVersion` →
  ##   empty graph stamped with `nimVersion`/`ccVersion`; dgdNimVersion(stored, current).
  ## - Stored nimVersion "" with a NON-empty entries table (the
  ##   loadStoredDepGraph missing-file/malformed/format-mismatch paths
  ##   already return "" with zero entries, so this only fires for a
  ##   genuinely-stored empty-string header — legacy/test data) and
  ##   `nimVersion` also differs from "" → same treatment: dgdNimVersion.
  ## - Otherwise, the SAME two checks against `ccVersion` (W3):
  ##   stored ccVersion observably different from `ccVersion` → empty graph
  ##   stamped with `nimVersion`/`ccVersion`; dgdCcVersion(stored, current).
  ##   Checked only once the nimVersion check above has already passed (a
  ##   nimVersion mismatch is reported as dgdNimVersion, never masked by a
  ##   simultaneous cc mismatch).
  ## - Otherwise (stored versions == requested versions, including "" == "")
  ##   → loaded cleanly; whatever `loadStoredDepGraph` reported stands.
  var stored = loadStoredDepGraph(config, discarded)
  if discarded.kind != dgdNone:
    # Already discarded by loadStoredDepGraph (missing file / malformed /
    # format mismatch) — re-stamp the header with the REQUESTED versions so
    # the caller's "empty graph" carries the versions it will compare
    # against on the next write, exactly as before this refactor.
    return initDepGraph(nimVersion, ccVersion)

  # A mismatch is flagged only when it is OBSERVABLE: an inert empty-string
  # header with zero entries is indistinguishable from "no file" (that is
  # exactly what a missing file loads as via loadStoredDepGraph) and must
  # stay dgdNone — otherwise a plain `--config` run with no depgraph yet
  # would spuriously report a nimVersion discard on its very first run.
  let mismatch = stored.header.nimVersion != nimVersion and
                 (stored.entries.len > 0 or stored.header.nimVersion != "")
  if mismatch:
    discarded = DepGraphDiscard(kind: dgdNimVersion,
                                stored: stored.header.nimVersion,
                                current: nimVersion)
    return initDepGraph(nimVersion, ccVersion)

  # W3: the cc-version sibling of the nimVersion check above, same
  # observability guard (an inert "" header with zero entries never trips
  # this on a cold-start/no-probe caller). Checked AFTER the nimVersion
  # check has already passed, so a simultaneous nim+cc change is always
  # reported as dgdNimVersion (nimVersion is the higher-priority signal).
  # This ordering was inherited from decideCompile's own two arms, which round 5
  # (R3-8) removed; it is pinned here now, by test_depgraph.nim's
  # `test_both_versions_changed_reported_as_nim`.
  let ccMismatch = stored.header.ccVersion != ccVersion and
                   (stored.entries.len > 0 or stored.header.ccVersion != "")
  if ccMismatch:
    discarded = DepGraphDiscard(kind: dgdCcVersion,
                                stored: stored.header.ccVersion,
                                current: ccVersion)
    return initDepGraph(nimVersion, ccVersion)

  # RFC-0009 A3c-i: depgraph-header validity for the root descriptor —
  # NEVER a cache/ledger version concern (§4), so this lives only in the
  # freshness loader, exactly like the nimVersion check above.  Each
  # persisted root's NAME is resolved against the CURRENT
  # `config.trackedRoots`: unresolvable (a renamed/removed dep root) →
  # dgdRootUnknown; resolvable but a `foldPolicy` disagreement →
  # dgdFoldMismatch (never compared cross-policy — see DepGraphHeader.roots).
  proc currentFoldPolicy(name: string; ok: var bool): FoldPolicy =
    ok = true
    if name == "": return config.trackedRoots.project.foldPolicy
    for d in config.trackedRoots.deps:
      if d.name == name: return d.foldPolicy
    ok = false

  for r in stored.header.roots:
    var resolved: bool
    let cur = currentFoldPolicy(r.name, resolved)
    if not resolved:
      discarded = DepGraphDiscard(kind: dgdRootUnknown, stored: r.name)
      return initDepGraph(nimVersion, ccVersion)
    if cur != r.foldPolicy:
      discarded = DepGraphDiscard(kind: dgdFoldMismatch,
                                  stored: $r.foldPolicy, current: $cur)
      return initDepGraph(nimVersion, ccVersion)

  stored.header.nimVersion = nimVersion
  stored.header.ccVersion  = ccVersion
  result = stored

# SOUNDNESS-PARAMETER WARNING (round-2 review R2-7; ENFORCED round 3, R3-7;
# text corrected round 4, R4-5, 2026-09-24): `ccVersion` below is a soundness
# parameter of the shape that produced defect L1, for the same reason as on the
# 4-arg overload above -- it decides whether a graph recorded under a DIFFERENT
# C toolchain is discarded as stale or accepted as fresh. It no longer carries a
# default: the compiler now says so at the call site, via the deprecated
# compatibility overloads in the R3-7 section below (a hard error under `dev
# check`'s `--warningAsError:Deprecated:on`). Pass it EXPLICITLY, including ""
# when you mean "no probe available". Full rationale on those overloads, on
# `planner.cachePath`'s, and at R2-7/R3-7 in
# docs/handoff/msvc-selection-layer.md.
proc loadDepGraph*(config: Config; nimVersion: string; ccVersion: string): DepGraph =
  ## Load the graph, discarding load provenance. See the 4-arg overload
  ## (with the `discarded: var DepGraphDiscard` out-parameter) for the full
  ## behavior and for observing WHY a persisted graph was discarded.
  var d: DepGraphDiscard
  result = loadDepGraph(config, nimVersion, d, ccVersion)

# ---------------------------------------------------------------------------
# R3-7 — deprecated compatibility overloads for loadDepGraph
# ---------------------------------------------------------------------------
##
## `ccVersion` on both `loadDepGraph` overloads above no longer defaults to "".
## It is the C-toolchain half of the FRESHNESS view: passing "" compares the
## stored header against "". A graph stamped with a real cc identity trips
## `ccMismatch` in `loadDepGraph`, which discards it and returns
## `initDepGraph(nimVersion, "")` -- an EMPTY graph now stamped "" (a one-time
## over-invalidation, not a per-load one). Once the caller saves that graph,
## every later "" load finds a ""-stamped header and accepts it with no
## C-toolchain check at all, whatever toolchain built its entries (the
## unsound half). That is a soundness parameter with a
## convenient default — the shape R2-7 catalogued and defect L1 was caused by —
## and the default is exactly what made an omission invisible in review.
##
## These two keep every existing call site compiling (63 were measured, nearly
## all in tests) while the compiler names the omission at the caller's own
## file:line. Full rationale on `planner.cachePath`'s deprecated overload
## (R3-7). No ambiguity between the two 3-arg shapes: the deprecated one's
## third parameter is `var DepGraphDiscard`, the full one's is `ccVersion:
## string`.

proc loadDepGraph*(config: Config; nimVersion: string;
                   discarded: var DepGraphDiscard): DepGraph
    {.deprecated: "R3-7: pass ccVersion explicitly (\"\" when no probe is available) — omitting it checks the stored header against \"\": a graph stamped with a real C-toolchain identity is discarded, the rebuilt graph the caller then saves is stamped \"\", and a \"\"-stamped graph is accepted by every later \"\" load with no C-toolchain check, whatever toolchain built it".} =
  loadDepGraph(config, nimVersion, discarded, "")

proc loadDepGraph*(config: Config; nimVersion: string): DepGraph
    {.deprecated: "R3-7: pass ccVersion explicitly (\"\" when no probe is available) — omitting it checks the stored header against \"\": a graph stamped with a real C-toolchain identity is discarded, the rebuilt graph the caller then saves is stamped \"\", and a \"\"-stamped graph is accepted by every later \"\" load with no C-toolchain check, whatever toolchain built it".} =
  loadDepGraph(config, nimVersion, "")
