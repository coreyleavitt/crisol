## tests/support/driversite.nim -- the `toolchain` a test hands
## `runner.execute` and `runcore.verifyCachePass` (R12-D4: one required
## `RunToolchain`, the probe and the identity keyed on it, built only by
## `runToolchain` or `unkeyed`), and the driver sites inside it (R11-D1).
##
## Not a `test_*.nim` file, so the self-discovering test task never runs it.

import crisol/[ccidentity, fnv, toolchainwarn, types, pipeline]
export toolchainwarn.RunToolchain, toolchainwarn.identity, toolchainwarn.site,
       toolchainwarn.probe

proc unprobedSite*(): DriverSite =
  ## For a run that compiles no C external and measures no compile reuse:
  ## no discovery, and a header probe, should one run, refuses rather than
  ## guessing a driver. A measured run needs `hostSite`: the measure worker
  ## resolves every generated C unit's driver against the site, and an
  ## unknown site leaves the artifact ledger empty.
  DriverSite(known: false,
             why: "this test learned no driver site (it compiles no C external)")

proc hostSite*(cfg: Config): DriverSite =
  ## The real, memoized discovery's site for `cfg`: what a production run
  ## of the same configuration resolves each compile command's driver
  ## against.
  cachedToolchainProbe(ccProbeContextOf(cfg)).site

proc unprobedToolchain*(): RunToolchain =
  ## Keyed on nothing (no nimcache suffix), with `unprobedSite`.
  unkeyed(unprobedSite())

proc hostUnkeyed*(cfg: Config): RunToolchain =
  ## Keyed on nothing, with the real discovery's site (`hostSite`).
  unkeyed(hostSite(cfg))

proc hostToolchain*(cfg: Config): RunToolchain =
  ## Exactly what a production run of `cfg` keys on: the real, memoized
  ## probe and its identity.
  runToolchain(cachedToolchainProbe(ccProbeContextOf(cfg)),
               proc(): string = "test-run-nonce")

proc fakeToolchain*(tag: string; site = unprobedSite()): RunToolchain =
  ## An IDENTIFIED toolchain named `tag` (printable, no `|` or `#`), for a
  ## test that needs distinct keys without a real probe: its identity is
  ## `"<tag> #<hex>|runtime of <tag> #<hex>"`, stable per tag.
  let hex = toHex16(fnv1a64(tag))
  let (fp, ok) = parseCcFingerprint(tag & " #" & hex & "|runtime of " & tag & " #" & hex)
  doAssert ok, "fakeToolchain: not a valid toolchain tag: " & tag
  runToolchain(ToolchainProbe(fp: fp, site: site),
               proc(): string = raiseAssert "an identified toolchain draws no nonce")
