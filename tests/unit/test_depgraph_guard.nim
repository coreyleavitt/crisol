## test_depgraph_guard.nim — issue #5 hardening of the depgraph writer.
##
## An EMPTY closure is never a plausible scan result for a real entrypoint
## (a compiled binary's closure contains at least the entrypoint itself).
## Recording one would make the entry permanently fresh: the content hash
## over nothing always matches, so decideCompile / the result-cache key /
## --changed selection could never observe a change. `updateEntry` therefore
## refuses an empty closure (cekInternal — it is a crisol defect, not a user
## error) and leaves any existing entry untouched.
##
## `invalidateEntry` is the writer-side companion: when a closure cannot be
## recorded after a successful compile, the runner must NOT keep serving the
## previous (arbitrarily stale) entry — it drops it, so the next plan sees
## "no closure record" (decideCompile → cdStale; narrow → unknown closure).
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_depgraph_guard.nim

import std/[json, options, os, sets, strutils, tables, unittest]
import crisol/types
import crisol/paths
import crisol/closure  # for buildSourceIndex — recordClosure needs a SourceIndex
import crisol/depgraph

proc tpSet(paths: varargs[string]): HashSet[TrackedPath] =
  ## RFC-0009 A3c-ii: build a `HashSet[TrackedPath]` via `classify` under a
  ## vacuous (zero-value) `TrackedRoots`. Every closure member built here is
  ## a plain project-relative string (rootTag 0), so the vacuous root is
  ## safe regardless of whatever REAL `TrackedRoots` a given test's `cfg`
  ## separately carries (see tests/unit/test_depgraph.nim's `tpSet` for the
  ## full reasoning).
  result = initHashSet[TrackedPath]()
  for p in paths:
    let pc = classify(p, default(TrackedRoots))
    doAssert pc.kind == pcTracked, "test path failed to classify: " & p
    result.incl pc.tp

suite "depgraph writer guards (issue #5)":

  test "updateEntry refuses an empty closure and keeps the existing entry":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    let prior = tpSet("tests/t.nim", "src/a.nim")
    g.updateEntry("tests/t.nim", fh, prior, "hash-prior", 1)

    var raised = false
    try:
      g.updateEntry("tests/t.nim", fh, initHashSet[TrackedPath](), "hash-empty", 1)
    except CrisolError as e:
      raised = true
      check e.kind == cekInternal
    check raised
    check g.entries[("tests/t.nim", fh)].closure == prior
    check g.entries[("tests/t.nim", fh)].closureHash == "hash-prior"

  test "updateEntry refuses an empty closure even for a brand-new key":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    expect CrisolError:
      g.updateEntry("tests/new.nim", fh, initHashSet[TrackedPath](), "h", 1)
    check ("tests/new.nim", fh) notin g.entries

  test "invalidateEntry drops the entry; absent key is a no-op":
    var g  = initDepGraph("")
    let fh = flagHash(@[])
    g.updateEntry("tests/t.nim", fh, tpSet("tests/t.nim"), "h", 1)
    g.invalidateEntry("tests/t.nim", fh)
    check ("tests/t.nim", fh) notin g.entries
    g.invalidateEntry("tests/t.nim", fh)          # idempotent
    g.invalidateEntry("tests/never.nim", fh)      # never present
    check g.entries.len == 0

# ---------------------------------------------------------------------------
# Migration + load-side defense
# ---------------------------------------------------------------------------

proc graphRoot(tag: string): string =
  result = getTempDir() / ("crisol_depgraph_guard_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / ".crisol")

proc fixedProbe(policy: FoldPolicy): proc (rootAbs, stateDir: string): Option[FoldPolicy] =
  ## RFC-0009 A3c-i: inject a FIXED policy for every root, bypassing the
  ## real OS probe entirely (see MEMORY: never hardcode `foldPolicy ==
  ## fpNone` against the real probe — this dev container is case-sensitive
  ## ext4, so a real probe never returns fpAsciiLower locally). Mirrors
  ## tests/unit/test_paths.nim's own `fixedProbe`.
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] = some(policy)

