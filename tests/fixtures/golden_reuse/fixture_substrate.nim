## fixture_substrate.nim — golden_reuse fixture: ORC-tailored substrate module
## (RFC-0006 M-golden-fixture).
##
## This is the fixture's designated **ORC-tailored / divergent** reusable
## unit: it exports two procs, but ep_a reaches only `substrateA` and ep_b
## reaches only `substrateB`. Under `--mm:orc` whole-program dead-code
## elimination, each entrypoint's generated `.c` for THIS module contains
## only the proc it actually reaches — so the two entrypoints' copies of
## this module's `.c` differ, even though the module (and its source text)
## is identical and imported by both. This is the empirical fact the RFC's
## Motivation section is built on: reuse is NOT guaranteed by module
## identity, and must be measured on the generated content, not the source.

proc substrateA*(): int =
  1

proc substrateB*(): int =
  2
