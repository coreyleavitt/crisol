## test_spike_import_case.nim — RFC-0009 A0-spike: empirical go/no-go for
## whether the Nim 2.2.10 compiler preserves EACH importer's own case
## spelling of one on-disk dependency, or unifies the module to a single
## spelling — and, if it unifies, WHICH spelling it keeps (the on-disk
## real case, or whatever an importer/resolution-order happened to spell).
##
## §4's Option B (the RFC's canonicalization-fork resolution) assumed the
## FIRST: two importers spelling one dependency differently (`import Foo`
## / `import foo`) putting TWO distinct spellings of one on-disk file into
## a compile's closure — the fold-class collision `canonicalMerge` exists
## to resolve. Round-3 review flagged that assumption as unverified; this
## file is the pre-committed empirical check (docs/rfc/0009-path-identity.md
## §4 + the A0-spike Stages-and-slices entry hold the decision tree).
##
## Three scenarios, so the answer is unambiguous rather than conflated:
##   S1 mixed importers, lower-first  (on-disk widget.nim; import widget, import Widget)
##   S2 mixed importers, upper-first  (same, entrypoint imports the upper module first)
##   S3 upper-ONLY importer            (on-disk widget.nim; ONLY `import Widget`)
## S3 is the decisive discriminator: on-disk file is lowercase and the only
## importer is uppercase, so the recorded spelling can ONLY be the on-disk
## real case (=> Nim canonicalizes to on-disk => a single deterministic
## spelling => canonicalMerge is unreachable, the SIMPLER outcome) or the
## import spelling (=> resolution-order-dependent => Option A's on-disk
## case query is the remaining fix). S1/S2 corroborate whether the kept
## spelling is order-sensitive.
##
## Self-contained: std-only imports, no `crisol/*` import of any kind —
## this spike stands entirely on its own (a fresh `nim c` subprocess and
## its own emitted manifest JSON).
##
## Fixtures are generated AT RUNTIME into fresh temp directories and removed
## afterward — never committed as a differently-cased file pair. A committed
## `Widget.nim` + `widget.nim` would collide into ONE file the moment this
## repo is checked out onto a case-insensitive volume (exactly the class of
## runner this spike targets), silently deleting one spelling before the
## compiler ever saw it and making the whole spike vacuous.
##
## Self-skips on a case-sensitive volume (this container's Linux ext4, and
## any other case-sensitive leg): the premise — `import Widget` resolving to
## an on-disk `widget.nim` — only holds on a case-INSENSITIVE volume.
## Probed inline against the real filesystem, not gated on `when
## defined(...)`, since case-sensitivity is a volume property, not a
## compile-time platform fact. No-op on Linux/podman; live on macOS APFS /
## Windows NTFS — the two legs `ci.yml` runs it on.

import std/[os, osproc, json, strutils, sequtils, unittest]

proc isCaseInsensitiveVolume(dir: string): bool =
  ## Creates a lowercase-named temp file directly under `dir` and checks
  ## whether its UPPERCASE spelling also resolves. `dir` must already exist.
  let lowerPath = dir / "spikeprobe_casetest.tmp"
  let upperPath = dir / "SPIKEPROBE_CASETEST.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)
  removeFile(lowerPath)

proc decodeMangledBody(raw: string): string =
  ## The same decode `crisol/closure.nim`'s `decodeBody` performs on a
  ## mangled manifest basename, duplicated here on purpose (std-only file).
  ## `@s` -> path separator, `@@` -> literal `@` (protected first).
  raw
    .replace("@@", "\x00")
    .replace("@s", $DirSep)
    .replace("\x00", "@")

