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
## `process/windows.nim` (Stage D) does not exist yet — `when` is a
## compile-time branch, so its unbuilt arm below is never parsed on this
## host. `process/darwin.nim` was born in C1b: `macosx` now maps to it
## directly, a pure shell over `process/posix` exactly like `process/linux.nim`
## — every macOS mechanism (kqueue `next`, libproc forensics) lives in
## `process/posixcore.nim`'s `when defined(macosx):` branches.

when defined(windows):
  import crisol/process/windows as backend
elif defined(linux):
  import crisol/process/linux as backend
elif defined(macosx):
  import crisol/process/darwin as backend
else:
  import crisol/process/posix as backend

export backend
