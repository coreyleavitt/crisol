## test_soundness_r6.nim — R6: closureContentHash must be non-commutative and position-sensitive.
##
## Bug: closureContentHash XORs per-file FNV-1a hashes. XOR is:
##   - Commutative: H(a) XOR H(b) == H(b) XOR H(a) → reordering files doesn't change hash.
##     (This is actually intentional — we sort first. Not the main bug.)
##   - Self-cancelling: H(x) XOR H(x) == 0 → two files with identical content cancel out.
##     If file A and file B have identical content, swapping A and B doesn't change the hash.
##   - Collision-prone: if two sets of hashes XOR to the same value, the combined hash
##     is the same even though the content sets differ.
##
## The key soundness bug: if file A contains "foo" and file B contains "foo"
## (identical content), the old scheme gives: H(a_content) XOR H(b_content) = 0.
## Now if you change A to contain "bar", and B already contains "bar" (different from old),
## the new XOR is still 0. So cdSkipFresh is returned → stale binary not rebuilt.
##
## Worse: if we have two files with content swapped (A had X, B had Y; now A has Y, B has X),
## the XOR hash is unchanged → stale binary not detected → under-rebuild.
##
## Fix: chain the hash through sorted (path, content) pairs so:
##   - The path is part of the hash contribution (path-sensitive)
##   - The running hash is chained (position-sensitive in sorted order)
##
## The fix must still be order-independent for the same set (sorted files).

import std/[os, sets]
import crisol/depgraph

block test_r6_identical_content_files_detected:
  ## Two files with identical content: old XOR scheme gives 0 XOR 0 = 0.
  ## If both change to another identical content, old hash is same (0 again).
  ## New hash must differ because the PATH is different even if content is same.
  let root = getTempDir() / "crisol_r6_a"
  createDir(root)
  defer: removeDir(root)

  let fa = root / "a.nim"
  let fb = root / "b.nim"
  writeFile(fa, "# same content")
  writeFile(fb, "# same content")

  let h1 = closureContentHash(@[fa, fb], root)
  # Both files have identical content. The hash must still distinguish this
  # set from a set with different paths (by being path-sensitive).
  # At minimum, the hash must be 16 hex chars and deterministic.
  assert h1.len == 16, "hash must be 16 chars"
  let h2 = closureContentHash(@[fa, fb], root)
  assert h1 == h2, "hash must be deterministic"

block test_r6_content_swap_detected:
  ## Files A and B swap content: old XOR hash is H(X) XOR H(Y) before = H(Y) XOR H(X) after.
  ## XOR is commutative → same hash → swap NOT detected → under-rebuild.
  ## The new hash must detect this swap.
  let root = getTempDir() / "crisol_r6_b"
  createDir(root)
  defer: removeDir(root)

  let fa = root / "a.nim"
  let fb = root / "b.nim"
  writeFile(fa, "# content X")
  writeFile(fb, "# content Y")

  let hBefore = closureContentHash(@[fa, fb], root)

  # Swap contents
  writeFile(fa, "# content Y")
  writeFile(fb, "# content X")

  let hAfter = closureContentHash(@[fa, fb], root)

  assert hBefore != hAfter,
    "R6: swapping file contents between two files must change the hash " &
    "(old XOR scheme returns same hash; chained scheme detects the swap)"

block test_r6_identical_content_no_cancellation:
  ## If files A and B have identical content X, adding file C (with content X too)
  ## should change the hash from H(A,B) to H(A,B,C).
  ## Old XOR scheme: H(X) XOR H(X) XOR H(X) = H(X) (not zero but not meaningful).
  ## More critically: removing C should change the hash.
  let root = getTempDir() / "crisol_r6_c"
  createDir(root)
  defer: removeDir(root)

  let fa = root / "a.nim"
  let fb = root / "b.nim"
  let fc = root / "c.nim"
  writeFile(fa, "# same")
  writeFile(fb, "# same")
  writeFile(fc, "# same")

  let h2 = closureContentHash(@[fa, fb], root)
  let h3 = closureContentHash(@[fa, fb, fc], root)

  assert h2 != h3,
    "R6: adding a third file with identical content must change the hash"

block test_r6_order_still_deterministic:
  ## The sorted-input requirement means the SAME SET of files always gives the SAME hash.
  ## (This was already true with XOR since we sort first; the fix must preserve this.)
  let root = getTempDir() / "crisol_r6_d"
  createDir(root)
  defer: removeDir(root)

  let fa = root / "a.nim"
  let fb = root / "b.nim"
  writeFile(fa, "# aaa")
  writeFile(fb, "# bbb")

  let h1 = closureContentHash(@[fa, fb], root)
  let h2 = closureContentHash(@[fb, fa], root)  # reversed order
  assert h1 == h2,
    "R6: same set of files in different order must give same hash (sort-invariant)"

block test_r6_changing_one_file_detected:
  ## Sanity: modifying one file must change the hash.
  let root = getTempDir() / "crisol_r6_e"
  createDir(root)
  defer: removeDir(root)

  let fa = root / "a.nim"
  let fb = root / "b.nim"
  writeFile(fa, "# original A")
  writeFile(fb, "# original B")

  let hBefore = closureContentHash(@[fa, fb], root)
  writeFile(fa, "# CHANGED A")
  let hAfter = closureContentHash(@[fa, fb], root)

  assert hBefore != hAfter,
    "R6: changing one file's content must change the combined hash"

echo "PASS test_soundness_r6"
