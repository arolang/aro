#!/usr/bin/env python3
"""Extract the authoritative ARO action-verb set and write it to
aro_action_verbs.json.

This is the ground truth for verb validity — every verb the ActionRegistry
answers to, aliases included (create/build/construct, update/modify/set, …).
The knowledge.json-derived verb list used by NB19's hallucination metric was
missing 16 of these (update, set, modify, insert, join, respond, …), so valid
verbs were miscounted as hallucinations (issue #436).

**The binary is the ground truth** (GitLab #779): `aro actions list --format
json` reports the registry the runtime actually assembled. The Swift-source
scan below is the fallback for a host with sources but no binary; it had
drifted two verbs behind — `reverse` and `flip` were missing, so every pair
using the perfectly valid `Reverse` action was dropped as hallucinated.

Regenerate after adding or renaming an action:

    python3 Train/script/extract_action_verbs.py

Verify the committed copy is current (this is what CI runs):

    python3 Train/script/extract_action_verbs.py --check
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aro_oracle  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "Sources" / "ARORuntime"
OUT = Path(__file__).resolve().parent / "aro_action_verbs.json"

_VERBS_RE = re.compile(r"verbs:\s*Set<String>\s*=\s*\[([^\]]*)\]")
_STR_RE = re.compile(r'"([^"]+)"')


def extract_from_sources():
    verbs = set()
    for f in SRC.rglob("*.swift"):
        for m in _VERBS_RE.finditer(f.read_text(errors="ignore")):
            for q in _STR_RE.findall(m.group(1)):
                verbs.add(q.lower())
    return sorted(verbs)


def extract():
    if aro_oracle.aro_bin():
        return aro_oracle.action_verbs()
    return extract_from_sources()


def load():
    """Return the authoritative verb set (lowercased). Falls back to the
    committed JSON when neither binary nor sources are present."""
    if OUT.exists():
        return set(json.loads(OUT.read_text()))
    return set(extract())


if __name__ == "__main__":
    if "--check" in sys.argv and not aro_oracle.aro_bin():
        print("cannot verify the verb set without an `aro` binary — "
              "set ARO_BIN or build one.", file=sys.stderr)
        sys.exit(2)
    verbs = extract()
    text = json.dumps(verbs, indent=1) + "\n"
    if "--check" in sys.argv:
        committed = OUT.read_text() if OUT.exists() else ""
        if committed != text:
            old = set(json.loads(committed)) if committed else set()
            print(f"{OUT.name} is stale against {aro_oracle.aro_version()}.",
                  file=sys.stderr)
            print(f"  missing: {sorted(set(verbs) - old)}", file=sys.stderr)
            print(f"  extra:   {sorted(old - set(verbs))}", file=sys.stderr)
            print("Regenerate: python3 Train/script/extract_action_verbs.py",
                  file=sys.stderr)
            sys.exit(1)
        print(f"{OUT.name} matches the runtime ({len(verbs)} verbs)")
        sys.exit(0)
    OUT.write_text(text)
    origin = "aro actions" if aro_oracle.aro_bin() else "Sources/ scan"
    print(f"wrote {len(verbs)} authoritative ARO action verbs "
          f"from {origin} -> {OUT}")
