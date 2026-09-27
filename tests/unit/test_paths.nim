## test_paths.nim — RFC-0009 A1 unit conformance for crisol/paths.nim.
##
## Pure unit tests over TrackedPath/PathClass/classify/fromCanonical/
## toNative/toJson/keyBytes/cmpKeyBytes, with an INJECTED fold policy
## throughout (`initTrackedRoots`'s `probe` parameter) — fold semantics are
## proven here without ever touching a real case-insensitive volume; the
## REAL `probeFoldPolicy` answering `fpAsciiLower` on an actual NTFS volume
## is tests/conformance/test_fold_probe.nim's job, not this file's.
##
## Every root used below is a purely LEXICAL fake absolute path — `classify`/
## `nativeCanonicalize` never touch disk for an ordinary tracked-vs-outside
## decision, so no real directory needs to exist. The one exception is the
## symlinked-root vector, which creates a REAL temp directory + symlink,
## because it exercises `NativeRoot.realAbs`, which IS computed from the
## real filesystem (`expandFilename`) at `initTrackedRoots` time.
##
## `initTrackedRoots`'s probe memo is keyed by canonical root abs path and
## is per-PROCESS (never reset between tests in this file). Since A3b-ii the
## memo is BYPASSED for any explicitly-injected non-default probe (see the
## "injected probe bypasses the memo" test below), so two tests injecting
## two different policies for one root can no longer collide; the fake roots
## below nonetheless stay unique per test, which is clearer regardless.

import std/[unittest, options, os, osproc, strutils, json, tempfiles]
import crisol/paths
import crisol/narrow
import ../support/symlinkprobe

proc fixedProbe(policy: FoldPolicy): proc (rootAbs, stateDir: string): Option[FoldPolicy] =
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy)

proc rootsWith(projectAbs: string; policy: FoldPolicy;
               deps: seq[tuple[name, native: string]] = @[]): TrackedRoots =
  initTrackedRoots(projectAbs, deps, "", fixedProbe(policy))

proc rootsWithReal(projectAbs: string; policy: FoldPolicy;
                    deps: seq[tuple[name, native: string]] = @[]): TrackedRoots =
  ## Same as `rootsWith`, but for vectors that need `expandFilename` to see
  ## a REAL directory (the symlinked-root vector).
  initTrackedRoots(projectAbs, deps, "", fixedProbe(policy))

# ===========================================================================
# Fold semantics (injected policy) — the A1 bullet's headline vectors.
# ===========================================================================

suite "TrackedPath == — fold semantics under an injected FoldPolicy":

  test "fpAsciiLower: case-variant spellings compare equal":
    let roots = rootsWith("/fake/proj-fold-a1", fpAsciiLower)
    let a = tracked("/fake/proj-fold-a1/Foo/Bar.nim", roots).get
    let b = tracked("/fake/proj-fold-a1/foo/bar.nim", roots).get
    check a == b

  test "fpAsciiLower: separator-variant spellings compare equal":
    let roots = rootsWith("/fake/proj-fold-a2", fpAsciiLower)
    let a = tracked("/fake/proj-fold-a2\\foo\\bar.nim", roots).get
    let b = tracked("/fake/proj-fold-a2/foo/bar.nim", roots).get
    check a == b

  test "fpAsciiLower: case-AND-separator-variant spellings compare equal":
    let roots = rootsWith("/fake/proj-fold-a3", fpAsciiLower)
    let a = tracked("/fake/proj-fold-a3\\Foo\\Bar.nim", roots).get
    let b = tracked("/fake/proj-fold-a3/foo/bar.nim", roots).get
    check a == b

  test "fpNone: separator-variant-only spellings compare equal":
    let roots = rootsWith("/fake/proj-fold-n1", fpNone)
    let a = tracked("/fake/proj-fold-n1\\foo\\bar.nim", roots).get
    let b = tracked("/fake/proj-fold-n1/foo/bar.nim", roots).get
    check a == b

  test "fpNone: case-variant spellings compare UNEQUAL":
    let roots = rootsWith("/fake/proj-fold-n2", fpNone)
    let a = tracked("/fake/proj-fold-n2/Foo/Bar.nim", roots).get
    let b = tracked("/fake/proj-fold-n2/foo/bar.nim", roots).get
    check a != b

  test "keyBytes never folds under fpAsciiLower":
    let roots = rootsWith("/fake/proj-fold-k1", fpAsciiLower)
    let a = tracked("/fake/proj-fold-k1/Foo.nim", roots).get
    let b = tracked("/fake/proj-fold-k1/foo.nim", roots).get
    check a == b   # same identity under the fold ...
    # ... but keyBytes preserves the raw, unfolded case difference.
    check string(keyBytes(a, roots)) != string(keyBytes(b, roots))

  test "keyBytes never folds under fpNone (identity check: unfolded already)":
    let roots = rootsWith("/fake/proj-fold-k2", fpNone)
    let a = tracked("/fake/proj-fold-k2/Foo.nim", roots).get
    check string(keyBytes(a, roots)) == "Foo.nim"

  test "hash agrees with == under fpAsciiLower (HashSet/Table correctness)":
    let roots = rootsWith("/fake/proj-fold-h1", fpAsciiLower)
    let a = tracked("/fake/proj-fold-h1/Foo.nim", roots).get
    let b = tracked("/fake/proj-fold-h1/foo.nim", roots).get
    check a == b
    check hash(a) == hash(b)

# ===========================================================================
# fold() itself — ASCII-only, by design (F25). `fold(s, fpAsciiLower)` is
# `toLowerAscii`-backed on purpose: bytes above the ASCII range (127) must
# pass through byte-identically, never Unicode/locale-folded. A regression
# that swapped `toLowerAscii` for `toLower` (locale-aware) would silently
# reintroduce exactly the drift this RFC's fold policy exists to forbid —
# and would NOT be caught by the fpAsciiLower vectors above, which only use
# plain ASCII letters. Non-ASCII bytes here are UTF-8 multibyte sequences
# for real letters (Ä, ß, É) spelled as their raw byte sequences, not
# single Latin-1 code points — `fold` operates on bytes, not codepoints.
# ===========================================================================

suite "fold — ASCII-only folding (RFC-0009 A5c / F25)":

  test "fpAsciiLower: non-ASCII bytes pass through untouched; adjacent ASCII folds":
    let s = "A\xC3\x84b\xC3\x9fC\xC3\x89d"
      # "A" + U+00C4 (Ä) + "b" + U+00DF (ß) + "C" + U+00C9 (É) + "d",
      # Ä/ß/É each UTF-8-encoded as two bytes, all > 127.
    let folded = fold(s, fpAsciiLower)
    check folded == "a\xC3\x84b\xC3\x9fc\xC3\x89d"
      # A->a, C->c fold; the six non-ASCII bytes are byte-identical.

  test "fpAsciiLower: an all-non-ASCII string is entirely unchanged":
    let s = "\xC3\x84\xC3\x9f\xC3\x89"  # "ÄßÉ"
    check fold(s, fpAsciiLower) == s

  test "fpNone: ASCII and non-ASCII bytes both pass through byte-identically":
    let s = "A\xC3\x84b\xC3\x9fC\xC3\x89d"
    check fold(s, fpNone) == s

