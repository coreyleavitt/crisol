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

import std/[hashes, json, options, os, strutils, tables]

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

  CacheKeyPath* = distinct string
    ## keyBytes' return type: canonical, UNFOLDED cache-key bytes. A distinct
    ## type, not `string`, so a cache-key consumer cannot accept a bare `rel`
    ## by accident. `string(k)` is the sole, explicit escape hatch.

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

# ---------------------------------------------------------------------------
# fold — private helper. Identity under fpNone, ASCII-lowercase under
# fpAsciiLower. NOT part of the public interface.
# ---------------------------------------------------------------------------

proc fold(s: string; policy: FoldPolicy): string =
  case policy
  of fpNone: s
  of fpAsciiLower: s.toLowerAscii()

# ---------------------------------------------------------------------------
# TrackedPath — comparison interface (context-free: no TrackedRoots needed).
# ---------------------------------------------------------------------------

proc display*(tp: TrackedPath): string = tp.rel
proc `$`*(tp: TrackedPath): string = tp.rel          ## logs/errors: real case
proc isProject*(tp: TrackedPath): bool = tp.rootTag == RootTag(0)

proc `==`*(a, b: TrackedPath): bool =
  ## FOLDED, computed on the fly from the stored POLICY — selection
  ## soundness. Invariant: same `rootTag` => same `fold` policy within one
  ## process (two TrackedPaths sharing a root were built from the same
  ## TrackedRoots, which probes each root's policy exactly once). A mismatch
  ## here is a cross-policy comparison bug (e.g. a test fixture built under a
  ## different policy than the roots it's compared against), never a
  ## legitimate case — asserted, not silently masked.
  if a.rootTag == b.rootTag:
    assert a.fold == b.fold,
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
  ## True iff `rel`'s first path segment matches `dep:[^/:]+` — the ESCAPE
  ## `keyBytes` guards against: a tag-0 directory literally named `dep:foo`
  ## is legal on ext4, and `classify` is total, so `dep:foo/x.nim` lands
  ## `pcTracked` tag 0 regardless of any config-time name validation.
  let seg = firstSegment(rel)
  if not seg.startsWith("dep:"): return false
  let rest = seg[4 .. ^1]
  rest.len > 0 and ':' notin rest

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
  ## (`C:/...` or bare `C:`), a UNC form (`//server/share...`), or a plain
  ## POSIX-rooted form (`/...`). Caller has already established `p` is
  ## absolute.
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
  ## prefix-stripped string: POSIX root, UNC, or a drive form (`C:` or
  ## `C:/...`) all count; a drive-RELATIVE spelling (`c:foo`) does not.
  if p.len == 0: return false
  if p[0] == '/': return true
  if p.len >= 2 and isAsciiAlpha(p[0]) and p[1] == ':':
    return p.len == 2 or p[2] == '/'
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

