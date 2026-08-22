# Changelog

All notable changes to crisol are documented here.

---

## Unreleased

### BREAKING CHANGE — `--base` without `--changed` is now an error (exit 3)

**Prior behaviour:** `crisol run --base <ref>` without `--changed` emitted a
warning to stderr and then ran normally (exit 0), silently ignoring the base
ref.

**New behaviour:** `crisol run --base <ref>` without `--changed` exits
immediately with code 3 and an error message:

```
crisol: error: --base requires --changed (a base ref without impact selection has no effect)
```

**Rationale:** `--base` is meaningful only when combined with `--changed`
(impact selection via git diff).  Supplying `--base` alone is always a
mistake; a silent no-op masked the error and produced a confusing full run.

**Migration:** If you shell out to `bin/crisol` and pass `--base` without
`--changed`, add `--changed` or remove `--base`.  amoxtli shells out to
`bin/crisol` and is directly affected — update its invocation before
upgrading.

### BREAKING CHANGE — dependency graph format 3: one-time full recompile (issue #5)

**Prior behaviour:** the per-entrypoint source closure was derived from the
nimcache manifest's `compile` array.  That array is Nim's per-invocation C
work list — complete only on a cold nimcache, partial on a warm recompile,
and empty when an edit changes no generated C.  The first incremental
recompile therefore persisted a truncated or empty closure, after which the
entrypoint could never go stale: compile avoidance, the result cache and
`--changed` selection all reported it fresh forever (masked-red incident).

**New behaviour:** the closure is derived from the manifest's `link` array,
which is complete on every compile.  `DepGraphFormatVersion` is now 3: an
existing `.crisol/depgraph` written by an older crisol is discarded on first
load, so the **next run recompiles every entrypoint once** and re-records
trustworthy closures.  Entries written by the old extractor cannot be healed
in place — a truncated closure hash-matches itself forever — which is why the
whole graph is discarded rather than migrated.

**Also:** an empty closure is never recorded (it is a crisol defect, reported
on stderr); when a compile succeeds but its closure cannot be recorded, the
entrypoint's dependency record is invalidated so it is recompiled and
force-selected next run instead of serving the previous, stale record.
Entrypoints outside `projectRoot`/`dep-roots` (library-API callers only) now
warn and recompile every run instead of being silently fresh forever. A
result whose closure could not be recorded is also NOT written to the result
cache (reported as `cacheDecision` `"closureUnrecorded"` in `--json`).

**Migration:** nothing to do; budget one full-suite compile after upgrading.

### Changed — search-path-resolved modules are now in closures (issue #8)

**Prior behaviour:** a module the compiler resolved through any nim search
path other than `projectRoot`, `projectRoot/src`, or a configured `dep-roots`
entry (+`/src`) — e.g. shared test helpers made importable by a
`tests/config.nims` `switch("path", thisDir())`, or a first-party library on
`--path:lib/x/src` — was silently absent from every closure.  Editing such a
module re-selected nothing under `--changed` and never invalidated the
compiled binary.

**New behaviour:** crisol builds a per-run index of every `.nim` file under
`projectRoot` (dot-directories, `nimcache`, the state dir, and symlinked
directories are skipped) plus each `dep-roots` entry, and resolves a
search-path-relative module to every indexed file that ends with that
relative path.  No configuration is needed for in-tree helpers; `dep-roots`
remains the opt-in for out-of-tree content (e.g. `_deps/<x>` symlinks into a
content store).  Closures may grow (they are now complete), so expect a
one-time recompile of entrypoints whose closure gained members.

### Fixed

