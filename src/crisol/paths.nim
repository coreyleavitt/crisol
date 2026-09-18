## paths.nim — the ONLY module that constructs or interprets path identity.
##
## RFC-0009 A1: `TrackedPath` and its family — a distinct, root-tagged,
## fold-aware identity for a file tracked under crisol's project root or one
## of its configured dep roots, replacing the ad-hoc `string` the rest of
## crisol used to compare, dedup, and hash a path with (docs/rfc/0009-path-
## identity.md §1). Pure leaf slice: nothing outside this module constructs
## or interprets a `TrackedPath`'s fields, and nothing yet CONSUMES this
## module (A1 is a pure leaf, proven by its own unit conformance — later
## RFC-0009 slices retrofit config.nim/discover.nim/closure.nim/etc. onto
## it, one surface at a time).
##
## No implicit `string` conversion exists anywhere below: every un-reduced
## comparison that survives the eventual migration is a compile error, not a
## latent Windows/case-insensitive-volume bug.

# RFC-0009 F29: `createAndStatFallback`'s probe-file create goes through
# `ioutils.exclusiveCreate`/`writeAllFd`/`closeFd` (RFC-0007 A3's sole owner
# of raw file I/O in `src/`, `test_rfc7_a3_ioutils_ownership.nim`'s
# allow-list already documents `paths.nim`'s ONLY direct `std/posix` use as
# the macOS `pathconf` capability query, never raw open/write) rather than
# hand-rolling a second hardened-open primitive here. No cycle: `ioutils`
# imports only `std/os`/`std/posix`/`std/winlean`/`std/sysrand` — nothing
# under `crisol/` — and `cachelocalfs.nim` already imports both modules side
# by side.
import std/[hashes, json, options, os, strutils, tables]
import crisol/ioutils

# ---------------------------------------------------------------------------
# §1 — the identity types
# ---------------------------------------------------------------------------

type
  RootTag* = distinct uint16
    ## Which tracked root a path is relative to. 0 = project; 1..N = configured
    ## dep roots, assigned in declared/discovered order — stable for a given
    ## config, never recomputed from a path string. Borrowed `==`/`hash` only
    ## — deliberately NO serialization proc: a RootTag's numeric value never
    ## escapes this process. Anything persisted is addressed by the root's
    ## configured NAME instead.

proc `==`*(a, b: RootTag): bool {.borrow.}
proc hash*(t: RootTag): Hash {.borrow.}

type
  FoldPolicy* = enum fpNone, fpAsciiLower   ## round 1: ASCII only (see Risks)

  TrackedPath* = object
    ## crisol's canonical identity of a file tracked under SOME root —
    ## project or a dep root. Constructed only via `classify`, `fromCanonical`,
    ## or `fromJson` (already-canonical input); every equality, membership,
    ## dedup, ordering, and cache-key input in the system is over
    ## `TrackedPath`, never a bare string. All fields private: a public `rel`
    ## field would let `TrackedPath(rel: x)` counterfeit an identity with no
    ## fold ever applied.
    rootTag: RootTag
    fold: FoldPolicy   ## the matched root's OWN probed policy at construction
                       ## time — a POLICY, not a derived folded string:
                       ## `==`/`hash` fold `rel` on the fly, one pass, from
                       ## this field.
    rel: string        ## real-case, forward-slash, root-relative spelling —
                       ## the STORED identity field. What humans see
                       ## (`display(tp)`/`$tp`) and what `toNative(tp, roots)`
                       ## re-expands to open/spawn.

  PathClassKind* = enum pcTracked, pcOutside
  PathClass* = object
    ## The TOTAL result of classifying a native path. Every native spelling
    ## lands in exactly one arm — there is no refusal here.
    case kind*: PathClassKind
    of pcTracked: tp*: TrackedPath   ## safe to expose: uncounterfeitable (above).
    of pcOutside: native*: NativeAbs

  NativeAbs* = object
    ## A native-absolute path that is not (yet, or ever) known to be under
    ## any tracked root. Distinct from TrackedPath by construction: it
    ## carries no root tag and can never feed a cache key. Native-
    ## canonicalized but NOT fold-policy-reduced. Private field.
    abs: string

  NativeRoot* = object
    ## One tracked root's native, absolute location and its own probed
    ## identity capability — computed ONCE and threaded, never re-derived
    ## downstream. Private fields + accessors.
    abs: string          ## native-canonicalized absolute path.
    realAbs: string       ## `expandFilename`'d once at construction — the
                          ## realpath form, so a symlinked root still matches
                          ## a realpath-expanded candidate at classify time.
    foldPolicy: FoldPolicy ## probed for THIS root's volume — each NativeRoot
                          ## answers for itself.
    name: string          ## configured name ("" for the project root) — the
                          ## ONLY thing ever persisted to identify a root.

  TrackedRoots* = object
    ## Immutable once constructed. PRIVATE fields: a public `deps` would
    ## break the counterfeit-proofing every other type in this family gets —
    ## `RootTag` is POSITIONAL, so a `var` reorder of a public `deps` would
    ## silently re-tag every path through the front door. Accessors below;
    ## construction only via `initTrackedRoots`.
    fproject: NativeRoot    ## rootTag 0.
    fdeps: seq[NativeRoot]  ## rootTag 1..deps.len, by configured name/order.
    degraded*: bool         ## RFC-0009 A-degraded (D2): true iff ANY root's
                            ## fold-policy probe genuinely failed (`none`) at
                            ## construction time. One root's failure degrades
                            ## the WHOLE run — every degraded-run-aware
                            ## consumer (narrowing, cache, dep-graph persist)
                            ## reads this single flag. Orthogonal to
                            ## `populated()` (that means "roots resolved at
                            ## all"; this means "resolved, but at least one
                            ## probe answer is unknown").
    degradedReason*: string ## human-readable, semicolon-joined reason(s)
                            ## naming every root whose probe failed — "" iff
                            ## not degraded. Surfaced in `--json` evidence
                            ## (a later slice) and safe to log as-is.

  CacheKeyPath* = distinct string
    ## keyBytes' return type: canonical, UNFOLDED cache-key bytes. A distinct
    ## type, not `string`, so a cache-key consumer cannot accept a bare `rel`
    ## by accident. `string(k)` is the sole, explicit escape hatch.

  DisplayPath* = distinct string
    ## `display`'s return type (RFC-0009 A-final-ii, wiring-audit F12). A
    ## distinct type, not `string`, so the PRODUCTION INVARIANT this module
    ## has always documented — `toNative` is the ONLY sanctioned way to turn
    ## a `TrackedPath` back into a filesystem path for I/O; `display`/`$tp`
    ## is for HUMANS and logs/JSON/key material only, and is NEVER fed to
    ## `readFile`/`open`/`fileExists`/`execProcess`/`absolutePath`/etc. — is
    ## now compiler-enforced instead of convention-only: every one of those
    ## procs takes a `string`, so passing a bare `DisplayPath` (or anything
    ## built from one without unwrapping it) is a TYPE ERROR, not a silent
    ## data-flow bug an undecidable textual scan could never catch.
    ##
    ## `string(dp)` is the sole, explicit, greppable escape hatch — every
    ## call site that reaches for it is asserting "this consumer genuinely
    ## wants the raw text" (JSON emission, XML escaping, string
    ## concatenation into a human message, a `Table`/tuple key that must
    ## stay wire-compatible with a persisted or widely-fixture-literal
    ## shape) and should read as self-evidently safe, or carry a half-line
    ## comment saying why. `==`/`hash`/`cmp` are borrowed directly (so a
    ## `DisplayPath` still sorts, hashes, and compares like the string it
    ## wraps, with zero I/O risk), plus a hand-written heterogeneous `==`
    ## against a bare `string` — legitimate for comparing against a literal
    ## in a test or an already-string-typed field, still no way to smuggle
    ## a `DisplayPath` into an I/O call through it. Deliberately NO `$` and
    ## NO `&`: either would be exactly as low-friction as `toNative` at an
    ## I/O call site while being far LESS greppable than `string(...)`,
    ## which would reopen the hole this type exists to close.

proc path*(n: NativeAbs): string = n.abs
proc `$`*(n: NativeAbs): string = n.abs
proc `==`*(a, b: NativeAbs): bool = a.abs == b.abs
proc hash*(n: NativeAbs): Hash = hash(n.abs)

proc foldPolicy*(r: NativeRoot): FoldPolicy = r.foldPolicy
proc name*(r: NativeRoot): string = r.name
  ## `abs`/`realAbs` are deliberately NOT exported as accessors: a public
  ## raw-path getter invites exactly the raw `startsWith` comparison this
  ## RFC's eventual grep-gate exists to flag. `classify` (same module) reads
  ## the private fields directly; nothing outside `paths.nim` needs the
  ## native root path itself — only its fold policy and name.

proc project*(r: TrackedRoots): lent NativeRoot = r.fproject
proc deps*(r: TrackedRoots): lent seq[NativeRoot] = r.fdeps

proc populated*(r: TrackedRoots): bool = r.fproject.abs.len > 0
  ## RFC-0009 A5c: a `TrackedRoots` built by `initTrackedRoots` always has a
  ## non-empty project `abs` (`nativeCanonicalize` never returns an empty
  ## string). Only a bare `TrackedRoots()` object-construction literal —
  ## never produced by this module's own constructor — is zero-valued this
  ## way, i.e. a caller that skipped `initTrackedRoots`/`config.loadConfig`
  ## entirely (a hand-built/malformed `Config`). `cacheregistry.configuredCache`
  ## is the one consumer: it has no fold POLICY to safely consult for such a
  ## caller, so it treats every `file://` remote as unverifiable and fails
  ## closed, rather than falling back to `fpNone` and risking an
  ## under-fold on whatever volume it actually lands on. Exposed as a named
  ## boolean query (not a raw `abs` getter) to keep the "no public raw-path
  ## accessor" invariant above intact.