proc classify*(native: string; roots: TrackedRoots): PathClass =
  ## TOTAL: every native spelling classifies. Nothing is refused here.
  let na = nativeCanonicalize(native, roots.project.abs)

  let projRel = underRoot(na.abs, roots.project.abs)
  let projRelReal = underRoot(na.abs, roots.project.realAbs)
  if projRel.isSome or projRelReal.isSome:
    # PROJECT FIRST: a path under the project root is ALWAYS tag 0 — even
    # one that also nests under a configured dep root's own directory.
    let rel = if projRel.isSome: projRel.get else: projRelReal.get
    return PathClass(kind: pcTracked,
      tp: TrackedPath(rootTag: RootTag(0), fold: roots.project.foldPolicy,
                       rel: rel))

  var bestIdx = -1
  var bestLen = -1
  var bestRel = ""
  for i, d in roots.fdeps:
    let r1 = underRoot(na.abs, d.abs)
    if r1.isSome and d.abs.len > bestLen:
      bestLen = d.abs.len; bestIdx = i; bestRel = r1.get
    let r2 = underRoot(na.abs, d.realAbs)
    if r2.isSome and d.realAbs.len > bestLen:
      bestLen = d.realAbs.len; bestIdx = i; bestRel = r2.get

  if bestIdx >= 0:
    return PathClass(kind: pcTracked,
      tp: TrackedPath(rootTag: RootTag(uint16(bestIdx + 1)),
                       fold: roots.fdeps[bestIdx].foldPolicy, rel: bestRel))

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
  ## invariant (rejecting a leading `\`, any `.`/`..` segment, an absolute
  ## form — drive letter, UNC, or leading `/` — and a doubled separator: all
  ## signs the caller handed it un-reduced native text) and applies the
  ## tagged root's fold policy. Critically never touches cwd. Returns
  ## `none` on a shape violation — NEVER raises: parsing untrusted/persisted
  ## text never crashes, the caller chooses degrade vs abort.
  if rel.len == 0: return none(TrackedPath)
  if rel[0] == '\\': return none(TrackedPath)
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
    fileCaseSensitiveInfoClass = 21'i32   # FILE_INFO_BY_HANDLE_CLASS
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
    ## ext2/3/4, xfs, btrfs, tmpfs — case-sensitive on Linux regardless of
    ## mount options (the per-directory ext4/F2FS casefold feature is a
    ## deliberately-enabled opt-in this query does not distinguish — round-1
    ## accepted scope, matching this RFC's other narrow-but-documented
    ## fold-probe simplifications). Answers `fpNone` for a plain ext4 mount
    ## — crisol's daily toolchain — WITHOUT ever touching disk.

  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    var buf: CStatfsLinux
    if c_statfs(cstring(rootAbs), buf) != 0'i32: return none(FoldPolicy)
    if int64(buf.f_type) in caseSensitiveMagics: some(fpNone)
    else: none(FoldPolicy)

else:
  proc osQueryFoldPolicy(rootAbs: string): Option[FoldPolicy] =
    none(FoldPolicy)

proc flipAsciiCase(s: string): string =
  result = newString(s.len)
  for i, c in s:
    if c >= 'a' and c <= 'z': result[i] = char(ord(c) - 32)
    elif c >= 'A' and c <= 'Z': result[i] = char(ord(c) + 32)
    else: result[i] = c

proc readOnlyFallback(rootAbs: string): Option[FoldPolicy] =
  ## READ-ONLY fallback: if `rootAbs` already contains at least one
  ## directory entry with an ASCII letter in its name, stat it under a
  ## case-flipped spelling of its own name. No write, no create/stat race
  ## window, answers definitively without ever requiring write access — the
  ## case a read-only milpa CAS dep root needs.
  var chosen = ""
  try:
    for kind, entryPath in walkDir(rootAbs):
      let name = entryPath.extractFilename()
      if flipAsciiCase(name) != name:
        chosen = name
        break
  except OSError:
    return none(FoldPolicy)
  if chosen.len == 0: return none(FoldPolicy)
  let flipped = flipAsciiCase(chosen)
  let flippedPath = rootAbs / flipped
  result = some(if fileExists(flippedPath) or dirExists(flippedPath): fpAsciiLower
                else: fpNone)

when defined(posix) and not defined(macosx):
  import std/posix   # macosx branch above already imported std/posix for pathconf

proc deviceIdOf(path: string): Option[uint64] =
  ## Best-effort device identifier, used only to decide whether the
  ## create-and-stat fallback may reuse `stateDir` (same volume as
  ## `rootAbs`) or must fall back to `rootAbs` itself. `none` on any
  ## failure (including "not posix") degrades to the safe choice at the
  ## call site (rootAbs).
  when defined(posix):
    var s: Stat
    if stat(cstring(path), s) == 0'i32: some(uint64(s.st_dev)) else: none(uint64)
  else:
    none(uint64)

proc sameVolume(a, b: string): bool =
  let da = deviceIdOf(a)
  let db = deviceIdOf(b)
  da.isSome and db.isSome and da.get == db.get

