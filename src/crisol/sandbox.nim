## sandbox.nim — A3: pure SandboxSpec resolution
##
## Resolves a ``SandboxSpec`` from a ``HermeticLevel`` and optional flags.
## This is **pure resolution only**: no spawn wiring, no config-KDL parsing,
## no CLI flag parsing.  Those integrations happen in later slices (A5, A2, A9).
##
## RFC-0004 §F2 governs the allowlist, rlimit defaults, and the monotone
## hermeticity-level invariant (each level is a strict superset of the one below).

import std/[algorithm, sequtils, strutils]
import std/options
import crisol/types
import crisol/depgraph

# ---------------------------------------------------------------------------
# Published constant: the default env allowlist
# ---------------------------------------------------------------------------

const DefaultEnvAllowlist*: seq[string] = @[
  "HOME",
  "LANG",
  "LOGNAME",
  "NIM_CONFIG_DIR",
  "NIMBLE_DIR",
  "PATH",
  "TERM",
  "TMPDIR",
  "TZ",
  "USER",
]
  ## The default env-var names passed through to a sandboxed child when
  ## ``hlIsolated`` or ``hlNetwork`` is active.  Published so callers can
  ## introspect or extend the set without hard-coding names.
  ##
  ## ``LC_*`` vars are handled via ``DefaultEnvAllowlistPrefixes``; they are
  ## never enumerated here because the full set is locale-specific.

const DefaultEnvAllowlistPrefixes*: seq[string] = @["LC_"]
  ## Prefix patterns matched against env-var names when building the child env.
  ## A var whose name starts with any of these prefixes is passed through even
  ## if it does not appear in ``envAllowlist``.

# ---------------------------------------------------------------------------
# Default rlimit constants (RFC-0004 §F2)
# ---------------------------------------------------------------------------
# RLIMIT_AS and RLIMIT_CPU default unset (none) — they are timing/memory
# sensitive and must be explicitly configured.  The remaining three carry
# safe deterministic defaults when rlimits are active.

const DefaultRlimitFsize*:  int64 = 256 * 1024 * 1024  # 256 MiB max file write
const DefaultRlimitNofile*: int64 = 1024
  ## Default RLIMIT_NOFILE (max open file descriptors) for a sandboxed child.
  ##
  ## WHY 1024 (was 256):
  ##   256 starved legitimate consumer workloads — e.g. a DB layer that
  ##   allocates one eventfd per in-flight async call exhausted 256 fds under
  ##   normal (non-pathological) concurrency and failed spuriously inside the
  ##   hermetic sandbox. 256 is also not a meaningful hermeticity guarantee:
  ##   it does not detect a "real" fd leak any better than a higher ceiling
  ##   does, since a legitimate test opening a few dozen files/sockets/eventfds
  ##   can plausibly approach it.
  ##
  ##   1024 is the conventional Linux soft `ulimit -n` default (matches
  ##   `/etc/security/limits.conf` defaults and systemd's DefaultLimitNOFILE
  ##   on most distros), so raising crisol's ceiling to 1024 makes the sandbox
  ##   behave like an ordinary shell session rather than an artificially tight
  ##   cage — it still catches unbounded fd leaks (a real leak blows past 1024
  ##   quickly) without punishing normal fan-out (event loops, connection
  ##   pools, async I/O) that a production-shaped test may exercise.
  ##
  ##   Consumers with unusual fd needs can still raise this further via
  ##   ``Config.rlimitNofile`` (crisol.kdl `rlimit-nofile N`) or
  ##   ``RunOptions.rlimitNofile`` without patching crisol.
const DefaultRlimitCore*:   int64 = 0                   # disable core dumps

const MinSafeRlimitAs*: int64 = 3 * 1024 * 1024 * 1024  # 3 GiB
  ## Minimum safe value for RLIMIT_AS when sandboxing Nim/ORC test binaries.
  ##
  ## WHY 3 GiB:
  ##   Nim's ORC garbage collector maps multiple virtual address regions at
  ##   startup: the arena root page, growable heap segments, metadata tables,
  ##   and the C runtime stack + BSS.  These add up to several hundred MiB of
  ##   virtual (not resident) address space before main() does any allocation.
  ##
  ##   A 512 MiB RLIMIT_AS ceiling causes SIGSEGV *before main() returns* because
  ##   ORC's arena initialization mmap() calls exceed the address-space budget.
  ##   This would crash crisol's forked child before any test work runs.
  ##
  ##   1 GiB is also dangerous: on container environments (podman rootless, WSL2)
  ##   the dynamic linker and shared-library segments can consume 400–800 MiB of
  ##   virtual space on their own, leaving less than 200 MiB for ORC's arena.
  ##
  ##   3 GiB is chosen as the published safe minimum because:
  ##     1. It is comfortably above the observed 512 MiB crash floor (6× headroom).
  ##     2. It leaves room for ORC startup + moderate test-binary overhead (e.g.
  ##        large linked libraries, debug info in memory) without risking OOM
  ##        before the first test line executes.
  ##     3. The A4c rlimit_as fixture allocates 4 GiB, so setting RLIMIT_AS =
  ##        MinSafeRlimitAs (3 GiB) means ORC boots (startup + overhead < 3 GiB)
  ##        but the 4 GiB alloc request tips the total past 3 GiB and is denied,
  ##        causing the child to exit non-zero without crashing the runner.
  ##     4. On 64-bit Linux virtual address space is abundant (128 TiB); a 3 GiB
  ##        RLIMIT_AS ceiling imposes no cost unless *resident* memory nears it.
  ##
  ## Consumers who configure limitAs below this value MUST document the risk.
  ## crisol logs a warning when limitAs < MinSafeRlimitAs at spec-resolution time.