# ---------------------------------------------------------------------------
# fold — identity under fpNone, ASCII-lowercase under fpAsciiLower.
# ---------------------------------------------------------------------------

proc fold*(s: string; policy: FoldPolicy): string =
  ## Exported (RFC-0009 A5c) for exactly one outside consumer:
  ## `cacheregistry.rootInsideStateDir`, which must fold a configured
  ## `file://` remote's directory and `stateDir` under the SAME policy
  ## `TrackedPath`'s own `==`/`hash` (above) use — not a second,
  ## independently-drifting fold implementation. Still governed by the
  ## same "no implicit string conversion" spirit: callers fold explicit,
  ## already-absolute strings, never a `TrackedPath`'s private `rel`.
  case policy
  of fpNone: s
  of fpAsciiLower: s.toLowerAscii()

# ---------------------------------------------------------------------------
# TrackedPath — comparison interface (context-free: no TrackedRoots needed).
# ---------------------------------------------------------------------------

proc display*(tp: TrackedPath): DisplayPath = DisplayPath(tp.rel)
  ## The sole accessor for the human/log/JSON/key-material spelling — see
  ## `DisplayPath`'s own doc for the invariant this return type enforces.

proc `==`*(a, b: DisplayPath): bool {.borrow.}
proc `==`*(a: DisplayPath; b: string): bool = string(a) == b
proc `==`*(a: string; b: DisplayPath): bool = a == string(b)
proc hash*(d: DisplayPath): Hash {.borrow.}
proc cmp*(a, b: DisplayPath): int {.borrow.}
proc len*(d: DisplayPath): int {.borrow.}
  ## A length query is exactly as I/O-safe as a comparison — borrowed for
  ## the same reason (e.g. a `.len > 0` sanity check on a `display()`
  ## result, never a byte fed anywhere).
  ## Borrowed, not re-derived: a `DisplayPath` still sorts/hashes/compares
  ## exactly like the string it wraps (order.nim's history sort, discover's
  ## `(path, group)` tie-break) with no I/O risk in doing so — comparison is
  ## not the operation `toNative` guards against. The two heterogeneous
  ## `==` overloads (against a bare `string`) exist for the equally-safe,
  ## extremely common case of comparing a `display()` result against a
  ## string literal or an already-string-typed field (test assertions,
  ## `discover`'s own `tp.display == relPath` invariant check below) without
  ## forcing an explicit `string(...)` unwrap at every such comparison.

proc `$`*(tp: TrackedPath): string = string(display(tp))
  ## logs/errors: real case. Derives from `display` (never a second,
  ## independently-drifting `tp.rel` read) but keeps returning a plain
  ## `string`: `$tp` is idiomatic for direct log/error interpolation, and
  ## unlike a bare `DisplayPath` escaping via a borrowed `$`, this is a
  ## SEPARATE, already-decided call — `$tp` reads a `TrackedPath` (never a
  ## `DisplayPath` value itself), so it adds no new way to unwrap a
  ## `DisplayPath` that `string(display(tp))` didn't already provide
  ## explicitly. `display(tp)` stays the sole ACCESSOR; `$tp` is sugar over
  ## it for the one call shape (`&`/interpolation) that was always going to
  ## need the plain string anyway.
proc isProject*(tp: TrackedPath): bool = tp.rootTag == RootTag(0)

proc `==`*(a, b: TrackedPath): bool =
  ## FOLDED, computed on the fly from the stored POLICY — selection
  ## soundness. Invariant: same `rootTag` => same `fold` policy within one
  ## process (two TrackedPaths sharing a root were built from the same
  ## TrackedRoots, which probes each root's policy exactly once). A mismatch
  ## here is a cross-policy comparison bug (e.g. a test fixture built under a
  ## different policy than the roots it's compared against), never a
  ## legitimate case — checked UNCONDITIONALLY via `doAssert` (not a plain
  ## `assert`): this is a cheap integer compare on a hot path, and the whole
  ## point of the guarantee is that it survives `-d:danger`/`--assertions:off`
  ## release builds rather than silently degrading to `a.fold`'s policy for
  ## one side of a genuinely mismatched pair.
  if a.rootTag == b.rootTag:
    doAssert a.fold == b.fold,
      "TrackedPath: same rootTag compared under two different fold policies"
  a.rootTag == b.rootTag and fold(a.rel, a.fold) == fold(b.rel, b.fold)

proc hash*(tp: TrackedPath): Hash =
  ## Over (rootTag, folded rel).
  var h: Hash = 0
  h = h !& hash(tp.rootTag)
  h = h !& hash(fold(tp.rel, tp.fold))
  result = !$h

# ---------------------------------------------------------------------------
# keyBytes / cmpKeyBytes — the cache-key boundary (context-FULL: TAKES roots).
# ---------------------------------------------------------------------------

proc firstSegment(rel: string): string =
  let idx = rel.find('/')
  if idx < 0: rel else: rel[0 ..< idx]

proc looksLikeDepEscape(rel: string): bool =
  ## True iff `rel`'s first path segment merely STARTS WITH `dep:` — the
  ## ESCAPE `keyBytes` guards against: a tag-0 directory literally named
  ## `dep:foo` (or `dep:`, or `dep:a:b` — ext4 permits any of these; config-
  ## time dep-root NAME validation, `config.nim`, has no say over a tag-0
  ## directory's real on-disk name) is legal, and `classify` is total, so
  ## `dep:<anything>/x.nim` lands `pcTracked` tag 0 regardless.
  ##
  ## Bug history (RFC-0009 wiring-audit): a prior revision only matched the
  ## strict `dep:[^/:]+` shape (rejecting an empty or colon-containing
  ## "name" half) to mirror `fromKeyBytes`'s STRICT dep-root-arm grammar —
  ## but `fromKeyBytes` routes ANY string starting `"dep:"` into that arm
  ## (returning `none` on a shape failure, never falling back to tag-0), so
  ## a tag-0 `dep:` or `dep:a:b` rel that this proc declined to escape
  ## round-tripped through `keyBytes` unescaped, straight into
  ## `fromKeyBytes`'s dep-root arm, and came back `none` — silently
  ## DROPPED from a persisted closure (unsound under-selection, never a
  ## crash). The escape must cover every shape `fromKeyBytes` would
  ## otherwise misclassify, i.e. every `dep:`-prefixed first segment, full
  ## stop — see `keyBytes`' "the escape is injective" note.
  firstSegment(rel).startsWith("dep:")

proc keyBytes*(tp: TrackedPath; roots: TrackedRoots): CacheKeyPath =
  ## Canonical, UNFOLDED cache-key bytes — NEVER the same accessor as
  ## `==`/`hash`. rootTag 0 (project) prefixes NOTHING: keyBytes == rel,
  ## EXCEPT the `dep:*` escape (below) — a single-root project's Linux keys
  ## are otherwise bit-identical to today's bare path string. rootTag N>0 (a
  ## dep root) prefixes the root's configured NAME, e.g.
  ## "dep:mydep/src/foo.nim" — portable by construction, no machine-local
  ## absolute path ever reaches a key again.
  if tp.rootTag == RootTag(0):
    if looksLikeDepEscape(tp.rel):
      CacheKeyPath("./" & tp.rel)
    else:
      CacheKeyPath(tp.rel)
  else:
    let idx = int(uint16(tp.rootTag)) - 1
    CacheKeyPath("dep:" & roots.deps[idx].name & "/" & tp.rel)

proc cmpKeyBytes*(a, b: TrackedPath; roots: TrackedRoots): int =
  ## The SOLE ordering over `TrackedPath`: total, over raw UNFOLDED
  ## `keyBytes` bytes — never over the folded form `==`/`hash` use. No
  ## public `<` exists: a bare `sort()` over `seq[TrackedPath]` is a compile
  ## error.
  cmp(string(keyBytes(a, roots)), string(keyBytes(b, roots)))

# ---------------------------------------------------------------------------
# §2 — nativeCanonicalize + classify: the one entry boundary.
# ---------------------------------------------------------------------------

