## test_rfc0007_w4_cgroup_memory_peak.nim — rfc-0007 wiring-audit W4: the
## cgroup `memory.peak` reader (`process/cgroup.nim`'s `cgroupLeafMemoryPeak`)
## that supersedes wait4 as the ledger's tagged-successor maxRss producer.
##
## Mirrors r12's fake-leaf idiom (test_rfc0007_r12_cgroup_killsnapshot.nim):
## `cgroupLeafMemoryPeak` reads `<leaf>/memory.peak` as a PLAIN TEXT FILE —
## a single unadorned integer, no cgroupfs-specific syscalls — so it is
## provable here with a plain temp directory standing in for a leaf, no real
## cgroup-v2 delegation required. Only the CI `cgroup` job proves the real
## kernel-maintained file end-to-end (test_rfc0007_b3_cgroup.nim's suite 1
## and tests/integration/test_rfc0007_a5_ledger_maxrss.nim's cgroup-tier
## suite assert against it directly).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_w4_cgroup_memory_peak.nim

when defined(linux):
  import std/[options, os, unittest]
  import crisol/process/posixcore

  suite "rfc-0007 w4 — cgroupLeafMemoryPeak: a real value file reads back exactly":

    test "a leaf with a known integer in memory.peak reads back that exact value":
      let dir = getTempDir() / ("crisol_w4_leaf_" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "memory.peak", "123456789\n")

      let peak = cgroupLeafMemoryPeak(dir)
      require peak.isSome
      check peak.get == 123456789'i64

    test "a leaf that genuinely peaked at 0 bytes still reads back some(0), not none":
      let dir = getTempDir() / ("crisol_w4_leaf_zero_" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "memory.peak", "0\n")

      let peak = cgroupLeafMemoryPeak(dir)
      require peak.isSome
      check peak.get == 0'i64

  suite "rfc-0007 w4 — cgroupLeafMemoryPeak: absent/malformed is honestly none, never a fabricated value":

    test "a leaf path that does not exist at all yields none":
      let missingDir = getTempDir() / ("crisol_w4_missing_" & $getCurrentProcessId())
      removeDir(missingDir)   # ensure it genuinely does not exist

      check cgroupLeafMemoryPeak(missingDir).isNone

    test "a memory.peak file with non-numeric content yields none, not a crash":
      let dir = getTempDir() / ("crisol_w4_malformed_" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "memory.peak", "max\n")   # a real cgroup v2 sentinel value
                                                  # some peer files use — never
                                                  # a crisol-produced numeric peak
      check cgroupLeafMemoryPeak(dir).isNone

    test "an empty memory.peak file yields none":
      let dir = getTempDir() / ("crisol_w4_empty_" & $getCurrentProcessId())
      removeDir(dir)
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "memory.peak", "")

      check cgroupLeafMemoryPeak(dir).isNone

  when isMainModule:
    echo "test_rfc0007_w4_cgroup_memory_peak: done"
else:
  when isMainModule:
    echo "CRISOL-SKIP: tests/unit/test_rfc0007_w4_cgroup_memory_peak.nim"
    echo "test_rfc0007_w4_cgroup_memory_peak: skipped (linux-only cgroup mechanism)"