proc observeDepSpellings(base, depOnDisk: string;
                         mods: seq[(string, string)];
                         epImports: seq[string]):
                         tuple[ok: bool, spellings: seq[string],
                               raw: seq[string], output: string] =
  ## Generate a fixture tree in `base`, compile the entrypoint, and return
  ## the DISTINCT spellings the manifest records for `depOnDisk` (matched
  ## case-insensitively by basename). `mods` is (moduleFileName, importText)
  ## pairs; `epImports` is the entrypoint's own import list, in order.
  createDir(base)
  writeFile(base / depOnDisk, "proc widgetValue*(): int = 42\n")
  var idx = 0
  for (fname, importText) in mods:
    writeFile(base / fname,
      "import " & importText & "\n" &
      "proc use" & $idx & "*(): int = widgetValue()\n")
    inc idx
  writeFile(base / "spikemain.nim",
    "import " & epImports.join(", ") & "\n" &
    "echo (block:\n" &
    (block:
      var calls: seq[string]
      for i in 0 ..< mods.len: calls.add("use" & $i & "()")
      "  " & calls.join(" + ")) & ")\n")

  let nimExe = findExe("nim")
  require nimExe.len > 0
  let nimcacheDir = base / "nc"
  let outBin = base / "spikemain"
  let cmd = nimExe & " c --compileOnly --hints:off --warnings:off " &
            "-d:nimBetterRun --nimcache:" & nimcacheDir & " -o:" & outBin &
            " " & (base / "spikemain.nim")
  let (compileOutput, rc) = execCmdEx(cmd)
  if rc != 0:
    return (false, @[], @[], compileOutput)

  let manifestPath = nimcacheDir / "spikemain.json"
  require fileExists(manifestPath)
  let manifest = parseJson(readFile(manifestPath))
  require manifest.hasKey("compile")

  var raw: seq[string]
  var spellings: seq[string]
  let depLower = depOnDisk.toLowerAscii()
  for entry in manifest["compile"].getElems():
    let elems = entry.getElems()
    require elems.len >= 1
    let b = elems[0].getStr().extractFilename()
    if not b.startsWith("@m"): continue
    let noPrefix = b[2 .. ^1]
    if not noPrefix.endsWith(".c"): continue
    let decoded = decodeMangledBody(noPrefix[0 ..< ^2])
    raw.add(b)
    if decoded.extractFilename().toLowerAscii() == depLower:
      spellings.add(decoded.extractFilename())
  return (true, spellings.deduplicate(), raw, compileOutput)

suite "RFC-0009 A0-spike — compiler import-case manifest observation":

  test "does Nim unify differently-cased importers of one on-disk dependency, and to which spelling?":
    let root = getTempDir() / ("crisol_a0spike_" & $getCurrentProcessId())
    createDir(root)
    defer:
      try: removeDir(root)
      except OSError: discard

    if not isCaseInsensitiveVolume(root):
      echo "SPIKE SKIPPED: case-sensitive volume — the `import Widget` " &
           "resolving to on-disk `widget.nim` premise does not hold here"
      skip()
    else:
      # S1 — mixed importers, lower module imported first.
      let s1 = observeDepSpellings(root / "s1", "widget.nim",
        @[("mod_lower.nim", "widget"), ("mod_upper.nim", "Widget")],
        @["mod_lower", "mod_upper"])
      # S2 — mixed importers, UPPER module imported first (order swap).
      let s2 = observeDepSpellings(root / "s2", "widget.nim",
        @[("mod_lower.nim", "widget"), ("mod_upper.nim", "Widget")],
        @["mod_upper", "mod_lower"])
      # S3 — DECISIVE: on-disk lowercase, the ONLY importer is uppercase.
      let s3 = observeDepSpellings(root / "s3", "widget.nim",
        @[("mod_upper.nim", "Widget")],
        @["mod_upper"])

      for (name, r) in [("S1-lower-first", s1), ("S2-upper-first", s2),
                        ("S3-upper-only", s3)]:
        if not r.ok:
          echo "SPIKE OBSERVATION: ", name, " compile FAILED; output follows"
          echo r.output
        else:
          echo "SPIKE OBSERVATION: ", name,
               " raw @m basenames: ", $r.raw
          echo "SPIKE OBSERVATION: ", name,
               " distinct widget.nim spellings: ", $r.spellings

      require s3.ok
      # The decisive read: S3 has a lowercase file on disk and a single
      # UPPERCASE importer, so the one recorded spelling reveals Nim's rule.
      let s3spell = if s3.spellings.len == 1: s3.spellings[0] else: ""
      echo "SPIKE OBSERVATION: VERDICT — S3 recorded spelling = \"", s3spell,
           "\" (on-disk was \"widget.nim\", sole importer was `import Widget`)"
      if s3spell == "widget.nim":
        echo "SPIKE OBSERVATION: VERDICT — Nim canonicalizes to the ON-DISK " &
             "real case; a dependency has ONE deterministic spelling per " &
             "committed tree regardless of importer case/order. The " &
             "fold-class collision canonicalMerge/Option B targets does not " &
             "arise via the manifest path. Simpler outcome: keyBytes is " &
             "deterministic by on-disk case; canonicalMerge is unreachable."
      elif s3spell == "Widget.nim":
        echo "SPIKE OBSERVATION: VERDICT — Nim records the IMPORT spelling, " &
             "not the on-disk case; with mixed importers the kept spelling " &
             "is resolution-order-dependent. Option A (on-disk case query) " &
             "is the remaining fix; Option B's textual merge is insufficient."
      else:
        echo "SPIKE OBSERVATION: VERDICT — unexpected S3 result; inspect the " &
             "raw basenames above."

when isMainModule:
  echo "test_spike_import_case done"
