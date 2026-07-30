## ep_a.nim — golden_reuse fixture entrypoint A (RFC-0006 M-golden-fixture).
##
## Reaches `fixture_substrate.substrateA` (NOT `substrateB`) and
## `fixture_ffi.fixtureDouble` — the same FFI call `ep_b.nim` makes. Kept to
## pure-int arithmetic (no `echo`/`$`/`format`) to keep the pulled-in stdlib
## substrate (`system`, etc.) as small as possible: this fixture must stay
## small enough for a human to hand-verify the closed-form reuse ratios.

import ./fixture_substrate
import ./fixture_ffi

let v = substrateA() + int(fixtureDouble(1))
quit(v)
