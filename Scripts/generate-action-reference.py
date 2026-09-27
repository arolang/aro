#!/usr/bin/env python3
"""Generate (or verify) ARO-0004's built-in action reference from the runtime.

ARO-0004 §11 is titled "Complete Built-in Actions Reference" and is the
authoritative spec for action names, roles and prepositions. It was maintained by
hand and had drifted from the code in several ways at once (GitLab #480):

  - it listed 48 actions; the runtime registers 70;
  - `Store` was documented with role `export`, but StoreAction declares
    `.response`;
  - `Store` was documented as accepting `in`, which is not a Preposition case at
    all — `Preposition.in` is an alias for `.into` and the lexer has no `in`
    token, so `Store the <x> in the <repo>.` does not parse;
  - `Execute` was documented as accepting only `with`, but it accepts
    `for, on, with` — and the documented example in Examples/SystemMonitor uses
    `for`;
  - the wait action was named `Keepalive` in the spec and `WaitForEvents` in the
    registry.

Generating the table removes the whole class of problem: it cannot drift if it is
derived. Run with `--check` in CI to fail when the committed table no longer
matches the code.

    python3 Scripts/generate-action-reference.py            # rewrite the table
    python3 Scripts/generate-action-reference.py --check     # verify only

The table is delimited in ARO-0004 by the BEGIN/END marker comments below;
everything between them is owned by this script.
"""

from __future__ import annotations

import argparse
import glob
import re
import sys

PROPOSAL = "Proposals/ARO-0004-actions.md"
INDEX = "Proposals/README.md"
BEGIN = "<!-- BEGIN GENERATED ACTION TABLE -->"
END = "<!-- END GENERATED ACTION TABLE -->"

# Per-role tables in ARO-0004 §2.1-§2.5, and the role summary in Proposals/README.md.
# Same reason as §11: the prose tables listed different verbs and prepositions
# from the generated one two screens below them (GitLab #831).
ROLE_BEGIN = "<!-- BEGIN GENERATED ROLE TABLE: {role} -->"
ROLE_END = "<!-- END GENERATED ROLE TABLE: {role} -->"
SUMMARY_BEGIN = "<!-- BEGIN GENERATED ROLE SUMMARY -->"
SUMMARY_END = "<!-- END GENERATED ROLE SUMMARY -->"

ROLES = ["request", "own", "response", "export", "server"]

# `Preposition.in` and `.through` are aliases declared in ServerActions.swift,
# not enum cases. Resolve them so the table never documents a preposition the
# lexer cannot tokenise.
PREPOSITION_ALIASES = {"in": "into", "through": "via"}


def strip_comments(source: str) -> str:
    """Blank out line and block comments, preserving offsets.

    Necessary because `ActionProtocol.swift` documents the protocol with a
    `/// public struct ExtractAction: ActionImplementation {` example, which a
    naive scan counts as a 71st action.
    """
    out = list(source)
    index, length = 0, len(source)
    while index < length:
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end == -1 else end
            for position in range(index, end):
                out[position] = " "
            index = end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            for position in range(index, end):
                if out[position] != "\n":
                    out[position] = " "
            index = end
        elif source[index] == '"':
            # Skip string literals so a brace or `//` inside one is not treated
            # as code or as a comment start.
            index += 1
            while index < length and source[index] != '"':
                index += 2 if source[index] == "\\" else 1
            index += 1
        else:
            index += 1
    return "".join(out)


def type_bodies(source: str):
    """Yield (name, conformances, body) for each type, using brace matching."""
    pattern = re.compile(r"\b(?:public\s+)?(?:struct|final class|class)\s+(\w+)\s*(:[^{]*)?\{")
    for match in pattern.finditer(source):
        name, conformances = match.group(1), match.group(2) or ""
        index, depth = match.end() - 1, 0
        while index < len(source):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        yield name, conformances, source[match.end() : index]


DOC_COMMENT = re.compile(
    r"((?:^[ \t]*///[^\n]*\n)+)[ \t]*(?:public\s+)?(?:struct|final class|class)\s+(\w+)\s*:",
    re.MULTILINE,
)


def doc_summaries(source: str) -> dict[str, str]:
    """First doc-comment line of each type, keyed by type name.

    The Description column of the §2 tables used to be written by hand and was
    the part that drifted furthest. Taking it from the implementation's own
    summary line means the table describes the action that exists.
    """
    summaries: dict[str, str] = {}
    for match in DOC_COMMENT.finditer(source):
        lines = [line.strip().lstrip("/").strip() for line in match.group(1).strip().split("\n")]

        # The summary is the doc comment's first sentence, which may wrap over
        # several lines. Stop at a blank line or any markdown structure.
        collected: list[str] = []
        for line in lines:
            if not line or line.startswith(("#", "```", "|", "-", ">", "*", "/")):
                break
            collected.append(line)
            if line.endswith("."):
                break
        if not collected:
            continue

        summary = " ".join(collected)
        sentence = re.split(r"(?<=[a-z0-9)`])\.\s", summary, maxsplit=1)[0]
        summaries[match.group(2)] = sentence.rstrip(". ")
    return summaries