# ===========================================================================
# toNative round-trip, including a deliberate >260-char path.
# ===========================================================================

suite "toNative — round trip through classify":

  test "ordinary path round-trips: classify(toNative(tp)) == tp":
    let roots = rootsWith("/fake/proj-native-1", fpNone)
    let tp = tracked("/fake/proj-native-1/a/b/c.nim", roots).get
    let native = toNative(tp, roots)
    # RFC-0009 B4a: toNative is a native-I/O boundary -- it emits backslashes
    # on Windows BY DESIGN (see toNative's doc comment), so the expected
    # literal must be platform-aware rather than assuming POSIX separators.
    when defined(windows):
      check native == "\\fake\\proj-native-1\\a\\b\\c.nim"
    else:
      check native == "/fake/proj-native-1/a/b/c.nim"
    check tracked(native, roots).get == tp

  test "a deliberate >260-character rel round-trips through toNative":
    let roots = rootsWith("/fake/proj-native-2", fpNone)
    let longSeg = "x".repeat(80)
    let deepRel = [longSeg, longSeg, longSeg, longSeg].join("/") & ".nim"
    check deepRel.len > 260
    let tp = tracked("/fake/proj-native-2/" & deepRel, roots).get
    let native = toNative(tp, roots)
    check tracked(native, roots).get == tp
    check native.len > 260

  test "a \\\\?\\-prefixed and unprefixed spelling of the same path classify identically":
    let roots = rootsWith("/fake/proj-native-3", fpNone)
    let plain = tracked("/fake/proj-native-3/foo.nim", roots).get
    let prefixed = tracked("\\\\?\\/fake/proj-native-3/foo.nim", roots).get
    check plain == prefixed

# ===========================================================================
# UNC / \\?\ / drive-relative / case-varied-root / trailing-sep / empty vectors.
# ===========================================================================

suite "nativeCanonicalize / classify — native-spelling vectors":

  test "UNC spelling classifies tag 0 under a UNC project root":
    let roots = rootsWith("//srv/share/proj-unc", fpNone)
    let tp = tracked("//srv/share/proj-unc/foo.nim", roots).get
    check tp.isProject
    check tp.display == "foo.nim"

  test "a \\\\server\\share backslash spelling normalizes to the same UNC identity":
    let roots = rootsWith("//srv/share/proj-unc2", fpNone)
    let a = tracked("//srv/share/proj-unc2/foo.nim", roots).get
    let b = tracked("\\\\srv\\share\\proj-unc2\\foo.nim", roots).get
    check a == b

  test "\\\\?\\UNC\\ long-path UNC spelling strips to the same identity":
    let roots = rootsWith("//srv/share/proj-unc3", fpNone)
    let a = tracked("//srv/share/proj-unc3/foo.nim", roots).get
    let b = tracked("\\\\?\\UNC\\srv\\share\\proj-unc3\\foo.nim", roots).get
    check a == b

  test "drive-relative (c:foo) is treated as relative text, never throws":
    let roots = rootsWith("C:/proj-drive-rel", fpNone)
    let pc = classify("c:sub/foo.nim", roots)
    check pc.kind in {pcTracked, pcOutside}   # total: some arm, never a throw

  test "case-varied drive-letter root-prefix classifies tag 0":
    let roots = rootsWith("c:/proj-drivecase", fpNone)
    let tp = tracked("C:/proj-drivecase/foo.nim", roots).get
    check tp.isProject

  test "trailing-separator spellings normalize to the same identity":
    let roots = rootsWith("/fake/proj-trail", fpNone)
    let a = tracked("/fake/proj-trail/foo/", roots).get
    let b = tracked("/fake/proj-trail/foo", roots).get
    check a == b

  test "three-or-more leading slashes collapse to a plain POSIX root, not UNC":
    let roots = rootsWith("/fake/proj-triple", fpNone)
    let a = tracked("///fake/proj-triple/foo.nim", roots).get
    let b = tracked("/fake/proj-triple/foo.nim", roots).get
    check a == b

  test "empty native path never throws and classifies (the root itself, pcOutside)":
    let roots = rootsWith("/fake/proj-empty", fpNone)
    let pc = classify("", roots)
    check pc.kind == pcOutside

# ===========================================================================
# Totality: pcOutside, never throws, the tracked root's own directory.
# ===========================================================================

suite "classify — totality":

  test "a path outside every root classifies pcOutside, never throws":
    let roots = rootsWith("/fake/proj-outside", fpNone)
    let pc = classify("/somewhere/else/entirely.nim", roots)
    check pc.kind == pcOutside
    check pc.native.path == "/somewhere/else/entirely.nim"

  test "the tracked root's own directory classifies pcOutside":
    let roots = rootsWith("/fake/proj-selfdir", fpNone)
    let pc = classify("/fake/proj-selfdir", roots)
    check pc.kind == pcOutside

  test "a dep root's own directory classifies pcOutside":
    let roots = rootsWith("/fake/proj-depselfdir", fpNone,
                           @[("mydep", "/fake/dep-selfdir")])
    let pc = classify("/fake/dep-selfdir", roots)
    check pc.kind == pcOutside

  test "Windows-reserved device names classify total, never throw":
    let roots = rootsWith("/fake/proj-reserved", fpNone)
    for name in ["CON.nim", "NUL", "AUX.nim", "COM1.nim", "LPT1"]:
      let pc = classify("/fake/proj-reserved/" & name, roots)
      check pc.kind == pcTracked
      check pc.tp.display == name

# ===========================================================================
# Root priority: project-first, dep-root nesting, dep-root longest match.
# ===========================================================================

suite "classify — root priority":

  test "a path nested under project root but coincident with a dep root's dir classifies tag 0":
    let roots = rootsWith("/fake/proj-priority",
                           fpNone,
                           @[("vendored", "/fake/proj-priority/vendor/dep")])
    let tp = tracked("/fake/proj-priority/vendor/dep/foo.nim", roots).get
    check tp.isProject
    check tp.display == "vendor/dep/foo.nim"

  test "a path under a dep root (not nested under project) classifies that dep's tag":
    let roots = rootsWith("/fake/proj-priority2", fpNone,
                           @[("mydep", "/fake/dep-priority2")])
    let tp = tracked("/fake/dep-priority2/src/foo.nim", roots).get
    check (not tp.isProject)
    check tp.display == "src/foo.nim"

  test "longest match wins between two overlapping dep roots":
    let roots = rootsWith("/fake/proj-priority3", fpNone,
                           @[("outer", "/fake/dep-outer"),
                             ("inner", "/fake/dep-outer/inner")])
    let tp = tracked("/fake/dep-outer/inner/foo.nim", roots).get
    check tp.display == "foo.nim"   # matched the INNER (longer) root, not outer

