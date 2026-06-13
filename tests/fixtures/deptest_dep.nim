## deptest_dep.nim — level-2 module for D1a dependency-chain fixture.
## Imported by deptest_main.nim; itself imports deptest_dep2 (3-level chain).

import ./deptest_dep2

proc depValue*(): int = dep2Value() + 1
