#!/usr/bin/env python3
"""Generate validated error→fix training pairs.

For each cached base program and each injection transform: build the broken
variant, confirm it is REALLY broken (aro check fails, or the FIXTRAIN linter
flags an error), and emit an instruction/output pair whose output is the
original correct program. Structurally cannot produce trivial_fix_no_diff:
broken != correct, correct passes, broken fails.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, "/Users/kris/Projects/ARO/ARO-Lang/Train/script")
import config  # noqa: E402
import inject  # noqa: E402

POOL = json.loads((HERE / "base_pool.json").read_text())
OUT = HERE / "errorfix.jsonl"

INSTR_TEMPLATES = [
    "The following ARO code fails `aro check`. Fix it:\n```aro\n{broken}\n```",
    "Fix the error in this ARO feature set:\n```aro\n{broken}\n```",
    "This ARO code has a bug. Correct it so it passes `aro check`:\n```aro\n{broken}\n```",
    "`aro check` reports:\n```\n{error}\n```\nFix this code:\n```aro\n{broken}\n```",
]


def broken_error(broken):
    """Return the aro-check error string if broken fails, else '' when only the
    linter flags it (semantic issue that is syntactically valid)."""
    passed, err = config.aro_check_snippet(broken, timeout=15)
    if passed is False:
        return err or "syntax error", True
    # syntactically valid — check the FIXTRAIN semantic linter
    try:
        issues = config.check_fixtrain_issues(broken)
    except Exception:
        issues = []
    if issues:
        return (issues[0] if isinstance(issues[0], str) else str(issues[0])), True
    return "", False


def main(limit_bases=None):
    seen = set()
    n = 0
    with open(OUT, "w") as f:
        bases = POOL[:limit_bases] if limit_bases else POOL
        for idx, item in enumerate(bases):
            code = item["code"]
            for t in inject.TRANSFORMS:
                r = inject.apply_transform(code, t)
                if not r:
                    continue
                broken, label = r
                err, is_broken = broken_error(broken)
                if not is_broken:
                    continue
                key = re.sub(r"\s+", " ", broken)
                if key in seen:
                    continue
                seen.add(key)
                tmpl = INSTR_TEMPLATES[(idx + n) % len(INSTR_TEMPLATES)]
                instruction = tmpl.format(broken=broken, error=(err or "syntax error")[:300])
                rec = {
                    "instruction": instruction,
                    "output": f"```aro\n{code}\n```",
                    "category": "correction",
                    "task_type": "correction",
                    "error_class": label,
                    "source": "eval_gen_errorfix",
                }
                f.write(json.dumps(rec) + "\n")
                n += 1
    # class distribution
    classes = {}
    for line in open(OUT):
        c = json.loads(line)["error_class"]
        classes[c] = classes.get(c, 0) + 1
    print(f"error->fix pairs: {n}")
    print("by class:", dict(sorted(classes.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main(limit_bases=int(sys.argv[1]) if len(sys.argv) > 1 else None)
