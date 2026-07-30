## ep_b.nim — golden_reuse fixture entrypoint B (RFC-0006 M-golden-fixture).
##
## Reaches `fixture_substrate.substrateB` (NOT `substrateA`) and
## `fixture_ffi.fixtureDouble` — the same FFI call `ep_a.nim` makes. See
## ep_a.nim's doc comment for why this stays pure-int / echo-free.

import ./fixture_substrate
import ./fixture_ffi

let v = substrateB() + int(fixtureDouble(1))
quit(v)
