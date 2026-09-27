## cache_env_probe.nim — prints whether the remote-cache credentials reached
## this process (CR18). One line per variable: `NAME=<value>` or
## `NAME=<UNSET>`. `CRISOL_TOOL_CONTROL` is not a cache variable: it must
## arrive, which proves the environment is still inherited at all.

import std/os

const probeVars = ["CRISOL_CACHE_TOKEN", "CRISOL_CACHE_TOKEN_MIRROR",
                   "CRISOL_CACHE_HMAC_KEY", "CRISOL_CACHE_SIGN_KEY",
                   "CRISOL_CACHE_TOKEN_LC", "CRISOL_TOOL_CONTROL"]

for name in probeVars:
  echo name & "=" & getEnv(name, "<UNSET>")
