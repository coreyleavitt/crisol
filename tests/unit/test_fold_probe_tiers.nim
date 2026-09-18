## test_fold_probe_tiers.nim — RFC-0009 review-ledger F6/F7/F8/F17/F29.
##
## Direct unit coverage for probe tiers 2 (`readOnlyFallback`) and 3
## (`createAndStatFallback`), plus the Linux tier-1 casefold-refinement pure
## decode function (`decodeLinuxCasefold`) — ALL previously untested (F17):
## tier 1 (the real OS query) is definitive on every CI leg today, so a test
## driving `probeFoldPolicy` itself can never reach tiers 2/3 on this
## platform (that is exactly what `tests/conformance/test_fold_probe.nim`
## exercises for tier 1, on a real windows-latest NTFS volume). This file
## calls the tiers DIRECTLY — `readOnlyFallback`/`createAndStatFallback`/
## `fileIdentity` are exported from `crisol/paths` ONLY for this purpose
## (see each proc's own "exported ONLY for..." doc comment); `probeFoldPolicy`
## remains the sole production entry point.
##
## Fabrication notes — what IS honestly constructible on this container's
## plain ext4, without mocking anything:
##   - "flipped spelling absent" and "flipped spelling present, DISTINCT
##     file" (F6's two case-SENSITIVE-volume verdicts) are both directly
##     constructible: ext4 is case-sensitive, so `Alpha.txt`/`aLPHA.TXT` are
##     two perfectly ordinary, independently-written files.
##   - "flipped spelling present, SAME file" (F6's case-INSENSITIVE-volume
##     verdict) does NOT need a real case-insensitive volume: a HARD LINK
##     (`os.createHardlink`, portable, no `std/posix`) between a
##     case-flipped NAME pair gives two directory entries with the SAME
##     device+inode — exactly what `fileIdentity` (device+file-id) observes
##     on a genuinely case-insensitive volume. This is real coverage of the
##     identity-comparison branch, not a mock of it.
##   - tier 3's "root unwritable -> none" needs an ACTUAL permission
##     failure, which `chmod 0` does not guarantee inside a root-mapped
##     container (rootless podman maps the host user to root-in-container,
##     and root bypasses permission bits). The test PROBES for this
##     honestly — it attempts a real write after chmod-0 and self-skips,
##     with a named reason, when the container's root can write through it
##     anyway, rather than asserting a permission model that empirically
##     doesn't hold here (this project's honest-skip convention).
##   - the real `chattr +F` ext4/F2FS casefold ioctl SUCCESS path cannot be
##     exercised on ordinary, unprivileged CI (a mount-time/inode-flag
##     feature, not something this process can enable on demand) —
##     `decodeLinuxCasefold` is a PURE function taking an already-obtained
##     flags answer, so its mapping is unit-tested directly against a
##     synthetic flags value instead of faking the `ioctl` call itself; the
##     `ioctl` PLUMBING (`queryCasefoldFlag`) is exercised for its ordinary
##     failure/unsupported path by every real Linux CI run already (this
##     container's ext4 has no casefold-enabled directory to report).
##   - F29's symlink-refusal case needs the EXACT name tier 3 will use in
##     THIS process to pre-place a symlink there before calling
##     `createAndStatFallback` — `probeBaseName` is exported for exactly
##     this (its own "exported ONLY for..." doc comment), and its random
##     suffix is cached per-process, so calling it here returns the SAME
##     name tier 3's own internal call will use a moment later. Same
##     `createSymlink`-may-be-unprivileged honest-skip convention as the
##     tier-2 dangling-symlink test above.
##
## CI-fix round (2026-09-17/18) — VOLUME-AWARE tier-2 fixtures:
##   The above fabrication notes describe what is constructible on THIS
##   container's ext4 (case-sensitive). The first real macOS CI run exposed
##   that three tier-2 fixtures had baked in a case-SENSITIVE-volume
##   assumption instead of actually depending on it: macOS runners' temp
##   volume is APFS, which is case-INSENSITIVE (case-preserving) — see
##   project memory `rfc0009-macos-test-gotchas`. A single `writeFile` of
##   `Alpha.txt` makes the case-flipped spelling `alpha.txt` exist BY
##   CONSTRUCTION there (same directory entry), so "flipped spelling
##   absent" and "flipped spelling present, DISTINCT file" are unfabricable
##   on that volume — a second `writeFile` under the flipped spelling folds
##   onto the SAME file instead of creating a second one. Rather than
##   skip-everything, these fixtures now PROBE the real temp volume's own
##   case behavior once (`detectCaseInsensitiveVolume`, mirroring
##   `readOnlyFallback`'s own identity-comparison logic) and branch:
##   case-sensitive volumes keep the original three scenarios unchanged;
##   case-insensitive volumes honestly self-skip the two unfabricable ones
##   and instead run a NEW positive scenario ("flipped spelling present,
##   SAME file, REAL volume fold") that ONLY a case-insensitive volume can
##   prove without the hardlink stand-in above — the missing positive proof
##   of tier 2's insensitive branch that Linux ext4 can never exercise. The
##   dangling-symlink fall-through test's TERMINAL answer also depends on
##   volume behavior (its own fallback candidate pair folds together on an
##   insensitive volume, changing the provable verdict from `fpNone` to
##   `fpAsciiLower`); the symlink-is-skipped property itself is
##   volume-independent, so that test now asserts the volume-appropriate
##   terminal value rather than assuming ext4's.