proc createAndStatFallback(rootAbs, stateDir: string): FoldPolicy =
  ## LAST RESORT, only if the OS query is unsupported and the read-only
  ## fallback found no entry to test against (an empty root): a probe-file
  ## pair whose name carries a per-PROCESS-unique suffix — never a fixed
  ## name, which would race a concurrent run's create/stat window into a
  ## false case-sensitive read. Housed in `stateDir` IFF stateDir is on the
  ## same volume as `rootAbs`; otherwise an ignored dot-name file directly
  ## in `rootAbs`, removed after.
  let unique = "crisol_fold_probe_" & $getCurrentProcessId()
  let useStateDir = stateDir.len > 0 and sameVolume(rootAbs, stateDir)
  let dir = if useStateDir: stateDir else: rootAbs
  let baseName = if useStateDir: unique & ".tmp" else: "." & unique & ".tmp"
  let lowerPath = dir / baseName
  let upperPath = dir / flipAsciiCase(baseName)
  result = fpNone
  try:
    createDir(dir)
    writeFile(lowerPath, "")
    result = if fileExists(upperPath): fpAsciiLower else: fpNone
  except OSError:
    result = fpNone
  finally:
    try: removeFile(lowerPath)
    except OSError: discard
    try:
      if fileExists(upperPath): removeFile(upperPath)
    except OSError: discard

proc probeFoldPolicy*(rootAbs: string; stateDir: string): FoldPolicy =
  ## 1. OS QUERY FIRST (authoritative; rarely fails; NEVER touches disk).
  ## 2. READ-ONLY FALLBACK on query failure.
  ## 3. CREATE-AND-STAT, only if (1) is unsupported and (2) found no entry
  ##    to test against.
  ## Injectable past this proc entirely: `initTrackedRoots`'s `probe`
  ## parameter lets a test fix a FoldPolicy directly, so fold semantics are
  ## unit-testable on Linux CI without a Windows round-trip.
  let osAnswer = osQueryFoldPolicy(rootAbs)
  if osAnswer.isSome: return osAnswer.get
  let roAnswer = readOnlyFallback(rootAbs)
  if roAnswer.isSome: return roAnswer.get
  createAndStatFallback(rootAbs, stateDir)

# ---------------------------------------------------------------------------
# initTrackedRoots — eager root construction, per-process memoized probe.
# ---------------------------------------------------------------------------

var probeMemo: Table[string, FoldPolicy]
  ## Per-process memo keyed by canonical root abs path — Config is built
  ## hundreds of times across the test suite, so the probe is a per-process,
  ## per-root cost paid once, never once per Config construction.

proc memoizedProbe(rootAbs, stateDir: string;
                    probe: proc (rootAbs, stateDir: string): FoldPolicy): FoldPolicy =
  if probeMemo.hasKey(rootAbs):
    return probeMemo[rootAbs]
  result = probe(rootAbs, stateDir)
  probeMemo[rootAbs] = result

proc safeExpandFilename(p: string): string =
  try: expandFilename(p)
  except OSError: p
  except ValueError: p

proc initTrackedRoots*(projectNative: string;
                        deps: seq[tuple[name, native: string]];
                        stateDir: string;
                        probe: proc (rootAbs, stateDir: string): FoldPolicy =
                          probeFoldPolicy): TrackedRoots =
  ## Builds project + each dep NativeRoot, probing EAGERLY here — not lazily
  ## on first comparison — backed by a per-process memo keyed by canonical
  ## root abs path. `projectNative` is assumed already-absolute (the one
  ## legitimate cwd read for `projectRoot` resolution is config.nim's job,
  ## captured once before this is ever called); `nativeCanonicalize` still
  ## lexically normalizes it. Each dep's relative-path base is `projectAbs`.
  let projectAbs = nativeCanonicalize(projectNative, projectNative).abs
  let projectReal = safeExpandFilename(projectAbs)
  let projectPolicy = memoizedProbe(projectAbs, stateDir, probe)
  let projectRoot = NativeRoot(abs: projectAbs, realAbs: projectReal,
                                foldPolicy: projectPolicy, name: "")

  var depRoots: seq[NativeRoot] = @[]
  for (depName, depNative) in deps:
    let depAbs = nativeCanonicalize(depNative, projectAbs).abs
    let depReal = safeExpandFilename(depAbs)
    let depPolicy = memoizedProbe(depAbs, stateDir, probe)
    depRoots.add NativeRoot(abs: depAbs, realAbs: depReal,
                             foldPolicy: depPolicy, name: depName)

  TrackedRoots(fproject: projectRoot, fdeps: depRoots)
