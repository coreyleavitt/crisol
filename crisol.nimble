# Package

version     = "0.1.0"
author      = "Corey Leavitt"
description = "Host-side, out-of-process, assertion-agnostic Nim test runner + impact analysis"
license     = "MIT"
srcDir      = "src"

bin = @["crisol"]

# Dependencies

requires "nim >= 2.0"

# --- Tasks ---------------------------------------------------------------
# Bootstrap rule (RFC Testing Strategy): the unit suite ALWAYS runs serially
# via plain `nim c -r`, forever — never replaced by the eventual dogfood run.
# Self-discovering so new test files need no manual registration.
#
# CRISOL_TEST_DIRS (colon-separated, optional): overrides the default dir
# list (["tests/unit", "tests/integration"]) when set. Used by CI to point
# the harness at tests/meta (the deliberately-failing dummy, proving honest
# exit-code propagation) and tests/timing (the serial timing leg) without
# ever letting those dirs leak into a default `nimble test` run.
#
# Honest-exit contract: every discovered file runs, even after an earlier
# one fails (NimScript's `exec` raises `OSError` on a nonzero child exit —
# confirmed empirically, not assumed — so each `exec` is individually
# try/except'd rather than letting the task abort at the first failure).
# Failures are collected and reported in a summary; the task `quit(1)` if
# any file failed, so the process exit code is never a false 0 as observed
# from `nim e` directly.
#
# IMPORTANT — nimble's own process exit code is NOT trustworthy for a custom
# task's failure (verified against nimble 0.22.2 source): a failing custom
# task surfaces to nimble's main() as `NimbleError` (`object of CatchableError`),
# which main()'s `except CatchableError` branch displays but never turns into
# a nonzero `exitCode` — only `NimbleQuit` (`object of Defect`, raised solely
# by nimble's own built-in commands, unreachable from a NimScript task body)
# does that. So `nimble test` itself always exits 0 at the process level,
# regardless of this task's `quit(1)`. To get an honest exit code from
# outside nimble, this task ALSO writes a plain marker file
# (`.crisol-test-result`, gitignored) as its last action before quitting;
# `ci/run-tests.sh` is the wrapper that reads it and is what `./dev test`,
# `./dev timing`, and CI actually invoke instead of bare `nimble test`.
import std/[algorithm, os, strutils]

const resultMarker = ".crisol-test-result"

task test, "run the unit + integration suites serially (bootstrap runner)":
  let dirsEnv = getEnv("CRISOL_TEST_DIRS")
  let dirs = if dirsEnv.len > 0: dirsEnv.split(':') else: @["tests/unit", "tests/integration"]
  var files: seq[string]
  for dir in dirs:
    if dirExists(dir):
      for f in walkDirRec(dir):
        if f.endsWith(".nim") and f.extractFilename.startsWith("test_"):
          files.add f
  files.sort()
  var failed: seq[string]
  for t in files:
    try:
      exec "nim r --hints:off --warnings:off --path:src " & t
    except OSError:
      failed.add t
  if failed.len > 0:
    writeFile(resultMarker, "FAIL")
    echo "FAILED: " & $failed.len & " file(s)"
    for f in failed:
      echo "  " & f
    quit(1)
  else:
    writeFile(resultMarker, "OK")
    echo "OK: " & $files.len & " file(s)"
