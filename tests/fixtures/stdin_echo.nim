## stdin_echo.nim — fixture for `toolrun.realRunWithStdinIn` (R10-D2).
##
## Reads its whole stdin to EOF, then writes it back to stdout, framed so an
## empty read is visible: `[stdin:<bytes>]`. No newline is added (stdout is a
## text-mode stream on Windows). A child whose stdin is never closed blocks
## here forever, which is the point: a runner that leaves stdin open times
## out on this fixture instead of answering.

when isMainModule:
  let got = stdin.readAll()
  stdout.write("[stdin:" & got & "]")
  stdout.flushFile()
  quit(0)
