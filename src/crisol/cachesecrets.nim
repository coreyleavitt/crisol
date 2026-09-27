## cachesecrets.nim — the one test for the remote-cache credential namespace.
##
## The remote-cache credentials (`CRISOL_CACHE_TOKEN[_<TIER>]`,
## `CRISOL_CACHE_HMAC_KEY`, `CRISOL_CACHE_SIGN_KEY`) are env-borne, and every
## place that reads, scrubs or ignores them must agree on which names they
## are: `runcore.resolveCacheSecrets` (the read and the `delEnv` scrub),
## `sandbox.filterEnv` (a test child's environment), `toolexec.toolEnv` (a
## tool's environment) and `ccidentity.realStamp` (the probe memo's stamp).
##
## The name test follows the environment's own case rule: on Windows variable
## names are case-insensitive, so `getEnv("CRISOL_CACHE_TOKEN")` returns a
## `crisol_cache_token` set by the caller, and that spelling is a credential
## like any other. Elsewhere names are exact, and a lower-case spelling is a
## different variable that nothing reads.
##
## A leaf with no crisol imports: `sandbox` is pure and must not pull in the
## process layer `toolexec` sits on.

import std/strutils

const CacheSecretPrefix* = "CRISOL_CACHE_"
  ## The namespace. Compared through `cacheSecretKey`, never directly.

func cacheSecretKey*(name: string): string =
  ## `name` in the form the environment compares it in: upper-cased on
  ## Windows, unchanged elsewhere. Two names with the same key are the same
  ## variable, so a credential read by its canonical name is the variable a
  ## scrub of any spelling of it removes.
  when defined(windows): name.toUpperAscii
  else: name

func isCacheSecretName*(name: string): bool =
  ## Whether `name` is in the `CRISOL_CACHE_*` namespace.
  cacheSecretKey(name).startsWith(CacheSecretPrefix)
