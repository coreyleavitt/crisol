## test_cachesecrets.nim — one `CRISOL_CACHE_*` name test, applied alike by
## every site that reads, scrubs or ignores the remote-cache credentials.
##
## On Windows environment names are case-insensitive: `getEnv(
## "CRISOL_CACHE_TOKEN")` returns a `crisol_cache_token` the caller set. Such
## a spelling was used as the credential, yet the run's `delEnv` scrub and
## `sandbox.filterEnv` matched the prefix case-sensitively, so it reached the
## compile child and `--hermetic none` test binaries. Pinned here, per site:
##
##   - `isCacheSecretName` / `cacheSecretKey`: case-insensitive exactly where
##     the environment is (Windows), exact elsewhere;
##   - `sandbox.filterEnv`: a test child's environment never holds one;
##   - `runcore.resolveCacheSecrets`: whatever spelling it read the
##     credential from is what it removes, including a per-tier token, which
##     is keyed by its canonical suffix so the tier lookup still finds it;
##   - `ccidentity.realStamp`: the memo stamp ignores the namespace.
##
## The Windows half runs in the Windows unit sweep; on POSIX the same checks
## pin the other side of the rule (a lower-case name is another variable).
##
## Run with:
##   nim r --hints:off --warnings:off --path:src tests/unit/test_cachesecrets.nim

import std/[options, os, strutils, tables, unittest]
import crisol/[cachesecrets, sandbox, runcore, ccidentity, cacheregistry, types]

const foldsCase = defined(windows)

suite "isCacheSecretName: one predicate, the environment's own case rule":

  test "the exact prefix is in the namespace":
    check isCacheSecretName("CRISOL_CACHE_TOKEN")
    check isCacheSecretName("CRISOL_CACHE_TOKEN_MIRROR")
    check isCacheSecretName("CRISOL_CACHE_HMAC_KEY")
    check isCacheSecretName("CRISOL_CACHE_")

  test "a near miss is not":
    check not isCacheSecretName("CRISOL_CACHE")
    check not isCacheSecretName("CRISOL_CACHEX")
    check not isCacheSecretName("XCRISOL_CACHE_TOKEN")
    check not isCacheSecretName("CRISOL_SINK")
    check not isCacheSecretName("")

  test "another spelling matches exactly where the environment folds case":
    check isCacheSecretName("crisol_cache_token") == foldsCase
    check isCacheSecretName("Crisol_Cache_Hmac_Key") == foldsCase

  test "cacheSecretKey is the environment's comparison form":
    check cacheSecretKey("CRISOL_CACHE_TOKEN") == "CRISOL_CACHE_TOKEN"
    when foldsCase:
      check cacheSecretKey("crisol_cache_token_mirror") == "CRISOL_CACHE_TOKEN_MIRROR"
    else:
      check cacheSecretKey("crisol_cache_token_mirror") == "crisol_cache_token_mirror"

suite "every credential site applies the one predicate":

  test "filterEnv: no spelling of a credential reaches a --hermetic none child":
    let spec = resolveSandbox(hlNone)
    let parent = @[("CRISOL_CACHE_TOKEN", "upper"),
                   ("crisol_cache_lower", "lower"),
                   ("Crisol_Cache_Mixed", "mixed"),
                   ("HOME", "/home/probe")]
    var names: seq[string] = @[]
    for (k, _) in filterEnv(parent, spec, @[]): names.add k
    checkpoint("child env names: " & $names)
    check "HOME" in names
    check "CRISOL_CACHE_TOKEN" notin names
    check ("crisol_cache_lower" in names) == not foldsCase
    check ("Crisol_Cache_Mixed" in names) == not foldsCase

  test "resolveCacheSecrets: the spelling it reads is the spelling it removes":
    putEnv("crisol_cache_hmac_key", "lower-hmac")
    putEnv("crisol_cache_token", "lower-bare")
    putEnv("crisol_cache_token_mirror", "lower-mirror")
    putEnv("crisol_cache_unknown", "lower-other")
    putEnv("CRISOL_CACHE_TOKEN_UPPERTIER", "upper-tier")
    let secrets = resolveCacheSecrets()
    var left: seq[string] = @[]
    for k, _ in envPairs():
      if k.toUpperAscii.startsWith("CRISOL_CACHE_"): left.add k   # independent of the predicate
    checkpoint("namespace left in the environment: " & $left)
    # The exact spelling is read and removed on every platform.
    check secrets.httpTokens.getOrDefault("UPPERTIER") == "upper-tier"
    check getEnv("CRISOL_CACHE_TOKEN_UPPERTIER") == ""
    when foldsCase:
      check secrets.hmacKey == some("lower-hmac")
      check secrets.defaultHttpToken == some("lower-bare")
      check secrets.httpTokens.getOrDefault("MIRROR") == "lower-mirror"
      check left.len == 0
    else:
      # Another variable here: not read, not removed.
      check secrets.hmacKey.isNone
      check secrets.defaultHttpToken.isNone
      check "MIRROR" notin secrets.httpTokens
      check "mirror" notin secrets.httpTokens
      check getEnv("crisol_cache_hmac_key") == "lower-hmac"
      check getEnv("crisol_cache_unknown") == "lower-other"
    for k in ["crisol_cache_hmac_key", "crisol_cache_token",
              "crisol_cache_token_mirror", "crisol_cache_unknown"]:
      delEnv(k)

  test "realStamp: the memo stamp ignores every spelling of the namespace":
    let root = getTempDir() / "crisol_cachesecrets_stamp"
    createDir(root)
    defer: removeDir(root)
    let ctx = CcProbeContext(projectRoot: root, stateDir: root / ".crisol", flags: @[])
    let base = realStamp(ctx, @[])
    putEnv("CRISOL_CACHE_STAMP_UPPER", "x")
    check realStamp(ctx, @[]) == base
    delEnv("CRISOL_CACHE_STAMP_UPPER")
    putEnv("crisol_cache_stamp_lower", "x")
    check (realStamp(ctx, @[]) == base) == foldsCase
    delEnv("crisol_cache_stamp_lower")
    check realStamp(ctx, @[]) == base
