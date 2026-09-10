## lock.nim — rfc-0007 A4/D2a: advisory lock, backend selected at compile time
## (mirrors process.nim). posix uses flock(2); windows uses LockFileEx. Real
## modules, not include — each nim check --os:<x>s from any host. See
## lock/posix.nim for the flock-vs-fcntl rationale and lock/windows.nim for
## the LockFileEx contract.
when defined(windows): import crisol/lock/windows as backend
else:                   import crisol/lock/posix as backend
export backend