import std/[unittest, options, os, strutils]
import crisol/paths

proc flipAsciiCaseLocal(s: string): string =
  ## Local mirror of `crisol/paths`'s private (unexported) `flipAsciiCase` —
  ## this file already duplicates tier-3 constants/logic elsewhere in spirit
  ## (see `probeBaseName`'s doc comment); kept ASCII-only, identical
  ## semantics, so the volume probe below exercises the exact same
  ## case-flip notion `readOnlyFallback` does.
  result = newString(s.len)
  for i, c in s:
    if c >= 'a' and c <= 'z': result[i] = char(ord(c) - 32)
    elif c >= 'A' and c <= 'Z': result[i] = char(ord(c) + 32)
    else: result[i] = c

proc freshDir(tag: string): string =
  result = getTempDir() / ("crisol_test_fold_tiers_" & tag & "_" & $getCurrentProcessId())
  try: removeDir(result)
  except OSError: discard
  createDir(result)

proc detectCaseInsensitiveVolume(): bool =
  ## Tiny setup probe, mirroring `readOnlyFallback`'s OWN identity-comparison
  ## logic (RFC-0009 F6): write one file, then check whether its ASCII
  ## case-flipped spelling both EXISTS and shares the same OS file identity
  ## (`fileIdentity` — device+file-id). This answers honestly for whatever
  ## volume actually backs `getTempDir()` on THIS CI leg (ext4 on the Linux
  ## container, APFS on macOS runners) instead of assuming either. Path
  ## composed directly from `getTempDir()`/`freshDir` throughout — never
  ## compared lexically against a realpath-resolved spelling (the macOS
  ## `/var` -> `/private/var` symlink gotcha; see project memory
  ## `rfc0009-macos-test-gotchas`).
  let dir = freshDir("volprobe")
  defer: removeDir(dir)
  let originalName = "CaseProbe.tmp"
  let original = dir / originalName
  writeFile(original, "x")
  let flipped = dir / flipAsciiCaseLocal(originalName)
  if not fileExists(flipped):
    return false
  let originalId = fileIdentity(original)
  let flippedId = fileIdentity(flipped)
  originalId.isSome and flippedId.isSome and originalId.get == flippedId.get

let volumeIsCaseInsensitive = detectCaseInsensitiveVolume()
  ## Computed once at process start (before any suite runs) since it is a
  ## property of the volume, not of any individual test's fixture dir.

# ---------------------------------------------------------------------------
# fileIdentity — the tier-2 identity helper itself (F6)
# ---------------------------------------------------------------------------

suite "fileIdentity — tier 2's identity helper (F6)":

  test "an existing file's identity is Some and stable across two calls":
    let dir = freshDir("fid-self")
    defer: removeDir(dir)
    writeFile(dir / "f.txt", "x")
    let a = fileIdentity(dir / "f.txt")
    let b = fileIdentity(dir / "f.txt")
    check a.isSome and b.isSome
    check a.get == b.get

  test "a nonexistent path is None":
    check fileIdentity(getTempDir() / "crisol_fileidentity_does_not_exist_xyz").isNone