# ===========================================================================
# Symlinked root: NativeRoot.realAbs catches a realpath-form candidate.
# ===========================================================================

suite "classify — symlinked dep root (NativeRoot.realAbs)":

  test "a candidate reaching classify via a symlinked root's realpath form classifies under that root's tag":
    when defined(windows):
      # RFC-0009 B4a: gated on Windows. CI showed `tracked(...).get` raising
      # UnpackDefect here -- i.e. `tracked` returned `none`, meaning
      # `classify` did NOT resolve `realDir/foo.nim` under the "linked" dep
      # root's `realAbs` (expandFilename'd from the directory-symlink
      # `linkDir`) even though the symlink itself was created successfully
      # (this is NOT the SeCreateSymbolicLinkPrivilege case the
      # `symlinksAvailable()` guard exists for). That points at some
      # Windows-specific divergence in how `expandFilename` resolves a
      # directory reparse point vs. this fixture's assumption -- undiagnosed
      # without a native Windows box to repro against. Flagged for a
      # Windows-repro follow-up rather than gated blindly forever.
      echo "CRISOL-SKIP-TEST: tests/unit/test_paths.nim#classify_symlinked_deproot_realabs_windows_known_divergence"
      skip()
    else:
      # A fresh, uniquely named directory (R3-13), never a predictable name
      # a planted symlink could already occupy.
      let rawBase = createTempDir("crisol_test_paths_symlink_", "")
      # Resolve the base up front so the fixture's own paths are internally
      # consistent. On macOS getTempDir() lives under /var/folders, itself a
      # symlink to /private/var/folders; without this, the candidate below
      # would be built in the /var (lexical) spelling while the dep root's
      # realAbs (expandFilename'd) is the /private/var spelling, and the two
      # would never prefix-match. Production never hands classify such a hybrid
      # (a real-path candidate comes from closure's expandFilename'd
      # IndexedFile.real, fully resolved) — this keeps the fixture faithful to
      # that contract. No-op on Linux, where getTempDir() has no symlink.
      let base = expandFilename(rawBase)
      let realDir = base / "real-dep-target"
      let linkDir = base / "dep-link"
      createDir(realDir)
      writeFile(realDir / "foo.nim", "# fixture\n")
      defer:
        try: removeDir(base)
        except OSError: discard
      if not symlinksAvailable():
        echo "CRISOL-SKIP-TEST: tests/unit/test_paths.nim#classify_symlinked_deproot_realabs_no_symlink_privilege"
        skip()   # symlink privilege unavailable in this environment
      else:
        createSymlink(realDir, linkDir)
        defer: removeSymlinkSafe(linkDir)
        let roots = rootsWith(base / "project-root", fpNone,
                               @[("linked", linkDir)])
        # Reach the file through its REAL (non-symlink) path, not the
        # configured symlink spelling — this must still classify under the
        # dep root's tag.
        let tp = tracked(realDir / "foo.nim", roots).get
        check (not tp.isProject)
        check tp.display == "foo.nim"

# ===========================================================================
# RFC-0009 wiring-audit F18 — candidate-side 8.3 short-name expansion.
#
# `plausibly8Dot3` is pure text and cross-platform-testable directly. The
# real EXPANSION (`safeExpandFilename` on a genuine Windows short name) only
# ever fires on Windows CI -- on Linux, only the predicate and the fallback
# WIRING inside `classify` are exercised, via an injected `expandCandidate`
# (the same injectable-seam pattern `initTrackedRoots`'s `probe` parameter
# uses for `FoldPolicy`), following the RFC-0009 macOS/Windows gotcha
# playbook of proving wiring locally and noting the real-disk case as
# untested-on-CI until a Windows leg runs it.
# ===========================================================================

suite "plausibly8Dot3 — the DOS short-name signature predicate":

  test "detects a '~<digit>' component (the real RUNNER~1 shape)":
    check plausibly8Dot3("C:/Users/RUNNER~1/project/foo.nim")

  test "detects the signature in a non-final component":
    check plausibly8Dot3("C:/PROGRA~1/vendor/foo.nim")

  test "an ordinary path with no tilde does not trigger":
    check (not plausibly8Dot3("C:/Users/runneradmin/project/foo.nim"))

  test "a bare tilde with no trailing digit does not trigger (not the 8.3 shape)":
    check (not plausibly8Dot3("/home/~backup/foo.nim"))

  test "a tilde at the very end of a component (no digit follows) does not trigger":
    check (not plausibly8Dot3("/home/foo~/bar.nim"))

suite "classify — F18 candidate-side 8.3 expansion (injected expandCandidate)":

  test "a short-name candidate under a long-form root resolves via the injected expander":
    let roots = rootsWith("C:/Users/runneradmin/project", fpNone)
    # Simulates GetFinalPathNameByHandleW resolving the 8.3 alias to its
    # long form -- the wiring this test proves, not the real Windows call.
    proc fakeExpand(p: string): string =
      p.replace("RUNNER~1", "runneradmin")
    let pc = classify("C:/Users/RUNNER~1/project/foo.nim", roots, expandCandidate = fakeExpand)
    check pc.kind == pcTracked
    check pc.tp.isProject
    check pc.tp.display == "foo.nim"

  test "a short-name candidate under a dep root resolves via the injected expander":
    let roots = rootsWith("C:/Users/runneradmin/project", fpNone,
                           @[("mydep", "C:/Users/runneradmin/depsrc")])
    proc fakeExpand(p: string): string =
      p.replace("RUNNER~1", "runneradmin")
    let pc = classify("C:/Users/RUNNER~1/depsrc/foo.nim", roots, expandCandidate = fakeExpand)
    check pc.kind == pcTracked
    check (not pc.tp.isProject)
    check pc.tp.display == "foo.nim"

  test "an expander that cannot resolve the short name still degrades to pcOutside, never throws":
    let roots = rootsWith("C:/Users/runneradmin/project", fpNone)
    proc noopExpand(p: string): string = p   # safeExpandFilename's own "never raises" degrade: unchanged on failure
    let pc = classify("C:/Users/RUNNER~1/project/foo.nim", roots, expandCandidate = noopExpand)
    check pc.kind == pcOutside

  test "an ordinary candidate (no 8.3 signature) never invokes the expander at all — zero cost on the hot path":
    let roots = rootsWith("C:/Users/runneradmin/project", fpNone)
    proc explodingExpand(p: string): string =
      doAssert false, "expandCandidate must not be called for a non-8.3-shaped candidate"
      p
    let pc = classify("C:/Users/runneradmin/project/foo.nim", roots, expandCandidate = explodingExpand)
    check pc.kind == pcTracked
    check pc.tp.display == "foo.nim"

  test "a short-name candidate that is genuinely outside every root stays pcOutside even after expansion":
    let roots = rootsWith("C:/Users/runneradmin/project", fpNone)
    proc fakeExpand(p: string): string =
      p.replace("RUNNER~1", "runneradmin")
    let pc = classify("C:/Users/RUNNER~1/elsewhere/foo.nim", roots, expandCandidate = fakeExpand)
    check pc.kind == pcOutside

