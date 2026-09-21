#!/usr/bin/env python3
"""Generate (or verify) the editor TextMate grammars from the action registry.

Every other surface that knows what an ARO verb is — the language server, the
MCP server, REPL completion, `aro actions`, SOLARO — reads `AROCatalog`, which
is built from the runtime's registered actions. The three TextMate grammars
under `Editor/` were the exception: hand-maintained lists that had drifted
badly (GitLab #695).

  - `Editor/vscode-aro` listed 67 verbs against 130 in the runtime. None of the
    Git verbs (`Stage`, `Commit`, `Pull`, `Push`, `Clone`, `Checkout`, `Tag`)
    existed in any grammar, so ARO-0080 code highlighted as prose.
  - `Editor/intellij-aro` shipped *two* grammars with different contents, only
    one of which the plugin actually loads.
  - Both listed `Parameters` and `Watch`, which no runtime action implements.

A derived list cannot drift. This script owns the `actions` node of the
canonical grammar and writes the IntelliJ bundle as a byte-identical copy of
it, so "which grammar is right" stops being a question.

    python3 Scripts/generate-editor-grammars.py           # rewrite
    python3 Scripts/generate-editor-grammars.py --check    # verify only

Everything in the canonical grammar *except* `repository.actions` is still
hand-written and passes through untouched — edit it there and re-run this
script to propagate it to the bundle copy.

The verbs come from the same scrape `Scripts/generate-action-reference.py`
uses for ARO-0004 §11, imported rather than copied so the two cannot disagree
about what the runtime registers.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ACTION_REFERENCE = REPO_ROOT / "Scripts" / "generate-action-reference.py"

# The one grammar. Everything else is a copy of it.
CANONICAL = Path("Editor/vscode-aro/syntaxes/aro.tmLanguage.json")
COPIES = [
    Path("Editor/intellij-aro/src/main/resources/textmate/aro-bundle/syntaxes/aro.tmLanguage.json"),
]

# Runtime role -> (scope name, comment). `server` keeps the scope name
# `lifecycle` the grammars already used, so a theme that styles it keeps
# working; the other four already matched the runtime's own names.
ROLE_SCOPES = [
    ("request", "keyword.action.request.aro", "REQUEST actions - data coming IN"),
    ("own", "keyword.action.own.aro", "OWN actions - internal processing"),
    ("response", "keyword.action.response.aro", "RESPONSE actions - data going OUT"),
    ("export", "keyword.action.export.aro", "EXPORT actions - persistence/external"),
    ("server", "keyword.action.lifecycle.aro", "SERVER actions - lifecycle and services"),
]

GENERATED_NOTE = (
    "The `actions` patterns are generated from the runtime action registry by "
    "Scripts/generate-editor-grammars.py — do not hand-edit them, run the script."
)


def load_action_reference():
    """Import the sibling generator so the verb scrape is shared, not copied."""
    spec = importlib.util.spec_from_file_location("aro_action_reference", ACTION_REFERENCE)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {ACTION_REFERENCE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Camel casing that no type name carries. `createdirectory` is a *synonym* on
# `MakeAction`, so there is nothing to derive `CreateDirectory` from — the one
# case where the spelling has to be written down. A verb absent from this table
# simply gets its first letter raised.
CAMEL_SPELLINGS = {
    "createdirectory": "CreateDirectory",
}


def display_spellings(verb: str, action_name: str) -> set[str]:
    """Every casing a verb is plausibly written in.

    Verbs are stored lowercased in `static let verbs`, but ARO source spells
    them capitalised and a few are camel-cased. Two sources recover the camel
    form: the action's own *type* name, when the verb is the one that names it
    (`ParseHtmlAction` -> `ParseHtml` for `parsehtml`), and `CAMEL_SPELLINGS`
    for synonyms that name no type.

    The naive "raise the first letter" form is always included as well, because
    that is exactly what `AROCatalog.displayCase` produces and therefore what
    LSP completion inserts — `Parsehtml` should highlight just as `ParseHtml`
    does, since the parser matches verbs case-insensitively and both run.
    """
    spellings = {verb[:1].upper() + verb[1:]}
    if verb == action_name.lower():
        spellings.add(action_name)
    if verb in CAMEL_SPELLINGS:
        spellings.add(CAMEL_SPELLINGS[verb])
    return spellings


def verbs_by_role(actions: list[dict]) -> dict[str, list[str]]:
    grouped: dict[str, set[str]] = {}
    for action in actions:
        for verb in action["verbs"]:
            grouped.setdefault(action["role"], set()).update(
                display_spellings(verb, action["name"])
            )
    return {role: sorted(names) for role, names in grouped.items()}


def render_actions(grouped: dict[str, list[str]]) -> dict:
    patterns = []
    for role, scope, comment in ROLE_SCOPES:
        names = grouped.get(role, [])
        if not names:
            continue
        patterns.append(
            {
                "name": scope,
                "match": r"\b(" + "|".join(names) + r")\b",
                "comment": f"{comment} ({len(names)} verbs, generated)",
            }
        )
    unknown = sorted(set(grouped) - {role for role, _, _ in ROLE_SCOPES})
    if unknown:
        raise RuntimeError(
            "runtime declares action roles this script has no scope for: "
            + ", ".join(unknown)
            + " — add them to ROLE_SCOPES"
        )
    return {"patterns": patterns}


def render_grammar(current: dict, grouped: dict[str, list[str]]) -> str:
    grammar = dict(current)
    grammar["comment"] = GENERATED_NOTE
    repository = dict(grammar.get("repository", {}))
    repository["actions"] = render_actions(grouped)
    grammar["repository"] = repository
    return json.dumps(grammar, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify without rewriting")
    args = parser.parse_args()

    if not CANONICAL.exists():
        print(f"error: {CANONICAL} not found — run from the repository root")
        return 1

    actions = load_action_reference().collect_actions()
    if not actions:
        print("error: no actions found — run from the repository root")
        return 1

    grouped = verbs_by_role(actions)
    total = sum(len(names) for names in grouped.values())

    current = json.loads(CANONICAL.read_text(encoding="utf-8"))
    rendered = render_grammar(current, grouped)

    targets = [CANONICAL, *COPIES]

    if args.check:
        stale = [path for path in targets if not path.exists() or path.read_text(encoding="utf-8") != rendered]
        if stale:
            print(
                "error: editor grammars are out of date with the runtime "
                f"({total} verbs registered):\n  "
                + "\n  ".join(str(path) for path in stale)
                + "\n  Regenerate with: python3 Scripts/generate-editor-grammars.py"
            )
            return 1
        print(f"Editor grammars are up to date: {total} verbs across {len(targets)} files.")
        return 0

    for path in targets:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered, encoding="utf-8")
    print(f"Wrote {total} verbs into {len(targets)} grammar files.")
    for role, _, _ in ROLE_SCOPES:
        print(f"  {role}: {len(grouped.get(role, []))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
