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
