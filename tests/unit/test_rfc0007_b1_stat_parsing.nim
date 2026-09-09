## test_rfc0007_b1_stat_parsing.nim — rfc-0007 B1: `parseStatLine` grows a
## starttime (field 22) return value; this pins the field-counting directly
## against a synthetic /proc/<pid>/stat line rather than only indirectly
## through the live escapee-kill tracers (test_rfc0007_a6a_escapee_evidence.nim),
## which would otherwise be the only signal a miscounted starttime field
## broke — B1's pid-reuse-safety check depends on this number being right.
##
## Run with:
##   ./dev run nim r --hints:off --warnings:off --path:src \
##         tests/unit/test_rfc0007_b1_stat_parsing.nim

import std/unittest
import crisol/process/posixcore

suite "rfc-0007 B1 — parseStatLine field counting":

  test "ppid/pgrp/starttime land on the correct fields (synthetic stat line)":
    ## Fields after "pid (comm) " (1-indexed overall / 0-indexed token
    ## after the split): state(3/0) ppid(4/1) pgrp(5/2) session(6/3)
    ## tty_nr(7/4) tpgid(8/5) flags(9/6) minflt(10/7) cminflt(11/8)
    ## majflt(12/9) cmajflt(13/10) utime(14/11) stime(15/12) cutime(16/13)
    ## cstime(17/14) priority(18/15) nice(19/16) num_threads(20/17)
    ## itrealvalue(21/18) starttime(22/19).
    let line = "999 (fake comm) S 111 222 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 5555555 0 0"
    let (ppid, pgrp, comm, starttime) = parseStatLine(line)
    check ppid == 111
    check pgrp == 222
    check comm == "fake comm"
    check starttime == 5555555

  test "comm containing parens/spaces still yields the right starttime (split on LAST ')')":
    let line = "42 (weird (nested) name) R 7 8 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123456 0 0"
    let (ppid, pgrp, comm, starttime) = parseStatLine(line)
    check ppid == 7
    check pgrp == 8
    check comm == "weird (nested) name"
    check starttime == 123456

  test "short/malformed line: starttime stays the -1 sentinel, never a garbage value":
    let line = "1 (x) S 0 0"
    let (ppid, pgrp, comm, starttime) = parseStatLine(line)
    check ppid == 0
    check pgrp == 0
    check comm == "x"
    check starttime == -1

echo "test_rfc0007_b1_stat_parsing: done"
