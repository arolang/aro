#!/usr/bin/env python3
"""Validate the combined base pool once and cache it to base_pool.json so the
downstream generators don't re-run `aro check` on 272 programs every time."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from base_pool import validated_pool  # noqa: E402
from supplement import CANDIDATES  # noqa: E402

OUT = Path(__file__).resolve().parent / "base_pool.json"


def main():
    pool = [{"code": c, "source": "harvest"} for c in validated_pool()]
    pool += [{"code": c, "source": f"authored:{k}"} for k, c in CANDIDATES.items()]
    OUT.write_text(json.dumps(pool, indent=1))
    print(f"cached {len(pool)} validated base programs -> {OUT}")


if __name__ == "__main__":
    main()
