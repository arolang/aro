#!/usr/bin/env python3
"""Harvest known-good ARO feature sets from the repo to use as a base pool for
error-injection (error→fix) and code_generation examples.

Sources: Examples/**/*.aro (real, runnable) and Train/Material/canonical.json
(curated, aro-check-passing). Each candidate is validated with `aro check`
(wrapped if it is a bare fragment) and only kept if it passes.
"""
import json
import re
import sys
from pathlib import Path

REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

FEATURE_SET_RE = re.compile(r"\([^()\n]*:[^()\n]*\)\s*\{.*?\n\}", re.DOTALL)


def _strip_comments(text):
    return re.sub(r"\(\*.*?\*\)", "", text, flags=re.DOTALL)


def harvest_examples():
    out = []
    for f in (REPO / "Examples").rglob("*.aro"):
        text = f.read_text(errors="ignore")
        for m in FEATURE_SET_RE.finditer(text):
            block = m.group(0).strip()
            out.append(block)
    return out


def harvest_canonical():
    out = []
    p = REPO / "Train" / "Material" / "canonical.json"
    if not p.exists():
        return out
    data = json.loads(p.read_text())
    items = data if isinstance(data, list) else data.get("pairs", data.get("items", []))
    for it in items if isinstance(items, list) else []:
        out_field = it.get("output") or it.get("response") or ""
        for blk in config.extract_aro_blocks(out_field):
            if "{" in blk and "(" in blk:
                out.append(blk.strip())
    return out


def validated_pool(limit_check=None):
    seen, pool = set(), []
    cands = harvest_examples() + harvest_canonical()
    for block in cands:
        key = re.sub(r"\s+", " ", block)
        if key in seen:
            continue
        seen.add(key)
        passed, _ = config.aro_check_snippet(block, timeout=15)
        if passed:
            pool.append(block)
        if limit_check and len(pool) >= limit_check:
            break
    return pool


if __name__ == "__main__":
    pool = validated_pool(limit_check=int(sys.argv[1]) if len(sys.argv) > 1 else None)
    print(f"validated base programs: {len(pool)}")
    # verb coverage
    verbs = {}
    for b in pool:
        for m in re.finditer(r"^\s*([A-Z][a-zA-Z.]+)\s", _strip_comments(b), re.M):
            v = m.group(1)
            verbs[v] = verbs.get(v, 0) + 1
    top = sorted(verbs.items(), key=lambda x: -x[1])
    print("verb coverage:", ", ".join(f"{k}:{n}" for k, n in top[:30]))
    if len(sys.argv) > 2:
        print("\n=== sample ===\n" + pool[0])
