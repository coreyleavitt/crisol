## test_envscrub.nim — unit tests for filterEnv and hermeticEnvHash (A5)

import std/[unittest, sequtils]
import crisol/[types, sandbox]

suite "filterEnv":
  test "no-scrub: all parent env passes through, injected vars appended":
    let spec = SandboxSpec(level: hlNone, envScrub: false)
    let parent = @[("HOME", "/root"), ("SECRET", "s3cr3t"), ("PATH", "/usr/bin")]
    let injected = @[("CRISOL_SINK", "/tmp/sink")]
    let result = filterEnv(parent, spec, injected)
    # All parent vars present
    check result.anyIt(it[0] == "HOME" and it[1] == "/root")
    check result.anyIt(it[0] == "SECRET" and it[1] == "s3cr3t")
    check result.anyIt(it[0] == "PATH" and it[1] == "/usr/bin")
    # Injected appended at end
    check result[^1] == ("CRISOL_SINK", "/tmp/sink")

  test "scrub=true: unlisted var SECRET_XYZ is dropped":
    let spec = SandboxSpec(
      level: hlIsolated, envScrub: true,
      envAllowlist: @["HOME", "PATH"],
      envAllowlistPrefixes: @[],
    )
    let parent = @[("HOME", "/root"), ("SECRET_XYZ", "forbidden"), ("PATH", "/usr/bin")]
    let result = filterEnv(parent, spec, @[])
    check not result.anyIt(it[0] == "SECRET_XYZ")
    check result.anyIt(it[0] == "HOME")
    check result.anyIt(it[0] == "PATH")

  test "scrub=true: allowlisted var PATH is kept":
    let spec = SandboxSpec(
      level: hlIsolated, envScrub: true,
      envAllowlist: @["PATH"],
      envAllowlistPrefixes: @[],
    )
    let parent = @[("PATH", "/usr/bin"), ("GOPATH", "/go")]
    let result = filterEnv(parent, spec, @[])
    check result.anyIt(it[0] == "PATH" and it[1] == "/usr/bin")
    check not result.anyIt(it[0] == "GOPATH")

  test "scrub=true + LC_* prefix: LC_ALL kept, GOPATH dropped":
    let spec = SandboxSpec(
      level: hlIsolated, envScrub: true,
      envAllowlist: @["PATH"],
      envAllowlistPrefixes: @["LC_"],
    )
    let parent = @[("PATH", "/usr/bin"), ("LC_ALL", "en_US.UTF-8"), ("GOPATH", "/go")]
    let result = filterEnv(parent, spec, @[])
    check result.anyIt(it[0] == "LC_ALL" and it[1] == "en_US.UTF-8")
    check not result.anyIt(it[0] == "GOPATH")

  test "scrub=true: injected vars survive even if not in allowlist":
    let spec = SandboxSpec(
      level: hlIsolated, envScrub: true,
      envAllowlist: @["PATH"],
      envAllowlistPrefixes: @[],
    )
    let parent = @[("PATH", "/usr/bin"), ("SECRET", "drop-me")]
    let injected = @[("CRISOL_SINK", "/tmp/sink"), ("CRISOL_ATTEMPT", "1")]
    let result = filterEnv(parent, spec, injected)
    check not result.anyIt(it[0] == "SECRET")
    check result.anyIt(it[0] == "CRISOL_SINK")
    check result.anyIt(it[0] == "CRISOL_ATTEMPT")

  test "scrub=true: output is deterministic (filtered portion sorted by name)":
    let spec = SandboxSpec(
      level: hlIsolated, envScrub: true,
      envAllowlist: @["HOME", "PATH", "USER"],
      envAllowlistPrefixes: @[],
    )
    # Provide parent in reverse-alpha order
    let parent1 = @[("USER", "alice"), ("PATH", "/usr/bin"), ("HOME", "/root")]
    let parent2 = @[("HOME", "/root"), ("USER", "alice"), ("PATH", "/usr/bin")]
    let r1 = filterEnv(parent1, spec, @[])
    let r2 = filterEnv(parent2, spec, @[])
    check r1 == r2
    # Verify sorted order: HOME < PATH < USER
    check r1[0][0] == "HOME"
    check r1[1][0] == "PATH"
    check r1[2][0] == "USER"

suite "hermeticEnvHash":
  test "same input produces same hash (stable)":
    let env = @[("HOME", "/root"), ("PATH", "/usr/bin"), ("USER", "alice")]
    check hermeticEnvHash(env) == hermeticEnvHash(env)

  test "different TMPDIR values produce the same hash (name hashed, value skipped)":
    let env1 = @[("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-abc123")]
    let env2 = @[("PATH", "/usr/bin"), ("TMPDIR", "/tmp/run-xyz999")]
    check hermeticEnvHash(env1) == hermeticEnvHash(env2)

  test "changing an allowlisted value changes the hash":
    let env1 = @[("PATH", "/usr/bin"), ("HOME", "/root")]
    let env2 = @[("PATH", "/usr/local/bin"), ("HOME", "/root")]
    check hermeticEnvHash(env1) != hermeticEnvHash(env2)

  test "CRISOL_SINK and CRISOL_ATTEMPT are excluded from hash":
    let base = @[("PATH", "/usr/bin"), ("HOME", "/root")]
    let withSink = base & @[("CRISOL_SINK", "/tmp/sink1"), ("CRISOL_ATTEMPT", "1")]
    let withSinkDiff = base & @[("CRISOL_SINK", "/tmp/other-sink"), ("CRISOL_ATTEMPT", "5")]
    check hermeticEnvHash(base) == hermeticEnvHash(withSink)
    check hermeticEnvHash(withSink) == hermeticEnvHash(withSinkDiff)

when isMainModule:
  echo "test_envscrub done"
