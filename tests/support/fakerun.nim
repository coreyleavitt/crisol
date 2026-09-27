## tests/support/fakerun.nim -- building `toolrun.RunResult`s for fake runners.
##
## Most fakes describe a candidate tool by what it printed and whether it
## succeeded. `fakeReply` maps that onto the seam's endings, following the
## real runners' contract (`toolrun.RunProc`):
##
##   ok                      -> ran, exit 0, `output` as given
##   not ok, some output     -> ran, exit 1 (a present tool that failed)
##   not ok, no output       -> never started (an absent tool)
##
## A fake that needs any other ending (a timeout, a read error, a present
## tool that failed silently) builds it directly with `ran`/`notRun`.
##
## Not a `test_*.nim` file, so the self-discovering test task never runs it.

import crisol/toolrun
import crisol/ccprobe   # DriverLocation/DriverResolver/anySepBaseName: the resolvers below

proc fakeReply*(output: string; ok: bool): RunResult =
  if ok: ran(0, output, "")
  elif output.len > 0: ran(1, output, "")
  else: notRun(reNotStarted, "fake: not on PATH")

proc locatedAt*(path: string): DriverLocation =
  ## A driver the build's nim resolved to `path` (`ccidentity.locateDriver`).
  DriverLocation(found: true, path: path)

proc asNamed*(): DriverResolver =
  ## Every driver token resolves to the file it names: the suites that are
  ## not about driver resolution.
  result = proc(driver: string): DriverLocation = locatedAt(driver)

proc locatedIn*(dir: string): DriverResolver =
  ## Every driver token resolves to its basename in `dir` (a Windows `dir`,
  ## one holding a backslash, joins with a backslash), as the build's nim
  ## would find each driver it runs in one toolchain directory.
  let sep = if '\\' in dir: "\\" else: "/"
  result = proc(driver: string): DriverLocation =
    locatedAt(dir & sep & anySepBaseName(driver))

proc unresolved*(why: string): DriverResolver =
  ## No driver token resolves: the build's nim would find none.
  result = proc(driver: string): DriverLocation =
    DriverLocation(found: false, why: why)

proc recordingResolver*(asked: ref seq[string]; inner: DriverResolver): DriverResolver =
  ## `inner`, noting each token it is asked for.
  result = proc(driver: string): DriverLocation =
    asked[].add driver
    inner(driver)
