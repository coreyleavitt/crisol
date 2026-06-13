## deptest_main.nim — entrypoint for D1a dependency-chain fixture.
##
## Unconditionally imports deptest_dep (which imports deptest_dep2),
## and conditionally imports deptest_extra under -d:extraDep.
## Used by spike D1a to verify the nimcache JSON compile-array decode algorithm.

import ./deptest_dep

when defined(extraDep):
  import ./deptest_extra
  proc run(): int = depValue() + extraValue()
else:
  proc run(): int = depValue()

when isMainModule:
  let v = run()
  assert v > 0, "unexpected value: " & $v
