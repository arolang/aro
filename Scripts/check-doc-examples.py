#!/usr/bin/env python3
"""Check every fenced ``aro`` block in the documentation against the parser.

The proposals, the books and the example READMEs are the reference *and* the
training corpus for `aro ask`, so a block that the parser rejects is worse than a
typo: it teaches syntax the language does not have. GitLab #834 catalogued the
damage — `Increment`, `Reserve`, `Generate` and nine other verbs presented as
built-ins, `if … then { }` where the language has `when`, `now()` and
`<high-value>.count()` method syntax, `Process each <item> in <items>`.

This script closes the class. It finds every fenced block whose info string
starts with `aro`, and applies two checks:

  1. **It parses.** Blocks holding whole feature sets are written to a temporary
     application directory and run through `aro check`; bare statement lists go
     through `aro check --syntax`. Only errors fail the build — warnings such as
     "used before definition" are expected in a fragment torn out of context.

  2. **Its verbs exist.** `aro check` does not (yet) reject an unknown verb
     (GitLab #840), so a statement starting with a word that no action declares
     is reported here instead. The verb table is read straight out of
     `Sources/ARORuntime` by `generate-action-reference.py`, so it cannot drift.

Blocks that are deliberately not ARO — a grammar sketch, a rejected syntax shown
to explain why it is rejected, a snippet from a hypothetical future version —
opt out with a directive on the line before the fence:

    <!-- aro-check: skip — grammar sketch, not a program -->
    ```aro
    ...
    ```

or by tagging the fence ```` ```aro-invalid ```` (for deliberate counter-examples),
which this script skips and which highlighters treat as plain text.

Blocks that already fail are listed in `Scripts/doc-examples-baseline.txt` as
documentation debt, and the baseline identifies a block **by its contents**, not
by where it sits in the file. It used to be keyed on the line the fence opens at,
which meant any edit higher up in the same document renumbered every baselined
block below it and CI reported long-standing debt as a brand-new failure —
GitLab #889, where a refactor that added two lines to ARO-0004 failed the build
with ten "new" problems in blocks it had never touched. Keying on the contents
also gets the other half right: editing a baselined block *does* re-expose it,
because the block you changed is not the block that was excused.

    python3 Scripts/check-doc-examples.py              # check everything
    python3 Scripts/check-doc-examples.py Proposals    # check one tree
    python3 Scripts/check-doc-examples.py --list-skips # what is opted out, and why

Exit status is 0 when clean, 1 otherwise. Run from the repository root.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

# `Book/` is deliberately not here yet. Its own sweep is GitLab #836, in a
# separate merge request. Add "Book" to this list once #836 has landed — the
# script already handles it, and `python3 Scripts/check-doc-examples.py Book`
# reports on it today.
DEFAULT_ROOTS = [
    "Proposals",
    "Examples",
    "Learning",
    "README.md",
    "CLAUDE.md",
    "OVERVIEW.md",
    "CONTRIBUTING.md",
]

BASELINE = "Scripts/doc-examples-baseline.txt"

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})[ \t]*([^\s`]*)[ \t]*(.*)$")
SKIP_DIRECTIVE = re.compile(r"<!--\s*aro-check:\s*skip\b[^>]*-->", re.IGNORECASE)
FEATURE_SET_HEADER = re.compile(r"^\s*\([^)\n]+:[^)\n]+\)\s*\{", re.MULTILINE)
APPLICATION_START = re.compile(r"^\s*\(\s*Application-Start\s*:", re.MULTILINE)

# A statement's opening word. Deliberately conservative: only lines whose first
# word is followed by an ARO-looking operand are considered, so prose inside a
# block (and the body of a `when` guard) is not mistaken for a statement.
STATEMENT_START = re.compile(
    r"^\s*([A-Za-z][A-Za-z0-9_-]*)\s+(?:the\s+|an\s+|a\s+)?[<\"']"
)

# Statement openers that are syntax rather than actions, so they are not in the
# verb table. `Given`/`When`/`Then` are ARO-0015 test clauses; `for`/`parallel`
# introduce iteration; `Application` and any dotted word are a call.
NON_ACTION_OPENERS = {
    # control flow and test clauses
    "for", "each", "parallel", "match", "case", "otherwise", "else", "while",
    "break", "continue", "publish", "application",
    # `Require` declares a dependency and is a statement, not an action —
    # which is the whole point of CLAUDE.md's "Statements that are not
    # actions" section. `aro actions` lists it the same way (GitLab #828).
    "require",
    # boolean glue, and continuation lines of a wrapped statement
    "and", "or", "not",
    # a wrapped statement's continuation starts with its preposition
    "from", "to", "into", "via", "with", "against", "on", "at", "by",
}


def load_verb_table() -> set[str]:
    """Verbs declared by the runtime, via the action-reference generator."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate-action-reference.py")
    spec = importlib.util.spec_from_file_location("aro_action_reference", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    verbs: set[str] = set()
    for action in module.collect_actions():
        verbs.update(action["verbs"])
    return verbs


def find_aro_binary(explicit: str | None) -> str | None:
    """Locate an `aro` to check with: --aro, $ARO_BIN, the build dirs, $PATH."""
    candidates = [
        explicit,
        os.environ.get("ARO_BIN"),
        ".build/out/Products/Release/aro",
        ".build/release/aro",
        ".build/out/Products/Debug/aro",
        ".build/debug/aro",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return shutil.which("aro")


def markdown_files(roots: list[str]) -> list[str]:
    files: list[str] = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue
        for directory, _, names in os.walk(root):
            if "node_modules" in directory or "/.build" in directory:
                continue
            for name in sorted(names):
                if name.endswith(".md"):
                    files.append(os.path.join(directory, name))
    return sorted(files)


def extract_blocks(path: str):
    """Yield (start_line, info, body, skip_reason) for each ``aro`` fence."""
    with open(path, encoding="utf-8", errors="ignore") as handle:
        lines = handle.read().split("\n")

    index = 0
    while index < len(lines):
        match = FENCE.match(lines[index])
        if not match:
            index += 1
            continue

        indent, ticks, info, rest = match.groups()
        info_lower = info.lower()
        if not info_lower.startswith("aro"):
            # Skip to the closing fence so a ```aro inside a ```markdown block
            # is not opened twice.
            closing = index + 1
            while closing < len(lines) and not _closes(lines[closing], ticks, indent):
                closing += 1
            index = closing + 1
            continue

        body_start = index + 1
        closing = body_start
        while closing < len(lines) and not _closes(lines[closing], ticks, indent):
            closing += 1
        body = "\n".join(line[len(indent) :] if line.startswith(indent) else line for line in lines[body_start:closing])

        reason = None
        if info_lower in {"aro-invalid", "aro-grammar", "aro-pseudo"}:
            reason = f"fence tagged `{info}`"
        else:
            for previous in range(index - 1, max(index - 4, -1), -1):
                if lines[previous].strip() == "":
                    continue
                directive = SKIP_DIRECTIVE.search(lines[previous])
                if directive:
                    reason = directive.group(0)
                break

        yield body_start + 1, info, body, reason
        index = closing + 1


def _closes(line: str, ticks: str, indent: str) -> bool:
    stripped = line.strip()
    return stripped.startswith(ticks[0] * len(ticks)) and set(stripped) <= {ticks[0]}


def check_parses(aro: str, body: str) -> list[str]:
    """Run the block through `aro check`; return error lines only."""
    has_feature_set = bool(FEATURE_SET_HEADER.search(body))

    with tempfile.TemporaryDirectory() as workdir:
        if has_feature_set:
            source = body
            offset = 0
            if not APPLICATION_START.search(body):
                preamble = "(Application-Start: Documentation Example) {\n    Return an <OK: status> for the <startup>.\n}\n\n"
                source = preamble + body
                offset = preamble.count("\n")
            target = os.path.join(workdir, "main.aro")
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(source if source.endswith("\n") else source + "\n")
            command = [aro, "check", workdir, "--no-warnings"]
        else:
            offset = 0
            target = os.path.join(workdir, "snippet.aro")
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(body if body.endswith("\n") else body + "\n")
            command = [aro, "check", "--syntax", target, "--no-warnings"]

        result = subprocess.run(command, capture_output=True, text=True, timeout=120)

    output = (result.stdout or "") + (result.stderr or "")
    errors = []
    for line in output.split("\n"):
        match = re.match(r"\s*(\d+):(\d+): error: (.*)", line)
        if match:
            row = max(int(match.group(1)) - offset, 1)
            errors.append(f"line {row}, col {match.group(2)}: {match.group(3)}")
        elif "error:" in line and "Found" not in line:
            errors.append(line.strip())
    return errors


def check_verbs(body: str, verbs: set[str]) -> list[str]:
    """Report statements opening with a word no action declares."""
    problems: list[str] = []
    in_comment = False
    for number, line in enumerate(body.split("\n"), start=1):
        stripped = line.strip()
        if in_comment:
            if "*)" in stripped:
                in_comment = False
            continue
        if stripped.startswith("(*"):
            if "*)" not in stripped:
                in_comment = True
            continue
        match = STATEMENT_START.match(line)
        if not match:
            continue
        word = match.group(1)
        if "." in line[: match.end(1)]:
            continue
        lowered = word.lower()
        if lowered in verbs or lowered in NON_ACTION_OPENERS:
            continue
        # `Given`/`When`/`Then` are in the verb table already; anything that
        # survives here opened a statement with a word the runtime cannot map.
        problems.append(f"line {number}: `{word}` is not a verb of any action — {stripped[:70]}")
    return problems


def block_key(path: str, body: str) -> str:
    """The baseline's name for a block: its file, plus a digest of its text.

    Not its line number. A line number says where everything *above* the block
    ends, so a paragraph added at the top of a proposal renamed every baselined
    block beneath it and the checker reported documentation debt it had been
    ignoring for months as ten new failures (GitLab #889). The digest moves only
    when the block moves — which is the behaviour the other direction wants too:
    rewrite a baselined block and it no longer matches, so the rewrite is checked
    instead of inheriting the old block's excuse.

    Trailing whitespace and surrounding blank lines are normalised away, so a
    reflow that does not touch the ARO does not churn the baseline.
    """
    normalized = "\n".join(line.rstrip() for line in body.split("\n")).strip()
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]
    return f"{path}:{digest}"


def _annotated_line(entry: str) -> int:
    """The line number in an entry's trailing `# line N` signpost, for ordering."""
    match = re.search(r"#\s*line\s+(\d+)\s*$", entry)
    return int(match.group(1)) if match else -1


def entry_under_roots(key: str, roots: list[str]) -> bool:
    """Could this run have looked at the block a baseline key names?

    The key is `<file>:<digest>`, so the file is everything before the last
    colon. This used to compare the whole key against the root, which worked for
    directories (`Proposals/…` starts with `Proposals/`) and silently never
    matched for the single-file roots — `CLAUDE.md:325` is neither equal to
    `CLAUDE.md` nor prefixed by `CLAUDE.md/`. Entries for CLAUDE.md, README.md
    and the rest were therefore invisible to both the "no longer fails" report
    and `--write-baseline`, so three dead CLAUDE.md entries sat in the baseline
    unnoticed until this rewrite had to resolve them.
    """
    file = key.rpartition(":")[0] or key
    return any(file == root or file.startswith(root.rstrip("/") + "/") for root in roots)


def read_baseline_lines(path: str) -> dict[str, str]:
    """Baseline keys, mapped to the whole line they were written on."""
    if not os.path.exists(path):
        return {}
    entries: dict[str, str] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            # Everything after the key is the human-readable `# line N`
            # annotation saying where the block sat when it was recorded. It is
            # for the reader; nothing compares against it, precisely because a
            # line number is the thing that goes stale.
            key = stripped.split()[0]
            if ":" not in key:
                # Not a `<file>:<digest>` key. This file is edited by hand and
                # merged between branches, and it arrived here with three lines
                # of Git conflict markers committed into it, carried silently as
                # three entries that could never match a block. Say so.
                sys.stderr.write(f"[check-doc-examples] Warning: ignoring unparsable baseline line: {stripped}\n")
                continue
            entries[key] = stripped
    return entries


def read_baseline(path: str) -> set[str]:
    return set(read_baseline_lines(path))


def write_baseline(path: str, failing: dict[str, str], roots: list[str]) -> None:
    """Record the blocks that fail today, so CI can fail only on new ones.

    Every line here is a documentation bug that has not been fixed yet, not an
    exemption. A block that is deliberately not ARO belongs behind an
    `aro-check: skip` directive with a reason, where a reader of the document
    can see it. Shrink this file; do not grow it.
    """
    existing = read_baseline_lines(path)
    # Only rewrite the parts of the baseline the current roots could observe,
    # so `--write-baseline Proposals` cannot silently drop Examples' entries.
    kept = {
        key: line
        for key, line in existing.items()
        if not entry_under_roots(key, roots)
    }
    lines = dict(kept)
    for key, location in failing.items():
        lines[key] = f"{key}  # line {location.rpartition(':')[2]}"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            "# Fenced ``aro`` blocks that Scripts/check-doc-examples.py cannot parse yet.\n"
            "#\n"
            "# Documentation debt (GitLab #834), not a list of exemptions: CI fails on any\n"
            "# failure NOT listed here, so the set can only shrink. When you fix one, or\n"
            "# annotate it with `<!-- aro-check: skip — why -->`, rerun:\n"
            "#\n"
            "#     python3 Scripts/check-doc-examples.py --write-baseline\n"
            "#\n"
            "# Format: <file>:<digest of the block's text>  # <line it was at>\n"
            "# The digest is the key; the trailing comment is only a signpost, because a\n"
            "# line number changes whenever anything above the block does (GitLab #889).\n"
        )
        # Grouped by file and ordered the way a reader walks the document, not
        # by the digest, which sorts arbitrarily.
        for key in sorted(lines, key=lambda k: (k.rpartition(":")[0], _annotated_line(lines[k]), k)):
            handle.write(lines[key] + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("roots", nargs="*", default=None, help="files or directories to scan")
    parser.add_argument("--aro", help="path to the aro binary")
    parser.add_argument("--list-skips", action="store_true", help="list opted-out blocks and exit")
    parser.add_argument("--no-verb-check", action="store_true", help="only check that blocks parse")
    parser.add_argument("--baseline", default=BASELINE, help=f"known-failing blocks (default {BASELINE})")
    parser.add_argument("--write-baseline", action="store_true", help="record the current failures as the baseline")
    parser.add_argument("--strict", action="store_true", help="ignore the baseline; fail on every problem")
    args = parser.parse_args()

    if not os.path.isdir("Proposals"):
        print("error: run from the repository root (no Proposals/ directory here)")
        return 1

    roots = args.roots or [root for root in DEFAULT_ROOTS if os.path.exists(root)]
    aro = find_aro_binary(args.aro)
    if aro is None and not args.list_skips:
        print(
            "error: no `aro` binary found. Build one with `make aro`, or pass --aro/$ARO_BIN.\n"
            "       (CI builds it before running this check.)"
        )
        return 1

    verbs = load_verb_table()
    failures: list[tuple[str, str]] = []   # (baseline key, human-readable report)
    failing_blocks: dict[str, str] = {}    # baseline key -> where it is today
    skips: list[str] = []
    checked = 0

    for path in markdown_files(roots):
        for line_number, info, body, skip_reason in extract_blocks(path):
            if not body.strip():
                continue
            if skip_reason:
                skips.append(f"{path}:{line_number} — {skip_reason}")
                continue
            if args.list_skips:
                continue

            checked += 1
            problems = check_parses(aro, body)
            if not args.no_verb_check:
                problems += check_verbs(body, verbs)
            key = block_key(path, body)
            if problems:
                failing_blocks[key] = f"{path}:{line_number}"
            for problem in problems:
                failures.append((key, f"{path}:{line_number} (```{info}): {problem}"))

    if args.list_skips:
        print(f"{len(skips)} block(s) opted out of the check:\n")
        for entry in skips:
            print(f"  {entry}")
        return 0

    if args.write_baseline:
        write_baseline(args.baseline, failing_blocks, roots)
        print(f"Wrote {len(failing_blocks)} known-failing block(s) to {args.baseline}.")
        return 0

    baseline = set() if args.strict else read_baseline(args.baseline)
    new_failures = [report for key, report in failures if key not in baseline]

    if new_failures:
        print(f"Documentation example check failed: {len(new_failures)} new problem(s) in {checked} block(s).\n")
        for failure in new_failures:
            print(f"  - {failure}")
        print(
            "\nFix the block, or — if it is deliberately not ARO — put\n"
            "  <!-- aro-check: skip — why -->\n"
            "on the line before the fence, or tag the fence ```aro-invalid.\n"
            "A block reported here is either new or edited — moving one down the\n"
            "page no longer counts as either. Rerun with --write-baseline only\n"
            "when you have checked the diff."
        )
        return 1

    # Only entries this run could have observed: `check-doc-examples.py CLAUDE.md`
    # must not report the whole Proposals/ baseline as fixed.
    observed = {entry for entry in baseline if entry_under_roots(entry, roots)}
    fixed = observed - set(failing_blocks)
    print(
        f"Documentation example check passed: {checked} ARO block(s) checked, "
        f"{len(skips)} opted out, {len(set(failing_blocks) & baseline)} known-failing."
    )
    if fixed:
        print(
            f"{len(fixed)} baselined block(s) no longer fail. Shrink the baseline:\n"
            "  python3 Scripts/check-doc-examples.py --write-baseline"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
