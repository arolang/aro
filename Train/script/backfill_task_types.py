#!/usr/bin/env python3
"""Fill in the task_type nobody set (GitLab #782).

4 822 of the 10 007 rows in knowledge_pairs.jsonl carry `task_type: None` —
the book-QA, knowledge-extraction and LLM-extraction stages never set one.
17_dataset_assembly then guesses from the source prefix and 20_evaluation
stratifies the holdout on that guess, which is why a 200-row holdout contained
exactly one `translation`, one `correction` and one `multi_file_application`
sample: the labels the stratifier needed did not exist.

save_notebook_pairs refuses a pair without one now. This is the one-off
backfill for the rows already written, and the census that the caps and the
holdout should be reading.

    # what would change
    python3 Train/script/backfill_task_types.py

    # change it, keeping a backup
    python3 Train/script/backfill_task_types.py --write

    # and record the census next to the dataset
    python3 Train/script/backfill_task_types.py --write --update-stats

Nothing already labelled is relabelled. A row whose type cannot be inferred is
reported and left alone rather than filed under a plausible-looking default —
a wrong label is worse than a missing one, because the missing one is visible.
"""
from __future__ import annotations

import argparse
import collections
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402

DEFAULT_CORPUS = config.DATA_ROOT / '02_knowledge' / 'knowledge_pairs.jsonl'
DEFAULT_STATS = config.DATA_ROOT / '05_dataset' / 'stats.json'


def backfill(path: Path, write: bool = False):
    rows, header = [], None
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if config.is_jsonl_metadata_record(record):
                header = record
                continue
            rows.append(record)

    before = collections.Counter(r.get('task_type') or '(none)' for r in rows)
    filled = collections.Counter()
    unresolved = []
    for record in rows:
        if record.get('task_type'):
            continue
        inferred = config.infer_task_type(record)
        if not inferred:
            unresolved.append(record)
            continue
        record['task_type'] = inferred
        record.setdefault('provenance', {})['task_type_backfilled'] = (
            datetime.now(timezone.utc).isoformat(timespec='seconds'))
        filled[inferred] += 1
    after = collections.Counter(r.get('task_type') or '(none)' for r in rows)

    if write:
        backup = path.with_suffix(
            f'.pre-task-type-backfill.{datetime.now().strftime("%Y%m%dT%H%M%S")}.jsonl')
        shutil.copy2(path, backup)
        with open(path, 'w') as handle:
            if header:
                handle.write(json.dumps(header) + '\n')
            for record in rows:
                handle.write(json.dumps(record) + '\n')
        print(f'wrote {len(rows)} rows to {path} (backup: {backup.name})')

    return before, after, filled, unresolved


def _table(before, after):
    keys = sorted(set(before) | set(after))
    lines = [f'{"task_type":<26} {"before":>8} {"after":>8}']
    for key in keys:
        lines.append(f'{key:<26} {before.get(key, 0):>8} {after.get(key, 0):>8}')
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('corpus', nargs='?', type=Path, default=DEFAULT_CORPUS)
    parser.add_argument('--write', action='store_true',
                        help='rewrite the corpus (a timestamped backup is kept)')
    parser.add_argument('--update-stats', action='store_true',
                        help='merge the census into data/05_dataset/stats.json')
    parser.add_argument('--stats-path', type=Path, default=DEFAULT_STATS)
    args = parser.parse_args(argv)

    if not args.corpus.exists():
        print(f'{args.corpus}: not found', file=sys.stderr)
        return 2

    before, after, filled, unresolved = backfill(args.corpus, args.write)
    total = sum(before.values())
    print(f'{args.corpus}  ({total} pairs)')
    print(f'  missing before : {before.get("(none)", 0)} '
          f'({100.0 * before.get("(none)", 0) / total if total else 0:.1f}%)')
    print(f'  filled         : {sum(filled.values())}  {dict(filled)}')
    print(f'  still missing  : {len(unresolved)}')
    print()
    print(_table(before, after))
    for record in unresolved[:10]:
        prov = record.get('provenance') or {}
        print(f'  unresolved: notebook={record.get("notebook")} '
              f'source={prov.get("source") or record.get("source")!r}')

    if args.update_stats:
        stats = {}
        if args.stats_path.exists():
            stats = json.loads(args.stats_path.read_text())
        stats['task_type_counts'] = dict(after)
        stats['task_type_counts_generated_at'] = datetime.now(
            timezone.utc).isoformat(timespec='seconds')
        args.stats_path.parent.mkdir(parents=True, exist_ok=True)
        args.stats_path.write_text(json.dumps(stats, indent=1) + '\n')
        print(f'\ncensus -> {args.stats_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
