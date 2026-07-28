#!/usr/bin/env python3
"""Extract the authoritative ARO action-verb set from the runtime ActionRegistry
(Sources/ARORuntime/Actions/**/*.swift) and write it to aro_action_verbs.json.

This is the ground truth for verb validity — every `verbs: Set<String> = [...]`
declaration, including aliases (create/build/construct, update/modify/set, ...).
The knowledge.json-derived verb list used by NB19's hallucination metric was
missing 16 of these (update, set, modify, insert, join, respond, ...), so valid
verbs were miscounted as hallucinations (issue #436). Regenerate after adding or
renaming an action:

    python3 Train/script/extract_action_verbs.py
"""
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "Sources" / "ARORuntime"
OUT = Path(__file__).resolve().parent / "aro_action_verbs.json"

_VERBS_RE = re.compile(r"verbs:\s*Set<String>\s*=\s*\[([^\]]*)\]")
_STR_RE = re.compile(r'"([^"]+)"')


def extract():
    verbs = set()
    for f in SRC.rglob("*.swift"):
        for m in _VERBS_RE.finditer(f.read_text(errors="ignore")):
            for q in _STR_RE.findall(m.group(1)):
                verbs.add(q.lower())
    return sorted(verbs)


def load():
    """Return the authoritative verb set (lowercased). Falls back to the
    committed JSON when the Swift sources aren't present (e.g. training host)."""
    if OUT.exists():
        return set(json.loads(OUT.read_text()))
    return set(extract())


if __name__ == "__main__":
    verbs = extract()
    OUT.write_text(json.dumps(verbs, indent=1) + "\n")
    print(f"wrote {len(verbs)} authoritative ARO action verbs -> {OUT}")
