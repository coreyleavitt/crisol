/* fixture.c — companion C source for the golden_reuse fixture (RFC-0006
 * M-golden-fixture). Pulled into the build via `fixture_ffi.nim`'s
 * `{.compile.}` pragma.
 */
#include "fixture.h"

int crisol_fixture_double(int x) {
  return x * 2;
}
