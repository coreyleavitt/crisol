## tests/support/ccprobes.nim -- fingerprint-only views of the C toolchain
## probe, for tests (R12-D7).
##
## Production reads the probe as one `ccidentity.ToolchainProbe` (the
## fingerprint and the driver site together, R11-D1), through the one
## memo, `ccidentity.cachedToolchainProbe`. These wrappers used to be
## exported from `ccidentity` although nothing in `src/` called them, which
## made them look like supported surface; they are test conveniences.
##
## Not a `test_*.nim` file, so the self-discovering test task never runs it.

import crisol/ccidentity

proc ccFingerprintWith*(io: CcProbeIo): CcFingerprint =
  ## `ccProbeWith(io).fp`: the derivation over injected effects.
  ccProbeWith(io).fp

proc ccFingerprint*(ctx: CcProbeContext): CcFingerprint =
  ## The real probe (`probeRun`), unmemoized.
  probeRun(ctx).toolchain.fp

proc cachedCcFingerprint*(ctx: CcProbeContext): CcFingerprint =
  ## The production memo's fingerprint (`cachedToolchainProbe`).
  cachedToolchainProbe(ctx).fp

proc cachedCcVersion*(ctx: CcProbeContext): string =
  ## `$cachedCcFingerprint(ctx)`: the serialized fingerprint. For an
  ## IDENTIFIED toolchain this is the run's toolchain identity
  ## (`toolchainwarn.toolchainIdentity`), which the depgraph header,
  ## `KeyInputs.ccVersion` and the persistent nimcache path carry. For an
  ## unidentified one it is NOT: since R10-S4 a run keys on
  ## `toolchainIdentity(fp, nonce)`, `$fp` plus a nonce drawn per run, so no
  ## run's key equals this string (R11-D4).
  $cachedCcFingerprint(ctx)
