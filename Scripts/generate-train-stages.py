#!/usr/bin/env python3
"""Generate (or verify) the training pipeline's stage table from the pipeline.

`Train/script/00_META_PIPELINE.ipynb` owns the stage list: its `NOTEBOOKS`
constant is what actually runs, in the order it actually runs. Everything else
kept a copy, and every copy was wrong in a different way (GitLab #802):

  - `Train/README.md`'s tables were offset by two in their first half and by one
    in their second — README "05 warmstart" is `07_warmstart_finetune.ipynb` —
    and its directory layout listed notebooks that no longer exist;
  - `01_init.ipynb`'s own "Pipeline order" table listed `23_package` and
    `24_material_finetune`, numbers from before the 2026-07 renumber;
  - the book appendix warned the reader that notebook headings carry older
    numbers than their filenames, which was true of 21 of the 27 notebooks.

So the table is derived, and the numbering is checked:

    python3 Scripts/generate-train-stages.py            # rewrite the tables
    python3 Scripts/generate-train-stages.py --check    # verify only

Three things are verified, because a generated table alone would not have
caught any of the above:

  1. every stage in `NOTEBOOKS` has a notebook file, and every numbered
     notebook under `Train/script/` is in `NOTEBOOKS` — a renumber that adds or
     drops a file fails here rather than silently running less;
  2. each notebook's own first markdown heading carries its filename's number;
  3. the generated blocks in the README and the book appendix are current.

The `# NN — Title` headings are rewritten too, since they are the same fact.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

META = Path("Train/script/00_META_PIPELINE.ipynb")
SCRIPT_DIR = Path("Train/script")
README = Path("Train/README.md")
APPENDIX = Path("Book/AROByHallucination/AppendixA-TrainingPipeline.md")

BEGIN = "<!-- BEGIN GENERATED STAGE TABLE -->"
END = "<!-- END GENERATED STAGE TABLE -->"

HEADING = re.compile(r"^#\s*(\S+)\s*—\s*(.*)$")


def notebook_cells(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)["cells"]


def stages() -> list[tuple[str, str, str]]:
    """The `NOTEBOOKS` list from the meta pipeline: (number, name, description)."""
    source = "".join(
        "".join(cell["source"]) for cell in notebook_cells(META) if cell["cell_type"] == "code"
    )
    match = re.search(r"^NOTEBOOKS = (\[.*?^\])", source, re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit(f"error: {META} has no NOTEBOOKS list")
    parsed = ast.literal_eval(match.group(1))
    return [(str(num), str(name), str(desc)) for num, name, desc in parsed]


def check_inventory(rows: list[tuple[str, str, str]]) -> list[str]:
    """Stages without a notebook, and notebooks the pipeline never runs."""
    problems = []
    listed = {name for _num, name, _desc in rows}

    for num, name, _desc in rows:
        if not (SCRIPT_DIR / f"{name}.ipynb").is_file():
            problems.append(f"stage {num} runs {name}.ipynb, which does not exist")
        if not name.startswith(num):
            problems.append(f"stage {num} runs {name}.ipynb, whose filename disagrees")

    for path in sorted(SCRIPT_DIR.glob("[0-9][0-9]_*.ipynb")):
        if path.stem != "00_META_PIPELINE" and path.stem not in listed:
            problems.append(f"{path.name} exists but the meta pipeline never runs it")
    return problems


def notebook_heading(path: Path) -> tuple[str, str] | None:
    """(number, title) of the notebook's first markdown heading."""
    for cell in notebook_cells(path):
        if cell["cell_type"] != "markdown":
            continue
        first = "".join(cell["source"]).strip().split("\n", 1)[0]
        match = HEADING.match(first)
        return (match.group(1), match.group(2)) if match else None
    return None


def fix_headings(rows: list[tuple[str, str, str]], write: bool) -> list[str]:
    """Make each notebook's own heading carry its filename's number."""
    problems = []
    for num, name, _desc in rows:
        path = SCRIPT_DIR / f"{name}.ipynb"
        if not path.is_file():
            continue
        heading = notebook_heading(path)
        if heading is None:
            problems.append(f"{path.name} has no `# NN — Title` heading")
            continue
        found, title = heading
        if found == num:
            continue
        if not write:
            problems.append(f"{path.name} opens with '# {found} — {title}'")
            continue

        # Edit the raw JSON rather than round-tripping it: re-serialising a
        # notebook rewrites every line of a 5 000-line file for a two-character
        # change, and the diff is then unreviewable. The heading is the first
        # `"# NN — ` in the file, which is the first markdown cell's first line.
        raw = path.read_text(encoding="utf-8")
        needle = f'"# {found} — '
        if needle not in raw:
            problems.append(f"{path.name}'s heading is not a plain '# {found} — …' line")
            continue
        path.write_text(raw.replace(needle, f'"# {num} — ', 1), encoding="utf-8")
        print(f"Renumbered {path.name}: '# {found} —' → '# {num} —'.")
    return problems


def render(rows: list[tuple[str, str, str]]) -> str:
    lines = [
        BEGIN,
        "",
        "<!-- Generated by Scripts/generate-train-stages.py — do not edit by hand. -->",
        "<!-- Regenerate with: python3 Scripts/generate-train-stages.py -->",
        "",
        f"The {len(rows)} stages, in the order `00_META_PIPELINE.ipynb` runs them —",
        "which is the `NOTEBOOKS` list, not the filename numbers. Each runs in its",
        "own kernel.",
        "",
        "| # | Notebook | What it does |",
        "|---|----------|--------------|",
    ]
    for num, name, desc in rows:
        lines.append(f"| {num} | `{name}` | {desc} |")
    lines += ["", END]
    return "\n".join(lines)


def splice(document: str, replacement: str, path: Path) -> str:
    if BEGIN not in document or END not in document:
        raise SystemExit(f"error: {path} is missing the {BEGIN} / {END} markers")
    head = document[: document.index(BEGIN)]
    tail = document[document.index(END) + len(END) :]
    return head + replacement + tail


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="verify without rewriting")
    args = parser.parse_args()

    if not META.is_file():
        print(f"error: {META} not found — run from the repository root")
        return 1

    rows = stages()
    problems = check_inventory(rows)
    problems += fix_headings(rows, write=not args.check)

    table = render(rows)
    stale = []
    for path in (README, APPENDIX):
        current = path.read_text(encoding="utf-8")
        updated = splice(current, table, path)
        if updated == current:
            continue
        if args.check:
            stale.append(path)
            continue
        path.write_text(updated, encoding="utf-8")
        print(f"Updated the stage table in {path}.")

    if stale:
        problems += [f"{path} carries a stale stage table" for path in stale]

    if problems:
        print(
            f"error: the training pipeline's {len(rows)} stages and its documentation disagree:\n"
            + "".join(f"    {problem}\n" for problem in problems)
            + "  Regenerate with: python3 Scripts/generate-train-stages.py"
        )
        return 1

    print(f"Training stage documentation is up to date: {len(rows)} stages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