# ---------------------------------------------------------------------------
# Tier 2 — readOnlyFallback (F6)
# ---------------------------------------------------------------------------

suite "readOnlyFallback (probe tier 2) — F6":

  test "flipped spelling absent -> fpNone (case-sensitive; unchanged behavior)":
    if volumeIsCaseInsensitive:
      echo "SKIPPED: this temp volume is case-insensitive (e.g. macOS " &
           "APFS) -- writing `Alpha.txt` makes its case-flipped spelling " &
           "`alpha.txt` EXIST by construction (same directory entry), so " &
           "\"flipped spelling absent\" is unfabricable here"
      skip()
    else:
      let dir = freshDir("t2-absent")
      defer: removeDir(dir)
      writeFile(dir / "Alpha.txt", "x")
      check readOnlyFallback(dir) == some(fpNone)

  test "flipped spelling present, DISTINCT file -> fpNone, PROVEN not assumed":
    # Two genuinely separate files whose names are exact case-flips of each
    # other. This is legal only on a case-sensitive volume (an insensitive
    # one could never let both coexist), so `fpNone` here is a proof, not a
    # default -- the exact F6 gap: a pre-fix probe would have seen the
    # flipped spelling exist and wrongly answered `fpAsciiLower`.
    if volumeIsCaseInsensitive:
      echo "SKIPPED: this temp volume is case-insensitive -- two files " &
           "whose names are exact case-flips of each other cannot coexist " &
           "here (the second write folds onto the first, same directory " &
           "entry), so the DISTINCT-file scenario is unfabricable"
      skip()
    else:
      let dir = freshDir("t2-distinct")
      defer: removeDir(dir)
      writeFile(dir / "Alpha.txt", "original")
      writeFile(dir / "aLPHA.TXT", "distinct")
      check readOnlyFallback(dir) == some(fpNone)

  test "flipped spelling present, SAME file, REAL volume fold -> fpAsciiLower":
    # The positive proof the hardlink test below only SIMULATES: on a
    # genuinely case-insensitive volume, no hardlink trick is needed at all
    # -- a plain write under one spelling already makes the case-flipped
    # spelling resolve to the SAME file, exactly what `fileIdentity` (and
    # so `readOnlyFallback`) is meant to detect. This is the missing
    # positive proof of tier 2's insensitive branch that Linux ext4 can
    # never exercise on its own -- only a real case-insensitive CI leg
    # (macOS/APFS) can run it, hence the skip on a case-sensitive volume.
    if not volumeIsCaseInsensitive:
      echo "SKIPPED: this temp volume is case-sensitive -- a plain " &
           "case-flipped write cannot create a same-identity pair without " &
           "the hardlink simulation in the test above; this scenario " &
           "proves the same branch via the volume's OWN real fold instead"
      skip()
    else:
      let dir = freshDir("t2-samefile-real")
      defer: removeDir(dir)
      writeFile(dir / "Gamma.txt", "content")
      check readOnlyFallback(dir) == some(fpAsciiLower)

  test "flipped spelling present, SAME file (hardlink) -> fpAsciiLower":
    # A hard link under the case-flipped name gives two directory entries
    # sharing one device+inode -- exactly what a real case-insensitive
    # volume would show `fileIdentity`, fabricated here without needing one.
    let dir = freshDir("t2-samefile")
    defer: removeDir(dir)
    writeFile(dir / "alpha.txt", "content")
    var linked = true
    try:
      createHardlink(dir / "alpha.txt", dir / "ALPHA.TXT")
    except OSError:
      linked = false
    if not linked:
      echo "SKIPPED: this environment cannot create hard links " &
           "(createHardlink raised) -- F6's same-file verdict is untestable here"
      skip()
    else:
      check readOnlyFallback(dir) == some(fpAsciiLower)

  test "empty-of-letters root -> none (no candidate; falls through to tier 3)":
    let dir = freshDir("t2-noletters")
    defer: removeDir(dir)
    writeFile(dir / "000111", "no ascii letters anywhere in this name")
    check readOnlyFallback(dir) == none(FoldPolicy)

  test "a dangling-symlink candidate is skipped in favor of a resolvable one":
    # `Dangle` is letter-bearing and case-flippable, but its target does not
    # exist -- `fileIdentity` on it fails, and this tier must skip it rather
    # than let that failure manufacture a wrong answer. `Beta.txt`/`bETA.TXT`
    # give it a second, genuinely resolvable candidate to fall through to.
    #
    # Re-examined for volume-awareness: `Dangle`'s OWN identity check fails
    # regardless of volume type (its target genuinely does not exist either
    # way), so the skip-and-fall-through PROPERTY under test is fabricable
    # on both. What differs is the fallback pair's TERMINAL answer: on a
    # case-sensitive volume `Beta.txt`/`bETA.TXT` stay two distinct files
    # (`fpNone`, as before); on a case-insensitive volume the second write
    # folds onto the first (one file, two spellings), which is itself a
    # genuinely resolvable same-identity candidate (`fpAsciiLower`) -- both
    # are honest, volume-appropriate proofs that the dangling candidate was
    # skipped rather than allowed to manufacture a wrong answer.
    let dir = freshDir("t2-dangling")
    defer: removeDir(dir)
    var linked = true
    try:
      createSymlink(dir / "does_not_exist_target", dir / "Dangle")
    except OSError:
      linked = false
    if not linked:
      echo "SKIPPED: this environment cannot create symlinks -- the " &
           "dangling-candidate fall-through path is untestable here"
      skip()
    else:
      writeFile(dir / "Beta.txt", "original")
      writeFile(dir / "bETA.TXT", "distinct")
      let expected = if volumeIsCaseInsensitive: fpAsciiLower else: fpNone
      check readOnlyFallback(dir) == some(expected)

