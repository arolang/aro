#!/usr/bin/env python3
"""Extract the authoritative per-action catalog from the runtime ActionRegistry
(Sources/ARORuntime/**/*.swift) — role, trigger verbs (incl. aliases), and valid
prepositions — straight from each `ActionImplementation` struct declaration.

This is the ground truth behind the grounded syntax_qa answers (issue #437):
per-verb role/preposition facts and NB19's fact-checked judging both read it.
Regenerate after adding or changing an action:

    python3 Train/script/extract_action_catalog.py

Output: aro_action_catalog.json — {canonical_verb: {role, prepositions, aliases}}
where canonical_verb is the first verb listed for the struct.
"""
import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "Sources" / "ARORuntime"
OUT = Path(__file__).resolve().parent / "aro_action_catalog.json"

# Split source into per-struct chunks, keep only ActionImplementation structs.
# Actions conform directly to ActionImplementation or via the SynchronousAction
# convenience protocol (ReturnAction, ThrowAction, ComputeAction, PublishAction…).
_STRUCT_RE = re.compile(
    r"struct\s+(\w+)\s*:\s*[^{]*\b(?:ActionImplementation|SynchronousAction)\b[^{]*\{",
    re.DOTALL)
_ROLE_RE = re.compile(r"static\s+let\s+role\s*:\s*ActionRole\s*=\s*\.(\w+)")
_VERBS_RE = re.compile(r"static\s+let\s+verbs\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]")
_PREPS_RE = re.compile(
    r"static\s+let\s+validPrepositions\s*:\s*Set<Preposition>\s*=\s*\[([^\]]*)\]")
_STR_RE = re.compile(r'"([^"]+)"')
_DOT_RE = re.compile(r"\.(\w+)")

ROLE_LABEL = {
    "request": "REQUEST (External → Internal)",
    "own": "OWN (Internal → Internal)",
    "response": "RESPONSE (Internal → External)",
    "export": "EXPORT (makes symbols global / exports data)",
    "server": "SERVER (service lifecycle operations)",
}


def extract():
    catalog = {}
    for f in sorted(SRC.rglob("*.swift")):
        text = f.read_text(errors="ignore")
        # Window each struct from its declaration to the next struct (or a
        # bounded fallback). role/verbs/validPrepositions always appear in the
        # first lines, so a boundary window is more robust than brace-balancing
        # (which trips on `{` inside string literals and doc comments).
        matches = list(_STRUCT_RE.finditer(text))
        for idx, m in enumerate(matches):
            end = matches[idx + 1].start() if idx + 1 < len(matches) else m.start() + 2000
            body = text[m.start():end]
            role_m = _ROLE_RE.search(body)
            verbs_m = _VERBS_RE.search(body)
            if not (role_m and verbs_m):
                continue
            verbs = [v.lower() for v in _STR_RE.findall(verbs_m.group(1))]
            if not verbs:
                continue
            preps_m = _PREPS_RE.search(body)
            preps = _DOT_RE.findall(preps_m.group(1)) if preps_m else []
            canonical = verbs[0]
            catalog[canonical] = {
                "role": role_m.group(1),
                "role_label": ROLE_LABEL.get(role_m.group(1), role_m.group(1)),
                "prepositions": preps,
                "aliases": verbs,
                "source": str(f.relative_to(REPO)),
            }
    return dict(sorted(catalog.items()))


def load():
    """Return the authoritative catalog. Falls back to the committed JSON when
    the Swift sources aren't present (e.g. on the training host)."""
    if OUT.exists():
        return json.loads(OUT.read_text())
    return extract()


if __name__ == "__main__":
    catalog = extract()
    OUT.write_text(json.dumps(catalog, indent=1) + "\n")
    n_preps = sum(1 for v in catalog.values() if v["prepositions"])
    print(f"wrote {len(catalog)} actions ({n_preps} with prepositions) -> {OUT}")
