## process.nim — the ONLY process-lifecycle surface the executor imports.
## Re-exports the backend MODULE selected at compile time:
##   when defined(windows): import process/windows as backend
##   elif defined(linux):   import process/linux    # posix + Linux capabilities
##   elif defined(macosx):  import process/darwin   # posix + kqueue/libproc overrides
##   else:                  import process/posix
##   export backend
## Real modules, not `include`: platform-neutral types live in process/types.nim,
## and each backend is a self-contained module that `nim check --os:<x>`s from any
## host — signatures get per-platform compiler checking; the conformance suite
## (A2a-ii) checks behaviour. (`include` would reduce the contract to doc comments.)
##
## `process/windows.nim` (Stage D) and `process/darwin.nim` (C1b) do not exist
## yet — `when` is a compile-time branch, so the unbuilt arms below are never
## parsed on this host; `macosx` maps to `process/posix` directly until C1b.

when defined(windows):
  import crisol/process/windows as backend
elif defined(linux):
  import crisol/process/linux as backend
elif defined(macosx):
  import crisol/process/posix as backend
else:
  import crisol/process/posix as backend

export backend
