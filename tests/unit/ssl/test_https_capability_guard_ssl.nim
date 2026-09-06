## test_https_capability_guard_ssl.nim — RFC-0005 review fix (L1/T-guard):
## the SSL-side counterpart of tests/integration/test_https_capability_guard.nim
## — proves that under `-d:ssl` (this directory's own config.nims scopes the
## define here, same convention as test_ssl_link.nim/
## test_https_handshake_compiles.nim), configuring an `https://` remote-cache
## tier does NOT trip the new fail-closed guard: this build CAN dial TLS, so
## `configuredCache`/`config.loadConfig` must proceed exactly as they did
## before this slice (the guard is `when defined(ssl)`-gated dead code here).
##
## No network: `productionRegistry`'s default fetcher is never invoked here
## (`configuredCache` only builds the `TieredCache`/backend closures — a
## `lookup`/`put` is what would actually dial out, and this test never calls
## either), so this stays a pure config-wiring probe, consistent with the
## rest of this directory's "link/typecheck, no I/O" contract.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/unit/ssl/test_https_capability_guard_ssl.nim

import std/[os, unittest]
import crisol/types
import crisol/cachetier
import crisol/cacheport
import crisol/cacheregistry
import crisol/cachetelemetry
import crisol/config as cfgmod

when not defined(ssl):
  {.error: "test_https_capability_guard_ssl.nim asserts the SSL-enabled " &
           "behavior and must always be compiled with -d:ssl -- see this " &
           "directory's config.nims.".}

proc freshStateDir(name: string): string =
  result = getTempDir() / ("crisol_https_guard_ssl_" & name)
  removeDir(result)
  createDir(result)

suite "cacheregistry.configuredCache — https-capability guard is inert under -d:ssl":

  test "an https:// remote-cache tier is accepted (this build CAN dial TLS)":
    let sd = freshStateDir("configured_cache")
    let cfg = CacheConfig(remotes: @[
      RemoteTier(name: "mirror", url: "https://cache.example.com/crisol")
    ])
    let rt = configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                             secrets = CacheSecrets(), sink = NilSink[TelemetryEvent]())
    check rt.cache.tiers.len == 2
    check rt.cache.tiers[1].name == "mirror"

suite "config.validate — https-capability guard is inert under -d:ssl":

  test "loadConfig accepts an https:// remote-cache block (no cache-trust warning noise here)":
    let tmp = getTempDir() / "crisol_https_guard_ssl_loadconfig"
    removeDir(tmp)
    createDir(tmp)
    let kdlPath = tmp / "crisol.kdl"
    writeFile(kdlPath, """
cache-trust {
    policy "hmac"
}
remote-cache "mirror" {
    url "https://cache.example.com/crisol"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
    let (cfg, _) = cfgmod.loadConfig(configPath = kdlPath)
    check cfg.cache.remotes.len == 1
    check cfg.cache.remotes[0].url == "https://cache.example.com/crisol"
    removeDir(tmp)