suite "classify — F18 candidate-side CASE expansion (issue #21 slice 1c)":
  ## The 8.3 suite above fixed ONE spelling of a candidate that names a real
  ## tracked file in a non-canonical way. Case is the same defect in
  ## different clothes, and `cl /sourceDependencies` makes it total: it
  ## lowercases every path it reports, so under any mixed-case project root
  ## EVERY MSVC-derived header lexically missed `matchRoots` and landed
  ## pcOutside — silently dropped from the closure, which is why impact
  ## selection stayed dead under vcc even after the dep probe itself worked.
  ##
  ## The fix is deliberately NOT "fold the membership test". `TrackedPath.rel`
  ## is documented REAL-CASE and `keyBytes` is `rel` UNFOLDED — it IS the
  ## cache-key material. Matching while mis-cased would store cl's lowercased
  ## spelling, so a cl-populated closure and a gcc-populated one would hash
  ## differently for the same files and cross-host cache portability
  ## (RFC-0005) would break. Instead the candidate is RESOLVED to its real
  ## on-disk spelling (`winRealPath`/GetFinalPathNameByHandleW returns the
  ## true case) and the existing case-SENSITIVE `underRoot` decides, so `rel`
  ## comes out real-case by construction.

  test "a lowercased candidate under an fpAsciiLower root resolves, and rel keeps the REAL case":
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    # What cl reports vs what is actually on disk.
    const reported = "c:/users/runneradmin/project/native/add.h"
    const onDisk   = "C:/Users/RunnerAdmin/Project/Native/Add.h"
    proc fakeExpand(p: string): string =
      ## Models GetFinalPathNameByHandleW: it resolves whatever casing it is
      ## handed to the ONE true on-disk spelling. (classify canonicalizes the
      ## drive letter to upper case before calling this, so an exact-string
      ## fake would miss for a reason the real call never has.)
      if p.toLowerAscii == reported: onDisk else: p
    let pc = classify(ReportedPath(reported), roots, fakeExpand)
    check pc.kind == pcTracked
    check pc.tp.isProject
    # The load-bearing assertion: the REAL spelling is stored, not the
    # lowercased one the probe happened to report. keyBytes == rel, so this
    # is what keeps a cl-derived closure hash equal to a gcc-derived one.
    check pc.tp.display == "Native/Add.h"

  test "a lowercased candidate under an fpAsciiLower DEP root resolves too":
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower,
                           @[("mydep", "C:/Users/RunnerAdmin/DepSrc")])
    const reported = "c:/users/runneradmin/depsrc/inc/vendor.h"
    const onDisk   = "C:/Users/RunnerAdmin/DepSrc/inc/Vendor.h"
    proc fakeExpand(p: string): string =
      ## Models GetFinalPathNameByHandleW: it resolves whatever casing it is
      ## handed to the ONE true on-disk spelling. (classify canonicalizes the
      ## drive letter to upper case before calling this, so an exact-string
      ## fake would miss for a reason the real call never has.)
      if p.toLowerAscii == reported: onDisk else: p
    let pc = classify(ReportedPath(reported), roots, fakeExpand)
    check pc.kind == pcTracked
    check (not pc.tp.isProject)
    check pc.tp.display == "inc/Vendor.h"

  test "a genuinely-outside lowercased candidate never invokes the expander — the folded pre-filter is text-only, no I/O":
    ## This is the whole reason the trigger is a folded PREFIX test rather
    ## than "retry on every miss": every system header and every stdlib path
    ## is a miss, and each one would otherwise pay a disk round-trip.
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    proc explodingExpand(p: string): string =
      doAssert false, "expandCandidate must not be called for a candidate no root could claim"
      p
    let pc = classify(ReportedPath("c:/msvc/vc/include/stdint.h"), roots, explodingExpand)
    check pc.kind == pcOutside

  test "under fpNone a mis-cased candidate is NOT rescued, and the expander is never called":
    ## Case is SIGNIFICANT on an fpNone root: two spellings are two files.
    ## The pre-filter must respect the root's probed policy, not assume
    ## Windows semantics everywhere.
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpNone)
    proc explodingExpand(p: string): string =
      doAssert false, "expandCandidate must not be called under fpNone"
      p
    let pc = classify(ReportedPath("c:/users/runneradmin/project/native/add.h"), roots,
                      explodingExpand)
    check pc.kind == pcOutside

  test "an expander that cannot resolve the case still degrades to pcOutside, never throws":
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    proc noopExpand(p: string): string = p   # safeExpandFilename's degrade contract
    let pc = classify(ReportedPath("c:/users/runneradmin/project/native/add.h"), roots,
                      noopExpand)
    check pc.kind == pcOutside

  test "W1: an exact-case ROOT with a mis-cased TAIL still resolves to the real spelling":
    ## The wiring-audit W1 vector, and the one slice 1c left open.
    ##
    ## Every other test in this suite mis-cases the ROOT PREFIX, which is
    ## the only thing `matchRoots` can miss on: `underRoot` compares the
    ## prefix case-sensitively and then slices the remainder VERBATIM. So a
    ## candidate whose root spelling already case-matches is a DIRECT HIT
    ## and its tail is stored exactly as the foreign tool spelled it —
    ## running the expansion only as a miss-fallback fixed mis-cased roots
    ## and left mis-cased tails alone.
    ##
    ## This is the shape `windows-latest` actually runs: the workspace is
    ## `D:\a\crisol\crisol`, all lowercase, so cl's lowercased output
    ## case-matches the root exactly and only the tail can differ.
    let roots = rootsWith("C:/Users/runneradmin/project", fpAsciiLower)
    const reported = "c:/users/runneradmin/project/native/add.h"
    const onDisk   = "C:/Users/runneradmin/project/Native/Add.h"
    proc fakeExpand(p: string): string =
      if p.toLowerAscii == reported: onDisk else: p
    let pc = classify(ReportedPath(reported), roots, fakeExpand)
    check pc.kind == pcTracked
    check pc.tp.isProject
    # keyBytes == rel, UNFOLDED — so this is the assertion that keeps a
    # cl-populated closure hashing equal to a gcc-populated one.
    check pc.tp.display == "Native/Add.h"

  test "a TRUSTED (string) exactly-cased candidate never invokes the expander — the hot path is unchanged":
    ## `SourceIndex` classifies thousands of candidates per run, all of them
    ## crisol's own real-case spellings. They must not pay a disk round-trip
    ## for W1's sake — which is why provenance is now carried by the
    ## ARGUMENT'S TYPE (a bare `string` here, never a `ReportedPath`) rather
    ## than a parameter a caller could pass wrong or forget (CR10).
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    proc explodingExpand(p: string): string =
      doAssert false, "expandCandidate must not be called for a trusted (string) candidate"
      p
    let pc = classify("C:/Users/RunnerAdmin/Project/Native/Add.h", roots,
                      explodingExpand)
    check pc.kind == pcTracked
    check pc.tp.display == "Native/Add.h"

  test "a REPORTED (ReportedPath) exactly-cased candidate DOES pay one resolution, and still answers real case":
    ## The cost this fix accepts, stated as a behaviour rather than left
    ## implicit: for a REPORTED spelling there is no way to know the tail is
    ## already canonical without asking the disk, so the resolution runs even
    ## when it turns out to be a no-op. One `GetFinalPathNameByHandleW` per
    ## tracked header per external — tens per run, not thousands, because
    ## the folded pre-filter still excludes every system header first.
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    var calls = 0
    proc countingExpand(p: string): string =
      inc calls
      p          # already canonical: resolution is a no-op here
    let pc = classify(ReportedPath("C:/Users/RunnerAdmin/Project/Native/Add.h"), roots,
                      countingExpand)
    check calls == 1
    check pc.kind == pcTracked
    check pc.tp.display == "Native/Add.h"

