# member.nim — RFC-0009 A0 golden-pin fixture: a depRoot closure member
# living OUTSIDE the project root (tests/fixtures/rfc9_golden_pin/deproot/
# project/). Its ABSOLUTE native path (which embeds the checkout location)
# is exactly the fnv.nim:68 fall-through case this vector exercises — see
# test_rfc9_golden_pin.nim's "depRoot vector" suite and RFC-0009's A0
# bullet. Committed content is FIXED — do not edit.
proc depMemberValue*(): int = 7