def collect_actions() -> list[dict]:
    """Every type conforming to ActionImplementation / SynchronousAction."""
    actions: list[dict] = []

    for path in sorted(glob.glob("Sources/ARORuntime/**/*.swift", recursive=True)):
        with open(path, encoding="utf-8") as handle:
            raw = handle.read()
        summaries = doc_summaries(raw)
        source = strip_comments(raw)

        for name, conformances, body in type_bodies(source):
            if "ActionImplementation" not in conformances and "SynchronousAction" not in conformances:
                continue

            role = re.search(r"static let role:\s*ActionRole\s*=\s*\.(\w+)", body)
            verbs = re.search(r"static let verbs:\s*Set<String>\s*=\s*\[([^\]]*)\]", body)
            preps = re.search(r"static let validPrepositions:\s*Set<Preposition>\s*=\s*\[([^\]]*)\]", body)
            if not (role and verbs and preps):
                continue

            def split(raw: str) -> list[str]:
                return [item.strip().strip('"').lstrip(".").strip("`") for item in raw.split(",") if item.strip()]

            resolved = sorted({PREPOSITION_ALIASES.get(p, p) for p in split(preps.group(1))})
            display = name[:-6] if name.endswith("Action") else name

            actions.append(
                {
                    "name": display,
                    "role": role.group(1),
                    "verbs": sorted(split(verbs.group(1))),
                    "prepositions": resolved,
                    "summary": summaries.get(name, ""),
                }
            )

    actions.sort(key=lambda a: a["name"])
    return actions


def user_facing(actions: list[dict]) -> list[dict]:
    """Actions you can actually write.

    `ParseLinkHeaderAction` conforms to the protocol and is registered, but
    declares no verbs of its own — `ParseDispatchAction` owns `parse` and calls
    it for the `link-header` qualifier (GitLab #521). Counting it made the
    reference claim 72 actions where `aro actions` prints 71.
    """
    return [action for action in actions if action["verbs"]]


def render(actions: list[dict]) -> str:
    lines = [
        BEGIN,
        "",
        "<!-- Generated by Scripts/generate-action-reference.py — do not edit by hand. -->",
        "<!-- Regenerate with: python3 Scripts/generate-action-reference.py -->",
        "",
        f"All {len(actions)} actions registered by the runtime, with the role, verbs and",
        "prepositions each one declares.",
        "",
        "| # | Action | Role | Verbs | Prepositions |",
        "|---|--------|------|-------|--------------|",
    ]
    for index, action in enumerate(actions, start=1):
        lines.append(
            f"| {index} | {action['name']} | {action['role']} | "
            f"{', '.join(action['verbs'])} | {', '.join(action['prepositions'])} |"
        )
    lines += ["", END]
    return "\n".join(lines)


GENERATED_NOTE = [
    "<!-- Generated by Scripts/generate-action-reference.py — do not edit by hand. -->",
    "<!-- Regenerate with: python3 Scripts/generate-action-reference.py -->",
]


def render_role_table(role: str, actions: list[dict]) -> str:
    """One §2.x table: every action the runtime gives this role."""
    members = [action for action in actions if action["role"] == role]
    lines = [ROLE_BEGIN.format(role=role), ""] + GENERATED_NOTE + [
        "",
        "| Action | Verbs | Prepositions | Description |",
        "|--------|-------|--------------|-------------|",
    ]
    for action in members:
        lines.append(
            f"| **{action['name']}** | {', '.join(action['verbs'])} | "
            f"{', '.join(action['prepositions'])} | {action['summary']} |"
        )
    lines += ["", ROLE_END.format(role=role)]
    return "\n".join(lines)


def render_role_summary(actions: list[dict]) -> str:
    """The Role -> Actions grid in Proposals/README.md."""
    lines = [SUMMARY_BEGIN, ""] + GENERATED_NOTE + [
        "",
        "| Role | Actions |",
        "|------|---------|",
    ]
    for role in ROLES:
        members = [action["name"] for action in actions if action["role"] == role]
        lines.append(f"| {role.upper()} | {', '.join(members)} |")
    lines += ["", SUMMARY_END]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLAUDE.md's role summary (GitLab #846)
