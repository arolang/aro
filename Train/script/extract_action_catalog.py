#!/usr/bin/env python3
"""Extract the authoritative per-action catalog — role, trigger verbs (incl.
aliases), and valid prepositions — for every action the runtime registers.

This is the ground truth behind the grounded syntax_qa answers (issue #437):
per-verb role/preposition facts and NB19's fact-checked judging both read it.

**The binary is the ground truth** (GitLab #779). `aro actions list --format
json` reports the registry as the runtime assembled it, which the Swift-source
scan below cannot reproduce: several structs contribute verbs to one
registered action, and a dispatcher can take a verb away from the struct that
declares it (`parse` is ParseDispatch's, not ExtractAction's). Scanning the
sources instead left the catalog claiming `Store … in` was valid when
`aro check` rejects it, and counting a perfectly good `Reverse` as a
hallucinated verb because the action was missing entirely.

The Swift scan survives as the fallback for hosts with sources but no binary,
and supplies the `source:` file path the knowledge generator prints.

Regenerate after adding or changing an action:

    python3 Train/script/extract_action_catalog.py

Verify the committed copy is current (this is what CI runs):

    python3 Train/script/extract_action_catalog.py --check

Output: aro_action_catalog.json — {canonical_verb: {role, prepositions, aliases}}
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import aro_oracle  # noqa: E402

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

ROLE_LABEL = aro_oracle.ROLE_LABEL


def extract_from_sources():
    """Per-struct scan of Sources/ARORuntime. Fallback, and the source of the
    `source:` file paths."""
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


def _source_paths():
    """{verb: 'Sources/…swift'} from the struct scan, for attribution."""
    paths = {}
    for canonical, meta in extract_from_sources().items():
        for alias in meta["aliases"] + [canonical]:
            paths.setdefault(alias, meta["source"])
    return paths


def extract():
    """The catalog. Binary first, Swift scan when there is no binary."""
    if not aro_oracle.aro_bin():
        return extract_from_sources()
    catalog = aro_oracle.action_catalog()
    paths = _source_paths() if SRC.exists() else {}
    out = {}
    for verb, meta in catalog.items():
        source = paths.get(verb) or next(
            (paths[a] for a in meta["aliases"] if a in paths), "ActionRegistry")
        out[verb] = {
            "role": meta["role"],
            "role_label": meta["role_label"],
            "prepositions": meta["prepositions"],
            "aliases": meta["aliases"],
            "source": source,
        }
    return dict(sorted(out.items()))


def load():
    """Return the authoritative catalog. Falls back to the committed JSON when
    neither the binary nor the Swift sources are present (e.g. a training
    host with only the pipeline checked out)."""
    if OUT.exists():
        return json.loads(OUT.read_text())
    return extract()


def _serialize(catalog):
    return json.dumps(catalog, indent=1, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    if "--check" in sys.argv and not aro_oracle.aro_bin():
        # Refuse to compare the committed catalog against the fallback scan:
        # the scan is what produced the drift this check exists to catch.
        print("cannot verify the catalog without an `aro` binary — "
              "set ARO_BIN or build one.", file=sys.stderr)
        sys.exit(2)
    catalog = extract()
    text = _serialize(catalog)
    if "--check" in sys.argv:
        committed = OUT.read_text() if OUT.exists() else ""
        if committed != text:
            print(f"{OUT.name} is stale against {aro_oracle.aro_version()}.",
                  file=sys.stderr)
            print("Regenerate: python3 Train/script/extract_action_catalog.py",
                  file=sys.stderr)
            old = json.loads(committed) if committed else {}
            for verb in sorted(set(catalog) | set(old)):
                if catalog.get(verb) != old.get(verb):
                    print(f"  {verb}: committed={old.get(verb)} "
                          f"runtime={catalog.get(verb)}", file=sys.stderr)
            sys.exit(1)
        print(f"{OUT.name} matches the runtime ({len(catalog)} actions)")
        sys.exit(0)
    OUT.write_text(text)
    n_preps = sum(1 for v in catalog.values() if v["prepositions"])
    origin = "aro actions" if aro_oracle.aro_bin() else "Sources/ scan"
    print(f"wrote {len(catalog)} actions ({n_preps} with prepositions) "
          f"from {origin} -> {OUT}")
