#!/usr/bin/env python3
"""Validate proposal identifiers and references across the repository.

`Proposals/` is the project's top-priority source of truth (see CLAUDE.md), so an
ambiguous or dangling identifier there is a real defect. Before this check:

  - four proposals all claimed ARO-0052, three of them marked Implemented, so
    "see ARO-0052" resolved to four different documents;
  - ARO-0053, ARO-0067 and ARO-0073 were each claimed twice;
  - ARO-0056 and ARO-0052-numeric-separators specified the same feature and were
    both Implemented, so neither was definitive;
  - eleven `ARO-00NN` references in Sources/ pointed at proposals that do not
    exist — eight of them were GitLab issue numbers written in proposal form.

See GitLab #481.

Checks performed:

  1. Every proposal's filename prefix is a unique ARO-NNNN identifier.
  2. The ID in the front matter matches the filename.
  3. Every `ARO-NNNN` reference in Sources/, Proposals/ and CLAUDE.md resolves to
     an existing proposal.

Exit status is 0 when clean, 1 otherwise. Run from the repository root:

    python3 Scripts/check-proposals.py
"""

from __future__ import annotations

import glob
import os
import re
import sys

PROPOSAL_GLOB = "Proposals/ARO-*.md"
REFERENCE_GLOBS = ("Sources/**/*.swift", "Proposals/**/*.md", "CLAUDE.md")

# References that are known not to resolve and are accepted for now. Keep this
# empty if you can: an entry here is documentation debt, not a fix. Listing them
# means the set cannot grow silently.
KNOWN_DANGLING: dict[str, str] = {
    # ARO-0014 lists `Requires: ARO-0001, ARO-0006, ARO-0012`, but ARO-0012 was
    # never written and its intended subject is not recoverable from context —
    # GitLab #12 is an unrelated example request, so it is not the
    # issue-number mistake the others were. Left for whoever knows what the
    # domain-modeling proposal was meant to depend on: either write ARO-0012,
    # or correct ARO-0014's Requires line and delete this entry.
    "0012": "referenced by ARO-0014 Requires; intended subject unknown",
}

ID_PATTERN = re.compile(r"ARO-(\d{4})")


def proposal_ids() -> tuple[dict[str, str], list[str]]:
    """Map ARO id -> path, collecting duplicate-id errors."""
    by_id: dict[str, str] = {}
    errors: list[str] = []

    for path in sorted(glob.glob(PROPOSAL_GLOB)):
        match = ID_PATTERN.search(os.path.basename(path))
        if not match:
            errors.append(f"{path}: filename does not start with an ARO-NNNN identifier")
            continue
        ident = match.group(1)
        if ident in by_id:
            errors.append(
                f"ARO-{ident} is claimed by two proposals:\n"
                f"    {by_id[ident]}\n"
                f"    {path}\n"
                f"  Renumber the later one and add a 'Renumbered from' note."
            )
            continue
        by_id[ident] = path

    return by_id, errors


def front_matter_errors(by_id: dict[str, str]) -> list[str]:
    """Each document's self-declared ID must match its filename."""
    errors: list[str] = []

    for ident, path in sorted(by_id.items()):
        with open(path, encoding="utf-8") as handle:
            head = handle.read(4000)

        declared = {
            m.group(1)
            for m in ID_PATTERN.finditer(head)
            # A "Renumbered from ARO-XXXX" note legitimately names the old ID, and
            # Requires/Supersedes lines legitimately name other proposals.
            if not re.search(
                r"(Renumbered from|Requires|Supersedes|Superseded by|Related)[^\n]*$",
                head[: m.start()].split("\n")[-1],
            )
        }
        if declared and ident not in declared:
            errors.append(
                f"{path}: front matter declares ARO-{sorted(declared)[0]} "
                f"but the filename says ARO-{ident}"
            )

    return errors


def reference_errors(by_id: dict[str, str]) -> list[str]:
    """Every ARO-NNNN reference must resolve to a proposal that exists."""
    errors: list[str] = []
    seen: dict[str, set[str]] = {}

    for pattern in REFERENCE_GLOBS:
        for path in glob.glob(pattern, recursive=True):
            with open(path, encoding="utf-8", errors="ignore") as handle:
                for lineno, line in enumerate(handle, start=1):
                    for match in ID_PATTERN.finditer(line):
                        ident = match.group(1)
                        if ident in by_id or ident in KNOWN_DANGLING:
                            continue
                        seen.setdefault(ident, set()).add(f"{path}:{lineno}")

    for ident in sorted(seen):
        sites = sorted(seen[ident])
        shown = "\n    ".join(sites[:5])
        more = f"\n    … and {len(sites) - 5} more" if len(sites) > 5 else ""
        errors.append(
            f"ARO-{ident} is referenced but no such proposal exists:\n    {shown}{more}\n"
            f"  Either create it, point the reference at the right proposal, or — if "
            f"this is a GitLab issue number — write it as 'GitLab #{int(ident)}'."
        )

    return errors


def main() -> int:
    if not os.path.isdir("Proposals"):
        print("error: run from the repository root (no Proposals/ directory here)")
        return 1

    by_id, errors = proposal_ids()
    errors += front_matter_errors(by_id)
    errors += reference_errors(by_id)

    if errors:
        print(f"Proposal check failed with {len(errors)} problem(s):\n")
        for error in errors:
            print(f"  - {error}\n")
        return 1

    print(f"Proposal check passed: {len(by_id)} proposals, all IDs unique and all references resolve.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
