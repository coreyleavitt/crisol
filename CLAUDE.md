# CLAUDE.md — crisol

**crisol** is a host-side, out-of-process, assertion-agnostic **Nim test runner + impact analysis** library/CLI. It discovers test entrypoints, compiles and runs them in parallel, aggregates results (continue-on-failure), supports named groups, and — given a git diff — runs only the tests a change actually affects.

It is a sibling lib (milpa/proptest tier), extracted because `lib/cel`, `lib/kdl`, proptest, fresco, and amoxtli all hand-roll the same primitive serial `nimble exec`-list runner. amoxtli is crisol's first consumer.

## What crisol is NOT
- Not an assertion/spec library — std/unittest stays; crisol runs *any* test binary (structured result protocol is opt-in; exit-code fallback otherwise).
- Not a property-testing library — proptest is a *consumer*, not a component.
- Not compiled into consumers' production binaries — it's build-time tooling.

## Conventions
- Nim, `--mm:orc`. Per-entrypoint nimcache (NEVER a shared `--nimcache` across entrypoints — ORC link collisions; this is the bug crisol must respect when orchestrating).
- Tests live in `tests/unit/` (pure) and `tests/integration/`; crisol dogfoods itself once the runner works.
- Design and locked decisions: see `docs/rfc/`.

## Compact Instructions
When compacting, preserve in the summary: the active RFC and its handoff-doc path, the current stage/round, slices done vs remaining, open forks awaiting me, and the exact resume command. After compacting, re-read the handoff doc and MEMORY.md before continuing.
