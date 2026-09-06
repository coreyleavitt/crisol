## test_https_capability_guard.nim — RFC-0005 review fix (L1/T-guard):
## proves the FAIL-CLOSED half of the https-capability guard added to
## `cacheregistry.configuredCache` and `config.validate` — a binary
## compiled WITHOUT `-d:ssl` (this file's own compile: tests/integration/
## carries no ssl-scoping config.nims, so it builds exactly like every
## other non-ssl unit/integration file) must turn an `https://`
## remote-cache tier into a HARD `CrisolError(cekConfig)` at plan time,
## never a silent dead tier that only shows up as an inexplicable cache
## miss once a run actually happens.
##
## The SSL-side counterpart (proving the SAME configuration does NOT raise
## this guard under `-d:ssl`) lives in
## tests/unit/ssl/test_https_capability_guard_ssl.nim, compiled under that
## directory's own `config.nims`.
##
## Lives in tests/integration/ rather than tests/unit/ purely because this
## agent's edit allowlist scoped new test files to tests/unit/ssl/* and
## tests/integration/ — there is nothing integration-specific about this
## test otherwise (no sockets, no subprocess; it is exactly the shape of a
## unit test).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##     tests/integration/test_https_capability_guard.nim

import std/[os, strutils, unittest]
import crisol/types
import crisol/cachetier
import crisol/cacheport
import crisol/cacheregistry
import crisol/cachetelemetry
import crisol/config as cfgmod

when defined(ssl):
  {.error: "test_https_capability_guard.nim asserts the NON-ssl fail-closed " &
           "behavior and must never be compiled with -d:ssl -- see " &
           "tests/unit/ssl/test_https_capability_guard_ssl.nim for the ssl side.".}

proc freshStateDir(name: string): string =
  ## Mirrors test_cachetier.nim's/test_resultcache.nim's own convention —
  ## `configuredCache` needs a real (empty) directory for its local "l1" tier.
  result = getTempDir() / ("crisol_https_guard_" & name)
  removeDir(result)
  createDir(result)

suite "cacheregistry.configuredCache — https-capability guard (non-ssl build)":

  test "an https:// remote-cache tier is a hard cekConfig error, not a silent dead tier":
    let sd = freshStateDir("configured_cache")
    let cfg = CacheConfig(remotes: @[
      RemoteTier(name: "mirror", url: "https://cache.example.com/crisol")
    ])
    var caught = false
    var kind: CrisolErrorKind
    var msg = ""
    try:
      discard configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                              secrets = CacheSecrets(), sink = NilSink[TelemetryEvent]())
    except CrisolError as e:
      caught = true
      kind = e.kind
      msg = e.msg
    check caught
    check kind == cekConfig
    check "mirror" in msg
    check "lacks TLS support" in msg
    check "-d:ssl" in msg

  test "a file:// remote-cache tier is unaffected by the guard (no TLS involved)":
    let sd = freshStateDir("configured_cache_file")
    let remoteRoot = freshStateDir("configured_cache_file_remote")
    let cfg = CacheConfig(remotes: @[
      RemoteTier(name: "mirror", url: "file://" & remoteRoot)
    ])
    let rt = configuredCache(cfg, sd, maxEntries = 0, reg = productionRegistry(),
                             secrets = CacheSecrets(), sink = NilSink[TelemetryEvent]())
    check rt.cache.tiers.len == 2
    check rt.cache.tiers[1].name == "mirror"

suite "config.validate — https-capability guard (non-ssl build)":

  test "loadConfig rejects an https:// remote-cache block with the same guard":
    let tmp = getTempDir() / "crisol_https_guard_loadconfig"
    removeDir(tmp)
    createDir(tmp)
    let kdlPath = tmp / "crisol.kdl"
    writeFile(kdlPath, """
remote-cache "mirror" {
    url "https://cache.example.com/crisol"
}
group "unit" {
    globs "tests/unit/test_*.nim"
}
""")
    var caught = false
    var kind: CrisolErrorKind
    var msg = ""
    try:
      discard cfgmod.loadConfig(configPath = kdlPath)
    except CrisolError as e:
      caught = true
      kind = e.kind
      msg = e.msg
    check caught
    check kind == cekConfig
    check "lacks TLS support" in msg
    removeDir(tmp)
