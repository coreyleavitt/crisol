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
import std/[algorithm, os, strutils]

task test, "run the unit + integration suites serially (bootstrap runner)":
  var files: seq[string]
  for dir in ["tests/unit", "tests/integration"]:
    if dirExists(dir):
      for f in walkDirRec(dir):
        if f.endsWith(".nim") and f.extractFilename.startsWith("test_"):
          files.add f
  files.sort()
  for t in files:
    exec "nim r --hints:off --warnings:off --path:src " & t
