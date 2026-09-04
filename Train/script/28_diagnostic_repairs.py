#!/usr/bin/env python3
"""
28_diagnostic_repairs.py — training pairs for fixing `aro check` diagnostics.

The DATA lives in Train/seeds/28_repairs/*.json; this script holds none of it.
It loads the seed files, validates every case against the real `aro check`,
and saves the survivors to the pairs corpus. Add or edit cases in the JSON —
never here.

  Train/seeds/28_repairs/repair_cases.json   before/after applications + pair
  Train/seeds/28_repairs/knowledge_qa.json   Q/A mirroring aro_knowledge

Seeds live under Train/seeds/ (versioned), NOT Train/data/ (gitignored
generated outputs) — curated inputs must survive a checkout.

Why this exists: `aro ask /fix` failed on a real project (Crawler) in every
way a repair can fail — it appended handlers that already existed in sibling
files, could not delete a single unused-variable line without retyping the
whole file, and never once checked whether a warning was true before acting
on it. The repair *mechanics* are now deterministic in AROAsk, but the model
still writes the handlers and judges the reports, so it is trained on the
cases in the seed files: append a genuinely missing handler; recognise a
handler in a SIBLING file and change nothing; delete exactly the binding
line; take the enclosing `case` block when the binding is its only
statement; refuse to delete a variable a loop bound reads; remove a
duplicated handler.

Every case is VALIDATED before it is saved: `before_files` must produce the
diagnostic named in `expect_before` (when set), `after_files` must check
clean. A case that does not validate fails the whole run loudly — silently
training on the survivors would hide a template bug or a checker change.

Binary: $ARO_BIN if set, else the repo's own .build/{release,debug}/aro,
else `aro` on PATH. The repo build is preferred because the installed binary
may predate checker fixes this data depends on (per-file orphan events,
range-loop reads).

Usage:
    python3 Train/script/28_diagnostic_repairs.py            # generate+save
    python3 Train/script/28_diagnostic_repairs.py --dry-run  # validate only

Idempotent: re-running replaces this script's pairs (clean_notebook_pairs).
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    save_notebook_pairs, clean_notebook_pairs, TRAIN_ROOT,
)

NOTEBOOK_TAG = 'NB28_repairs'
SEED_DIR = TRAIN_ROOT / 'seeds' / '28_repairs'


# ── aro binary ───────────────────────────────────────────────────────────────

def resolve_aro() -> str:
    env = os.environ.get('ARO_BIN')
    if env and os.access(env, os.X_OK):
        return env
    repo = Path(__file__).resolve().parents[2]
    for cfg in ('release', 'debug'):
        candidate = repo / '.build' / cfg / 'aro'
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return 'aro'


ARO = resolve_aro()


def aro_check(files: dict) -> tuple[int, str]:
    """`aro check` over a dict of {filename: content} as one application."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, content in files.items():
            (Path(tmp) / name).write_text(content)
        r = subprocess.run([ARO, 'check', tmp],
                           capture_output=True, text=True, timeout=30)
        return r.returncode, (r.stdout + r.stderr)


# ── load + validate ──────────────────────────────────────────────────────────

def load_seed(name: str) -> dict:
    path = SEED_DIR / name
    if not path.exists():
        sys.exit(f'missing seed file: {path}')
    return json.loads(path.read_text())


def build_pairs() -> tuple[list[dict], list[str]]:
    pairs, failures = [], []

    for case in load_seed('repair_cases.json')['cases']:
        case_id = case['id']

        _, before_out = aro_check(case['before_files'])
        expect = case.get('expect_before')
        if expect and expect not in before_out:
            failures.append(f'{case_id}: before missing "{expect}"')
            continue

        code, after_out = aro_check(case['after_files'])
        if code != 0 or 'warning:' in after_out:
            failures.append(f'{case_id}: after not clean: {after_out[:120]}')
            continue

        pairs.append({
            'instruction': case['instruction'],
            'output': case['output'],
            'source': 'repair',
            'task_type': case['task_type'],
            'category': case['category'],
        })

    # Q/A needs no toolchain validation — it contains no checkable app —
    # but it rides the same seed-file rule: data in JSON, never here.
    for qa in load_seed('knowledge_qa.json')['pairs']:
        pairs.append({
            'instruction': qa['instruction'],
            'output': qa['output'],
            'source': 'repair',
            'task_type': 'syntax_qa',
            'category': 'repair_knowledge',
        })

    return pairs, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true',
                    help='validate and report; save nothing')
    args = ap.parse_args()

    print(f'aro binary: {ARO}')
    print(f'seed dir:   {SEED_DIR}')
    pairs, failures = build_pairs()

    for f in failures:
        print(f'  DROPPED  {f}')
    print(f'validated pairs: {len(pairs)}  (dropped: {len(failures)})')

    if failures:
        # A dropped case means the toolchain disagrees with the seed data —
        # a bug in the data or a checker change — and silently training on
        # the survivors would hide it.
        print('FAILING: every seed case must validate. Fix the case or the '
              'expectation in Train/seeds/28_repairs/ before saving.')
        return 1

    if args.dry_run:
        print('dry run — nothing saved')
        return 0

    removed = clean_notebook_pairs(NOTEBOOK_TAG)
    if removed:
        print(f'replaced {removed} previous pairs')
    written = save_notebook_pairs(NOTEBOOK_TAG, pairs)
    print(f'saved {written} pairs as {NOTEBOOK_TAG}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
