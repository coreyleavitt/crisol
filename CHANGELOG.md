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

### Added

- `crisol clean --config <path>` — `clean` now accepts `--config <path>` so it
  honours a project's custom `state-dir` setting.  Previously `clean` always
  used the default `.crisol/` directory regardless of config.
- `crisol --version` / `-V` — prints `crisol <version>` and exits 0.
- `crisol init [path] [--force]` — writes a canonical starter `crisol.kdl` to
  `path` (default `./crisol.kdl`); refuses to overwrite without `--force`.
- `--help` / `-h` now writes usage to **stdout** and exits 0.  (Previously
  printed to stderr with a non-zero code in some paths.)
- `clean` subcommand and `-j` / `-t` short forms documented in `--help` output.
