# crisol

A host-side, out-of-process, assertion-agnostic Nim test runner and impact-analysis tool.

crisol discovers test entrypoints, compiles and runs them in parallel with per-entrypoint isolated nimcaches, aggregates results with continue-on-failure, and — given a git diff — runs only the tests a change actually affects.

## What crisol is not

- Not an assertion library — std/unittest is unchanged.
- Not a property-testing library — proptest is a consumer that runs as a test binary under crisol.
- Not compiled into production binaries — it is build-time tooling only.

## Status

Pre-v1. RFC in review (`docs/rfc/0001-crisol-test-runner.md`). No implementation yet.

## Design

See [`docs/rfc/0001-crisol-test-runner.md`](docs/rfc/0001-crisol-test-runner.md) for the full design, architecture, and open questions.

## Distribution

Consumed via the [`milpa`](https://github.com/knurl/milpa) dep resolver using a local path pin. Not published to a public registry.

## License

MIT
