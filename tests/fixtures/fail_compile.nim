## fail_compile.nim — deliberate compile error fixture.
## This file MUST NOT compile. Used by A2b integration tests to verify
## oCompileFailed classification. Never passed to build.nim.
let x = undeclaredIdentifier