# ---------------------------------------------------------------------------
# resolveSandbox — the pure resolution proc
# ---------------------------------------------------------------------------

proc resolveSandbox*(
  level:            HermeticLevel   = hlIsolated;
  passthroughs:     seq[string]     = @[];
  chdirIntoScratch: bool            = false;
  rlimits:          RlimitOverrides = RlimitOverrides();
): SandboxSpec =
  ## Resolve a ``SandboxSpec`` from a hermeticity level and optional overrides.
  ##
  ## *Pure* — no I/O, no env reads, no side effects.
  ##
  ## ``level`` is the governing hermeticity level:
  ## - ``hlNone``      — all isolation disabled; all fields false/empty.
  ## - ``hlIsolated``  — env allowlist + isolated tmpdir + config-declared rlimits.
  ## - ``hlNetwork``   — superset of hlIsolated, plus network namespace isolation.
  ##
  ## ``passthroughs`` appends extra names to ``envAllowlist``; duplicates are
  ## removed.  The final list is sorted for determinism.
  ##
  ## ``chdirIntoScratch`` — opt-in ``chdir`` into the scratch tmpdir (default off).
  ##
  ## ``rlimits`` is a ``RlimitOverrides`` bundle: each ``some`` field overrides
  ## the per-field default; each ``none`` field falls back to the built-in safe
  ## default (applied only when rlimits are active, i.e. level != hlNone).  The
  ## named-field bundle (vs. five positional ``Option[int64]`` args) makes a
  ## transposition a compile-visible misnomer rather than a silent bug.

  if level == hlNone:
    return SandboxSpec(level: hlNone)

  # hlIsolated and hlNetwork share the same isolation body; netIso differs.
  let netIso = (level == hlNetwork)

  # Build the env allowlist: default vars + caller passthroughs, deduped + sorted.
  var allowlist = DefaultEnvAllowlist & passthroughs
  allowlist = allowlist.deduplicate(isSorted = false)
  sort(allowlist)

  # Resolve rlimit fields: caller override wins; else apply safe defaults.
  let activeFsize  = if rlimits.limitFsize.isSome:  rlimits.limitFsize  else: some(DefaultRlimitFsize)
  let activeNofile = if rlimits.limitNofile.isSome: rlimits.limitNofile else: some(DefaultRlimitNofile)
  let activeCore   = if rlimits.limitCore.isSome:   rlimits.limitCore   else: some(DefaultRlimitCore)

  SandboxSpec(
    level:                level,
    envScrub:             true,
    tmpdir:               true,
    rlimits:              true,
    netIso:               netIso,
    chdirIntoScratch:     chdirIntoScratch,
    envAllowlist:         allowlist,
    envAllowlistPrefixes: DefaultEnvAllowlistPrefixes,
    rlimitConfig: RlimitConfig(
      limitAs:     rlimits.limitAs,    # default none(int64) per RFC
      limitCpu:    rlimits.limitCpu,   # default none(int64) per RFC
      limitFsize:  activeFsize,
      limitNofile: activeNofile,
      limitCore:   activeCore,
    ),
  )

# ---------------------------------------------------------------------------
# filterEnv — pure env-var filtering per SandboxSpec (A5)
# ---------------------------------------------------------------------------

