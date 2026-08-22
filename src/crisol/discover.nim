## discover.nim — file-tree walker, glob matcher, gate seam for crisol A1
##
## Public API (pure planning):
##   matchGlob*(glob, relPath: string): bool         — pure; directly unit-testable
##   toDiscoveredSet*(eps: seq[Entrypoint]): DiscoveredSet  — test constructor
##   discover*(config, selection): DiscoveredSet     — file-tree walk; derives root
##                                                      from config.projectRoot
##
## Gate seam (separated from discover):
##   loadGateState*(config: Config): GateState       — effectful; reads env vars once
##   initGateState*(vars): GateState                 — test constructor; no env access
##   applyGates*(eps, config, state): tuple[...]     — pure filter; returns runnable
##                                                      entries + gated-out groups
##
## Walk discipline:
##   • Never follows directory symlinks (pcLinkToDir entries are skipped).
##   • Skips directories whose name starts with '.' (.git, .crisol, …).
##   • Uses a hand-rolled recursive walker (os.walkDir per level) so both
##     prune conditions are enforced cleanly without relying on walkDirRec flags.

import std/[algorithm, os, options, sequtils, sets, strutils, tables]
import crisol/types

# ---------------------------------------------------------------------------
# matchGlob — pure single-segment and multi-segment wildcard matcher
# ---------------------------------------------------------------------------

proc matchSegment(pat, s: string): bool =
  ## Match a single path segment with `*` and `?` wildcards (no `**` here;
  ## that is handled one level up in matchGlob).  No '/' ever appears in either
  ## argument at this point.
  var pi, si: int
  while pi < pat.len and si < s.len:
    let pc = pat[pi]
    if pc == '*':
      # Consume all consecutive '*' (a run of stars == one star in a segment).
      while pi < pat.len and pat[pi] == '*': inc pi
      if pi == pat.len: return true            # trailing * matches anything left
      # Try matching the rest of the pattern at every position in s from here.
      while si <= s.len:
        if matchSegment(pat[pi..^1], s[si..^1]): return true
        inc si
      return false
    elif pc == '?':
      inc pi
      inc si
    else:
      if pc != s[si]: return false
      inc pi
      inc si
  # Drain any trailing '*' from the pattern.
  while pi < pat.len and pat[pi] == '*': inc pi
  result = pi == pat.len and si == s.len

proc matchGlob*(glob: string; relPath: string): bool =
  ## Match a project-root-relative path against a glob pattern.
  ##
  ## Segment separator: '/'.  Special tokens:
  ##   `*`   within a segment — any run of chars, never crosses '/'.
  ##   `?`   within a segment — exactly one char.
  ##   `**`  as a whole segment — matches zero or more whole path segments.
  ##
  ## Examples:
  ##   tests/unit/test_*.nim  ↔  tests/unit/test_parser.nim     → true
  ##   tests/**/test_*.nim    ↔  tests/test_a.nim               → true  (** = 0)
  ##   tests/**/test_*.nim    ↔  tests/unit/deep/test_b.nim     → true  (** = 2)
  ##   tests/*/x.nim          ↔  tests/a/b/x.nim                → false
  let gParts = glob.split('/')
  let pParts = relPath.split('/')

  proc match(gi, pi: int): bool =
    if gi == gParts.len and pi == pParts.len: return true
    if gi == gParts.len: return false

    if gParts[gi] == "**":
      # Try consuming zero or more path segments.
      var consumed = pi
      while consumed <= pParts.len:
        if match(gi + 1, consumed): return true
        inc consumed
      return false
    else:
      if pi == pParts.len: return false
      if not matchSegment(gParts[gi], pParts[pi]): return false
      return match(gi + 1, pi + 1)

  result = match(0, 0)

# ---------------------------------------------------------------------------
# Gate seam — loadGateState (effectful) and initGateState (test constructor)
# ---------------------------------------------------------------------------