# ---------------------------------------------------------------------------
# Tier 3 — createAndStatFallback (F7)
# ---------------------------------------------------------------------------

suite "createAndStatFallback (probe tier 3) — F7":

  test "writable rootAbs -> definitive answer, probed IN rootAbs, no leftover":
    let dir = freshDir("t3-writable")
    defer: removeDir(dir)
    let policy = createAndStatFallback(dir, "")
    check policy.isSome

    # Independently confirm the answer matches this volume's real
    # case-sensitivity, via a DIFFERENT filename than tier 3 used
    # internally -- this assertion cannot be fooled by an artifact tier 3
    # left behind.
    let indepLower = dir / "indep_check_lower.tmp"
    let indepUpper = dir / "INDEP_CHECK_LOWER.TMP"
    writeFile(indepLower, "x")
    let reallyInsensitive = fileExists(indepUpper)
    removeFile(indepLower)
    check policy == some(if reallyInsensitive: fpAsciiLower else: fpNone)

    # No leftover probe artifact in rootAbs (both cleaned up in the finally).
    var leftovers = 0
    for kind, p in walkDir(dir):
      leftovers.inc
    check leftovers == 0

  test "rootAbs not writable -> genuine none, NEVER another directory's answer":
    let dir = freshDir("t3-unwritable")
    let stateDir = freshDir("t3-unwritable-state")  # writable; must be IGNORED
    setFilePermissions(dir, {})

    var containerRootCanWriteAnyway = true
    try:
      # `std/syncio.writeFile` raises `IOError` on a genuine write failure,
      # not `OSError` -- catching only `OSError` here let a real macOS
      # (non-root) IOError escape unhandled instead of setting
      # `containerRootCanWriteAnyway = false` as intended. A raise here
      # means unwritable-confirmed (proceed to the actual assertion below);
      # success means the container's root bypassed the chmod (self-skip).
      writeFile(dir / "probe_write_check.tmp", "x")
      removeFile(dir / "probe_write_check.tmp")
    except IOError, OSError:
      containerRootCanWriteAnyway = false

    if containerRootCanWriteAnyway:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      removeDir(dir)
      removeDir(stateDir)
      echo "SKIPPED: running as root inside this container -- chmod 0 does " &
           "not block a write here, so tier 3's unwritable-root path " &
           "cannot be forced honestly in this environment"
      skip()
    else:
      # `stateDir` is a real, writable, DIFFERENT directory -- the F7 bug
      # would have answered for it instead of the unwritable `rootAbs`. The
      # fix must return a genuine probe failure instead.
      let answer = createAndStatFallback(dir, stateDir)
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
      removeDir(dir)
      removeDir(stateDir)
      check answer == none(FoldPolicy)

