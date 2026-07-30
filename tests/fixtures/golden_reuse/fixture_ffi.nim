## fixture_ffi.nim — golden_reuse fixture: companion-C-header FFI wrapper
## (RFC-0006 M-golden-fixture).
##
## This is the fixture's designated **shared / byte-identical** reusable
## unit: both ep_a and ep_b import this module and call `fixtureDouble`
## identically, so ORC's whole-program DCE reaches the exact same code from
## both entrypoints and the generated `.c` (after the fixed 4-line per-slot
## header is stripped) is byte-for-byte identical across the two.
##
## `{.compile.}` pulls in the companion `fixture.c`; `{.header.}` makes the
## generated `.c` `#include "fixture.h"` literally — the header itself lives
## in `include/`, reachable only via an explicit `-I<fixture>/include` passed
## at compile time (NOT auto-discovered from the nimcache), which is exactly
## the include-closure / `-I`-variance the RFC's soundness argument turns on.

{.compile: "fixture.c".}

proc fixtureDouble*(x: cint): cint {.importc: "crisol_fixture_double", header: "fixture.h".}
