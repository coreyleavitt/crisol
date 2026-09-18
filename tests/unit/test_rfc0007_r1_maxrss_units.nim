## test_rfc0007_r1_maxrss_units.nim — rfc-0007 code-review finding r1:
## `decodeRusage` scaled `ru_maxrss` by 1024 UNCONDITIONALLY. Linux reports
## `ru_maxrss` in KILOBYTES (so *1024 is correct there); Darwin reports it
## in BYTES ALREADY (the same convention `readVmRssBytes`'s libproc arm
## documents for `pti_resident_size`) — the old code shipped every macOS
## reap's maxRssBytes 1024x inflated.
##
## `maxRssBytesFrom` is the extracted pure helper (posixcore.nim) — both
## platform arms are pinned here directly, on ANY host, with no macOS
## machine required to catch a regression in either one.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_r1_maxrss_units.nim

import std/unittest
import crisol/process/posixcore

suite "rfc-0007 r1 — maxRssBytesFrom platform unit scaling":

  test "linux arm: raw kilobytes scaled by 1024 to bytes":
    check maxRssBytesFrom(1_024, darwin = false) == 1_048_576

  test "darwin arm: raw value already bytes — passed through unscaled":
    ## This is the new assertion the r1 fix adds — against the old
    ## unconditional `* 1024` logic this would have observed 1_048_576
    ## instead of the correct 1_024 (a 1024x inflation).
    check maxRssBytesFrom(1_024, darwin = true) == 1_024

  test "zero stays zero on both arms":
    check maxRssBytesFrom(0, darwin = false) == 0
    check maxRssBytesFrom(0, darwin = true) == 0

echo "test_rfc0007_r1_maxrss_units: done"