proc loadGateState*(config: Config): GateState =
  ## Effectful: reads each group's gate env var exactly once and snapshots the
  ## result.  This is the ONLY place that touches the real environment.
  ## Tests use initGateState instead.
  var vars: seq[tuple[name: string; value: string]]
  var seen: HashSet[string]
  for g in config.groups:
    if g.gate.isSome:
      let envName = g.gate.get.env
      if envName notin seen:
        seen.incl envName
        vars.add (name: envName, value: getEnv(envName).strip())
  GateState(vars: vars)

proc initGateState*(pairs: openArray[(string, string)]): GateState =
  ## Test constructor: builds a GateState snapshot from explicit name/value
  ## pairs.  Internal representation stays opaque.  Use this in tests; never
  ## loadGateState.
  var vars: seq[tuple[name: string; value: string]]
  for (n, v) in pairs:
    vars.add (name: n, value: v.strip())
  GateState(vars: vars)

proc gateOpen(state: GateState; envName: string): bool =
  ## Returns true iff envName is present in state with a non-empty value.
  ## A missing key is treated as "gate closed" (conservative).
  for entry in state.vars:
    if entry.name == envName:
      return entry.value.len > 0
  false

# ---------------------------------------------------------------------------
# applyGates — pure filter; returns runnable entries + gated-out groups
# ---------------------------------------------------------------------------

proc applyGates*(
  eps:    DiscoveredSet;
  config: Config;
  state:  GateState;
): tuple[run: seq[Entrypoint]; gatedOut: seq[GatedEntry]] =
  ## PURE: filters `eps` by gate state.  Returns:
  ##   run      — entrypoints whose group's gate (if any) is open.
  ##   gatedOut — one GatedEntry (path, group, reason) per gated-out ENTRYPOINT,
  ##              e.g. reason = "env AMOXTLI_OPENROUTER_API_KEY not set".  Carrying
  ##              the path lets callers (pipeline) build the rendering list
  ##              directly without re-walking the discovered set (no unsafeToSeq).
  ## Tests pass a hand-built GateState — never touching the environment.

  # Build a map of gated-out group name → reason.
  var gatedReason: Table[string, string]

  for g in config.groups:
    if g.gate.isSome:
      let envName = g.gate.get.env
      if not gateOpen(state, envName):
        gatedReason[g.name] = "env " & envName & " not set"

  var run: seq[Entrypoint]
  var gatedOut: seq[GatedEntry]
  for ep in eps.entries:
    if ep.group in gatedReason:
      gatedOut.add (path: ep.path, group: ep.group, reason: gatedReason[ep.group])
    else:
      run.add ep

  (run: run, gatedOut: gatedOut)

# ---------------------------------------------------------------------------
# Private file-tree walker
# ---------------------------------------------------------------------------

proc walkNimFiles(root: string; result: var seq[string]) =
  ## Recursively collect .nim files under `root`.
  ## • Skips entries of kind pcLinkToDir (directory symlinks) — do not descend.
  ## • Skips directories whose names start with '.' (hidden dirs).
  for entry in walkDir(root):
    case entry.kind
    of pcLinkToDir:
      discard                          # never descend into symlinked dirs
    of pcDir:
      let name = entry.path.lastPathPart
      if not name.startsWith("."):
        walkNimFiles(entry.path, result)
    of pcFile, pcLinkToFile:
      if entry.path.endsWith(".nim"):
        result.add entry.path

# ---------------------------------------------------------------------------
# toDiscoveredSet — test constructor bypassing the file-tree walk
# ---------------------------------------------------------------------------

proc toDiscoveredSet*(eps: seq[Entrypoint]): DiscoveredSet =
  ## Exported test constructor — lets unit tests build a DiscoveredSet without
  ## going through discover().  This is the only bypass constructor.
  ## adHocPaths is empty — this constructor bypasses gskFiles resolution
  ## entirely.
  DiscoveredSet(entries: eps)