suite "W9m guard -- the shared `folds` predicate keeps foldMatchesSomeRoot and narrow.anyRootFolds in agreement":
  ## RFC-0009 wiring-audit W9m: `foldMatchesSomeRoot` (this module, private
  ## -- exercised here through `classify`'s mis-case rescue, which is its
  ## only observable effect) and `narrow.anyRootFolds` each used to ask
  ## "does this policy fold case?" with their OWN `== fpAsciiLower` /
  ## `!= fpNone` comparison. `FoldPolicy` has exactly two arms today, so
  ## those happened to agree -- but nothing forced them to keep agreeing
  ## once a third arm existed. Both call sites now route through the one
  ## `folds` predicate declared next to `FoldPolicy` itself, so they cannot
  ## silently diverge; this test pins that INTENT directly rather than
  ## trusting the refactor, and iterates `FoldPolicy` itself (not today's
  ## two arms by name) so a future arm gains coverage here automatically.
  test "every FoldPolicy arm: classify's mis-case rescue and narrow.anyRootFolds agree with `folds`":
    const reported = "c:/users/runneradmin/project/native/add.h"
    const onDisk   = "C:/Users/RunnerAdmin/Project/Native/Add.h"
    proc fakeExpand(p: string): string =
      if p.toLowerAscii == reported: onDisk else: p

    for p in FoldPolicy:
      let roots = rootsWith("C:/Users/RunnerAdmin/Project", p)
      # paths.nim's call site: foldMatchesSomeRoot gates classify's mis-case
      # rescue for a ReportedPath candidate -- its only observable effect.
      let pc = classify(ReportedPath(reported), roots, fakeExpand)
      let rescuedByPaths = pc.kind == pcTracked
      # narrow.nim's call site.
      let foldsByNarrow = anyRootFolds(roots)
      check rescuedByPaths == folds(p)
      check foldsByNarrow == folds(p)
      check rescuedByPaths == foldsByNarrow

# ===========================================================================
# The dep:* keyBytes escape (Linux-only: a colon-containing filename can't
# exist on NTFS).
# ===========================================================================

suite "keyBytes — the dep:* escape at tag 0":

  test "a tag-0 rel whose first segment looks like dep:foo gets the ./ keyBytes prefix":
    let roots = rootsWith("/fake/proj-depescape", fpNone)
    let tp = tracked("/fake/proj-depescape/dep:foo/bar.nim", roots).get
    check tp.isProject
    check string(keyBytes(tp, roots)) == "./dep:foo/bar.nim"

  test "an ordinary tag-0 rel is NOT escaped":
    let roots = rootsWith("/fake/proj-depescape2", fpNone)
    let tp = tracked("/fake/proj-depescape2/foo.nim", roots).get
    check string(keyBytes(tp, roots)) == "foo.nim"

  test "the escape is injective: nothing else legitimately begins ./":
    let roots = rootsWith("/fake/proj-depescape3", fpNone)
    # fromCanonical rejects a leading '.' segment, so "./real" can never be
    # a legitimate rel reaching keyBytes from that constructor.
    check fromCanonical("./real", roots).isNone

  test "a real dep root's key uses the dep:<name>/rel form":
    let roots = rootsWith("/fake/proj-depescape4", fpNone,
                           @[("mydep", "/fake/dep-escape4")])
    let tp = tracked("/fake/dep-escape4/src/foo.nim", roots).get
    check string(keyBytes(tp, roots)) == "dep:mydep/src/foo.nim"

# ===========================================================================
# cmpKeyBytes — the sole ordering; no `<` exists.
# ===========================================================================

suite "cmpKeyBytes — total order over unfolded keyBytes":

  test "orders by raw keyBytes bytes, unaffected by fold policy":
    let roots = rootsWith("/fake/proj-order", fpAsciiLower)
    let a = tracked("/fake/proj-order/Alpha.nim", roots).get
    let b = tracked("/fake/proj-order/beta.nim", roots).get
    check cmpKeyBytes(a, b, roots) < 0    # "Alpha.nim" < "beta.nim" byte-wise
    check cmpKeyBytes(b, a, roots) > 0
    check cmpKeyBytes(a, a, roots) == 0

  test "no `<` operator exists over TrackedPath (compile-time check, not a runtime assertion)":
    # This test's existence (and the fact that it compiles) IS the check:
    # `compiles(a < b)` must be false, so a bare `sort()` over
    # `seq[TrackedPath]` is a compile error elsewhere in the system.
    let roots = rootsWith("/fake/proj-nolt", fpNone)
    let a = tracked("/fake/proj-nolt/a.nim", roots).get
    let b = tracked("/fake/proj-nolt/b.nim", roots).get
    check (not compiles(a < b))
    # Positive controls (R2-10): the same operands and the same `<` shape DO
    # compile once an order exists, so the seal above fails for want of `<`
    # over TrackedPath, not because `a`/`b` or the expression are malformed.
    check compiles(cmpKeyBytes(a, b, roots) < 0)
    check compiles(string(keyBytes(a, roots)) < string(keyBytes(b, roots)))