proc filterEnv*(
  parentEnv: openArray[(string, string)];
  spec: SandboxSpec;
  injected: openArray[(string, string)];
): seq[(string, string)] =
  ## Filter the parent environment according to ``spec``, then append injected
  ## key=value pairs (always last, in the order given; override any duplicate).
  ##
  ## When ``spec.envScrub == false`` (hlNone): parent env passes through as-is.
  ## When ``spec.envScrub == true``: keep only vars whose name appears in
  ## ``spec.envAllowlist`` OR whose name starts with any prefix in
  ## ``spec.envAllowlistPrefixes``.  The kept (non-injected) portion is sorted
  ## by name for determinism before the injected pairs are appended.
  ##
  ## Injected vars always appear at the end in the order given.  If an injected
  ## name duplicates a kept parent var, the injected value wins (the kept copy
  ## is removed and replaced at the tail).

  if not spec.envScrub:
    # No scrub: pass parent through, then override/append injected.
    # Build result as a table to handle overrides, but preserve parent order
    # for non-overridden vars.
    var injectedNames: seq[string] = @[]
    for (k, _) in injected:
      injectedNames.add(k)

    result = @[]
    for pair in parentEnv:
      if pair[0] notin injectedNames:
        result.add(pair)
    for pair in injected:
      result.add(pair)
    return

  # envScrub == true: filter parent to allowlist + prefixes, sort, append injected.
  var injectedNames: seq[string] = @[]
  for (k, _) in injected:
    injectedNames.add(k)

  var kept: seq[(string, string)] = @[]
  for pair in parentEnv:
    let name = pair[0]
    # Skip vars that will be overridden by injected (they'll appear at the tail)
    if name in injectedNames:
      continue
    # Check exact allowlist
    var pass = name in spec.envAllowlist
    # Check prefix allowlist
    if not pass:
      for pfx in spec.envAllowlistPrefixes:
        if name.startsWith(pfx):
          pass = true
          break
    if pass:
      kept.add(pair)

  # Sort kept portion by name for determinism.
  kept.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))

  result = kept
  for pair in injected:
    result.add(pair)

# ---------------------------------------------------------------------------
# hermeticEnvHash — stable hash of the filtered env for the soundness key (A5)
# ---------------------------------------------------------------------------
#
# This is the ONLY proc that feeds the soundness key's env component.
# It hashes NAMES AND VALUES of every allowlisted var that actually reaches
# the hermetic child (post-allowlist-filter from filterEnv), with two
# deliberate exclusions to avoid per-run noise:
#
#   CRISOL_SINK, CRISOL_ATTEMPT — runner-internal injections; excluded entirely.
#   TMPDIR                      — value carries a per-run random mkdtemp suffix;
#                                 name is hashed but value is not.
#
# WHY values must enter the key (RFC-0004 §Keys):
#   An allowlisted var is one tests are *allowed to depend on*, so its value
#   is a real input to the test outcome.  Soundness requires: equal key ⇒
#   equal result.  Therefore, two runs where (e.g.) PATH differs must produce
#   different soundness keys; they cannot share a cache entry.  Omitting values
#   (names-only) was unsound: a stale cached pass from one host/CI runner could
#   be served on another where allowlisted values differ.
#
#   Cross-host cache reuse must be achieved by pinning / standardizing the env
#   (same approach as Bazel --action_env, Nix derivations), NOT by omitting
#   values from the key.
#
# Production call site (cachedispatch.realSeams):
#   hermeticEnvHash(filterEnv(parentEnv, spec, @[]))
# where `parentEnv` is the host env snapshot (toSeq(envPairs())) and `spec`
# carries the allowlist.  The filtered env is the same set of vars the child
# process will actually see (minus per-run CRISOL_* injections that are added
# later in spawn.nim and excluded here anyway).

const hermeticSkipVars = ["CRISOL_SINK", "CRISOL_ATTEMPT"]
  ## Per-run runner injections: excluded entirely from the soundness key hash.

const hermeticNameOnlyVars = ["TMPDIR"]
  ## Vars whose value carries a per-run random suffix (mkdtemp): hash name only.

proc hermeticEnvHash*(filteredEnv: seq[(string, string)]): string =
  ## Compute a stable FNV-1a hash of a filtered env for the soundness key.
  ##
  ## Input must be the post-allowlist-filter env (output of filterEnv with no
  ## injected pairs, or with CRISOL_* injections included — they are excluded
  ## here regardless).
  ##
  ## Rules:
  ## - Input is sorted by name (for determinism regardless of call-site order).
  ## - CRISOL_SINK and CRISOL_ATTEMPT are skipped entirely (per-run injections).
  ## - TMPDIR name is hashed but not its value (value is a per-run random suffix).
  ## - All other pairs contribute "name=value\0" — VALUES ARE INCLUDED so the
  ##   key reflects the actual env the child will see, not just the allowlist shape.
  ##
  ## Returns toHex16(hash).

  # Sort a copy by name for determinism.
  var sorted = filteredEnv
  sorted.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))

  var blob = ""
  for (name, value) in sorted:
    if name in hermeticSkipVars:
      continue
    elif name in hermeticNameOnlyVars:
      blob.add(name & "\0")
    else:
      blob.add(name & "=" & value & "\0")

  result = toHex16(fnv1a64(blob))
