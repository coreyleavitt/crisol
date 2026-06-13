## deptest_extra.nim — conditional module for D1a dependency-chain fixture.
## Imported by deptest_main.nim ONLY when -d:extraDep is set.
## Used to verify that compile arrays differ by flag set.

proc extraValue*(): int = 999
