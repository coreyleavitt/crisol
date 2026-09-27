## nimargv.nim -- the one builder of crisol's `nim c` argv.
##
## Pure, and std-free, so both the compile paths (`compiledriver`, which
## re-exports it, and through it `runner`) and the C toolchain probe
## (`ccidentity`, which must not import `compiledriver`: that reaches
## `closure` and `config`) build the argv from the same code. The probe's
## discovery compile sees the configuration a real compile sees because it
## is the same argv, not a copy kept in step by a test.

proc nimCompileArgs*(entrypoint: string; flags: seq[string];
                     nimcacheDir, outputBinPath: string;
                     compileOnly = false): seq[string] =
  ## Assembles the argv AFTER the `nim` executable for one entrypoint
  ## compile. This is the SINGLE place `nim c` argv is assembled across
  ## crisol's compile paths: `runner.nim`'s monolithic production path
  ## (`monolithicCompArgs`), `compiledriver`'s measure-mode compile-only
  ## path (`realCompileOnly`) and `ccidentity`'s discovery compile.
  ##
  ## Always injects `-d:nimBetterRun`. That define makes the compiler write
  ## a `depfiles` array into the nimcache manifest
  ## (`<nimcacheDir>/<binaryName>.json`) — `[[absPath, hash], ...]` for
  ## EVERY file `conf.m.fileInfos` records: the main module, every import,
  ## every `include`d file, every `staticRead`/`slurp` target, and
  ## `nim.cfg`/`config.nims` (`compiler/extccomp.nim`
  ## `writeJsonBuildInstructions`, gated on `optRun in conf.globalOptions or
  ## isDefined(conf, "nimBetterRun")`). `closure.extractClosure` unions
  ## `depfiles` into the source closure (issue #11): without this define,
  ## an `include`d file, a `staticRead`/`slurp` input, or a config file is
  ## invisible to crisol — it neither triggers a recompile
  ## (`planner.decideCompile`'s closure content hash only covers closure
  ## files) nor gets selected under `--changed` (`narrow.narrowByDiff`
  ## intersects the git diff with the closure).
  ##
  ## The define has one other compiler effect: it also gates Nim's own
  ## "nothing changed, skip the whole compile" short-circuit
  ## (`compiler/main.nim` `commandCompileToC` ->
  ## `changeDetectedViaJsonBuildInstructions`). That short-circuit cannot
  ## fire in crisol's flow regardless of the define: it additionally
  ## requires the `-o:` output binary to still exist at the same path, and
  ## crisol's runner removes any pre-existing `-o:` target immediately
  ## before spawning the compiler (`runner.spawnCompileStable`) and deletes
  ## the per-slot scratch bin dir after copying the produced binary out to
  ## its stable location — so the precondition is false by construction.
  ## This matters: Nim's change detection covers `depfiles` but NOT
  ## `{.compile.}`d C sources, so an accidental short-circuit after a C
  ## edit would serve a stale binary. (`--compileOnly` never produces the
  ## `-o:` target, so the measure path is unaffected either way.)
  ##
  ## Deliberately NOT folded into `Entrypoint.flags`: it is an
  ## implementation-detail define crisol injects on every compile, not a
  ## user- or config-supplied flag, so entrypoint identity
  ## (`planner.slug`/`flagHash`) is unaffected by its presence.
  result = @["c", "--mm:orc", "--hints:off"]
  if compileOnly:
    result.add "--compileOnly"
  result.add "--nimcache:" & nimcacheDir
  result.add "-o:" & outputBinPath
  result.add "-d:nimBetterRun"
  for f in flags:
    result.add f
  result.add entrypoint
