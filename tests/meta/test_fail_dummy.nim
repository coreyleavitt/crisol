## test_fail_dummy.nim — A0 CI meta-test dummy (rfc-0007).
##
## This file always fails. It exists to prove, mechanically, that a failing
## test file actually turns the harness's exit code nonzero — the "honest
## exit codes" half of slice A0. Without a deliberately-failing dummy, an
## exit-0-on-failure regression in the nimble `test` task (as happened
## historically — see docs/rfc/0004-incremental-hermetic-execution.handoff.md)
## would go undetected by CI.
##
## Run ONLY by the CI meta step, which points the harness at this directory
## explicitly:
##
##   CRISOL_TEST_DIRS=tests/meta ./dev run env CRISOL_TEST_DIRS=tests/meta nimble test
##
## `tests/meta` is deliberately outside the nimble task's default dir list
## (["tests/unit", "tests/integration"]), so this file is NEVER discovered
## by a normal `./dev test` / `nimble test` run — only by the meta step that
## opts in via CRISOL_TEST_DIRS.

doAssert false, "deliberate failure: CI meta-test asserting nonzero exit propagates"