proc unsafeToSeq*(ds: DiscoveredSet): seq[Entrypoint] =
  ## Narrow, documented escape hatch: unwraps DiscoveredSet WITHOUT calling
  ## applyGates.  Valid uses ONLY:
  ##   1. clean.nim's orphan scan (gates must be ignored — a closed gate must
  ##      never cause cache deletion).
  ##   2. Internal pipeline construction where gated entries are needed for
  ##      rendering (e.g. building the gatedEntries list in pipeline.nim).
  ##   3. Tests that need the raw sequence after construction.
  ## DO NOT use this to skip gate enforcement in production run paths.
  ds.entries

# ---------------------------------------------------------------------------
# resolveFilesGroups — gskFiles path→group attribution (issue #3, RFC-0001:409)
# ---------------------------------------------------------------------------

proc normalizeRootRelative(p, root: string): string =
  ## Make an absolute path root-relative; leave a relative path as-is.
  ## Falls back to the original string if relativePath ever raises.
  if isAbsolute(p):
    try: relativePath(p, root)
    except: p
  else: p

proc resolveFilesGroups(
  config:    Config;
  selection: GroupSelection;
  root:      string;
  allRel:    seq[string];
): tuple[active: seq[Group]; adHocPaths: seq[string]] =
  ## PURE: resolve each gskFiles selector (a path or a glob) to the concrete
  ## files it denotes (`allRel` = every root-relative .nim under root), then
  ## each file to one synthesised single-path Group PER owning candidate group
  ## (carrying that group's name+flags), or the ad-hoc "paths" group + global
  ## flags when no candidate owns it.  See discover()'s gskFiles doc comment
  ## for the full attribution rule.
  var candidates: seq[Group]
  if selection.withinGroups.len > 0:
    # Validate every --group name exists (mirror gskNamed): an unknown group
    # name combined with a positional path must error, not silently degrade to
    # an ad-hoc entrypoint with global flags.
    let configNames = block:
      var s: HashSet[string]
      for g in config.groups: s.incl g.name
      s
    for wanted in selection.withinGroups:
      if wanted notin configNames:
        raise newCrisolError(cekConfig, "unknown group: " & wanted)
    for g in config.groups:
      if g.name in selection.withinGroups:
        candidates.add g
  else:
    candidates = config.groups

  for p in selection.paths:
    let np = normalizeRootRelative(p, root)

    # Expand the selector to the concrete files it denotes, so attribution is
    # always file -> owner (a glob selector must not be matched as a literal
    # string against group globs — that is how `crisol run 'tests/unit/*.nim'`
    # used to lose its group flags).  A selector denoting nothing on disk is
    # attributed as itself, so the downstream no-match diagnosis is unchanged.
    var files: seq[string]
    for rel in allRel:
      if rel == np or matchGlob(np, rel):
        files.add rel
    if files.len == 0:
      files = @[np]

    # Issue #10: a group denotes (globs x flags), so a file owned by several
    # candidate groups is several LEGS — one entrypoint per owner, each under
    # its own flags — exactly what default discovery yields for that file.
    # Naming the file selects the file; it never collapses the matrix.  The
    # caller narrows with `--group` (selection.withinGroups) when one leg is
    # wanted.  Legs are emitted in config-declaration order; dedup by (path,
    # group) identity happens in discover() as for any discovered entrypoint.
    for f in files:
      var matched = false
      for owner in candidates:
        if owner.globs.anyIt(matchGlob(it, f)):
          matched = true
          result.active.add Group(name: owner.name, globs: @[f], flags: owner.flags,
                                   optIn: false, timeoutSecs: owner.timeoutSecs)
      if not matched:
        result.active.add Group(name: "paths", globs: @[f], flags: config.flags, optIn: false)
        result.adHocPaths.add f

# ---------------------------------------------------------------------------
# discover — main entry point
# ---------------------------------------------------------------------------