# ---------------------------------------------------------------------------
# Tier 3 — F29: unpredictable name + exclusive, symlink-refusing create
# ---------------------------------------------------------------------------

suite "createAndStatFallback (probe tier 3) — F29 symlink-refusing create":

  test "a pre-placed symlink AT the probe path is refused; victim untouched":
    # Attacker model: a co-resident process sharing `dir` (the
    # CRISOL_STATE_DIR-redirectable case `rootInsideStateDir` makes
    # reachable) pre-places a symlink at the EXACT name this process's
    # probe will use, targeting a file it wants truncated. Pre-fix, plain
    # `writeFile` would follow the symlink and truncate `victim`; the fix
    # must refuse the create outright and leave `victim`'s content intact.
    let dir = freshDir("t3-symlink-refuse")
    defer: removeDir(dir)
    let victim = dir / "victim.txt"
    writeFile(victim, "precious-victim-content")
    let probePath = dir / probeBaseName()

    var linked = true
    try:
      createSymlink(victim, probePath)
    except OSError:
      linked = false

    if not linked:
      echo "SKIPPED: this environment cannot create symlinks -- F29's " &
           "symlink-refusal path is untestable here"
      skip()
    else:
      let answer = createAndStatFallback(dir, "")
      # The exclusive create must have refused to follow the symlink: the
      # victim's content is exactly what it was before the probe ran.
      check readFile(victim) == "precious-victim-content"
      # A refused create is a genuine probe failure (D1) -- never a retry,
      # never a fallback read through the symlink.
      check answer == none(FoldPolicy)

  test "probe base name carries a random suffix beyond the PID (non-predictability)":
    let name = probeBaseName()
    let pidPrefix = "." & "crisol_fold_probe_" & $getCurrentProcessId() & "_"
    check name.startsWith(pidPrefix)
    check name.endsWith(".tmp")
    let suffix = name[pidPrefix.len ..< name.len - ".tmp".len]

    if suffix.len == 0:
      echo "SKIPPED: readRandomBytes returned no bytes in this environment " &
           "-- F29's non-predictability smoke needs a working " &
           "/dev/urandom (or sysrand) source here"
      skip()
    else:
      check suffix.len == 16  # 8 random bytes, hex-encoded
      for c in suffix:
        check c in {'0'..'9', 'a'..'f'}
      # Per-process cache (F29 design): a second call in the SAME process
      # returns the SAME suffix -- it is drawn ONCE per process, not
      # re-rolled (and independently re-guessable) on every probe call.
      check probeBaseName() == name

# ---------------------------------------------------------------------------
# Linux tier-1 casefold refinement — decodeLinuxCasefold (F8)
# ---------------------------------------------------------------------------

when defined(linux):
  suite "decodeLinuxCasefold — Linux tier-1 casefold refinement (F8)":

    test "FS_CASEFOLD_FL set -> fpAsciiLower, overriding a case-sensitive magic answer":
      check decodeLinuxCasefold(some(fsCasefoldFlag), some(fpNone)) == some(fpAsciiLower)

    test "FS_CASEFOLD_FL set among unrelated bits -> still fpAsciiLower":
      let flags = fsCasefoldFlag or 0x00000010'i32  # an unrelated bit alongside it
      check decodeLinuxCasefold(some(flags), some(fpNone)) == some(fpAsciiLower)

    test "FS_CASEFOLD_FL clear -> the magic answer stands, unrefined":
      check decodeLinuxCasefold(some(0'i32), some(fpNone)) == some(fpNone)

    test "ioctl query failed/unsupported (None) -> the magic answer stands, unchanged":
      check decodeLinuxCasefold(none(int32), some(fpNone)) == some(fpNone)

    test "flag set even when the magic answer itself is none -- the flag always wins":
      check decodeLinuxCasefold(some(fsCasefoldFlag), none(FoldPolicy)) == some(fpAsciiLower)

when isMainModule:
  echo "test_fold_probe_tiers done"
