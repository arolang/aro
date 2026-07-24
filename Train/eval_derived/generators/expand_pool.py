#!/usr/bin/env python3
"""Expand the base pool via entity variation: for each base that mentions a
known entity noun, produce variants with that noun consistently renamed, and
keep only variants that still pass `aro check`. Multiplies downstream error→fix
and code_generation while preserving validity."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/Users/kris/Projects/ARO/ARO-Lang/Train/script")
import config  # noqa: E402

POOL = json.loads((HERE / "base_pool.json").read_text())
OUT = HERE / "base_pool.json"  # overwrite in place with expanded pool

ENTITIES = ["user", "order", "product", "invoice", "payment", "customer", "account",
            "ticket", "comment", "article", "session", "booking", "device", "review",
            "shipment", "employee", "project", "task", "vendor", "coupon", "lead", "campaign"]


def rename(code, src, dst):
    # whole-word, case-insensitive on the lowercase noun; keep it simple/safe
    return re.sub(rf"\b{re.escape(src)}\b", dst, code)


def main(variants_per_base=2):
    out = list(POOL)  # keep originals
    seen = {re.sub(r"\s+", " ", p["code"]) for p in POOL}
    added = 0
    for item in POOL:
        code = item["code"]
        # find an entity noun present in this base
        present = [e for e in ENTITIES if re.search(rf"\b{e}\b", code)]
        if not present:
            continue
        src = present[0]
        alts = [e for e in ENTITIES if e != src][:variants_per_base]
        for dst in alts:
            variant = rename(code, src, dst)
            key = re.sub(r"\s+", " ", variant)
            if key in seen or variant.strip() == code.strip():
                continue
            passed, _ = config.aro_check_snippet(variant, timeout=15)
            if passed:
                seen.add(key)
                out.append({"code": variant, "source": item["source"] + f"|var:{src}->{dst}"})
                added += 1
    OUT.write_text(json.dumps(out, indent=1))
    print(f"expanded pool: {len(POOL)} -> {len(out)} (+{added} validated variants)")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 2)
