#!/usr/bin/env python3
"""Assert ci/source-soundness-gate.sh compiles every .nim file under src/.

Invoked by that script, never on its own -- it reads the depfiles manifests the
gate's aggregator passes leave behind. Exits 0 when covered, 1 with the missing
module names when not, 2 when it cannot tell.

Round 5, R5-11. The gate's invocation list is chosen by hand; before this, the
claim that the list's union covered all of src/ lived in a comment that a reader
was told to re-verify manually. A new module out of src/crisol.nim's import
closure on all three targets, not named in the gate's OUT_OF_CLOSURE list, would
be in NO gate -- and the gate would still print OK. See the gate's own header.

Inputs, all via the environment so the gate stays the single source of truth for
which modules and targets are gated:
  MANIFEST_DIR  one nimcache subdirectory per target, each holding crisol.json
  TARGETS       space-separated target names (the subdirectory names)
  GATED_MAINS   space-separated repo-relative main files gated individually
"""

import json
import os
import sys

SRC = "src"


def fail(msg, code=2):
    sys.stderr.write("assert-gate-coverage: %s\n" % msg)
    sys.exit(code)


def tracked_sources():
    """Every .nim file under src/, as repo-relative slash-separated paths.

    The filesystem, deliberately, not `git ls-files`: a module that is real but
    not yet committed is still shipped to a consumer that vendors the tree, and
    is exactly the kind of new file this check is for. The cost is that a stray
    scratch .nim under src/ fails the gate, which is the right direction.
    """
    out = set()
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.endswith(".nim"):
                out.add(os.path.join(dirpath, name).replace(os.sep, "/"))
    return out


def compiled_by(manifest_path, repo_root):
    """The src/ modules named in one manifest's depfiles key."""
    try:
        with open(manifest_path, "r") as fh:
            data = json.load(fh)
    except (IOError, OSError) as exc:
        fail("cannot read manifest %s (%s).\n  The gate's aggregator pass must "
             "run before this check." % (manifest_path, exc))
    except ValueError as exc:
        fail("manifest %s is not valid JSON (%s)" % (manifest_path, exc))

    if "depfiles" not in data:
        fail("manifest %s has no 'depfiles' key -- the aggregator pass must "
             "pass -d:nimBetterRun, which is what emits it." % manifest_path)

    out = set()
    for entry in data["depfiles"]:
        # Entries are [path, hash]; older/newer Nim may emit a bare path.
        path = entry[0] if isinstance(entry, (list, tuple)) else entry
        rel = os.path.relpath(os.path.realpath(path), repo_root)
        rel = rel.replace(os.sep, "/")
        if rel.startswith(SRC + "/") and rel.endswith(".nim"):
            out.add(rel)
    return out


def main():
    if not os.path.isdir(SRC):
        fail("run me from the repo root (no %s/ directory)" % SRC)

    manifest_dir = os.environ.get("MANIFEST_DIR", "")
    targets = os.environ.get("TARGETS", "").split()
    gated_mains = os.environ.get("GATED_MAINS", "").split()
    if not manifest_dir:
        fail("MANIFEST_DIR is unset; the gate sets it")
    if not targets:
        fail("TARGETS is unset or empty; the gate sets it")

    repo_root = os.path.realpath(os.getcwd())

    covered = set()
    per_target = {}
    for target in targets:
        manifest = os.path.join(manifest_dir, target, "crisol.json")
        reached = compiled_by(manifest, repo_root)
        if not reached:
            fail("the --os:%s manifest names no file under %s/ at all, which "
                 "cannot be right" % (target, SRC))
        per_target[target] = reached
        covered |= reached

    # An individually gated main file counts for itself only -- see the gate's
    # comment on conservative crediting.
    explicit = set(m.replace(os.sep, "/") for m in gated_mains)
    missing_mains = sorted(m for m in explicit if not os.path.isfile(m))
    if missing_mains:
        fail("the gate names main files that do not exist: %s"
             % " ".join(missing_mains))
    covered |= explicit

    tracked = tracked_sources()
    uncovered = sorted(tracked - covered)

    if uncovered:
        sys.stderr.write(
            "assert-gate-coverage: FAIL -- %d of %d files under %s/ are "
            "compiled by no pass of the soundness gate:\n"
            % (len(uncovered), len(tracked), SRC))
        for path in uncovered:
            sys.stderr.write("    %s\n" % path)
        sys.stderr.write(
            "\n  These are invisible to --warningAsError:UnusedImport and\n"
            "  --warningAsError:Deprecated, so a consumer building with either\n"
            "  flag can hit a hard error the gate reported clean.\n"
            "\n  Fix by making each reachable from a pass, not by editing this\n"
            "  check: add it to OUT_OF_CLOSURE in ci/source-soundness-gate.sh if\n"
            "  it is a module no target's closure reaches, or give it an import\n"
            "  edge from something that is already covered.\n")
        sys.exit(1)

    reach = ", ".join("%s %d" % (t, len(per_target[t])) for t in targets)
    print("gate coverage: %d of %d files under %s/ compiled "
          "(per-target closure reach: %s)"
          % (len(tracked), len(tracked), SRC, reach))
    return 0


if __name__ == "__main__":
    sys.exit(main())
