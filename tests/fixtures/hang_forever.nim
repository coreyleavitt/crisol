## hang_forever.nim — fixture that compiles clean but never exits.
## Used by A2b integration tests to verify oTimeout classification and
## process-group kill. The compile timeout must be long enough; the run
## timeout short (e.g. 1500 ms) to keep the test suite fast.
import os
while true:
  os.sleep(1000)