proc discover*(
  config:    Config;
  selection: GroupSelection = GroupSelection(kind: gskDefault);
): DiscoveredSet =
  ## Walk the file tree under config.projectRoot, returning one Entrypoint per
  ## (file, group) pair where the file's root-relative path matches at least one
  ## of the group's globs and the group is active under `selection`.
  ##
  ## Active group rules (gates are NOT consulted here — call applyGates after):
  ##   gskDefault → exclude groups where optIn == true.
  ##   gskNamed   → include only groups in selection.names; unknown name → cekConfig.
  ##   gskAll     → all groups (opt-in flag ignored).
  ##   gskFiles   → for each given path/glob, find its owning group (a candidate
  ##                group — every configured group, or only those named in
  ##                `selection.withinGroups` when non-empty — whose globs match
  ##                it) so it inherits that group's name and flags. A path
  ##                matching no candidate is ad-hoc: synthesised "paths" group,
  ##                global flags only (RFC-0001:409; recorded in adHocPaths). A
  ##                path matching several candidates is several legs — one
  ##                entry per owning group, each under that group's flags
  ##                (issue #10: groups denote globs x flags; --group narrows).
  ##                Config is NOT mutated (RFC: "naming a file is the strongest opt-in").
  ##
  ## Dedup: by identity (path, group) — within a group a file matched by
  ## multiple globs (or reached through several gskFiles selectors) yields ONE
  ## entry.  Cross-group: the same file in two groups yields one entry PER group.
  ## Sort: returned sequence is sorted by (path, group).

  let root = config.projectRoot

  # 1. Collect .nim files under root (one pass; shared by selector expansion
  #    and group matching).  Root-relative, '/' separated.
  var allRel: seq[string]
  block:
    var allNims: seq[string]
    walkNimFiles(root, allNims)
    for absPath in allNims:
      var relPath = absPath[root.len .. ^1]
      # Strip exactly one leading separator.
      if relPath.len > 0 and (relPath[0] == '/' or relPath[0] == '\\'):
        relPath = relPath[1 .. ^1]
      when defined(windows):
        relPath = relPath.replace('\\', '/')
      allRel.add relPath

  # 2. Resolve active groups (selection only — no gate logic).
  var active: seq[Group]
  var adHocPaths: seq[string]

  case selection.kind
  of gskDefault:
    for g in config.groups:
      if not g.optIn:
        active.add g
  of gskNamed:
    # Validate every requested name exists in config.
    let configNames = block:
      var s: HashSet[string]
      for g in config.groups: s.incl g.name
      s
    for wanted in selection.names:
      if wanted notin configNames:
        raise newCrisolError(cekConfig, "unknown group: " & wanted)
    for g in config.groups:
      if g.name in selection.names:
        active.add g
  of gskAll:
    active = config.groups
  of gskFiles:
    let resolved = resolveFilesGroups(config, selection, root, allRel)
    active     = resolved.active
    adHocPaths = resolved.adHocPaths

  # 3. For each active group, match files against globs.  Dedup by entrypoint
  #    IDENTITY (path, group name) across all active groups — a file matched by
  #    several globs of one group, or the same group reached through several
  #    selectors (gskFiles synthesises one Group per selector), is one leg.
  var entries: seq[Entrypoint]
  var seen: HashSet[(string, string)]

  for group in active:
    for relPath in allRel:
      # Match against any glob in the group (union semantics).
      var matched = false
      for glob in group.globs:
        if matchGlob(glob, relPath):
          matched = true
          break

      if matched and (relPath, group.name) notin seen:
        seen.incl (relPath, group.name)
        entries.add Entrypoint(
          path:           relPath,
          group:          group.name,
          flags:          group.flags,
          runTimeoutSecs: group.timeoutSecs,  # 0 = inherit global (RFC-0002 Feature A)
        )

  # 4. Sort by (path, group) — stable ordering for deterministic output.
  entries.sort(proc(a, b: Entrypoint): int =
    let cmp1 = cmp(a.path, b.path)
    if cmp1 != 0: cmp1 else: cmp(a.group, b.group)
  )

  DiscoveredSet(entries: entries, adHocPaths: adHocPaths)
