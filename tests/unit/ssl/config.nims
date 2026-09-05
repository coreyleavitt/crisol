# tests/unit/ssl/config.nims — RFC-0005 C1a.
#
# Nim loads config.nims/nim.cfg from the compiled file's own directory AND
# every parent directory up to the root (see
# tests/integration/test_closure_searchpath.nim for the mechanism, proven
# against a real compile). This file lives ONLY in tests/unit/ssl/, and
# test_ssl_link.nim is the only test file in that directory, so -d:ssl is
# scoped to that one probe — it does not leak into the rest of tests/unit
# (a shared directory with every other unit test file), tests/integration,
# tests/conformance, or src/. nim.cfg is milpa-generated ("do not edit"),
# so a project config.nims is the only place this flag can live.
switch("define", "ssl")
