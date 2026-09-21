"""
The human-rated slice (GitLab #813).

`ask-eval.csv` judged 3 495 of its 4 000 rows by `aro check`, 494 by keyword
and 11 not at all, and its reason column holds nothing but the check error.
The run's own analysis names "valid but wrong" as the dominant failure, and
neither judge can see it: a program that parses, runs, and computes the wrong
thing scores exactly like one that is right.

`Train/eval/functional/` closes the half of that gap with a checkable answer.
This module is the other half — a hundred answers per release read by a person
against the four-axis rubric in `Train/eval/human/RUBRIC.md`.

Two subcommands:

    python3 human_eval.py sample --prompts … --out Train/eval/human/<v>.csv
    python3 human_eval.py score Train/eval/human/<v>.csv [--against <prev>.csv]

The slice is drawn with `eval_stats.EVAL_SEED` and stratified across prompt
categories, so two releases are rated on the same prompts. Scores come back
with Wilson intervals: a hundred rows carries about a ten-point half-width
near 50 %, which is enough to see a large change and not a small one, and
saying so is the point.
"""

import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_stats  # noqa: E402

AXES = ('correct', 'idiomatic', 'complete', 'safe')
COLUMNS = ('id', 'category', 'prompt', 'answer') + AXES + ('note',)

DEFAULT_SLICE_SIZE = 100
VALID_VERDICTS = {'yes', 'no', 'n/a', ''}


def load_prompts(path):
    """Prompts from a JSON list of {'cat', 'prompt'} or plain strings."""
    with open(path) as fh:
        data = json.load(fh)
    rows = []
    for i, item in enumerate(data):
        if isinstance(item, str):
            rows.append({'id': f'p{i:04d}', 'category': '', 'prompt': item})
        elif isinstance(item, dict) and item.get('prompt'):
            rows.append({'id': item.get('id') or f'p{i:04d}',
                         'category': item.get('cat') or item.get('category') or '',
                         'prompt': item['prompt']})
    return rows


def draw_slice(prompts, size=DEFAULT_SLICE_SIZE, seed=eval_stats.EVAL_SEED):
    """A fixed, stratified slice.

    Stratified so a category with eleven prompts is not swamped by one with a
    thousand, and seeded so the same release drawn twice gives the same sheet
    — and two releases are compared on the same rows rather than on two
    different samples of the same corpus.
    """
    from eval_metrics import stratified_sample
    sampled, composition = stratified_sample(
        prompts, size, key_fn=lambda p: p.get('category') or 'uncategorised',
        seed=seed)
    return sampled, composition