proc isAsciiAlpha(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')

proc stripLongPathPrefix(p: string): string =
  ## Strips a leading `//?/UNC/` (-> UNC form `//server/...`) or `//?/`
  ## prefix, on a string that has ALREADY had `\` normalized to `/`.
  if p.len >= 8 and p[0 ..< 4] == "//?/" and
     p[4 ..< 7].toLowerAscii() == "unc" and p[7] == '/':
    "//" & p[8 .. ^1]
  elif p.len >= 4 and p[0 ..< 4] == "//?/":
    p[4 .. ^1]
  else:
    p

type AbsKind = enum akPosix, akDrive, akUnc

proc splitAbsolute(p: string): tuple[kind: AbsKind, prefix: string, rest: string] =
  ## `p` has already had backslashes normalized to `/` and any long-path
  ## prefix stripped. Recognizes exactly one of: a drive-absolute form
  ## (`C:/...`), a UNC form (`//server/share...`), or a plain POSIX-rooted
  ## form (`/...`). Caller has already established `p` is absolute — per
  ## `isAbsoluteNative`, a bare two-char `C:` never counts as absolute (it
  ## is drive-relative), so it never reaches here un-joined.
  if p.len >= 2 and isAsciiAlpha(p[0]) and p[1] == ':':
    let drive = $toUpperAscii(p[0]) & ":"
    let rest = if p.len > 2: p[2 .. ^1] else: ""
    (akDrive, drive, rest)
  elif p.len >= 2 and p[0] == '/' and p[1] == '/' and (p.len == 2 or p[2] != '/'):
    # EXACTLY two leading slashes is UNC; three-or-more collapses to a plain
    # POSIX root below (resolveDotSegments already drops empty segments).
    (akUnc, "//", p[2 .. ^1])
  else:
    (akPosix, "/", p[1 .. ^1])

proc resolveDotSegments(rest: string; collapseAboveRoot: bool): seq[string] =
  ## Lexical `.`/`..` resolution + redundant-separator collapse over a
  ## (possibly leading/trailing-slashed) `/`-joined tail. `collapseAboveRoot`
  ## drops a `..` that would climb above the root entirely (absolute-path
  ## semantics: `..` above root is a no-op, never negative).
  result = @[]
  for seg in rest.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    elif seg == "..":
      if result.len > 0 and result[^1] != "..":
        result.setLen(result.len - 1)
      elif not collapseAboveRoot:
        result.add seg
      # else: silently absorbed (can't climb above an absolute root)
    else:
      result.add seg

proc isAbsoluteNative(p: string): bool =
  ## Host-agnostic absoluteness check over a backslash-normalized,
  ## prefix-stripped string: POSIX root, UNC, or a drive-absolute form
  ## (`C:/...`) all count. A bare two-char drive spelling (`C:`, no
  ## separator) does NOT: real Windows semantics treat bare `C:` as
  ## drive-RELATIVE — "the current directory of drive C" — not the drive
  ## root `C:/`; it is deliberately classified the same as `c:foo`
  ## (drive-relative) below, so both fall through to
  ## `nativeCanonicalize`'s drive-relative branch (joined against `base`,
  ## never resolved against an actual per-drive cwd this proc never reads).
  if p.len == 0: return false
  if p[0] == '/': return true
  if p.len >= 2 and isAsciiAlpha(p[0]) and p[1] == ':':
    return p.len > 2 and p[2] == '/'
  false

proc nativeCanonicalize*(native: string; base: string): NativeAbs =
  ## Reduces a raw OS-native spelling to a canonical absolute form, WITHOUT
  ## ever reading the process cwd (`base` MUST already be absolute and
  ## canonical — the one legitimate cwd read in the whole retrofit is
  ## captured once, by the call site that owns it, never inside this proc):
  ##   1. if `native` is relative, join against `base`.
  ##   2. absolutePath + normalizedPath (`.`/`..`, redundant separators).
  ##   3. drive-letter case + UNC canonicalization; strip a leading `\\?\`
  ##      or `\\?\UNC\` prefix (re-added only by `toNative`, when a path
  ##      needs it); `\` -> `/`.
  ## Host-agnostic by design (not gated on `defined(windows)`): identity is
  ## textual, not platform-conditional, so a Windows-shaped native spelling
  ## canonicalizes identically whether this process is running on Linux,
  ## macOS, or Windows — the property this RFC's Linux-side conformance
  ## vectors for UNC/drive/`\\?\` spellings depend on.
  var p = native.replace('\\', '/')
  p = stripLongPathPrefix(p)

  var driveRelativeTail = ""
  var isRelative = false
  if p.len == 0:
    isRelative = true
  elif isAbsoluteNative(p):
    isRelative = false
  elif p.len >= 2 and isAsciiAlpha(p[0]) and p[1] == ':':
    # drive-relative (`c:foo`): cannot be resolved without the per-drive
    # current directory, an OS-level concept this proc deliberately never
    # reads. Treated as ordinary relative text (joined against `base`,
    # itself already absolute) after discarding the drive prefix — a
    # documented, deterministic, total choice, not an attempt to honor
    # Windows' actual per-drive-cwd semantics.
    isRelative = true
    driveRelativeTail = p[2 .. ^1]
  else:
    isRelative = true

  if isRelative:
    let tail = if driveRelativeTail.len > 0: driveRelativeTail else: p
    let baseNorm = base.replace('\\', '/')
    p = (if baseNorm.endsWith("/"): baseNorm else: baseNorm & "/") & tail

  let (kind, prefix, rest) = splitAbsolute(p)
  let segs = resolveDotSegments(rest, collapseAboveRoot = true)
  case kind
  of akPosix:
    result = NativeAbs(abs: "/" & segs.join("/"))
  of akDrive:
    result = NativeAbs(abs: prefix & "/" & segs.join("/"))
  of akUnc:
    result = NativeAbs(abs: "//" & segs.join("/"))

proc underRoot(candidate, rootAbs: string): Option[string] =
  ## Component-boundary match: `candidate` under `rootAbs`, never a raw
  ## `startsWith` (which would wrongly match a sibling directory that merely
  ## shares the root's name as a prefix). Returns the relative tail on
  ## match; `none` if `candidate` equals the root itself (a container, never
  ## a trackable file) or isn't under it at all.
  let prefix = if rootAbs.endsWith("/"): rootAbs else: rootAbs & "/"
  if candidate.len > prefix.len and candidate.startsWith(prefix):
    some(candidate[prefix.len .. ^1])
  else:
    none(string)

proc isUnderRoot*(candidate, rootAbs: string): bool =
  ## The ONE sanctioned root-membership primitive. True iff `candidate` is
  ## `rootAbs` itself or lives strictly under it, matched at a path-component
  ## boundary — never a bare string prefix that would wrongly match a sibling
  ## sharing the root's name (`/proj-old` under `/proj`). Separators are
  ## normalized to `/` so a native-normalized candidate (backslashes on
  ## Windows) compares correctly against a `/`-form root and vice versa.
  ##
  ## Operates on already-normalized NATIVE paths; it does NOT fold case or
  ## resolve symlinks. Two distinct callers need it: the depgraph M10
  ## traversal-bounds predicate (deliberately non-folding — a filesystem
  ## security check must not fold), and cacheregistry's rootInsideStateDir
  ## (which folds BOTH operands first, then asks membership here). This is why
  ## it stays separate from `classify`, which folds for SELECTION identity;
  ## conflating the two would either weaken the traversal defense or corrupt
  ## selection. The path-identity gate (tests/conformance/
  ## test_rfc9_path_identity_gate.nim) forbids raw `startsWith(root & …)`
  ## everywhere else so this remains the single implementation.
  let c = candidate.replace('\\', '/')
  let r = rootAbs.replace('\\', '/')
  c == r or underRoot(c, r).isSome

proc safeExpandFilename*(p: string): string
  ## Forward-declared here so `classify`'s injectable `expandCandidate`
  ## default (RFC-0009 wiring-audit F18, below) can name it without
  ## reordering this module's existing §1/§2/§3 layout — the real
  ## definition lives in §3, next to `winRealPath`, which its doc comment
  ## explains in full.

proc looksLike8Dot3Component(seg: string): bool =
  ## True iff `seg` (one already-split `/`-segment) bears the DOS 8.3
  ## short-name signature: a `~` immediately followed by an ASCII digit
  ## (`RUNNER~1`, `PROGRA~1`, …) — the shape every short name Windows
  ## actually generates. A bare trailing `~` with no digit after it (a
  ## legal, if unusual, ordinary filename byte) does NOT match: MSDN's own
  ## 8.3 algorithm always tacks on a numeric disambiguator, so a `~` with no
  ## following digit is never a genuine short name.
  for i in 0 ..< seg.len:
    if seg[i] == '~' and i + 1 < seg.len and seg[i + 1] in {'0'..'9'}:
      return true
  false

proc plausibly8Dot3*(nativeAbs: string): bool =
  ## True iff ANY `/`-separated component of `nativeAbs` (already
  ## `nativeCanonicalize`'d — forward-slash, absolute) plausibly carries a
  ## DOS 8.3 short name. Exported (RFC-0009 wiring-audit F18) so this pure,
  ## cross-platform predicate is directly unit-testable on Linux — the real
  ## 8.3 EXPANSION `classify` gates behind it only ever does real work on
  ## Windows (`safeExpandFilename`'s `winRealPath` branch), but the
  ## predicate itself is ordinary text and needs no platform gate to prove.
  for seg in nativeAbs.split('/'):
    if looksLike8Dot3Component(seg): return true
  false

type CandidateExpander* = proc (p: string): string
  ## RFC-0009 wiring-audit F18: the injectable candidate-side realpath-
  ## expansion seam `classify` falls back to — NEVER on the hot path (see
  ## `classify`'s own doc comment for the cost budget this protects).
  ## Defaults everywhere to `safeExpandFilename`, the real cross-platform
  ## realpath primitive (§3): on Windows, `winRealPath`
  ## (`GetFinalPathNameByHandleW`) resolves a DOS 8.3 short-name component
  ## to its long form as a documented side effect (see `winRealPath`'s own
  ## doc comment); on POSIX this fallback is unreachable in practice (8.3
  ## short names are a Windows/FAT concept — `plausibly8Dot3` can still fire
  ## on a POSIX path that happens to contain a `~<digit>` component, but
  ## `expandFilename` there is an ordinary realpath with nothing 8.3-shaped
  ## to resolve, so the retry is simply a no-op match failure, not a wrong
  ## answer). An explicitly-injected non-default expander is the Linux-
  ## testability seam that exercises the FALLBACK'S WIRING (predicate ->
  ## expand -> re-match) without a real Windows short name to expand,
  ## mirroring `FoldProbe` above.

proc matchRoots(abs: string; roots: TrackedRoots): Option[PathClass] =
  ## The shared root-membership decision `classify` applies to a candidate
  ## abs path — factored out so the RFC-0009 wiring-audit F18 8.3 fallback
  ## (below) can retry it against an EXPANDED candidate without duplicating
  ## the matching logic itself. `none` means "no root claims this spelling",
  ## the caller's cue to either try a fallback or land `pcOutside`.
  let projRel = underRoot(abs, roots.project.abs)
  let projRelReal = underRoot(abs, roots.project.realAbs)
  if projRel.isSome or projRelReal.isSome:
    # PROJECT FIRST: a path under the project root is ALWAYS tag 0 — even
    # one that also nests under a configured dep root's own directory.
    let rel = if projRel.isSome: projRel.get else: projRelReal.get
    return some(PathClass(kind: pcTracked,
      tp: TrackedPath(rootTag: RootTag(0), fold: roots.project.foldPolicy,
                       rel: rel)))

  var bestIdx = -1
  var bestLen = -1
  var bestRel = ""
  for i, d in roots.fdeps:
    let r1 = underRoot(abs, d.abs)
    if r1.isSome and d.abs.len > bestLen:
      bestLen = d.abs.len; bestIdx = i; bestRel = r1.get
    let r2 = underRoot(abs, d.realAbs)
    if r2.isSome and d.realAbs.len > bestLen:
      bestLen = d.realAbs.len; bestIdx = i; bestRel = r2.get

  if bestIdx >= 0:
    return some(PathClass(kind: pcTracked,
      tp: TrackedPath(rootTag: RootTag(uint16(bestIdx + 1)),
                       fold: roots.fdeps[bestIdx].foldPolicy, rel: bestRel)))
  none(PathClass)

proc classify*(native: string; roots: TrackedRoots;
               expandCandidate: CandidateExpander = safeExpandFilename): PathClass =
  ## TOTAL: every native spelling classifies. Nothing is refused here.
  ##
  ## RFC-0009 wiring-audit F18: only ROOTS were ever realpath-expanded
  ## (`NativeRoot.realAbs`, `initTrackedRoots` time) — the CANDIDATE side
  ## stayed purely lexical (`nativeCanonicalize` never touches disk), so a
  ## Windows 8.3 short-name CANDIDATE (`C:\Users\RUNNER~1\...`) under a
  ## long-form root lexically mismatched and silently landed `pcOutside`
  ## (dropped from selection/diff reduction) even though it names a real
  ## tracked file. Fixed as a FALLBACK, not a widening of the hot path:
  ## `SourceIndex` classifies thousands of paths per run, so this must cost
  ## nothing for the overwhelming common case. `matchRoots` is tried first
  ## against the plain lexical candidate, exactly as before; only when that
  ## fails AND the candidate plausibly contains an 8.3 component
  ## (`plausibly8Dot3` — a cheap text scan, no I/O) does `expandCandidate`
  ## (real disk I/O on Windows, a no-op match failure everywhere else) run
  ## at all, and the result is re-matched exactly once. Still TOTAL: an
  ## expander that cannot resolve the name returns its input unchanged
  ## (`safeExpandFilename`'s own "never raises" contract), which re-matches
  ## identically to the first attempt and falls through to `pcOutside`.
  let na = nativeCanonicalize(native, roots.project.abs)

  let direct = matchRoots(na.abs, roots)
  if direct.isSome: return direct.get

  if plausibly8Dot3(na.abs):
    let expandedAbs = nativeCanonicalize(expandCandidate(na.abs), roots.project.abs).abs
    if expandedAbs != na.abs:
      let viaExpansion = matchRoots(expandedAbs, roots)
      if viaExpansion.isSome: return viaExpansion.get

  PathClass(kind: pcOutside, native: na)

proc tracked*(native: string; roots: TrackedRoots): Option[TrackedPath] =
  ## Convenience over `classify` for the include-or-skip call sites that
  ## only ever want the pcTracked case and discard pcOutside silently.
  let pc = classify(native, roots)
  case pc.kind
  of pcTracked: some(pc.tp)
  of pcOutside: none(TrackedPath)

# ---------------------------------------------------------------------------
# fromCanonical / fromJson — the already-canonical-text constructors.
# ---------------------------------------------------------------------------

proc foldPolicyForTag(tag: RootTag; roots: TrackedRoots): Option[FoldPolicy] =
  let idx = int(uint16(tag))
  if idx == 0: some(roots.project.foldPolicy)
  elif idx >= 1 and idx <= roots.fdeps.len: some(roots.fdeps[idx - 1].foldPolicy)
  else: none(FoldPolicy)

proc fromCanonical*(tag: RootTag; rel: string; roots: TrackedRoots): Option[TrackedPath] =
  ## For input that is ALREADY canonical relative form — a persisted `rel`
  ## read back from the dep graph, a `git diff` path. Validates the shape
  ## invariant (rejecting a `\` ANYWHERE — not just leading — any `.`/`..`
  ## segment, an absolute form — drive letter, UNC, or leading `/` — and a
  ## doubled separator: all signs the caller handed it un-reduced native
  ## text) and applies the tagged root's fold policy. Critically never
  ## touches cwd. Returns `none` on a shape violation — NEVER raises:
  ## parsing untrusted/persisted text never crashes, the caller chooses
  ## degrade vs abort.
  ##
  ## RFC-0009 wiring-audit F15: an EMBEDDED backslash (`"sub\file.nim"`, a
  ## backslash mid-segment, not just leading) is rejected too, not only a
  ## leading one. `nativeCanonicalize` (this module's ONE constructor for
  ## native, OS-spelled text) treats `\` as a path separator
  ## UNCONDITIONALLY, host-agnostically (its own doc comment: "identity is
  ## textual, not platform-conditional" — a Windows-shaped spelling
  ## canonicalizes identically on Linux, macOS, or Windows). Consequently no
  ## `rel` this module ever legitimately constructs via `classify` can
  ## contain a literal backslash byte at ANY position: every backslash in
  ## the original native string was already folded into `/` before the
  ## result was ever stored in `TrackedPath.rel`. A canonical-text caller
  ## (git's `--relative` output, always `/`-separated by git's own internal
  ## convention; a persisted `tp.display()` round-trip) can therefore never
  ## legitimately hand this proc a backslash at all — an embedded one is
  ## exactly as diagnostic of un-reduced native text as a leading one, and a
  ## shape check that only caught the leading case let
  ## `"sub\file.nim"` (Windows: one un-reduced two-segment path;
  ## POSIX: would-be single-segment text) through as a single opaque
  ## segment whose identity could never unify with the correctly-classified
  ## `"sub/file.nim"` spelling of the same file. Checked ahead of the
  ## per-segment split below so it also catches a bare `"\"` with no `/` at
  ## all.
  if rel.len == 0: return none(TrackedPath)
  if '\\' in rel: return none(TrackedPath)
  if rel.len >= 2 and isAsciiAlpha(rel[0]) and rel[1] == ':':
    return none(TrackedPath)   # drive-letter absolute form
  for seg in rel.split('/'):
    if seg.len == 0: return none(TrackedPath)      # leading/trailing/doubled '/'
    if seg == "." or seg == "..": return none(TrackedPath)
  let policy = foldPolicyForTag(tag, roots)
  if policy.isNone: return none(TrackedPath)
  some(TrackedPath(rootTag: tag, fold: policy.get, rel: rel))

proc fromCanonical*(rel: string; roots: TrackedRoots): Option[TrackedPath] =
  ## tag-0 (project) shorthand — most callers never have a dep tag to hand.
  fromCanonical(RootTag(0), rel, roots)

proc toJson*(tp: TrackedPath; roots: TrackedRoots): JsonNode =
  ## Emits {"root": name, "path": rel} — name is "" for the project root,
  ## else the tagged root's configured NAME (never the ordinal RootTag,
  ## which is not stable across a config edit).
  let name =
    if tp.rootTag == RootTag(0): ""
    else: roots.fdeps[int(uint16(tp.rootTag)) - 1].name
  result = newJObject()
  result["root"] = newJString(name)
  result["path"] = newJString(tp.rel)

proc fromJson*(node: JsonNode; roots: TrackedRoots): Option[TrackedPath] =
  ## Round-trip partner: resolves the persisted name back to a RootTag
  ## against the CURRENT roots; an unresolvable name (a renamed/removed dep
  ## root) returns `none` — the caller degrades, it never crashes on stale
  ## on-disk state.
  if node.kind != JObject: return none(TrackedPath)
  if not node.hasKey("root") or not node.hasKey("path"): return none(TrackedPath)
  let rootNode = node["root"]
  let pathNode = node["path"]
  if rootNode.kind != JString or pathNode.kind != JString: return none(TrackedPath)
  let name = rootNode.getStr()
  let rel = pathNode.getStr()
  if name.len == 0:
    return fromCanonical(RootTag(0), rel, roots)
  for i, d in roots.fdeps:
    if d.name == name:
      return fromCanonical(RootTag(uint16(i + 1)), rel, roots)
  none(TrackedPath)

proc fromKeyBytes*(s: string; roots: TrackedRoots): Option[TrackedPath] =
  ## The inverse of `keyBytes` — the depgraph closure member reader (RFC-0009
  ## W1). Reconstructs a `TrackedPath` from a persisted `string(keyBytes(tp,
  ## roots))` string, e.g. a depgraph closure entry read back off disk. Three
  ## arms, mirroring `keyBytes`' own three cases exactly:
  ##   - `"dep:<name>/<rel>"` — the root name is the text between `"dep:"`
  ##     and the first `/`; resolved against the CURRENT `roots.deps[i].name`
  ##     to `RootTag(i+1)`. An empty name, a `:` inside the name, an absent
  ##     `/` at all, an empty `rel`, or an unresolvable name (a renamed or
  ##     removed dep root) all return `none`. Since `looksLikeDepEscape`
  ##     (RFC-0009 wiring-audit fix) now escapes EVERY tag-0 rel whose
  ##     first segment starts with `dep:` — including the empty-name and
  ##     colon-in-name shapes — `keyBytes` never legitimately emits a bare
  ##     `"dep:"`-prefixed string with one of those malformed shapes any
  ##     more: a bare, unescaped `"dep:/x"` or `"dep:a:b/x"` arriving here
  ##     can now only mean pre-fix persisted data (a format-7-or-earlier
  ##     depgraph closure member written before the escape widened) or
  ##     genuine corruption — never a live round trip. `none` remains the
  ##     right answer for both: this is the SAME degrade-never-crash
  ##     posture as any other shape violation, just no longer reachable
  ##     from a healthy write.
  ##   - `"./<rel>"` — the §4 R3-20 escape (`keyBytes`' own `dep:` guard for
  ##     a tag-0 rel whose first segment starts with `dep:` at all — not
  ##     just a shape that also happens to parse as a well-formed dep-root
  ##     name). `rel` (the text after `./`) must itself satisfy
  ##     `looksLikeDepEscape` — nothing else legally begins `./` (see
  ##     `keyBytes`' "the escape is injective" note), so any other
  ##     `./`-prefixed text is malformed and returns `none`.
  ##   - anything else — tag 0, unchanged.
  ## Every arm delegates final shape validation to `fromCanonical`, which
  ## never raises: parsing persisted/untrusted text never crashes here
  ## either — a shape violation degrades to `none`, the caller chooses
  ## degrade vs abort (the same family rule `fromCanonical`/`fromJson`
  ## follow). Never touches cwd or disk.
  if s.startsWith("dep:"):
    let rest = s[4 .. ^1]
    let idx = rest.find('/')
    if idx < 0: return none(TrackedPath)
    let name = rest[0 ..< idx]
    let rel = rest[idx + 1 .. ^1]
    if name.len == 0 or ':' in name or rel.len == 0: return none(TrackedPath)
    for i, d in roots.fdeps:
      if d.name == name:
        return fromCanonical(RootTag(uint16(i + 1)), rel, roots)
    return none(TrackedPath)
  elif s.startsWith("./"):
    let rel = s[2 .. ^1]
    if not looksLikeDepEscape(rel): return none(TrackedPath)
    return fromCanonical(RootTag(0), rel, roots)
  else:
    return fromCanonical(RootTag(0), s, roots)

# ---------------------------------------------------------------------------
# toNative — the sole inverse, for I/O.
# ---------------------------------------------------------------------------

const winLongPathThreshold = 260
  ## MAX_PATH. `toNative` re-adds the `\\?\`/`\\?\UNC\` extended-length
  ## prefix on Windows only past this length: the resulting native path is
  ## already fully resolved (no `.`/`..`, drive/UNC-absolute), which is
  ## exactly the form Win32's extended-length convention requires, so it is
  ## always safe to add here. Short paths are untouched — byte-identical to
  ## today. Decided in THIS slice (not deferred): every native Win32 call
  ## site consumes `toNative`'s output through this one boundary, so the
  ## decision made here propagates everywhere automatically.
proc applyWinLongPathPrefix(native: string): string =
  ## Platform-independent so its lexical behavior is unit-testable from
  ## Linux; only ever CALLED under `when defined(windows)` in `toNative`.
  if native.len <= winLongPathThreshold:
    return native
  if native.len >= 2 and native[0] == '\\' and native[1] == '\\':
    "\\\\?\\UNC\\" & native[2 .. ^1]
  else:
    "\\\\?\\" & native

proc toNative*(tp: TrackedPath; roots: TrackedRoots): string =
  ## The inverse for I/O: the tagged root's native abs path, joined with
  ## `tp.rel` in OS-native separators — mirrors `classify`'s argument order
  ## (subject first, roots second).
  ##
  ## PRODUCTION INVARIANT (RFC-0009 A-final-ii): this is the ONLY way to
  ## turn a TrackedPath back into a filesystem path to open, compile, or
  ## spawn. `display(tp)` (== `tp.rel`) is for HUMANS and logs/JSON only —
  ## it is root-relative and never fed to an OS file operation. A direct
  ## textual scan for a `.display()` call feeding I/O is undecidable (data-
  ## flow, not lexical — post-completion, wiring-audit W4, 2026-09-17), so
  ## the path-identity gate (`test_rfc9_path_identity_gate.nim`) does not
  ## attempt one; it instead enforces the two lexically-decidable backstops
  ## this invariant actually reduces to: `toNative` being the sole sanctioned
  ## inverse out of `TrackedPath` (this type seal), and Tier 4's check that
  ## no key-surface proc reverts to a string-typed identity/path parameter
  ## (the concrete way a caller would bypass `toNative` in practice).
  ##
  ## As of this change (wiring-audit F12), the undecidable-scan gap above is
  ## closed for good, not merely narrowed: `display` returns `DisplayPath`,
  ## a distinct type, so `readFile(display(tp))`/`open(display(tp))`/etc. no
  ## longer merely LOOK wrong to a reviewer — they fail to compile. The only
  ## way to hand a `display()` result to an I/O proc is the explicit,
  ## greppable `string(...)` unwrap, at which point a `grep -n 'string(.*
  ## display('` finds every remaining suspect call site directly — the
  ## textual-scan limitation this paragraph describes is a property of
  ## SCANNING for a bare `.display()` call, not of the seal itself.
  let rootAbs =
    if tp.rootTag == RootTag(0): roots.fproject.abs
    else: roots.fdeps[int(uint16(tp.rootTag)) - 1].abs
  var native = (if rootAbs.endsWith("/"): rootAbs else: rootAbs & "/") & tp.rel
  when defined(windows):
    native = native.replace('/', '\\')
    native = applyWinLongPathPrefix(native)
  result = native

# ---------------------------------------------------------------------------
# §3 — probeFoldPolicy: a probed, per-root, per-process-memoized capability.
# ---------------------------------------------------------------------------

when defined(windows):
  import std/winlean

  type FileCaseSensitiveInfo = object
    flags: int32

  const
    fileCaseSensitiveInfoClass = 23'i32   # FILE_INFO_BY_HANDLE_CLASS ::
      ## FileCaseSensitiveInfo. MUST be 23, not 21 (FileDispositionInfoEx) --
      ## verified against mingw-w64's minwinbase.h enum ordinal (0-indexed:
      ## FileBasicInfo=0 .. FileFullDirectoryRestartInfo=15,
      ## FileStorageInfo=16 .. FileIdExtdDirectoryRestartInfo=20,
      ## FileDispositionInfoEx=21, FileRenameInfoEx=22, FileCaseSensitiveInfo=23,
      ## FileNormalizedNameInfo=24). The old value (21) queried
      ## FileDispositionInfoEx instead -- a DIFFERENT info class whose
      ## `FILE_DISPOSITION_INFO_EX.Flags` happens to be a same-sized `ULONG`,
      ## so the call did not fail loudly; it silently read the wrong bit,
      ## making the OS-query tier answer `some(fpAsciiLower)` (a normal
      ## handle's disposition flags are 0) far more often than it should have,
      ## masking whatever the REAL per-directory case-sensitivity flag was
      ## and never falling through to the read-only/create-and-stat
      ## fallbacks that a genuine query failure would trigger.
    fileCsFlagCaseSensitiveDir = 0x00000001'i32

  proc getFileInformationByHandleEx(hFile: Handle; infoClass: int32;
      lpInfo: pointer; dwBufferSize: int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetFileInformationByHandleEx".}

  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    ## Windows: FileCaseSensitiveInformation, the per-directory NTFS flag.
    ## Authoritative; never touches disk beyond opening the directory handle
    ## itself (no read of its contents).
    let winPath = rootAbs.replace('/', '\\')
    let h = createFileW(newWideCString(winPath), GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, Handle(0))
    if h == INVALID_HANDLE_VALUE: return none(FoldPolicy)
    defer: discard closeHandle(h)
    var info: FileCaseSensitiveInfo
    if getFileInformationByHandleEx(h, fileCaseSensitiveInfoClass,
        addr info, int32(sizeof(info))) == 0'i32:
      return none(FoldPolicy)
    if (info.flags and fileCsFlagCaseSensitiveDir) != 0:
      some(fpNone)
    else:
      some(fpAsciiLower)

  proc getFinalPathNameByHandleW(hFile: Handle; lpszFilePath: WideCString;
      cchFilePath, dwFlags: int32): int32
    {.stdcall, dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}

  proc winRealPath(p: string): string =
    ## True realpath via GetFinalPathNameByHandleW: opens `p` (file OR
    ## directory, via FILE_FLAG_BACKUP_SEMANTICS) and asks the OS to resolve
    ## every reparse point (symlink/junction/mount point) along the path.
    ## `expandFilename`'s own Windows branch is GetFullPathNameW — purely
    ## LEXICAL, it never follows a reparse point (RFC-0009 B4a). As a side
    ## effect this also canonicalizes 8.3 short-name components (RUNNER~1):
    ## GetFinalPathNameByHandleW's default flags always return the long form.
    ## Never raises: any failure returns `p` unchanged (safeExpandFilename's
    ## degrade contract).
    let winPath = p.replace('/', '\\')
    let h = createFileW(newWideCString(winPath), 0'i32,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, Handle(0))
    if h == INVALID_HANDLE_VALUE: return p
    defer: discard closeHandle(h)
    var bufSize = 260'i32                       # MAX_PATH; grown on demand
    var buf = newWideCString(bufSize.int)
    var n = getFinalPathNameByHandleW(h, buf, bufSize, 0'i32)
    if n == 0'i32: return p
    if n > bufSize:                             # buffer too small: n = needed
      bufSize = n
      buf = newWideCString(bufSize.int)
      n = getFinalPathNameByHandleW(h, buf, bufSize, 0'i32)
      if n == 0'i32 or n > bufSize: return p
    result = $buf

elif defined(macosx):
  import std/posix

  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    ## macOS: pathconf(rootAbs, _PC_CASE_SENSITIVE).
    const PC_CASE_SENSITIVE = 25.cint   # <unistd.h>, Darwin
    let r = pathconf(cstring(rootAbs), PC_CASE_SENSITIVE)
    if r < 0: none(FoldPolicy)
    elif r == 0: some(fpAsciiLower)
    else: some(fpNone)

elif defined(linux):
  type CStatfsLinux {.importc: "struct statfs", header: "<sys/vfs.h>", bycopy.} = object
    f_type: clong

  proc c_statfs(path: cstring; buf: var CStatfsLinux): cint
    {.importc: "statfs", header: "<sys/vfs.h>".}

  const caseSensitiveMagics = [0xEF53'i64, 0x58465342'i64, 0x9123683E'i64,
                                0x01021994'i64]
    ## ext2/3/4, xfs, btrfs, tmpfs — case-sensitive on Linux BY DEFAULT, but
    ## NOT unconditionally (see `fsCasefoldFlag*` below, RFC-0009 F8): the
    ## per-directory ext4/F2FS casefold feature (`chattr +F`, `FS_CASEFOLD_FL`)
    ## still reports one of these SAME magics via `statfs` — the magic alone
    ## cannot tell a plain ext4 directory from a casefold-enabled one, so it
    ## is a necessary but not sufficient condition for `fpNone` and is now
    ## always refined by an inode-flag check before being trusted as final.

  proc c_open(path: cstring; flags: cint): cint
    {.importc: "open", header: "<fcntl.h>", varargs.}
  proc c_close(fd: cint): cint
    {.importc: "close", header: "<unistd.h>".}
  proc c_ioctlGetFlags(fd: cint; request: culong; flags: ptr int32): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>".}

  const
    linuxORdonly = 0.cint
      ## O_RDONLY, <fcntl.h> — 0 on every Linux arch (glibc).
    linuxODirectory = 0o200000.cint
      ## O_DIRECTORY, <fcntl.h> (glibc `bits/fcntl-linux.h`) — Linux-specific,
      ## not part of POSIX and so not in `std/posix`. Combined with
      ## `linuxORdonly` so the probe opens `rootAbs` read-only and fails
      ## outright if it is not actually a directory, rather than silently
      ## opening some other kind of node.
    fsIocGetFlags = 0x80086601'u
      ## FS_IOC_GETFLAGS, `<linux/fs.h>` — `_IOR('f', 1, long)` expanded for
      ## a 64-bit `long` argument. Hard-coded (no `<linux/fs.h>` #include,
      ## which would pull kernel headers into a userspace build) per this
      ## module's existing no-new-deps posture (see `caseSensitiveMagics`).
    fsCasefoldFlag* = 0x40000000'i32
      ## FS_CASEFOLD_FL, `<linux/fs.h>` — set on a directory with the
      ## ext4/F2FS casefold feature enabled (`chattr +F`); inherited by
      ## every file/dir later created under it. A per-DIRECTORY property,
      ## exactly the granularity RFC-0009 §3 probes at. Exported so F17's
      ## unit test can construct a synthetic flags word without duplicating
      ## the magic number, rather than hand-copying it a second time.

  proc queryCasefoldFlag(rootAbs: string): Option[int32] =
    ## `FS_IOC_GETFLAGS` on `rootAbs` ITSELF, opened `O_RDONLY|O_DIRECTORY`
    ## — never touches the directory's contents, only its own inode flags.
    ## `none` on ANY failure: the `open` failing (permission, race, not a
    ## directory) or the `ioctl` itself failing/being unsupported (`ENOTTY`
    ## on a filesystem/kernel that predates the casefold ioctl). A failure
    ## HERE is not a probe failure — `osQueryFoldPolicy` already has its
    ## statfs-magic answer in hand before calling this; it only means this
    ## REFINEMENT has nothing to add, so the magic answer stands unchanged.
    let fd = c_open(cstring(rootAbs), linuxORdonly or linuxODirectory)
    if fd < 0'i32: return none(int32)
    defer: discard c_close(fd)
    var flags: int32 = 0
    if c_ioctlGetFlags(fd, culong(fsIocGetFlags), addr flags) != 0'i32:
      return none(int32)
    some(flags)

  proc decodeLinuxCasefold*(flagsAnswer: Option[int32];
                             magicAnswer: Option[FoldPolicy]): Option[FoldPolicy] =
    ## Pure decision, independent of any real `ioctl` call — this is what
    ## F17's unit test asserts against DIRECTLY (a real `chattr +F`
    ## casefold-enabled directory cannot be fabricated on ordinary,
    ## unprivileged CI, so the `ioctl` PLUMBING above (`queryCasefoldFlag`)
    ## is exercised only via its failure path there — `ENOTTY`/unsupported
    ## on this container's plain ext4 mount — while this function's
    ## flag-SET branch is proven correct by construction instead, exported
    ## for exactly that purpose).
    ##
    ## `FS_CASEFOLD_FL` set ⇒ the directory folds names case-insensitively
    ## (ext4/F2FS's own Unicode SIMPLE case fold, not a full Unicode fold)
    ## ⇒ `fpAsciiLower` — crisol's uniform ASCII-only conservative
    ## approximation of "insensitive" on every platform alike (Windows
    ## NTFS, macOS APFS, and now Linux casefold), never the filesystem's
    ## own full-Unicode table (round 1, §Risks — a full-Unicode fold that
    ## disagrees with the kernel's own table would reintroduce the exact
    ## split this RFC exists to prevent). Flag absent, or the query itself
    ## failed/unsupported, ⇒ the STATFS-magic answer stands unrefined: this
    ## is a refinement of a definitive `fpNone`, never a new failure mode.
    if flagsAnswer.isSome and (flagsAnswer.get and fsCasefoldFlag) != 0'i32:
      some(fpAsciiLower)
    else:
      magicAnswer

  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    var buf: CStatfsLinux
    if c_statfs(cstring(rootAbs), buf) != 0'i32: return none(FoldPolicy)
    let magicAnswer =
      if int64(buf.f_type) in caseSensitiveMagics: some(fpNone)
      else: none(FoldPolicy)
    # RFC-0009 F8: a case-sensitive-BY-MAGIC filesystem type still might be
    # a per-directory casefold-enabled mount (`chattr +F`) — refine via the
    # inode flag before trusting the magic as final. An UNKNOWN magic was
    # already a genuine query failure before this fix and stays one: the
    # refinement only ever turns a magic-based `fpNone` into `fpAsciiLower`,
    # never manufactures an answer the magic itself didn't already give.
    if magicAnswer.isNone: return magicAnswer
    decodeLinuxCasefold(queryCasefoldFlag(rootAbs), magicAnswer)

else:
  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    none(FoldPolicy)

proc flipAsciiCase(s: string): string =
  result = newString(s.len)
  for i, c in s:
    if c >= 'a' and c <= 'z': result[i] = char(ord(c) - 32)
    elif c >= 'A' and c <= 'Z': result[i] = char(ord(c) + 32)
    else: result[i] = c

proc fileIdentity*(path: string): Option[tuple[device: DeviceId, file: FileId]] =
  ## Exported ONLY so tests/unit/test_fold_probe_tiers.nim (RFC-0009 F17)
  ## can assert this helper's identity-vs-none behavior directly (a
  ## dangling symlink, in particular) without routing through a whole
  ## probe tier. Not part of the module's comparison or probe-entry
  ## interface (`probeFoldPolicy` stays the sole production entry point).
  ##
  ## Best-effort OS file identity (device + file-id, via `os.getFileInfo`,
  ## which follows symlinks by default — works identically on POSIX
  ## `st_dev`/`st_ino` and Windows' volume-serial/file-index). `none` on ANY
  ## failure: a dangling symlink, a permission race, or the path vanishing
  ## between the caller's own existence check and this call. The caller
  ## MUST treat `none` as "this candidate proves nothing," never silently
  ## as "distinct" — RFC-0009 §3's "a probe that cannot answer honestly
  ## returns none" applies one level down, inside a single tier, not only
  ## at `probeFoldPolicy`'s own top level.
  try:
    some(getFileInfo(path).id)
  except OSError:
    none(tuple[device: DeviceId, file: FileId])

proc readOnlyFallback*(rootAbs: string): Option[FoldPolicy] =
  ## Exported ONLY for direct unit-testing of this tier in isolation
  ## (RFC-0009 F17) — `probeFoldPolicy` stays the sole probe entry point
  ## production code calls; tier 1 (the OS query) is always definitive on
  ## every CI leg today, so this tier is otherwise unreachable from a test
  ## driving `probeFoldPolicy` itself.
  ##
  ## READ-ONLY fallback: if `rootAbs` already contains at least one
  ## directory entry with an ASCII letter in its name, stat it under a
  ## case-flipped spelling of its own name. No write, no create/stat race
  ## window — answers definitively without ever requiring write access, the
  ## case a read-only milpa CAS dep root needs.
  ##
  ## RFC-0009 F6 fix: existence of the flipped spelling ALONE cannot
  ## distinguish "the same file, seen through its case-flipped spelling"
  ## from "two genuinely distinct files that happen to be case-flips of
  ## each other" (a root containing both `A` and `a` — entirely legal on a
  ## case-sensitive volume). Verified via OS file identity (`fileIdentity`
  ## — device+file-id, symlink-following):
  ##   flipped spelling ABSENT                  ⇒ case-sensitive, `fpNone`
  ##     (unchanged — absence alone is unambiguous on either kind of
  ##     volume, so this branch never needed an identity check).
  ##   flipped spelling present, SAME identity  ⇒ case-insensitive,
  ##     `fpAsciiLower` — the two spellings are literally one file.
  ##   flipped spelling present, DIFFERENT identity ⇒ case-SENSITIVE,
  ##     `fpNone`, and this PROVES it rather than merely defaulting to it:
  ##     a case-INSENSITIVE volume can never let two directory entries
  ##     differing only by ASCII case coexist as distinct files, so two
  ##     genuinely distinct files at case-flipped spellings is possible
  ##     ONLY on a case-sensitive volume.
  ## An identity check that cannot be resolved honestly — the candidate's
  ## own stat fails (a dangling symlink: existence and stat disagree), or
  ## the flipped path's stat fails after `fileExists`/`dirExists` already
  ## reported it present (a race) — proves nothing about either spelling;
  ## this tier tries the next letter-bearing entry rather than guessing,
  ## and returns `none` (falling through to tier 3) only once every
  ## candidate has been exhausted that way.
  var candidates: seq[string] = @[]
  try:
    for kind, entryPath in walkDir(rootAbs):
      let name = entryPath.extractFilename()
      if flipAsciiCase(name) != name:
        candidates.add name
  except OSError:
    return none(FoldPolicy)
  for chosen in candidates:
    let originalPath = rootAbs / chosen
    let originalId = fileIdentity(originalPath)
    if originalId.isNone:
      continue  # dangling symlink / race on the candidate itself
    let flipped = flipAsciiCase(chosen)
    let flippedPath = rootAbs / flipped
    if not (fileExists(flippedPath) or dirExists(flippedPath)):
      return some(fpNone)
    let flippedId = fileIdentity(flippedPath)
    if flippedId.isNone:
      continue  # existence check and stat disagree (race) -- try another
    return some(if originalId.get == flippedId.get: fpAsciiLower else: fpNone)
  none(FoldPolicy)

var probeSuffixCache: string
var probeSuffixCached = false
  ## RFC-0009 F29: per-process cache for `probeRandomSuffix` below — computed
  ## at most once per process, on first use, not at module-init time (so a
  ## process that never reaches tier 3 never pays the `/dev/urandom` read).

proc probeRandomSuffix(): string =
  ## 8 bytes from `ioutils.readRandomBytes` (a `/dev/urandom` read on posix,
  ## BCryptGenRandom-backed on windows via `std/sysrand`), hex-encoded to 16
  ## lowercase ASCII hex characters, cached for the lifetime of this
  ## process. `readRandomBytes` is best-effort and never raises; a short or
  ## empty result degrades this to a shorter (or empty) suffix rather than
  ## failing the probe outright — the PID component alone already appears
  ## in the name, and `exclusiveCreate`'s `O_EXCL`/`CREATE_NEW` refusal
  ## (not name-unpredictability) is the actual guarantee that a pre-placed
  ## symlink can never be followed; the random suffix only narrows the
  ## window in which a co-resident process could pre-place a symlink at
  ## this exact PID's probe name BEFORE this process ever calls tier 3 —
  ## PID alone is a small, densely-enumerable space on any OS, which is
  ## exactly what a shared/redirected `CRISOL_STATE_DIR` (RFC-0009 review
  ## F29) makes newly reachable via `cacheregistry.rootInsideStateDir`'s
  ## `probeFoldPolicy(stateDir, stateDir)` call.
  if not probeSuffixCached:
    let raw = readRandomBytes(8)
    var suffix = ""
    for b in raw:
      suffix.add toHex(BiggestInt(b), 2).toLowerAscii
    probeSuffixCache = suffix
    probeSuffixCached = true
  probeSuffixCache

proc probeBaseName*(): string =
  ## Exported ONLY for direct unit-testing of this tier in isolation
  ## (RFC-0009 F17/F29), same rationale as `readOnlyFallback*` above: a test
  ## pre-places a symlink at exactly this name (the same name
  ## `createAndStatFallback` will use in THIS process, since the random
  ## component is cached per-process) to prove the exclusive-create refuses
  ## it rather than following it.
  "." & "crisol_fold_probe_" & $getCurrentProcessId() & "_" &
    probeRandomSuffix() & ".tmp"

proc createAndStatFallback*(rootAbs, stateDir: string): Option[FoldPolicy] =
  ## Exported ONLY for direct unit-testing of this tier in isolation
  ## (RFC-0009 F17), same rationale as `readOnlyFallback*` above.
  ##
  ## LAST RESORT, only if the OS query is unsupported and the read-only
  ## fallback found no entry to test against (an empty root): a probe-file
  ## pair whose name carries a per-PROCESS-unique suffix — never a fixed
  ## name, which would race a concurrent run's create/stat window into a
  ## false case-sensitive read.
  ##
  ## RFC-0009 F7 fix: the probe file is now created in `rootAbs` ITSELF,
  ## unconditionally — never in `stateDir`. Case-sensitivity is a
  ## PER-DIRECTORY property of the volume (§3's own rationale for probing
  ## per-root at all: NTFS's case-sensitivity flag is set per directory,
  ## not per volume), so a pre-fix version of this tier that housed the
  ## probe file in `stateDir` "when it's on the same volume as `rootAbs`"
  ## was unsound even in that same-volume case — `stateDir` and `rootAbs`
  ## can sit on one volume yet carry DIFFERENT per-directory NTFS flags,
  ## and reporting `stateDir`'s answer as `rootAbs`'s policy silently
  ## answers for the wrong directory. `stateDir` stays a parameter — this
  ## proc's exported caller (`probeFoldPolicy`) is a signature other
  ## agents' in-flight call sites depend on — but tier 3 no longer reads it
  ## for directory selection at all.
  ##
  ## If `rootAbs` is not writable (a read-only root that also failed the
  ## read-only fallback above — e.g. genuinely empty and read-only), this
  ## tier now returns a genuine `none`: a probe failure that flows to the
  ## caller's existing degraded/conservative pole (`initTrackedRoots`'s
  ## D1/D2), never a guess and never another directory's answer standing
  ## in for this one. `createDir(rootAbs)` below is a no-op when `rootAbs`
  ## already exists (the overwhelmingly common case: a configured project
  ## or dep root); it exists so a not-yet-created `stateDir`, probed here
  ## as its OWN root by `cacheregistry.rootInsideStateDir`
  ## (`probeFoldPolicy(stateDir, stateDir)` — a legitimate per-directory
  ## use, not the wrong-directory bug this fix removes, since `rootAbs`
  ## and `stateDir` are the SAME path in that call), still gets a
  ## definitive answer on a project's very first run rather than a
  ## spurious `none`.
  ##
  ## RFC-0009 A-degraded (D1): `none` means the probe GENUINELY failed (the
  ## create itself failed) — distinct from a definitive `some(fpNone)`
  ## answer (the write succeeded and the case-flipped spelling was simply
  ## absent, a legitimate case-sensitive-volume verdict). Conflating the two
  ## under a bare `fpNone` return (the pre-D1 shape) hid a genuine probe
  ## failure behind the same value a real case-sensitive volume produces —
  ## the bug this Option-typed return exists to fix.
  ##
  ## RFC-0009 F29 fix (round 3): two independent hardenings, since either
  ## alone left a gap.
  ##   1. UNPREDICTABLE NAME — `probeBaseName` (see its own doc comment)
  ##      appends a per-process random suffix after the PID, so a
  ##      co-resident process sharing this root (the CRISOL_STATE_DIR
  ##      redirect `cacheregistry.rootInsideStateDir`'s
  ##      `probeFoldPolicy(stateDir, stateDir)` call makes newly reachable)
  ##      cannot pre-place a symlink at a name this process will actually
  ##      use by simply enumerating the guessable PID space.
  ##   2. EXCLUSIVE, SYMLINK-REFUSING CREATE — the probe file is opened via
  ##      `ioutils.exclusiveCreate(_, noFollow = true)`
  ##      (`O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW` on posix, Win32 `CREATE_NEW`
  ##      + a reparse-point pre/post-check on windows) instead of plain
  ##      `writeFile`, which happily follows a pre-existing symlink and
  ##      truncates whatever it targets. `O_EXCL` alone already makes this
  ##      safe against a symlink specifically — POSIX `open(2)`: "If O_EXCL
  ##      and O_CREAT are set, and path names a symbolic link, open() shall
  ##      fail and set errno to [EEXIST]" — so hardening (1) is defense in
  ##      depth (a smaller race window before the first probe call, not the
  ##      thing that actually refuses the follow) on top of hardening (2)
  ##      (the actual refusal), not a substitute for it: name
  ##      unpredictability alone, without O_EXCL, would still let a symlink
  ##      planted AFTER this process picks its name (a narrower but
  ##      nonzero window between `probeBaseName()` and the open) get
  ##      followed by a plain `writeFile`.
  ##   `exclusiveCreate` returning `fd < 0` for ANY reason — including
  ##   `alreadyExists` (the randomized exact name was squatted, or a
  ##   symlink sits there) — is treated as a genuine probe failure and
  ##   falls straight through to `none` below: never retried, never
  ##   followed, never treated as "fall back to reading through it."
  let baseName = probeBaseName()
  let lowerPath = rootAbs / baseName
  let upperPath = rootAbs / flipAsciiCase(baseName)
  result = none(FoldPolicy)
  try:
    createDir(rootAbs)
    let (fd, _, _) = exclusiveCreate(lowerPath, noFollow = true)
    if fd >= 0:
      discard writeAllFd(fd, "")
      closeFd(fd)
      result = some(if fileExists(upperPath): fpAsciiLower else: fpNone)
    # fd < 0 (EEXIST/ELOOP/other OS failure, including a pre-existing
    # symlink at `lowerPath`) -- result stays none(FoldPolicy) above: the
    # D1 degraded-conservative pole, never a retry and never a follow.
  except OSError:
    result = none(FoldPolicy)
  finally:
    try: removeFile(lowerPath)
    except OSError: discard
    try:
      if fileExists(upperPath): removeFile(upperPath)
    except OSError: discard

proc probeFoldPolicy*(rootAbs: string; stateDir: string): Option[FoldPolicy] =
  ## 1. OS QUERY FIRST (authoritative; rarely fails; NEVER touches disk).
  ## 2. READ-ONLY FALLBACK on query failure.
  ## 3. CREATE-AND-STAT, only if (1) is unsupported and (2) found no entry
  ##    to test against.
  ## Injectable past this proc entirely: `initTrackedRoots`'s `probe`
  ## parameter lets a test fix a FoldPolicy directly, so fold semantics are
  ## unit-testable on Linux CI without a Windows round-trip.
  ##
  ## RFC-0009 A-degraded (D1): `none` means every stage genuinely failed —
  ## the run is DEGRADED (see `initTrackedRoots`). `some(fpNone)` /
  ## `some(fpAsciiLower)` are both definitive, non-degraded answers.
  let osAnswer = osQueryFoldPolicy(rootAbs)
  if osAnswer.isSome: return osAnswer
  let roAnswer = readOnlyFallback(rootAbs)
  if roAnswer.isSome: return roAnswer
  createAndStatFallback(rootAbs, stateDir)

# ---------------------------------------------------------------------------
# initTrackedRoots — eager root construction, per-process memoized probe.
# ---------------------------------------------------------------------------

type FoldProbe* = proc (rootAbs, stateDir: string): Option[FoldPolicy]
  ## The §3 injectable fold-policy probe. Defaults everywhere to
  ## `probeFoldPolicy` (the real per-volume probe); an explicitly-injected
  ## non-default probe is the Linux-testability seam that lets a test force a
  ## policy a real case-sensitive volume would never answer. Threaded from
  ## `config.loadConfig` (and `RunOptions.foldProbe`, via `api.planTests`)
  ## down to `initTrackedRoots` so a forced policy governs an ENTIRE run —
  ## both the graph a real `runTests` PERSISTS and any later `loadDepGraph`
  ## validation of that graph's header (RFC-0009 A3c-i) — not just a single
  ## hand-built `initTrackedRoots` call.
  ##
  ## RFC-0009 A-degraded (D1): `none` is a GENUINE probe failure — the run is
  ## degraded (`TrackedRoots.degraded`); `some(policy)` is a definitive
  ## answer, whichever policy it names.

var probeMemo: Table[string, Option[FoldPolicy]]
  ## Per-process memo keyed by canonical root abs path — Config is built
  ## hundreds of times across the test suite, so the probe is a per-process,
  ## per-root cost paid once, never once per Config construction. Memoizes
  ## BOTH a definitive `some` answer and a genuine `none` failure (D1) — a
  ## degraded root stays degraded for the rest of this process, never
  ## silently re-probed into a lucky-second-try `some`.

proc memoizedProbe*(rootAbs, stateDir: string;
                     probe: proc (rootAbs, stateDir: string): Option[FoldPolicy]):
                     Option[FoldPolicy] =
  ## The memo is a production hot-path optimization for the DEFAULT probe
  ## ONLY. An explicitly-injected non-default probe (the §3 Linux-testability
  ## seam) BYPASSES the memo entirely — both read and write — so an injected
  ## probe always reflects exactly what the caller asked for, never a value
  ## another call cached for this root under a different probe. Without this,
  ## a facade call using the real probe (e.g. a prior `runTests`) would poison
  ## the entry and silently defeat a later forced-policy injection against the
  ## same root — the memo ignoring probe identity is otherwise a footgun the
  ## advertised injectable seam cannot survive.
  ##
  ## Exported (RFC-0009 F31) so `cacheregistry.rootInsideStateDir` — which
  ## probes `stateDir`'s own volume policy fresh on every `configuredCache`
  ## call otherwise — shares this SAME per-process memo/bypass discipline
  ## instead of re-probing per configured remote; the bypass-on-non-default
  ## rule above already keeps that call site's injected-probe test seam
  ## honored (never memoized, never poisoned by a prior real-probe call).
  if probe != probeFoldPolicy:
    return probe(rootAbs, stateDir)
  if probeMemo.hasKey(rootAbs):
    return probeMemo[rootAbs]
  result = probe(rootAbs, stateDir)
  probeMemo[rootAbs] = result

proc safeExpandFilename*(p: string): string =
  ## Cross-platform "true realpath" — resolves symlinks/junctions to their
  ## target. POSIX: `expandFilename` (== realpath(3)). Windows: `winRealPath`
  ## (GetFinalPathNameByHandleW), because `expandFilename` there is
  ## GetFullPathNameW, which is LEXICAL and never follows a reparse point
  ## (RFC-0009 B4a). The Windows result is forward-slash-normalized and
  ## long-path-prefix-stripped so it matches `nativeCanonicalize`'s output
  ## form — `classify` compares `realAbs` against a `nativeCanonicalize`'d
  ## candidate via a raw (non-normalizing) prefix match, so a `\`-separated
  ## or `\\?\`-prefixed answer would silently never match. Exported so
  ## closure.nim shares this ONE realpath primitive rather than calling the
  ## lexical-on-Windows `expandFilename` directly. Never raises.
  when defined(windows):
    stripLongPathPrefix(winRealPath(p).replace('\\', '/'))
  else:
    try: expandFilename(p)
    except OSError: p
    except ValueError: p

proc initTrackedRoots*(projectNative: string;
                        deps: seq[tuple[name, native: string]];
                        stateDir: string;
                        probe: proc (rootAbs, stateDir: string): Option[FoldPolicy] =
                          probeFoldPolicy): TrackedRoots =
  ## Builds project + each dep NativeRoot, probing EAGERLY here — not lazily
  ## on first comparison — backed by a per-process memo keyed by canonical
  ## root abs path. `projectNative` is assumed already-absolute (the one
  ## legitimate cwd read for `projectRoot` resolution is config.nim's job,
  ## captured once before this is ever called); `nativeCanonicalize` still
  ## lexically normalizes it. Each dep's relative-path base is `projectAbs`.
  ##
  ## RFC-0009 A-degraded (D2): a `none` probe answer for ANY root (project or
  ## dep) sets that root's `foldPolicy = fpNone` (folding still uses the safe
  ## no-fold pole for the rest of THIS degraded run — it never aliases
  ## distinct files) and marks the WHOLE `TrackedRoots.degraded = true`, with
  ## `degradedReason` naming every such root (semicolon-joined if more than
  ## one).
  let projectAbs = nativeCanonicalize(projectNative, projectNative).abs
  let projectReal = safeExpandFilename(projectAbs)
  let projectAnswer = memoizedProbe(projectAbs, stateDir, probe)
  var degraded = false
  var reasons: seq[string] = @[]
  let projectPolicy =
    if projectAnswer.isSome:
      projectAnswer.get
    else:
      degraded = true
      reasons.add "fold-policy probe failed for root 'project' (" & projectAbs & ")"
      fpNone
  let projectRoot = NativeRoot(abs: projectAbs, realAbs: projectReal,
                                foldPolicy: projectPolicy, name: "")

  var depRoots: seq[NativeRoot] = @[]
  for (depName, depNative) in deps:
    let depAbs = nativeCanonicalize(depNative, projectAbs).abs
    let depReal = safeExpandFilename(depAbs)
    let depAnswer = memoizedProbe(depAbs, stateDir, probe)
    let depPolicy =
      if depAnswer.isSome:
        depAnswer.get
      else:
        degraded = true
        reasons.add "fold-policy probe failed for root '" & depName & "' (" & depAbs & ")"
        fpNone
    depRoots.add NativeRoot(abs: depAbs, realAbs: depReal,
                             foldPolicy: depPolicy, name: depName)

  TrackedRoots(fproject: projectRoot, fdeps: depRoots,
               degraded: degraded, degradedReason: reasons.join("; "))
