#!/usr/bin/env python3
"""Generate (or verify) the derivable half of the Construction Studies' grammar appendix.

Appendix B is the book's formal-grammar reference. Three of its sections are
not prose at all — they are tables that exist in the parser already, and every
one of them had drifted (GitLab #836):

  - **Precedence** claimed `not` was a level-2 prefix operator binding tighter
    than any comparison, with a worked example (`not <n> >= 3` grouping as
    `(not <n>) >= 3`) that inverts what the parser does. `Parser.swift` puts
    `not` at level 3, *below* the comparisons, as in Python. The appendix also
    predated the `default` level entirely.
  - **Prepositions** were listed by hand in a book that also states there are
    exactly ten of them.
  - **Reserved Words** mixed real lexer keywords with status-code names and
    feature-set labels that the lexer has never reserved.

A table cannot drift if it is derived, so these three are generated from
`Sources/AROParser/{Parser,Token,Lexer}.swift` and delimited by the BEGIN/END
markers below. Everything between them belongs to this script.

    python3 Book/TheConstructionStudies/generate-grammar-appendix.py
    python3 Book/TheConstructionStudies/generate-grammar-appendix.py --check

What is *not* generated is the EBNF itself. ARO's grammar lives in a
hand-written recursive-descent parser — there is no table to read it off, and
extracting one would mean changing the parser. The productions above these
tables are therefore maintained by hand, and checked against `aro check` when
they change.

Run from the repository root.
"""

from __future__ import annotations

import argparse
import re
import sys

APPENDIX = "Book/TheConstructionStudies/AppendixB-Grammar.md"
PARSER = "Sources/AROParser/Parser.swift"
TOKEN = "Sources/AROParser/Token.swift"
LEXER = "Sources/AROParser/Lexer.swift"

BEGIN = "<!-- BEGIN GENERATED GRAMMAR TABLES -->"
END = "<!-- END GENERATED GRAMMAR TABLES -->"

# How the lexer's comment headings group its reserved words, and the order the
# appendix presents them in. A group the lexer gains and this map does not know
# about still appears, under its own heading, at the end.
GROUP_TITLES = {
    "Keywords - Core": "Core",
    "Keywords - Control Flow": "Control flow",
    "Keywords - Iteration": "Iteration",
    "Keywords - While Loop": "Loops",
    "Keywords - Types": "Types",
    "Keywords - Error Handling": "Error handling",
    "Keywords - Logical Operators": "Operators and value keywords",
    "Boolean literals": "Boolean literals",
    "Articles": "Articles",
    "Prepositions": "Prepositions",
}


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def precedence_levels() -> list[tuple[str, int, str]]:
    """(case name, level, operator comment) from Parser.swift's Precedence enum."""
    source = read(PARSER)
    match = re.search(r"private enum Precedence: Int, Comparable \{(.*?)\n\}", source, re.DOTALL)
    if not match:
        raise SystemExit(f"error: no Precedence enum found in {PARSER}")

    levels: list[tuple[str, int, str]] = []
    for line in match.group(1).splitlines():
        entry = re.match(r"\s*case\s+(\w+)\s*=\s*(\d+)\s*(?://\s*(.*))?$", line)
        if entry:
            levels.append((entry.group(1), int(entry.group(2)), (entry.group(3) or "").strip()))
    if not levels:
        raise SystemExit(f"error: Precedence enum in {PARSER} has no cases")
    return levels


def prepositions() -> list[str]:
    source = read(TOKEN)
    match = re.search(r"public enum Preposition: String[^{]*\{(.*?)\n\}", source, re.DOTALL)
    if not match:
        raise SystemExit(f"error: no Preposition enum found in {TOKEN}")
    found = re.findall(r'case\s+`?\w+`?\s*=\s*"([^"]+)"', match.group(1))
    if not found:
        raise SystemExit(f"error: Preposition enum in {TOKEN} has no cases")
    return found


def reserved_words() -> list[tuple[str, list[str]]]:
    """(group heading, words) from the lexer's single reservedWords table."""
    source = read(LEXER)
    match = re.search(
        r"private static let reservedWords: \[String: ReservedWord\] = \[(.*?)\n\s*\]",
        source,
        re.DOTALL,
    )
    if not match:
        raise SystemExit(f"error: no reservedWords table found in {LEXER}")

    groups: list[tuple[str, list[str]]] = []
    current = "Other"
    seen: dict[str, list[str]] = {}
    order: list[str] = []

    for line in match.group(1).splitlines():
        heading = re.match(r"\s*//\s*(Keywords[^(]*|Boolean literals|Articles|Prepositions)\s*$", line)
        if heading:
            raw = heading.group(1).strip()
            # "Keywords - While Loop (ARO-0002 extension, …)" -> "Keywords - While Loop"
            current = GROUP_TITLES.get(raw, raw)
            continue
        word = re.match(r'\s*"([^"]+)":', line)
        if word:
            if current not in seen:
                seen[current] = []
                order.append(current)
            seen[current].append(word.group(1))

    for name in order:
        groups.append((name, seen[name]))
    if not groups:
        raise SystemExit(f"error: reservedWords table in {LEXER} yielded nothing")
    return groups