proc probeByHint(hint: string; hintPolicy, otherPolicy: FoldPolicy): proc (rootAbs, stateDir: string): Option[FoldPolicy] =
  ## Inject DIFFERING policies per root, discriminated by a substring of the
  ## root's native path (`hint`) — lets one test prove the project root and
  ## a dep root each keep their OWN persisted policy, without depending on
  ## call order.
  result = proc (rootAbs, stateDir: string): Option[FoldPolicy] =
    some(if hint in rootAbs: hintPolicy else: otherPolicy)

suite "depgraph load guards (issue #5 migration)":

  test "a formatVersion-2 graph (written by the compile-array extractor) loads as empty":
    ## Every v2 entry is suspect: any entry written after a warm recompile is
    ## truncated or empty and hash-matches itself forever, so upgrading does
    ## not self-heal it. Discard the whole graph once (one-time full recompile).
    let root = graphRoot("v2")
    defer: removeDir(root)
    writeFile(root / ".crisol" / "depgraph", """
    { "header": { "nimVersion": "2.2.10", "formatVersion": 2 },
      "entries": [ { "path": "tests/t.nim", "flagHash": "cbf29ce484222325",
                     "closure": ["tests/t.nim"], "closureHash": "abc", "protocolMajor": 1 } ] }
    """)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    check loadDepGraph(cfg, "2.2.10").entries.len == 0

  test "an entry with an empty closure is dropped on load":
    let root = graphRoot("emptycl")
    defer: removeDir(root)
    writeFile(root / ".crisol" / "depgraph", """
    { "header": { "nimVersion": "2.2.10", "formatVersion": """ & $DepGraphFormatVersion & """ },
      "entries": [
        { "path": "tests/empty.nim", "flagHash": "cbf29ce484222325",
          "closure": [], "closureHash": "abc", "protocolMajor": 1 },
        { "path": "tests/ok.nim", "flagHash": "cbf29ce484222325",
          "closure": ["tests/ok.nim"], "closureHash": "def", "protocolMajor": 1 } ] }
    """)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")
    let g = loadDepGraph(cfg, "2.2.10")
    check ("tests/empty.nim", "cbf29ce484222325") notin g.entries
    check ("tests/ok.nim", "cbf29ce484222325") in g.entries

# ---------------------------------------------------------------------------
# recordClosure — R5: the recovery policy lives beside the invariant it
# enforces (DepGraphEntry.closure, invariant NONEMPTY-CLOSURE).
# ---------------------------------------------------------------------------

proc writeManifest(dir, bname: string; link: seq[string]) =
  ## Minimal synthetic nimcache manifest — only `link` matters to
  ## extractClosure (see tests/unit/test_closure_warm.nim's writeManifest).
  let node = newJObject()
  node["compile"] = newJArray()
  let linkArr = newJArray()
  for o in link: linkArr.add newJString(o)
  node["link"]    = linkArr
  node["linkcmd"] = newJString("")
  node["depfiles"] = newJArray()
  createDir(dir)
  writeFile(dir / bname & ".json", $node)

proc recRoot(tag: string): string =
  result = getTempDir() / ("crisol_recordclosure_" & tag & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / ".crisol")
  createDir(result / "tests")

proc isHex16(s: string): bool =
  if s.len != 16: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