- **closure:** `@p`/`@n` bodies with leading `..` components — the shape Nim
  emits when the shortest relative path to a module runs from a `--path`
  root that isn't the module's ancestor (e.g. an in-root `../lib/x` import
  that is shorter measured from `--path:src` than from the importing file),
  or when a search-path root is reached through a symlink and Nim
  realpath-canonicalizes the resolved source (e.g. a milpa `_deps/<dep>`
  symlink into the CAS) — are now resolved.  Previously `SourceIndex.lookup`
  suffix-matched the *whole, unstripped* body against indexed absolute
  paths, so any body containing `..` matched nothing and the module silently
  dropped out of the closure (unsound: an edit to that file would not
  re-select the entrypoint under `--changed`).  The index now records each
  file's realpath alongside its lexical path, and `lookup` strips every
  leading `""`/`"."`/`".."` component before matching against either — a
  pure widening of the match, so still sound under the R7 over-selection
  policy.  The reported/recorded path remains the lexical one.  A follow-up
  found this still missed a related shape: a realpath-relative `@p`/`@n`
  body whose file lives under a directory `walkForIndex` prunes for WALK
  COST (a dot-dir or a `nimcache` dir) *inside* a tracked root — e.g. a
  milpa `_deps/<dep>` symlink whose target sits under a dot-dir inside
  projectRoot itself, rather than in an external CAS, with no `dep-roots`
  entry naming that dot-dir directly.  The compiler resolves and
  realpath-canonicalizes the import fine (the symlink is on the search
  path), but nothing under the pruned directory was ever indexed, so
  `SourceIndex.lookup` misses and the module silently dropped out of the
  closure.  That pruning is a walk-cost decision, not a tracking decision:
  when `lookup` returns no match at all, `resolveMangledAll`'s `@p`/`@n`
  branch now falls back to an existence check — the same stripped suffix
  joined onto each of `index.roots` in turn, keeping whichever candidate(s)
  exist on disk (`fileExists`/`symlinkExists`).  Sound (every candidate is
  under a tracked root by construction, and nothing is fabricated when no
  candidate exists), and consistent with the R7 over-selection policy when
  more than one root matches.
- **closure:** an `@m`-mangled `link` entry (Nim's entrypoint-directory-
  relative candidate, the mangler's default choice whenever it is not
  strictly longer than the `@p`/`@n` search-path-relative one) can *also*
  carry a realpath through a symlinked dep-root when the entrypoint is
  shallow enough for `@m` to still win — e.g. a depth-1 entrypoint
  importing a module via a milpa `_deps/<dep>` symlink into the CAS.
  Previously `resolveMangledAll` resolved `@m` bodies with a single
  `(entrypointDir / body).normalizedPath` candidate; when that candidate
  fell outside every tracked root (the realpath-through-symlink case) the
  under-tracked-root filter silently dropped it, so the dep was absent from
  the closure and an edit to it never re-selected the entrypoint under
  `--changed` (unsound).  A first fix (commit 38e094e) recovered the
  candidate by unioning it against `@p`/`@n`'s SUFFIX-based `SourceIndex`
  lookup, but review found that fallback over-selects: an `@m` body that
  escapes every tracked root because it names a genuinely UNTRACKED,
  out-of-root import (no dep-root of its own) could still suffix-match an
  unrelated same-basename/same-suffix decoy elsewhere in the tree, wrongly
  pulling it into the closure and churning `closureHash`/`--changed`
  selection.  `SourceIndex` now also indexes every file by its realpath
  (`byReal`), and the `@m` fallback resolves through an EXACT realpath
  match (`lookupByReal`) instead of a suffix scan: a genuine
  symlinked-dep-root escape has an indexed file at that exact realpath and
  is recovered at its lexical path, while an untracked import has none and
  correctly adds nothing.  Separately, when the entrypoint's OWN directory
  is itself reached through a symlink whose lexical path depth differs from
  its real path depth, the compiler computes the `@m` body from the real
  directory; joining that body onto the lexical directory (the prior
  behaviour in all cases) could land on a bogus, nonexistent path instead of
  the real dependency.  `resolveMangledAll` now detects that case
  (`expandFilename(epDir) != epDir`) and resolves the body from the real
  entrypoint directory instead, via the same exact-realpath lookup.  A
  follow-up review round found `expandFilename(epDir)` itself insufficient:
  Nim's `@m` base is `parentDir(realpath(ENTRYPOINT FILE))`, not `realpath`
  of the entrypoint's *directory* — a symlinked entrypoint FILE sitting
  inside an otherwise ordinary, non-symlinked directory (crisol's own
  discovery admits such entrypoints) left `expandFilename(epDir) == epDir`,
  so the code wrongly took the lexical-candidate branch and recorded a
  bogus, nonexistent sibling — `closureContentHash` then raised on the
  missing file on every subsequent run, permanently invalidating the entry
  (a perpetual "could not record its source closure … force-selected"
  warning, precision lost for that entrypoint).  `realEpDir` is now computed
  from `parentDir(expandFilename(entrypointPath))` (falling back to
  `expandFilename(epDir)`, then `epDir`, on an `OSError`), which subsumes
  the symlinked-directory case too.  Also, the real-candidate branch's
  fallback (when `lookupByReal` misses — e.g. a dependency deleted since the
  index was built) no longer falls back to the lexical candidate
  unconditionally: that candidate is not what the compiler actually saw in
  this branch, and could itself be a bogus-but-in-root path.  It is now used
  only when it exists on disk (`fileExists`/`symlinkExists`); otherwise the
  real candidate itself is kept and left to `extractClosure`'s ordinary
  under-tracked-root filter, exactly like any other out-of-root import.
