## test_spike_import_case.nim — RFC-0009 A0-spike: empirical go/no-go for
## whether the Nim 2.2.10 compiler preserves EACH importer's own case
## spelling of one on-disk dependency, or unifies the module to a single
## spelling before either importer's manifest entry is emitted.
##
## §4's Option B (the RFC's canonicalization-fork resolution) assumes the
## former: two importers spelling one dependency differently (`import Foo`
## / `import foo`) can put TWO distinct spellings of the same on-disk file
## into a compile's closure, which is exactly the fold-class collision
## `canonicalMerge`/`CanonicalSet` exists to resolve deterministically. This
## file is the pre-committed empirical check that assumption rests on —
## see docs/rfc/0009-path-identity.md §4 and the A0-spike Stages-and-slices
## entry for the full decision tree: per-importer preservation (>= 2
## distinct spellings observed below) means Option B stands as designed;
## unification to one spelling (exactly 1 observed) means the fold-class
## collision this RFC's canonicalization fork exists to resolve never
## occurs via the manifest path at all, and the RFC's own next step
## (`A4b`'s cold-vs-warm determinism assertion) is where that gets settled
## for good.
##
## Self-contained: std-only imports, no `crisol/*` import of any kind —
## this spike is decoupled from `closure.nim`'s not-yet-existing A0-onward
## retrofit and stands entirely on its own two feet (a fresh `nim c`
## subprocess and its own emitted manifest JSON).
##
## Fixtures are generated AT RUNTIME into a fresh temp directory and
## removed afterward — never committed as a differently-cased file pair.
## A committed `Widget.nim` + `widget.nim` would collide into ONE file the
## moment this repo is checked out onto a case-insensitive volume (exactly
## the class of runner this spike targets), silently deleting one spelling
## before the compiler ever saw it and making the whole spike vacuous.
##
## Self-skips on a case-sensitive volume (this container's Linux ext4, and
## any other case-sensitive leg): the entire premise — `import Widget`
## resolving to an on-disk `widget.nim` — only holds on a case-INSENSITIVE
## volume. Probed inline against the real filesystem rather than gated on
## `when defined(...)`, since case-sensitivity is a volume property, not a
## compile-time platform fact (a case-sensitive APFS volume is possible on
## macOS, same as a case-sensitive filesystem is possible, if unusual, on
## Windows). This makes the file a clean no-op on Linux/podman and live on
## macOS APFS / Windows NTFS — the two legs `ci.yml` runs it on.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/conformance/test_spike_import_case.nim

import std/[os, osproc, json, strutils, sequtils, unittest]

proc isCaseInsensitiveVolume(dir: string): bool =
  ## Creates a lowercase-named temp file directly under `dir` and checks
  ## whether its UPPERCASE spelling also resolves — the one on-disk fact
  ## this entire spike is contingent on (see header). `dir` must already
  ## exist.
  let lowerPath = dir / "spikeprobe_casetest.tmp"
  let upperPath = dir / "SPIKEPROBE_CASETEST.tmp"
  writeFile(lowerPath, "x")
  result = fileExists(upperPath)
  removeFile(lowerPath)

proc decodeMangledBody(raw: string): string =
  ## The same decode `crisol/closure.nim`'s `decodeBody` performs on a
  ## mangled manifest basename, duplicated here on purpose — this file
  ## imports std only, never `crisol/closure`. `@s` -> path separator,
  ## `@@` -> literal `@` (protected first so a literal `@` in the source
  ## path never collides with the `@s` escape).
  raw
    .replace("@@", "\x00")
    .replace("@s", $DirSep)
    .replace("\x00", "@")

suite "RFC-0009 A0-spike — compiler import-case manifest observation":

  test "two importers spelling one on-disk dependency differently: does the manifest preserve both spellings?":
    let base = getTempDir() / ("crisol_a0spike_" & $getCurrentProcessId())
    createDir(base)
    defer:
      try: removeDir(base)
      except OSError: discard

    if not isCaseInsensitiveVolume(base):
      echo "SPIKE SKIPPED: case-sensitive volume — the `import Widget` " &
           "resolving to on-disk `widget.nim` premise does not hold here"
      skip()
    else:
      # ---------------------------------------------------------------
      # Fixtures, generated fresh into `base` — never committed (header).
      # ---------------------------------------------------------------
      writeFile(base / "widget.nim", "proc widgetValue*(): int = 42\n")
      writeFile(base / "mod_lower.nim",
        "import widget\n" &
        "proc useLower*(): int = widgetValue()\n")
      writeFile(base / "mod_upper.nim",
        "import Widget\n" &
        "proc useUpper*(): int = widgetValue()\n")
      writeFile(base / "spikemain.nim",
        "import mod_lower, mod_upper\n" &
        "echo useLower() + useUpper()\n")

      let nimExe = findExe("nim")
      require nimExe.len > 0   # this file only runs via `nim r` in the first place

      let nimcacheDir = base / "nc"
      let outBin = base / "spikemain"
      let cmd = nimExe & " c --compileOnly --hints:off --warnings:off " &
                "-d:nimBetterRun --nimcache:" & nimcacheDir & " -o:" & outBin &
                " " & (base / "spikemain.nim")
      let (compileOutput, rc) = execCmdEx(cmd)

      if rc != 0:
        # A compile failure here is itself a finding: it would mean
        # `import Widget` did not resolve even on a case-insensitive
        # volume — a different, more basic result than the one this spike
        # is designed to measure.
        echo "SPIKE OBSERVATION: compile FAILED (rc=", rc, "); full output follows"
        echo compileOutput
        fail()
      else:
        let manifestPath = nimcacheDir / "spikemain.json"
        require fileExists(manifestPath)
        let manifest = parseJson(readFile(manifestPath))
        require manifest.hasKey("compile")

        var matchingBasenames: seq[string]
        var distinctSpellings: seq[string]

        for entry in manifest["compile"].getElems():
          # Real shape verified against tests/fixtures/nimcache/*/*.json:
          # each element is a `[cFilePath, ccCmd]` pair; the first element
          # is the ABSOLUTE path to the generated C file for that compile
          # unit — take its basename.
          let elems = entry.getElems()
          require elems.len >= 1
          let cPath = elems[0].getStr()
          let base2 = cPath.extractFilename()
          if not base2.startsWith("@m"): continue

          let noPrefix = base2[2 .. ^1]           # strip "@m"
          if not noPrefix.endsWith(".c"): continue
          let mangledNimName = noPrefix[0 ..< ^2]  # strip trailing ".c"
          let decoded = decodeMangledBody(mangledNimName)

          matchingBasenames.add(base2)
          if decoded.extractFilename().toLowerAscii() == "widget.nim":
            distinctSpellings.add(decoded.extractFilename())

        let distinctWidgetSpellings = distinctSpellings.deduplicate()

        echo "SPIKE OBSERVATION: raw @m basenames in compile[]: ", $matchingBasenames
        echo "SPIKE OBSERVATION: distinct widget.nim spellings observed: ",
             $distinctWidgetSpellings

        # The go/no-go: >= 2 distinct spellings means Nim preserved each
        # importer's own case spelling of the SAME on-disk dependency
        # (Option B stands as designed); == 1 means it unified to a
        # single spelling before either importer's manifest entry was
        # emitted (RFC escalation — see header).
        check distinctWidgetSpellings.len >= 2
        if distinctWidgetSpellings.len < 2:
          echo "SPIKE OBSERVATION: expected both \"widget.nim\" and " &
               "\"Widget.nim\" — Nim unified to a single spelling instead"

when isMainModule:
  echo "test_spike_import_case done"