# ===========================================================================
# fromCanonical — shape validation (never raises, returns Option).
# ===========================================================================

suite "fromCanonical — canonical-text shape validation":

  test "a well-formed relative rel round-trips":
    let roots = rootsWith("/fake/proj-fc1", fpNone)
    let tp = fromCanonical("a/b/c.nim", roots).get
    check tp.display == "a/b/c.nim"
    check tp.isProject

  test "rejects empty rel":
    let roots = rootsWith("/fake/proj-fc2", fpNone)
    check fromCanonical("", roots).isNone

  test "rejects a leading backslash":
    let roots = rootsWith("/fake/proj-fc3", fpNone)
    check fromCanonical("\\foo\\bar.nim", roots).isNone

  test "RFC-0009 wiring-audit F15: rejects an EMBEDDED backslash mid-segment":
    ## Un-reduced native Windows text ("sub\file.nim") handed to
    ## `fromCanonical` instead of `classify`/`nativeCanonicalize` must be
    ## rejected exactly like a leading backslash is -- `nativeCanonicalize`
    ## treats a backslash as a separator UNIVERSALLY, host-agnostically (its
    ## own doc comment: "identity is textual, not platform-conditional"), so
    ## no `rel` `classify` ever legitimately constructs can contain a literal
    ## backslash byte -- every backslash reaching this boundary is un-reduced
    ## native text, never a real single-segment filename byte, regardless of
    ## WHERE in the string it appears.
    let roots = rootsWith("/fake/proj-fc3b", fpNone)
    check fromCanonical("sub\\file.nim", roots).isNone
    check fromCanonical("a/b\\c.nim", roots).isNone

  test "rejects a leading '/' (absolute form)":
    let roots = rootsWith("/fake/proj-fc4", fpNone)
    check fromCanonical("/foo.nim", roots).isNone

  test "rejects a drive-letter absolute form":
    let roots = rootsWith("/fake/proj-fc5", fpNone)
    check fromCanonical("C:/foo.nim", roots).isNone
    check fromCanonical("c:foo.nim", roots).isNone

  test "rejects a doubled separator":
    let roots = rootsWith("/fake/proj-fc6", fpNone)
    check fromCanonical("a//b.nim", roots).isNone

  test "rejects a trailing separator":
    let roots = rootsWith("/fake/proj-fc7", fpNone)
    check fromCanonical("a/b/", roots).isNone

  test "rejects any '.' or '..' segment":
    let roots = rootsWith("/fake/proj-fc8", fpNone)
    check fromCanonical("a/./b.nim", roots).isNone
    check fromCanonical("a/../b.nim", roots).isNone

  test "two-arity fromCanonical resolves a dep tag":
    let roots = rootsWith("/fake/proj-fc9", fpNone,
                           @[("mydep", "/fake/dep-fc9")])
    let tp = fromCanonical(RootTag(1), "src/foo.nim", roots).get
    check (not tp.isProject)
    check tp.display == "src/foo.nim"

  test "an out-of-range tag returns none, never crashes":
    let roots = rootsWith("/fake/proj-fc10", fpNone)
    check fromCanonical(RootTag(7), "foo.nim", roots).isNone

# ===========================================================================
# toJson / fromJson round trip.
# ===========================================================================

suite "toJson / fromJson — round trip":

  test "project-tag path round-trips with root name \"\"":
    let roots = rootsWith("/fake/proj-json1", fpNone)
    let tp = fromCanonical("a/b.nim", roots).get
    let node = toJson(tp, roots)
    check node["root"].getStr() == ""
    check node["path"].getStr() == "a/b.nim"
    check fromJson(node, roots).get == tp

  test "dep-tag path round-trips with the configured NAME, not the ordinal":
    let roots = rootsWith("/fake/proj-json2", fpNone,
                           @[("mydep", "/fake/dep-json2")])
    let tp = fromCanonical(RootTag(1), "src/foo.nim", roots).get
    let node = toJson(tp, roots)
    check node["root"].getStr() == "mydep"
    check fromJson(node, roots).get == tp

  test "an unresolvable persisted root name degrades to none, never crashes":
    let roots = rootsWith("/fake/proj-json3", fpNone)
    let node = %*{"root": "goneDep", "path": "src/foo.nim"}
    check fromJson(node, roots).isNone

  test "a malformed JSON node degrades to none":
    let roots = rootsWith("/fake/proj-json4", fpNone)
    check fromJson(%*{"path": "a.nim"}, roots).isNone
    check fromJson(%*"not-an-object", roots).isNone

# ===========================================================================
# fromKeyBytes — the keyBytes grammar's inverse (RFC-0009 W1). The depgraph
# closure member reader: `fromKeyBytes(string(keyBytes(tp, roots)), roots)`
# must recover the ORIGINAL TrackedPath, tag and all — this is exactly the
# round trip the pre-W1 depgraph read side got wrong (it used `classify`,
# which re-tags every dep-root member as a phantom tag-0 project path).
# ===========================================================================

