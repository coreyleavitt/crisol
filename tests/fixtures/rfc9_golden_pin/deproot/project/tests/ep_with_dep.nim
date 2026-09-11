# ep_with_dep.nim — RFC-0009 A0 golden-pin fixture: the entrypoint half of
# the depRoot vector. The dep-root member itself lives OUTSIDE this
# project, at ../../depstore/dep/member.nim (see that file's own comment).
# No real import is needed here — the depRoot closure member is injected
# via a hand-written nimcache manifest (test_rfc9_golden_pin.nim), mirroring
# tests/unit/test_soundness_r7.nim's convention, so this file's own content
# only needs to be real, stable, and readable by chainedContentHash.
discard
