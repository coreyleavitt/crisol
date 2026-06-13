## build.nim — fixture pre-compiler for crisol A2b.
##
## Discovers tests/fixtures/*.nim, compiles each (except fail_compile.nim and
## build.nim itself) into tests/fixtures/bin/ with a per-entrypoint nimcache.
## Skips recompilation when the source content hash is unchanged (idempotent).
##
## Run with:
##   nim r tests/fixtures/build.nim
##
## Must be invoked from the project root (crisol/).

import std/[os, strutils]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc fnv1a64(s: string): uint64 =
  ## Stable 64-bit FNV-1a hash — used for content-change detection.
  ## Only used as a build-skip heuristic; not persisted across Nim versions.
  result = 14695981039346656037'u64
  for c in s:
    result = result xor uint64(ord(c))
    result = result * 1099511628211'u64

proc hashOfFile(path: string): string =
  ## Return a hex string of the FNV-1a64 of the file contents.
  let content = readFile(path)
  result = fnv1a64(content).toHex()

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

let fixtureDir  = "tests/fixtures"
let binDir      = fixtureDir / "bin"
let nimcacheDir = fixtureDir / "nimcache"

createDir(binDir)
createDir(nimcacheDir)

# Files to skip entirely (never compiled by this script).
# pathimport_main.nim requires --path:src and is compiled in test_closure.nim.
const skipList = ["build.nim", "fail_compile.nim", "pathimport_main.nim"]

var compiled = 0
var skipped  = 0

for entry in walkDir(fixtureDir):
  if entry.kind != pcFile: continue
  let name = entry.path.extractFilename
  if not name.endsWith(".nim"): continue
  if name in skipList: continue

  let stem     = name.changeFileExt("")
  let binPath  = binDir      / stem
  let hashPath = binDir      / (stem & ".hash")
  let cacheDir = nimcacheDir / stem

  # Compute current source hash.
  let currentHash = hashOfFile(entry.path)

  # Skip if hash unchanged and binary exists.
  if fileExists(binPath) and fileExists(hashPath):
    let storedHash = readFile(hashPath).strip()
    if storedHash == currentHash:
      echo "[skip] ", name, " (unchanged)"
      inc skipped
      continue

  echo "[compile] ", name
  createDir(cacheDir)

  let cmd = "nim c --mm:orc --hints:off --warnings:off" &
            " --nimcache:" & cacheDir &
            " -o:" & binPath &
            " " & entry.path
  let rc = execShellCmd(cmd)
  if rc != 0:
    echo "[ERROR] Failed to compile ", name, " (exit ", rc, ")"
    quit(1)

  # Store the hash only after a successful compile.
  writeFile(hashPath, currentHash)
  inc compiled

echo ""
echo "build.nim done: ", compiled, " compiled, ", skipped, " skipped."