def write_sheet(rows, path, answers=None):
    """The rating sheet: prompts, optional answers, empty verdict columns."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=list(COLUMNS))
        w.writeheader()
        for r in rows:
            row = {c: '' for c in COLUMNS}
            row.update({'id': r['id'], 'category': r.get('category', ''),
                        'prompt': r['prompt']})
            if answers:
                row['answer'] = answers.get(r['id'], '')
            w.writerow(row)
    return path


def read_sheet(path):
    with open(path, newline='') as fh:
        return list(csv.DictReader(fh))


def validate_sheet(rows):
    """Complaints about a filled-in sheet, as a list of strings."""
    problems = []
    seen = set()
    for i, r in enumerate(rows, start=2):
        rid = r.get('id') or f'(row {i})'
        if rid in seen:
            problems.append(f'{rid}: duplicate id')
        seen.add(rid)
        for axis in AXES:
            v = (r.get(axis) or '').strip().lower()
            if v not in VALID_VERDICTS:
                problems.append(
                    f'{rid}: {axis} is {v!r}; expected yes, no or n/a')
        if all(not (r.get(a) or '').strip() for a in AXES):
            problems.append(f'{rid}: not rated')
        if (r.get('correct') or '').strip().lower() == 'no' \
                and not (r.get('note') or '').strip():
            problems.append(f'{rid}: marked incorrect with no note — the note '
                            f'is the only record of WHY, and "valid but wrong" '
                            f'is the failure this slice exists to catch')
    return problems


def score_sheet(rows, floor=eval_stats.MIN_PROMPTS_PER_TASK):
    """Per-axis rates with intervals.

    'n/a' is excluded from an axis's denominator rather than counted as a
    pass. An axis rated on fewer than `floor` rows is reported with
    `underpowered` set, and the caller should print that rather than the rate
    alone.
    """
    out = {'n_rows': len(rows), 'axes': {}}
    for axis in AXES:
        yes = sum(1 for r in rows
                  if (r.get(axis) or '').strip().lower() == 'yes')
        rated = sum(1 for r in rows
                    if (r.get(axis) or '').strip().lower() in ('yes', 'no'))
        out['axes'][axis] = eval_stats.proportion(yes, rated, label=axis)
        out['axes'][axis]['underpowered'] = rated < floor
    out['all_four'] = eval_stats.proportion(
        sum(1 for r in rows
            if all((r.get(a) or '').strip().lower() in ('yes', 'n/a')
                   for a in AXES)
            and any((r.get(a) or '').strip() for a in AXES)),
        sum(1 for r in rows if any((r.get(a) or '').strip() for a in AXES)),
        label='all four')
    return out


def compare_sheets(current, previous):
    """Per-axis verdicts between two rated sheets."""
    a = score_sheet(previous)['axes']
    b = score_sheet(current)['axes']
    out = {}
    for axis in AXES:
        if not a[axis]['n'] or not b[axis]['n']:
            out[axis] = ('no data', None)
            continue
        out[axis] = eval_stats.compare(a[axis], b[axis])
    return out


# ── CLI ──────────────────────────────────────────────────────────────────────

def _cmd_sample(args):
    prompts = load_prompts(args.prompts)
    rows, composition = draw_slice(prompts, args.size)
    answers = None
    if args.answers:
        with open(args.answers) as fh:
            answers = json.load(fh)
    path = write_sheet(rows, args.out, answers)
    print(f'{len(rows)} prompts -> {path}')
    print('composition:', ', '.join(f'{k} {v}' for k, v in composition.items()))
    print(f'seed {eval_stats.EVAL_SEED} — do not change it, or the next '
          f'release is rated on different prompts')
    print(f'rubric: Train/eval/human/RUBRIC.md')
    return 0


def _cmd_score(args):
    rows = read_sheet(args.sheet)
    problems = validate_sheet(rows)
    if problems:
        print(f'{len(problems)} problem(s) with the sheet:')
        for p in problems[:40]:
            print(f'  {p}')
        if not args.force:
            return 2

    result = score_sheet(rows)
    print(f'{result["n_rows"]} rows\n')
    for axis in AXES:
        p = result['axes'][axis]
        if not p['n']:
            print(f'  {axis:<12} not rated')
            continue
        line = (f'  {axis:<12} {p["rate"]:.0%} '
                f'[{p["low"]:.0%}-{p["high"]:.0%}]  n={p["n"]}')
        if p['underpowered']:
            line += f'  UNDERPOWERED (floor {eval_stats.MIN_PROMPTS_PER_TASK})'
        print(line)
    allf = result['all_four']
    if allf['n']:
        print(f'\n  {"all four":<12} {allf["rate"]:.0%} '
              f'[{allf["low"]:.0%}-{allf["high"]:.0%}]  n={allf["n"]}')

    if args.against:
        print(f'\nagainst {args.against}:')
        for axis, (verdict, _) in compare_sheets(
                rows, read_sheet(args.against)).items():
            print(f'  {axis:<12} {verdict}')
    return 0


def _main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('sample', help='draw a rating sheet')
    s.add_argument('--prompts', required=True)
    s.add_argument('--out', required=True)
    s.add_argument('--size', type=int, default=DEFAULT_SLICE_SIZE)
    s.add_argument('--answers', default=None,
                   help='JSON {prompt_id: answer} to pre-fill the sheet')
    s.set_defaults(func=_cmd_sample)

    t = sub.add_parser('score', help='score a filled-in sheet')
    t.add_argument('sheet')
    t.add_argument('--against', default=None,
                   help='a previous release\'s sheet, to compare')
    t.add_argument('--force', action='store_true',
                   help='score despite validation problems')
    t.set_defaults(func=_cmd_score)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(_main())