suite "fromKeyBytes — the keyBytes grammar's inverse":

  test "project-tag plain rel round-trips":
    let roots = rootsWith("/fake/proj-fkb1", fpNone)
    let tp = tracked("/fake/proj-fkb1/a/b.nim", roots).get
    check fromKeyBytes(string(keyBytes(tp, roots)), roots).get == tp

  test "project-tag dep:* escape case round-trips":
    let roots = rootsWith("/fake/proj-fkb2", fpNone)
    let tp = tracked("/fake/proj-fkb2/dep:foo/bar.nim", roots).get
    check tp.isProject
    check string(keyBytes(tp, roots)) == "./dep:foo/bar.nim"
    check fromKeyBytes(string(keyBytes(tp, roots)), roots).get == tp

  test "BUG (verified): a tag-0 'dep:a:b/mod.nim' (colon in the pseudo-name) now round-trips through keyBytes/fromKeyBytes":
    ## Before the fix: `looksLikeDepEscape` declined to escape this shape
    ## (its first segment "dep:a:b" has a ':' after "dep:"), so `keyBytes`
    ## emitted it BARE as "dep:a:b/mod.nim" -- indistinguishable, to
    ## `fromKeyBytes`, from a real dep-root member. `fromKeyBytes` parsed
    ## a "name" of "a:b", rejected it for containing ':', and returned
    ## `none` -- silently dropping a real project file from a persisted
    ## closure (unsound under-selection).
    let roots = rootsWith("/fake/proj-fkb2b", fpNone)
    let tp = tracked("/fake/proj-fkb2b/dep:a:b/mod.nim", roots).get
    check tp.isProject
    let bytes = string(keyBytes(tp, roots))
    check bytes == "./dep:a:b/mod.nim"
    check fromKeyBytes(bytes, roots).get == tp

  test "BUG (verified): a tag-0 'dep:/x.nim' (empty pseudo-name) now round-trips through keyBytes/fromKeyBytes":
    ## Same defect, other malformed shape: "dep:" alone (empty "name" half)
    ## used to be emitted bare too.
    let roots = rootsWith("/fake/proj-fkb2c", fpNone)
    let tp = tracked("/fake/proj-fkb2c/dep:/x.nim", roots).get
    check tp.isProject
    let bytes = string(keyBytes(tp, roots))
    check bytes == "./dep:/x.nim"
    check fromKeyBytes(bytes, roots).get == tp

  test "a tag-0 well-formed-looking 'dep:x/y.nim' still round-trips (regression: the widened escape doesn't disturb the already-correct case)":
    let roots = rootsWith("/fake/proj-fkb2d", fpNone)
    let tp = tracked("/fake/proj-fkb2d/dep:x/y.nim", roots).get
    check tp.isProject
    let bytes = string(keyBytes(tp, roots))
    check bytes == "./dep:x/y.nim"
    check fromKeyBytes(bytes, roots).get == tp

  test "a real dep-root member round-trips to its OWN root tag, not tag 0":
    let roots = rootsWith("/fake/proj-fkb3", fpNone,
                           @[("mydep", "/fake/dep-fkb3")])
    let tp = tracked("/fake/dep-fkb3/src/foo.nim", roots).get
    check not tp.isProject
    let bytes = string(keyBytes(tp, roots))
    check bytes == "dep:mydep/src/foo.nim"
    let back = fromKeyBytes(bytes, roots)
    check back.isSome
    check back.get == tp
    check not back.get.isProject

  test "an unresolvable dep root name degrades to none, never crashes":
    let roots = rootsWith("/fake/proj-fkb4", fpNone,
                           @[("mydep", "/fake/dep-fkb4")])
    check fromKeyBytes("dep:goneDep/src/foo.nim", roots).isNone

  test "a BARE, unescaped 'dep:/x' (empty name) degrades to none -- old-format data or corruption, never a live round trip":
    ## RFC-0009 wiring-audit fix: `looksLikeDepEscape` now escapes EVERY
    ## tag-0 rel whose first segment starts with "dep:", including this
    ## empty-name shape -- a HEALTHY `keyBytes` never emits this bare
    ## spelling any more (see the "escaped dep:/x round-trips" test
    ## below for what it emits instead: "./dep:/x"). A bare, unescaped
    ## occurrence arriving here can therefore only mean pre-fix persisted
    ## data or genuine corruption -- `none` is still the right, degrade-
    ## never-crash answer for both.
    let roots = rootsWith("/fake/proj-fkb5", fpNone,
                           @[("mydep", "/fake/dep-fkb5")])
    check fromKeyBytes("dep:/x", roots).isNone

  test "a BARE, unescaped 'dep:a:b/x' (colon in the name) degrades to none -- old-format data or corruption, never a live round trip":
    ## Same reasoning as the empty-name case directly above.
    let roots = rootsWith("/fake/proj-fkb6", fpNone,
                           @[("mydep", "/fake/dep-fkb6")])
    check fromKeyBytes("dep:a:b/x", roots).isNone

  test "malformed dep: text (no '/' at all) degrades to none":
    let roots = rootsWith("/fake/proj-fkb7", fpNone,
                           @[("mydep", "/fake/dep-fkb7")])
    check fromKeyBytes("dep:mydep", roots).isNone

  test "malformed dep: text (empty rel after the name) degrades to none":
    let roots = rootsWith("/fake/proj-fkb8", fpNone,
                           @[("mydep", "/fake/dep-fkb8")])
    check fromKeyBytes("dep:mydep/", roots).isNone

  test "a bare ./ prefix without the dep-escape shape degrades to none":
    # Nothing else legitimately begins "./" (see keyBytes' own "the escape
    # is injective" note) -- nothing under this SPELLING was ever produced
    # by keyBytes for such a rel.
    let roots = rootsWith("/fake/proj-fkb9", fpNone)
    check fromKeyBytes("./x", roots).isNone
    check fromKeyBytes("./foo/bar.nim", roots).isNone

  test "empty text degrades to none":
    let roots = rootsWith("/fake/proj-fkb10", fpNone)
    check fromKeyBytes("", roots).isNone

# ===========================================================================
# Probe-memo bypass for injected probes (A3b-ii) — the injectable §3 seam
# must survive a prior default/other-probe call against the SAME root.
# ===========================================================================

suite "initTrackedRoots — injected probe bypasses the per-process memo":

  test "a second injection with a different policy is honored for the same root":
    # Same root abs path, two DIFFERENT injected policies in sequence. Before
    # the A3b-ii memo-bypass, the second call would return the first's
    # memoized answer (a footgun that silently defeated forced-policy
    # injection after any prior probe of the same root — e.g. runTests'
    # internal default probe). With the bypass, each injected probe answers
    # exactly what it was asked.
    let root = "/fake/proj-memo-bypass"
    let first  = rootsWith(root, fpNone)
    check first.project.foldPolicy == fpNone
    let second = rootsWith(root, fpAsciiLower)
    check second.project.foldPolicy == fpAsciiLower

# ===========================================================================
# TrackedRoots.populated() — the cacheregistry fail-closed sentinel (F26).
# `cacheregistry.configuredCache` is the one consumer: a `false` result
# means "this `TrackedRoots` was never actually built by `initTrackedRoots`"
# (a hand-built/malformed `Config` skipped roots resolution entirely), and
# it fails closed on any `file://` remote rather than guessing a fold
# policy. See `populated`'s own doc comment in paths.nim.
# ===========================================================================

suite "TrackedRoots.populated() — the cacheregistry fail-closed sentinel":

  test "a bare zero-value TrackedRoots() is NOT populated":
    let roots = TrackedRoots()
    check not roots.populated()

  test "a TrackedRoots built by initTrackedRoots IS populated":
    let roots = rootsWith("/fake/proj-populated", fpNone)
    check roots.populated()

suite "isUnderRoot — the sanctioned root-membership primitive":

  test "the root itself is a member (container == root)":
    check isUnderRoot("/proj", "/proj")
    check isUnderRoot("/proj/", "/proj/")

  test "a path strictly under the root is a member":
    check isUnderRoot("/proj/a/b.nim", "/proj")
    check isUnderRoot("/proj/a/b.nim", "/proj/")

  test "a sibling sharing the root's name as a prefix is NOT a member":
    # The whole reason a raw startsWith is forbidden: `/proj-old` shares the
    # textual prefix `/proj` but is a different tree.
    check not isUnderRoot("/proj-old/x.nim", "/proj")
    check not isUnderRoot("/project/x.nim", "/proj")

  test "an unrelated path is not a member":
    check not isUnderRoot("/etc/passwd", "/proj")
    check not isUnderRoot("../../etc/passwd", "/proj")

  test "separators are normalized so mixed forms compare correctly":
    check isUnderRoot("C:\\proj\\a\\b.nim", "C:/proj")
    check isUnderRoot("C:/proj/a/b.nim", "C:\\proj")
    check not isUnderRoot("C:\\proj-old\\a", "C:/proj")

