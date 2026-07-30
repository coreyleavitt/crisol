/* fixture.h — companion C header for the golden_reuse fixture (RFC-0006
 * M-golden-fixture). Deliberately tiny: this is the "companion C header in
 * the include closure with per-slot -I variance" the RFC's soundness
 * argument turns on — a real cc invocation must read a header from a
 * non-nimcache -I path, not merely stdlib.
 */
#ifndef CRISOL_FIXTURE_H
#define CRISOL_FIXTURE_H

int crisol_fixture_double(int x);

#endif
