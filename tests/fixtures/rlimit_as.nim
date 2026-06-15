## rlimit_as.nim — fixture for A4c integration tests
##
## Attempts to allocate virtual address space that exceeds RLIMIT_AS.
##
## When RLIMIT_AS is active the OS refuses mmap/brk requests that would push
## the total virtual address space above the ceiling.  Nim's allocator (ORC)
## uses mmap under the hood; a request for more virtual memory than the
## remaining headroom raises OutOfMemDefect or causes a SIGSEGV.
##
## IMPORTANT: RLIMIT_AS is set in the CHILD only (via setrlimit in the
## async-signal-safe fork window in forkExecEnvScratch).  It does NOT apply
## to the crisol runner process.  The ceiling is MinSafeRlimitAs (3 GiB),
## which is generous enough for ORC startup + test-binary overhead, but the
## 4 GiB allocation below tips the total past the ceiling and is denied.
##
## Strategy:
##   Allocate AllocBytes (4 GiB) via alloc().  With RLIMIT_AS = 3 GiB and
##   ORC/runtime overhead accounting for several hundred MiB, the total virtual
##   space requirement exceeds the ceiling; the alloc fails.  Nim raises
##   OutOfMemDefect, which terminates the process with a non-zero exit code.
##
## Exit 0  = allocation succeeded (no limit or limit generous enough — control).
## Exit ≠0 = allocation was denied (OutOfMemDefect or SIGSEGV from mmap fail).
##
## Usage: run under forkExecEnvScratch with limitAs = MinSafeRlimitAs (3 GiB).

const AllocBytes = 4 * 1024 * 1024 * 1024  # 4 GiB virtual request
  ## Large enough to push total virtual AS past MinSafeRlimitAs (3 GiB) even
  ## accounting for ORC arena startup + shared-library segments.

# Deliberately request 4 GiB of virtual address space.
# With RLIMIT_AS = MinSafeRlimitAs (3 GiB), ORC has already used several
# hundred MiB for its arena, so this request tips the total past the ceiling.
# ORC raises OutOfMemDefect; the process exits non-zero.
#
# With no limit (control case), virtual address space is abundant on 64-bit
# Linux; the alloc succeeds and we exit 0.
let p = alloc(AllocBytes)
if p == nil:
  quit(1)  # alloc returned nil (ORC-style: shouldn't happen; OutOfMemDefect is raised instead)

# If we reach here, the allocation succeeded — no ceiling was enforced.
dealloc(p)
quit(0)