# ---------------------------------------------------------------------------
# CLAUDE.md is the file an agent reads first, and it kept a sixth hand-written
# copy of the taxonomy: it put `Store`, `Log` and `Send` under EXPORT, where the
# code puts them under RESPONSE, and left the `server` role out altogether.
#
# The summary stays hand-picked — it names a handful of representative actions
# per role rather than all of them, which is the whole point of a summary — so
# it is *verified* rather than generated: every name it prints must resolve, in
# the runtime, to the role the bullet claims. A name may be a verb (`Extract`)
# or an action type (`WaitForEvents`); both spellings appear in the file and
# both are checkable.

CLAUDE_MD = "CLAUDE.md"
CLAUDE_SECTION = "### Action Semantic Roles"
CLAUDE_BULLET = re.compile(r"^- \*\*([A-Z]+)\*\* \(([^)]*)\):", re.MULTILINE)


def claude_md_section(document: str) -> str:
    """The Action Semantic Roles section, up to the next heading."""
    if CLAUDE_SECTION not in document:
        raise SystemExit(f"error: {CLAUDE_MD} is missing the '{CLAUDE_SECTION}' section")
    start = document.index(CLAUDE_SECTION) + len(CLAUDE_SECTION)
    rest = document[start:]
    end = rest.find("\n### ")
    return rest if end == -1 else rest[:end]


def check_claude_md(actions: list[dict]) -> list[str]:
    """Problems with CLAUDE.md's role bullets, as human-readable lines."""
    with open(CLAUDE_MD, encoding="utf-8") as handle:
        section = claude_md_section(handle.read())

    by_verb = {verb: action for action in actions for verb in action["verbs"]}
    by_name = {action["name"].lower(): action for action in actions}

    problems: list[str] = []
    seen: set[str] = set()
    for match in CLAUDE_BULLET.finditer(section):
        role = match.group(1).lower()
        seen.add(role)
        if role not in ROLES:
            problems.append(f"{role.upper()} is not a role; the five are {', '.join(r.upper() for r in ROLES)}")
            continue
        for raw in match.group(2).split(","):
            name = raw.strip().strip("*`").strip()
            if not name:
                continue
            action = by_verb.get(name.lower()) or by_name.get(name.lower())
            if action is None:
                problems.append(f"{role.upper()} names {name}, which is neither a registered verb nor an action")
            elif action["role"] != role:
                problems.append(
                    f"{role.upper()} names {name}, but the runtime gives "
                    f"{action['name']} the role {action['role']}"
                )

    for role in ROLES:
        if role not in seen:
            problems.append(f"the {role.upper()} role has no bullet")
    return problems


def splice(document: str, begin: str, end: str, replacement: str, path: str) -> str:
    if begin not in document or end not in document:
        raise SystemExit(f"error: {path} is missing the {begin} / {end} markers")
    prefix = document[: document.index(begin)]
    suffix = document[document.index(end) + len(end) :]
    return prefix + replacement + suffix


def rewrite(path: str, actions: list[dict]) -> str:
    """Return `path`'s content with every generated block refreshed."""
    with open(path, encoding="utf-8") as handle:
        document = handle.read()

    if path == PROPOSAL:
        document = splice(document, BEGIN, END, render(actions), path)
        for role in ROLES:
            begin, end = ROLE_BEGIN.format(role=role), ROLE_END.format(role=role)
            document = splice(document, begin, end, render_role_table(role, actions), path)
    elif path == INDEX:
        document = splice(document, SUMMARY_BEGIN, SUMMARY_END, render_role_summary(actions), path)

    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify without rewriting")
    args = parser.parse_args()

    actions = user_facing(collect_actions())
    if not actions:
        print("error: no actions found — run from the repository root")
        return 1

    stale = []
    for path in (PROPOSAL, INDEX):
        with open(path, encoding="utf-8") as handle:
            current = handle.read()
        updated = rewrite(path, actions)
        if updated == current:
            continue
        if args.check:
            stale.append(path)
            continue
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)
        print(f"Updated the generated tables in {path}.")

    # CLAUDE.md's summary is verified in both modes: it is a hand-picked list,
    # so there is nothing to rewrite, but a wrong role there is the same bug
    # (GitLab #846).
    problems = check_claude_md(actions)

    if args.check:
        if stale:
            print(
                "error: the generated action tables are out of date with the runtime "
                f"({len(actions)} actions registered):\n"
                + "".join(f"    {path}\n" for path in stale)
                + "  Regenerate with: python3 Scripts/generate-action-reference.py"
            )
            return 1
        if not problems:
            print(f"Action reference is up to date: {len(actions)} actions.")

    if problems:
        print(
            f"error: {CLAUDE_MD}'s Action Semantic Roles disagree with the runtime:\n"
            + "".join(f"    {problem}\n" for problem in problems)
            + "  `aro actions` prints the live table; fix the bullets to match it."
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