- **closure:** `decodeBody` now decodes Nim's `@c` (`:`) and `@h` (`#`)
  mangling escapes in addition to `@s` and `@@`; a module path containing a
  colon or hash character previously failed to decode correctly.
- **depgraph:** a discarded depgraph (recorded `nimVersion` differs from the
  current compiler fingerprint, or `formatVersion` differs from
  `DepGraphFormatVersion`) now surfaces as a structured warning in
  `run`/`list`/`closure` output and JSON, instead of silently falling back
  to an empty graph.  Previously, after a Nim upgrade, `crisol closure --all`
  reported `recorded:false` for every entrypoint with exit 0 —
  indistinguishable from "never ran" — and `run`/`list` silently
  recompiled and force-selected everything with no explanation.
- **closure:** a positional `<entrypoint>` path whose only match was
  discovered but GATED OUT (e.g. an unset `gate` env var) now prints the
  (empty-`entries`) report and exits 0, matching `run`'s `zrkAllGated`
  contract for the identical selection.  Previously it was treated the same
  as "matched no discovered entrypoint at all" and exited 3 — a gated-out
  entrypoint is a legitimate discovery result, not a configuration error.
  `ClosureReport` gained a `gatedOut` field (mirroring `PlanReport.gatedOut`)
  to distinguish the two cases; `crisol/closure/v1` JSON now serializes it
  too (schema revision bumped to 2), mirroring `crisol/plan/v1`'s existing
  `gatedOut` array.
- **run:** the zero-runnable "no entrypoints matched" branch (exit 3) now
  populates `RunReport.plan`, so its plan-phase config warnings (including
  the depgraph-discard warning) reach stderr (and `RunReport.plan.warnings`
  for library consumers) instead of being silently dropped. Previously that
  branch built a bare `RunReport` without `plan`, so the CLI's
  `for w in rr.plan.warnings` loop had nothing to iterate.
- **closure:** a positional `<entrypoint>` selection whose only match was
  discovered but GATED OUT now prints the gate-skip diagnostic
  (`skipped group "..." — ...`) to **stdout** in human (non-JSON) mode,
  mirroring `run`'s `zrkAllGated` case exactly (both the destination and the
  wording). Previously `renderClosure` only walked `.entries` and ignored
  `.gatedOut` entirely, so a fully-gated selection exited 0 and printed
  nothing — a silent, empty-looking success indistinguishable from an error
  swallowed upstream; a first fix routed the line to stderr, which was
  itself a parity gap against `run`'s stdout placement, now closed. `--json`
  mode is unaffected: `crisol/closure/v1` already serializes `gatedOut`, and
  nothing but the JSON document is written to stdout.