def format_operators(comment: str) -> str:
    """Turn a Precedence case's trailing comment into a table cell.

    The comments are written for a Swift reader: `not (prefix)`, `default
    (GitLab #547)`, `unary -`. Parenthetical asides become plain text beside
    the code spans, `is_not` becomes the two words the lexer actually matches,
    and a leading `unary` qualifies the operator that follows it rather than
    being typeset as one.
    """
    if not comment:
        return "—"

    aside = ""
    match = re.search(r"\(([^)]*)\)", comment)
    if match:
        aside = f" ({match.group(1)})"
        comment = comment[: match.start()] + comment[match.end():]

    tokens = comment.split()
    rendered: list[str] = []
    prefix = ""
    for token in tokens:
        if token == "unary":
            prefix = "unary "
            continue
        rendered.append(f"{prefix}`{token.replace('is_not', 'is not')}`")
        prefix = ""
    return (", ".join(rendered) or "—") + aside


def render() -> str:
    levels = precedence_levels()
    preps = prepositions()
    groups = reserved_words()

    lines = [
        BEGIN,
        "",
        "<!-- Generated by Book/TheConstructionStudies/generate-grammar-appendix.py — do not edit by hand. -->",
        "<!-- Regenerate with: python3 Book/TheConstructionStudies/generate-grammar-appendix.py -->",
        "",
        "## Precedence",
        "",
        "Read off `Parser.swift`'s `Precedence` enum, lowest binding power first.",
        "A prefix operator at a level binds looser than everything below it in this",
        "table.",
        "",
        "| Level | Name | Operators |",
        "|-------|------|-----------|",
    ]
    for name, level, operators in levels:
        if name == "none":
            continue
        lines.append(f"| {level} | {name} | {format_operators(operators)} |")

    lines += [
        "",
        "Two of those placements are decisions rather than consequences, and both",
        "are easy to misremember:",
        "",
        "- **`not` sits below the comparisons**, as in Python rather than C. `not <a>",
        "  == <b>` is `not (<a> == <b>)`, and `not <n> >= 3` asks whether `n` is",
        "  below three. Parenthesize when you mean to negate the operand instead.",
        "- **Unary `-` is the exception** and stays above `*`, so `-<a> * <b>` is",
        "  `(-<a>) * <b>`.",
        "",
        "## Prepositions",
        "",
        f"The `Preposition` enum has exactly {len(preps)} cases. `as` is not among them:",
        "it is a keyword introducing a result type.",
        "",
        "```ebnf",
        "preposition = " + "\n            | ".join(f'"{p}"' for p in preps) + " ;",
        "```",
        "",
        "## Reserved Words",
        "",
        "Every entry in the lexer's single `reservedWords` table. A word here is a",
        "keyword token rather than an identifier wherever it appears, whether or not",
        "the grammar above has a production that uses it — several are reserved",
        "against future syntax and are accepted nowhere today.",
        "",
    ]
    for name, words in groups:
        lines.append(f"**{name}:** " + ", ".join(f"`{w}`" for w in words))
        lines.append("")

    lines += [
        "`for` and `at` appear under Iteration rather than Prepositions because the",
        "lexer groups them where they are most often read, but they tokenize as",
        "prepositions and the parser accepts them in both roles. The canonical ten",
        "prepositions are the list above.",
        "",
        "Two families of name are *not* reserved, and can be used as ordinary",
        "identifiers: HTTP status names (`OK`, `Created`, `NotFound`, …), which are",
        "conventional qualifiers rather than keywords, and the feature-set labels",
        "`Application-Start`, `Application-End`, `Success`, `Error` and `Handler`,",
        "which the parser matches inside a feature-set header and nowhere else.",
        "",
        END,
    ]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify without rewriting")
    args = parser.parse_args()

    document = read(APPENDIX)
    if BEGIN not in document or END not in document:
        print(f"error: {APPENDIX} is missing the {BEGIN} / {END} markers")
        return 1

    prefix = document[: document.index(BEGIN)]
    suffix = document[document.index(END) + len(END) :]
    updated = prefix + render() + suffix

    if args.check:
        if updated != document:
            print(
                f"error: {APPENDIX}'s generated tables are out of date with the parser.\n"
                "  Regenerate with: python3 Book/TheConstructionStudies/generate-grammar-appendix.py"
            )
            return 1
        print("Grammar appendix tables are up to date.")
        return 0

    with open(APPENDIX, "w", encoding="utf-8") as handle:
        handle.write(updated)
    print(f"Wrote the precedence, preposition and reserved-word tables into {APPENDIX}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
