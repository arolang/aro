#!/usr/bin/env python3
"""Audit (and optionally drop) training samples that use qualifiers the
runtime cannot resolve — GitLab #486.

`aro check` validates syntax, and `<total: lines>` is perfectly well-formed
syntax, so nothing in the pipeline ever noticed that 202 distinct qualifier
names didn't exist. Samples teaching them compiled, checked clean, ran green,
and printed the wrong answer.

Report what's there:

    python3 Train/script/audit_qualifiers.py

Rewrite the files, dropping every contaminated sample (a `.bak` is written
next to each file it touches):

    python3 Train/script/audit_qualifiers.py --drop

Scope it:

    python3 Train/script/audit_qualifiers.py --path data/06_distill

Dropping is deliberately opt-in and never the default. Some of these samples
are salvageable by hand — `: sum` and `: lines` became real qualifiers in
#486, and others have an obvious rewrite — so "delete everything that trips
the gate" is a decision for a person, not a script run.
"""
import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_qualifier_catalog import load, is_known   # noqa: E402

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = SCRIPT_DIR.parent / "data"

QUALIFIER_RE = re.compile(
    r'\bComput\w*\s+(?:the\s+|an?\s+)?<\s*[\w-]+\s*:\s*([\w.\-|+]+)\s*>')


def offenders(text, catalog):
    """Unresolvable qualifier names in `text`, in order of appearance."""
    return [name for name in QUALIFIER_RE.findall(text)
            if not is_known(name, catalog)]


def audit(root, drop=False):
    catalog = load()
    if not catalog:
        print("no qualifier catalog — run extract_qualifier_catalog.py first",
              file=sys.stderr)
        return 1

    names = Counter()
    per_file = Counter()
    total_samples = 0
    dropped_samples = 0

    for path in sorted(Path(root).rglob("*.jsonl")):
        kept = []
        dirty = 0
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for line in lines:
            if not line.strip():
                continue
            total_samples += 1
            found = offenders(line, catalog)
            if found:
                dirty += 1
                names.update(found)
                per_file[str(path)] += len(found)
            else:
                kept.append(line)
        if drop and dirty:
            path.with_suffix(path.suffix + ".bak").write_text(
                "\n".join(lines) + "\n")
            path.write_text("\n".join(kept) + ("\n" if kept else ""))
            dropped_samples += dirty

    total_hits = sum(names.values())
    print(f"scanned {total_samples} samples under {root}")
    print(f"{total_hits} unresolvable qualifier uses "
          f"across {len(names)} distinct names")
    if names:
        print("\nmost frequent:")
        for name, count in names.most_common(20):
            print(f"  {count:5d}  {name}")
        print("\nworst files:")
        for name, count in per_file.most_common(10):
            print(f"  {count:5d}  {Path(name).relative_to(root)}")
    if drop:
        print(f"\ndropped {dropped_samples} samples (.bak written alongside)")
    return 1 if total_hits else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", default=str(DEFAULT_ROOT),
                        help="directory to scan (default: Train/data)")
    parser.add_argument("--drop", action="store_true",
                        help="rewrite files without the contaminated samples")
    args = parser.parse_args()
    raise SystemExit(audit(Path(args.path), drop=args.drop))


if __name__ == "__main__":
    main()