- **security:** untrusted-origin diagnostic text reaching stdout/stderr is
  now sanitized through ONE shared primitive,
  `ioutils.sanitizeControlBytes` (`depgraph.nim`'s `sanitizeOneSegment`
  delegates to it as well).
  Coverage is broadened well past `ConfigWarning.message` and the ad-hoc /
  ambiguous-path warning lines (already covered) to every other DIAGNOSTIC
  write of untrusted-origin text: every `CrisolError.msg` (including config
  parse errors, which embed nkdl's raw offending source line — an
  unsanitized ESC or other control byte in a `crisol.kdl` comment or string
  previously reached the terminal/CI log raw), `RunReport.error`,
  `gateSkipMessages` lines (group names / gate env-var names read back out
  of config), and JUnit-report write-error messages. Report BODIES —
  `render`/`renderPlan`/`renderClosure`'s own columns (entrypoint paths,
  group names) — are NOT sanitized; only the diagnostics listed above are.
  Sanitization is applied PER LINE
  (control bytes replaced with `'?'`; `'\n'` itself is preserved) so
  legitimately multi-line text — a config error's caret block — keeps its
  line structure; bytes 0x80-0x9f are left alone since they are ordinary
  UTF-8 continuation bytes, not interpretable C1 controls.

### Added

- `crisol closure <entrypoint>... [--json]` / `crisol closure --all [--json]` —
  read-only depgraph introspection (issue #9).  Emits one entry per planned
  entrypoint × group/flag-set: `path`, `group`, `flagHash`, `recorded`,
  sorted `closure`, `closureHash`; JSON schema `crisol/closure/v1`
  (revision 1).  Uses crisol's own config, discovery, group-flag resolution
  and depgraph loader (including the nim-version probe), so downstream
  tools never re-implement them.  No lock, no compile.
- `crisol closure` now accepts `--config <path>` / `--config=<path>`, matching
  `run`/`list`/`clean`.  Previously `closure` always walked up from the
  current directory for `crisol.kdl`, ignoring any explicit config override.
- `crisol closure` now prints the same ad-hoc / ambiguous path diagnostics
  `run`/`list` print (`crisol: path "..." matched no configured group; using
  global flags` / `crisol: path "..." matches multiple groups (...); using
  "..."`) to stderr when a positional `<entrypoint>` argument matches no
  configured group's globs, or matches more than one.  `ClosureReport`
  gained `adHocPaths`/`ambiguousPaths` fields (populated by
  `api.closureReport()`) to carry this; the `crisol/closure/v1` JSON
  document is unchanged (revision stays 1) — `crisol/plan/v1` does not
  serialize the equivalent `DiscoveredSet` fields either, so closure/v1
  stays symmetric with it and reports the same information as stderr text.
- `crisol closure <entrypoint>...` now exits 3 with `crisol: no entrypoints
  matched — check config/globs` when a given path matches no discovered
  entrypoint, matching `run`'s behaviour.  Previously it silently printed an
  empty report and exited 0, indistinguishable from a legitimate empty
  `--all` result.  `crisol closure --all` with zero discovered entrypoints is
  unaffected: it still exits 0 with an empty `entries` array.
- `crisol clean --config <path>` — `clean` now accepts `--config <path>` so it
  honours a project's custom `state-dir` setting.  Previously `clean` always
  used the default `.crisol/` directory regardless of config.
- `crisol --version` / `-V` — prints `crisol <version>` and exits 0.
- `crisol init [path] [--force]` — writes a canonical starter `crisol.kdl` to
  `path` (default `./crisol.kdl`); refuses to overwrite without `--force`.
- `--help` / `-h` now writes usage to **stdout** and exits 0.  (Previously
  printed to stderr with a non-zero code in some paths.)
- `clean` subcommand and `-j` / `-t` short forms documented in `--help` output.