suite "recordClosure — recovery policy (R5)":

  test "valid manifest → ok, entry recorded with non-empty closure + closureHash, persisted":
    let root = recRoot("ok")
    defer: removeDir(root)
    let ep = root / "tests" / "rec_ep.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"
    writeManifest(nc, "rec_ep", link = @[nc / "@mrec_ep.nim.c.o"])
    var cfg = Config(projectRoot: root, stateDir: ".crisol")
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")

    var graph = initDepGraph("")
    let r = recordClosure(graph, cfg, Entrypoint(path: "tests/rec_ep.nim", group: "t"),
                          nc, "rec_ep",
                          protocolMajor = 1, index = buildSourceIndex(cfg))
    check r.ok
    check r.error == ""

    let fh = flagHash(@[])
    check ("tests/rec_ep.nim", fh) in graph.entries
    let entry = graph.entries[("tests/rec_ep.nim", fh)]
    check entry.closure.len > 0
    check isHex16(entry.closureHash)

    check ("tests/rec_ep.nim", fh) in loadDepGraph(cfg, "").entries

  test "extraction failure (empty link) → ok=false, error non-empty, entry GONE in memory and on disk":
    let root = recRoot("fail")
    defer: removeDir(root)
    let ep = root / "tests" / "rec_fail.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"
    writeManifest(nc, "rec_fail", link = @[])   # empty link → extractClosure raises
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var graph = initDepGraph("")
    let fh = flagHash(@[])
    # Pre-seed a fresh-looking prior entry — exactly what a naive writer
    # would leave behind on failure.
    graph.updateEntry("tests/rec_fail.nim", fh, tpSet("tests/rec_fail.nim"),
                      "priorhash", 1)
    doAssert saveDepGraph(graph, cfg)

    let r = recordClosure(graph, cfg, Entrypoint(path: "tests/rec_fail.nim", group: "t"),
                          nc, "rec_fail",
                          protocolMajor = 1, index = buildSourceIndex(cfg))
    check not r.ok
    check r.error.len > 0
    check ("tests/rec_fail.nim", fh) notin graph.entries
    check ("tests/rec_fail.nim", fh) notin loadDepGraph(cfg, "").entries

  test "persist failure (issue #13.3): a manifest that would otherwise succeed still returns ok=false":
    ## Fault injection: `createDir(depgraphPath(cfg))`. `saveDepGraph` (via
    ## `ioutils.atomicPublish` as of RFC-0007 A3) writes its content to a
    ## PID-suffixed temp file (which this fault never touches, so that step
    ## succeeds) and then `rename(2)`s the temp file onto `depgraphPath(cfg)`
    ## — `rename(2)` reliably fails with `EISDIR` when the destination is an
    ## existing directory and the source is a regular file, so the final
    ## commit step fails deterministically without needing filesystem
    ## permissions the container's root user would bypass anyway (and
    ## without needing to predict a PID-suffixed filename in advance).
    let root = recRoot("persistfail")
    defer: removeDir(root)
    let ep = root / "tests" / "rec_persistfail.nim"
    writeFile(ep, "# ep\n")
    let nc = root / "nimcache"
    writeManifest(nc, "rec_persistfail", link = @[nc / "@mrec_persistfail.nim.c.o"])
    var cfg = Config(projectRoot: root, stateDir: ".crisol")
    cfg.trackedRoots = initTrackedRoots(root, newSeq[tuple[name, native: string]](), ".crisol")

    createDir(depgraphPath(cfg))

    var graph = initDepGraph("")
    let r = recordClosure(graph, cfg, Entrypoint(path: "tests/rec_persistfail.nim", group: "t"),
                          nc, "rec_persistfail",
                          protocolMajor = 1, index = buildSourceIndex(cfg))
    check not r.ok
    check "dependency graph could not be persisted" in r.error

    # The in-memory graph still holds the new entry (this run's own
    # selection logic sees it correctly) — only the ON-DISK side failed;
    # see recordClosure's doc comment for why the caller (the runner) must
    # not trust the stable binary despite this.
    let fh = flagHash(@[])
    check ("tests/rec_persistfail.nim", fh) in graph.entries

suite "saveDepGraph — return value (issue #13.3)":

  test "returns false and leaves no depgraph file when the destination path is occupied by a directory":
    let root = graphRoot("savefail")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    createDir(depgraphPath(cfg))

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    check not saveDepGraph(g, cfg)
    check not fileExists(depgraphPath(cfg))

  test "returns true and the depgraph file exists once the obstruction is removed":
    let root = graphRoot("savefail_recover")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    check saveDepGraph(g, cfg)
    check fileExists(depgraphPath(cfg))

  test "RFC-0009 A-degraded (D5): returns false and writes nothing at all when config.trackedRoots.degraded, even with no obstruction present":
    let root = graphRoot("savefail_degraded")
    defer: removeDir(root)
    var roots = default(TrackedRoots)
    roots.degraded = true
    roots.degradedReason = "fold-policy probe failed for root '' (" & root & ")"
    let cfg = Config(projectRoot: root, stateDir: ".crisol", trackedRoots: roots)

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    check not saveDepGraph(g, cfg)
    check not fileExists(depgraphPath(cfg))

