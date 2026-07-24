#!/usr/bin/env python3
"""Combine all generator outputs into one deduped training file under ./Train.

Reads errorfix / codegen / openapi / knowledge / toolcalls JSONL, dedups by
(instruction, output), writes Train/eval_derived/ask_eval_pairs.jsonl, and
prints the category/task_type distribution."""
import json
import re
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
OUT_DIR = REPO / "Train" / "eval_derived"
OUT = OUT_DIR / "ask_eval_pairs.jsonl"

SOURCES = ["errorfix.jsonl", "codegen.jsonl", "openapi_apps.jsonl",
           "knowledge.jsonl", "toolcalls.jsonl"]


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    seen, rows = set(), []
    for src in SOURCES:
        p = HERE / src
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            if not line.strip():
                continue
            r = json.loads(line)
            key = (norm(r["instruction"]), norm(r["output"]))
            if key in seen:
                continue
            seen.add(key)
            rows.append(r)
    with open(OUT, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    cats = Counter(r["category"] for r in rows)
    tasks = Counter(r["task_type"] for r in rows)
    print(f"TOTAL deduped pairs: {len(rows)} -> {OUT}")
    print("by category:", dict(cats.most_common()))
    print("by task_type:", dict(tasks.most_common()))


if __name__ == "__main__":
    main()