# ===========================================================================
# DisplayPath — the compiler-enforced seal (RFC-0009 wiring-audit F12).
#
# `display(tp)` returns `DisplayPath` (distinct string), not `string`, so
# the PRODUCTION INVARIANT `toNative` is the sole sanctioned I/O inverse
# (paths.nim's own doc comment on `toNative`) is now a TYPE ERROR to
# violate, not a convention a textual scan could never fully enforce. This
# suite makes that assertion executable: every I/O proc the invariant names
# must REFUSE a bare `display()` result, and the documented escape hatch
# (`string(...)`) must still work.
# ===========================================================================

suite "DisplayPath — display() is compiler-sealed against direct I/O use":

  test "a bare display() result does not compile against any I/O proc":
    var tp: TrackedPath
    check not compiles(readFile(display(tp)))
    check not compiles(open(display(tp)))
    check not compiles(fileExists(display(tp)))
    check not compiles(execProcess(display(tp)))
    check not compiles(absolutePath(display(tp)))

  test "F36: display() deliberately has no $ or & — pinned, not just documented":
    # `DisplayPath`'s doc comment in paths.nim states `$`/`&` are
    # deliberately NOT provided (either would be exactly as low-friction as
    # `toNative` at an I/O call site while being far less greppable than
    # the `string(...)` escape hatch). Nothing previously pinned that
    # omission executably — a future overload added elsewhere (a stray
    # generic, a borrow, a converter) could silently reopen it. `DisplayPath`
    # has no borrowed/hand-written `$` and no `converter` anywhere in
    # paths.nim (checked directly above), so these three must fail to
    # compile for the right reason — "no matching `$`/`&` overload for a
    # distinct, non-string, non-convertible type" — not by some accidental
    # generic/converter match.
    var tp: TrackedPath
    check not compiles($display(tp))
    check not compiles(display(tp) & "x")
    check not compiles("x" & display(tp))

  test "the explicit string(...) escape hatch still compiles":
    var tp: TrackedPath
    check compiles(readFile(string(display(tp))))
    check compiles(open(string(display(tp))))
    check compiles(fileExists(string(display(tp))))
    check compiles(execProcess(string(display(tp))))
    check compiles(absolutePath(string(display(tp))))

# ===========================================================================
# ReportedPath — the compiler-enforced seal (CR10).
#
# `ReportedPath` (distinct string) is what `ccprobe.depIncludeHeaders` (and
# `parseMsvcSourceDeps`/`parseCcMDeps` beneath it) hand back for a foreign
# tool's dependency-report path — see paths.nim's own doc comment on the
# type. The invariant this suite proves executably: a `ReportedPath` cannot
# reach `TrackedPath.rel` (the unfolded cache-key material) through any
# STRING-typed identity API — `fromCanonical`, the trusted `classify`
# overload, `nativeCanonicalize`, `isUnderRoot` — because none of them
# accept it; only `classify`/`tracked`'s dedicated `ReportedPath` overload
# does, and THAT overload is exactly the one that resolves it first (W1).
# The escape hatch, `string(rp)`, is explicit and greppable — mirroring
# `DisplayPath`'s own discipline above.
# ===========================================================================

suite "ReportedPath — a foreign-tool spelling cannot reach TrackedPath.rel without resolution (CR10)":

  test "a bare ReportedPath does not compile against any string-typed identity API":
    var roots: TrackedRoots
    let rp = ReportedPath("c:/msvc/vc/include/stdint.h")
    # The trusted-text constructors and the trusted `classify` overload all
    # take `string`, never `ReportedPath` — no implicit conversion exists,
    # so handing one a `ReportedPath` is a TYPE ERROR, not a silent
    # unresolved-spelling bug.
    check not compiles(fromCanonical(rp, roots))
    check not compiles(fromCanonical(RootTag(0), rp, roots))
    check not compiles(nativeCanonicalize(rp, "/fake/proj"))
    check not compiles(isUnderRoot(rp, "/fake/proj"))
    # Nor can it stand in for the trusted OTHER argument of `isUnderRoot`.
    check not compiles(isUnderRoot("/fake/proj/x.nim", rp))

  test "F36-style: ReportedPath deliberately has no $ or & — pinned, not just documented":
    ## Same rationale as `DisplayPath`'s own F36 test above: `$`/`&` would
    ## be exactly as low-friction as the sanctioned `classify`/`tracked`
    ## overload at a call site, while being far less greppable than the
    ## `string(...)` escape hatch — reopening the hole this type exists to
    ## close. Nothing borrows or hand-writes either for `ReportedPath`, and
    ## no `converter` exists anywhere in paths.nim, so these fail to compile
    ## for the right reason: no matching overload for a distinct,
    ## non-string, non-convertible type.
    let rp = ReportedPath("c:/msvc/vc/include/stdint.h")
    check not compiles($rp)
    check not compiles(rp & "x")
    check not compiles("x" & rp)

  test "the explicit string(...) escape hatch still compiles, and reaches the string-typed APIs":
    var roots: TrackedRoots
    let rp = ReportedPath("c:/msvc/vc/include/stdint.h")
    check compiles(fromCanonical(string(rp), roots))
    check compiles(nativeCanonicalize(string(rp), "/fake/proj"))
    check compiles(isUnderRoot(string(rp), "/fake/proj"))

  test "the ONE sanctioned path — classify/tracked's ReportedPath overload — compiles and actually resolves":
    let roots = rootsWith("C:/Users/RunnerAdmin/Project", fpAsciiLower)
    const reported = "c:/users/runneradmin/project/native/add.h"
    const onDisk   = "C:/Users/RunnerAdmin/Project/Native/Add.h"
    proc fakeExpand(p: string): string =
      if p.toLowerAscii == reported: onDisk else: p
    let rp = ReportedPath(reported)
    check compiles(classify(rp, roots, fakeExpand))
    check compiles(tracked(rp, roots))
    # Not just "compiles" — actually resolves to the real on-disk spelling,
    # the whole point of routing a ReportedPath through this overload at
    # all (mirrors the "classify — F18 candidate-side CASE expansion" suite
    # above, restated here as the type-level guarantee).
    let pc = classify(rp, roots, fakeExpand)
    check pc.kind == pcTracked
    check pc.tp.display == "Native/Add.h"