# ---------------------------------------------------------------------------
# depgraph load provenance — a discarded depgraph must be a visible,
# structured diagnostic, not a silent empty-graph fallback.
# ---------------------------------------------------------------------------

suite "depgraph load provenance: discarded persisted graph":

  test "nimVersion mismatch: entries empty AND message mentions both versions":
    let root = graphRoot("nimver_mismatch")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfg)

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.3.0", d)
    check loaded.entries.len == 0
    check d.kind == dgdNimVersion
    check d.key == "nimVersion"
    check "2.2.10" in d.message
    check "2.3.0" in d.message

  test "formatVersion mismatch: message mentions the format version":
    let root = graphRoot("fmtver_mismatch")
    defer: removeDir(root)
    let staleVer = DepGraphFormatVersion - 1
    writeFile(root / ".crisol" / "depgraph", """
    { "header": { "nimVersion": "2.2.10", "formatVersion": """ & $staleVer & """ },
      "entries": [ { "path": "tests/t.nim", "flagHash": "cbf29ce484222325",
                     "closure": ["tests/t.nim"], "closureHash": "abc", "protocolMajor": 1 } ] }
    """)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdFormatVersion
    check d.key == "formatVersion"
    check $staleVer in d.message
    check $DepGraphFormatVersion in d.message

  test "matching graph loads cleanly: dgdNone and message == \"\"":
    let root = graphRoot("clean_load")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfg)

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 1
    check d.kind == dgdNone
    check d.message == ""

  test "no file present: dgdNone":
    let root = graphRoot("no_file")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdNone
    check d.message == ""

  test "the 2-arg overload still works and drops provenance":
    let root = graphRoot("two_arg")
    defer: removeDir(root)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfg)

    check loadDepGraph(cfg, "2.2.10").entries.len == 1
    check loadDepGraph(cfg, "2.3.0").entries.len == 0   # discarded; no way to observe why

  test "control bytes and ANSI escapes in a stored header value are sanitized out of message":
    let root = graphRoot("control_bytes")
    defer: removeDir(root)
    let stalePayload = "2.2.10\x1b[31m\x01bad"
    let doc = %*{
      "header":  {"nimVersion": stalePayload, "formatVersion": DepGraphFormatVersion},
      "entries": newJArray(),
    }
    writeFile(root / ".crisol" / "depgraph", $doc)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.3.0", d)
    check loaded.entries.len == 0
    check d.kind == dgdNimVersion
    let msg = d.message
    for c in msg:
      check ord(c) >= 0x20

  test "message shows only the first line of a multi-line stored value":
    let root = graphRoot("multiline")
    defer: removeDir(root)
    let doc = %*{
      "header":  {"nimVersion": "A\nB\nC", "formatVersion": DepGraphFormatVersion},
      "entries": newJArray(),
    }
    writeFile(root / ".crisol" / "depgraph", $doc)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.3.0", d)
    check loaded.entries.len == 0
    check d.kind == dgdNimVersion
    let msg = d.message
    check "A" in msg
    check "\n" notin msg

  test "header missing nimVersion: dgdMalformed with reason text":
    let root = graphRoot("missing_nimver")
    defer: removeDir(root)
    let doc = %*{
      "header":  {"formatVersion": DepGraphFormatVersion},
      "entries": newJArray(),
    }
    writeFile(root / ".crisol" / "depgraph", $doc)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdMalformed
    check d.key == "malformed"
    check "nimVersion" in d.stored
    check "depgraph discarded" in d.message

  test "root is a JSON array: dgdMalformed":
    let root = graphRoot("root_array")
    defer: removeDir(root)
    writeFile(root / ".crisol" / "depgraph", "[]")
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdMalformed
    check d.key == "malformed"
    check "depgraph discarded" in d.message

  test "F6: header nimVersion of non-string JSON type → dgdMalformed with reason text":
    let root = graphRoot("nimver_not_string")
    defer: removeDir(root)
    let doc = %*{
      "header":  {"nimVersion": 123, "formatVersion": DepGraphFormatVersion},
      "entries": newJArray(),
    }
    writeFile(root / ".crisol" / "depgraph", $doc)
    let cfg = Config(projectRoot: root, stateDir: ".crisol")

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfg, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdMalformed
    check d.key == "malformed"
    check "nimVersion" in d.stored
    check "not a string" in d.stored
    check "depgraph discarded" in d.message

  test "F4: unreadable-but-present depgraph file → dgdMalformed with 'unreadable' in stored/message":
    ## Root-proof variant: chmod 0o000 is a NO-OP for root (root bypasses
    ## regular-file permission checks entirely), and this suite runs inside
    ## crisol's podman toolchain, which runs as root by default — so a
    ## chmod-based "deny read" never actually exercised this branch here
    ## (see toolchain-milpa-podman / dev-test-verification-gotchas memory:
    ## this is exactly the kind of silently-skipped assertion that gotcha
    ## warns about).
    ##
    ## `/proc/self/mem` gives a permission-independent way to trigger the
    ## same dgdMalformed "unreadable" branch: `fileExists` follows the
    ## symlink and stats a regular, present file (so the branch is reached
    ## at all — see loadDepGraph's own NOTE on why `fileExists` gates this),
    ## but reading from offset 0 always fails with EIO because that address
    ## is never mapped without a prior `lseek` — true for root exactly as
    ## for an unprivileged reader. This exercises the identical
    ## unreadable-but-present code path that root permissions cannot.
    let root = graphRoot("unreadable")
    defer: removeDir(root)
    let path = root / ".crisol" / "depgraph"
    if not fileExists("/proc/self/mem"):
      skip()
    else:
      createSymlink("/proc/self/mem", path)
      var d: DepGraphDiscard
      let loaded = loadDepGraph(Config(projectRoot: root, stateDir: ".crisol"), "2.2.10", d)
      check loaded.entries.len == 0
      check d.kind == dgdMalformed
      check d.key == "malformed"
      check "unreadable" in d.stored
      check "unreadable" in d.message

  test "F3: a '|'-delimited fingerprint renders as <first line>|<last-12 hash chars>, single-line, differs by hash":
    ## Two toolchains that share a `nim --version` line but differ in
    ## binary hash (e.g. a patched vs. stock 2.2.10 — this repo's exact
    ## situation) must not collapse to identical diagnostics.
    let d1 = DepGraphDiscard(kind: dgdNimVersion,
      stored:  "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at 2024-01-01|deadbeefcafe0001",
      current: "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at 2024-01-01|deadbeefcafe0001")
    let d2 = DepGraphDiscard(kind: dgdNimVersion,
      stored:  "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at 2024-01-01|deadbeefcafe0002",
      current: "Nim Compiler Version 2.2.10 [Linux: amd64]\nCompiled at 2024-01-01|deadbeefcafe0002")
    let msg1 = d1.message
    let msg2 = d2.message
    check msg1 != msg2
    check "\n" notin msg1
    check "\n" notin msg2
    check "Nim Compiler Version 2.2.10 [Linux: amd64]" in msg1
    check "Nim Compiler Version 2.2.10 [Linux: amd64]" in msg2
    check "beefcafe0001" in msg1   # last 12 chars of "deadbeefcafe0001"
    check "beefcafe0002" in msg2   # last 12 chars of "deadbeefcafe0002"

  test "the '|' hash heuristic applies ONLY to dgdNimVersion — a dgdMalformed path containing '|' renders intact":
    ## sanitizeHeaderField's '|'-tail rendering exists solely for the
    ## dgdNimVersion fingerprint shape ("<version text>|<hash>"). It must
    ## NOT apply to dgdMalformed's free-text `stored` reason: a filesystem
    ## path can legitimately contain '|' (e.g. an unusual-but-valid dir
    ## name), and running the fingerprint heuristic on it would mangle
    ## "unreadable: cannot open: /tmp/a|b/depgraph" down to
    ## "…|sol/depgraph" instead of showing the real path.
    let d = DepGraphDiscard(kind: dgdMalformed,
      stored: "unreadable: cannot open: /tmp/a|b/depgraph")
    check "a|b" in d.message
    check "unreadable: cannot open: /tmp/a|b/depgraph" in d.message

  test "RFC-0009 A3c-i: root descriptor (project + one named dep, each with its own injected foldPolicy) round-trips byte-for-byte through save/loadStoredDepGraph":
    let root = graphRoot("roots_roundtrip")
    defer: removeDir(root)
    let depNative = root / "depdir"
    createDir(depNative)

    var cfg = Config(projectRoot: root, stateDir: ".crisol")
    cfg.trackedRoots = initTrackedRoots(root, @[("mydep", depNative)], ".crisol",
                                        probeByHint("depdir", fpAsciiLower, fpNone))
    check cfg.trackedRoots.project.foldPolicy == fpNone
    check cfg.trackedRoots.deps[0].foldPolicy == fpAsciiLower

    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfg)

    var d: DepGraphDiscard
    let loaded = loadStoredDepGraph(cfg, d)
    check d.kind == dgdNone
    check loaded.header.roots.len == 2
    check loaded.header.roots[0] == (tag: 0, name: "", foldPolicy: fpNone)
    check loaded.header.roots[1] == (tag: 1, name: "mydep", foldPolicy: fpAsciiLower)

  test "RFC-0009 A3c-i: loadDepGraph discards as absent when a persisted root NAME is unknown to the current roots (dgdRootUnknown)":
    let root = graphRoot("root_unknown")
    defer: removeDir(root)
    var cfgWrite = Config(projectRoot: root, stateDir: ".crisol")
    cfgWrite.trackedRoots = initTrackedRoots(root, @[("gonedep", root / "gonedep")], ".crisol",
                                             fixedProbe(fpNone))
    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfgWrite)

    var cfgRead = Config(projectRoot: root, stateDir: ".crisol")
    cfgRead.trackedRoots = initTrackedRoots(root, @[], ".crisol", fixedProbe(fpNone))

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfgRead, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdRootUnknown
    check d.key == "rootUnknown"
    check d.stored == "gonedep"
    check "gonedep" in d.message

  test "RFC-0009 A3c-i: loadDepGraph discards as absent on a foldPolicy mismatch for a name that still resolves (dgdFoldMismatch), never compared cross-policy":
    let root = graphRoot("fold_mismatch")
    defer: removeDir(root)
    var cfgWrite = Config(projectRoot: root, stateDir: ".crisol")
    cfgWrite.trackedRoots = initTrackedRoots(root, @[], ".crisol", fixedProbe(fpNone))
    var g = initDepGraph("2.2.10")
    g.updateEntry("tests/t.nim", flagHash(@[]), tpSet("tests/t.nim"), "h", 1)
    doAssert saveDepGraph(g, cfgWrite)

    # Same root NAME ("" — the project root), a DIFFERENT injected policy —
    # never a live fold-class collision, just the injected values disagreeing.
    var cfgRead = Config(projectRoot: root, stateDir: ".crisol")
    cfgRead.trackedRoots = initTrackedRoots(root, @[], ".crisol", fixedProbe(fpAsciiLower))

    var d: DepGraphDiscard
    let loaded = loadDepGraph(cfgRead, "2.2.10", d)
    check loaded.entries.len == 0
    check d.kind == dgdFoldMismatch
    check d.key == "foldMismatch"
    check d.stored == "fpNone"
    check d.current == "fpAsciiLower"
    check "depgraph discarded" in d.message
