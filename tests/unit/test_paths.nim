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
## is per-PROCESS (never reset between tests in this file) — every fake
## root below therefore uses a path unique to its own test, so two tests
## injecting two different policies never collide on one memoized answer.

import std/[unittest, options, os, strutils, json]
import crisol/paths

proc fixedProbe(policy: FoldPolicy): proc (rootAbs, stateDir: string): FoldPolicy =
  result = proc (rootAbs, stateDir: string): FoldPolicy = policy

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
# toNative round-trip, including a deliberate >260-char path.
# ===========================================================================

suite "toNative — round trip through classify":

  test "ordinary path round-trips: classify(toNative(tp)) == tp":
    let roots = rootsWith("/fake/proj-native-1", fpNone)
    let tp = tracked("/fake/proj-native-1/a/b/c.nim", roots).get
    let native = toNative(tp, roots)
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
    let base = getTempDir() / ("crisol_test_paths_symlink_" & $getCurrentProcessId())
    let realDir = base / "real-dep-target"
    let linkDir = base / "dep-link"
    createDir(realDir)
    writeFile(realDir / "foo.nim", "# fixture\n")
    defer:
      try: removeDir(base)
      except OSError: discard
    var linked = true
    try:
      createSymlink(realDir, linkDir)
    except OSError:
      linked = false
    if not linked:
      skip()   # symlink privilege unavailable in this environment
    else:
      let roots = rootsWith(base / "project-root", fpNone,
                             @[("linked", linkDir)])
      # Reach the file through its REAL (non-symlink) path, not the
      # configured symlink spelling — this must still classify under the
      # dep root's tag.
      let tp = tracked(realDir / "foo.nim", roots).get
      check (not tp.isProject)
      check tp.display == "foo.nim"

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
