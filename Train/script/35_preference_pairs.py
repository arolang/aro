#!/usr/bin/env python3
"""Preference pairs whose preferred side is better, not longer (GitLab #799).

`data/dpo/dpo_pairs_raw.jsonl` holds 717 rows carrying exactly three fields —
prompt, chosen, rejected. No reason the rejected one was rejected, no record
of where either came from, so nothing downstream can audit the signal or
re-derive it when the language moves. In 68.6% of those rows the chosen answer
is the longer one; the anti-hallucination pairs are one verb swapped in an
otherwise identical program, a negative no model has to work for; and
31_failure_dpo yields five pairs out of 2 685 recorded failures because its
Jaccard threshold almost never matches a templated prompt.

Preference data should differ in the thing being preferred and in as little
else as possible. Every pair here is built from one program in two states:

  * **rejected** — the program with one thing wrong with it, and the oracle's
    own complaint recorded alongside,
  * **chosen** — the same program with that one thing right.

They differ by a preposition, a period, a verb, a qualifier. The length
difference is a handful of characters, so length cannot be the signal, and
`reason` and `origin` travel with every row.

    python3 Train/script/35_preference_pairs.py --dry-run
    python3 Train/script/35_preference_pairs.py --out data/dpo/repair_pairs.jsonl
    python3 Train/script/35_preference_pairs.py --audit data/dpo/dpo_pairs_raw.jsonl
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import statistics
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402
import revalidate_corpus as rc  # noqa: E402


def _load_thinking_generator():
    """34_thinking_pairs holds the mutation table; both stages want the same
    "one thing wrong, and here is what the oracle said" construction."""
    spec = importlib.util.spec_from_file_location(
        'thinking_pairs', SCRIPT_DIR / '34_thinking_pairs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


thinking = _load_thinking_generator()

DEFAULT_SOURCE = SCRIPT_DIR.parent / 'Material' / 'curated.jsonl'

# How much longer the chosen side may be before the pair teaches length.
# A one-token repair moves a program by a few characters; anything beyond a
# quarter is a different answer, not a corrected one.
LENGTH_RATIO_LIMIT = 1.25


def length_bias(pairs):
    """How much of the preference is explained by length alone."""
    if not pairs:
        return {}
    deltas = [len(p['chosen']) - len(p['rejected']) for p in pairs]
    longer = sum(1 for d in deltas if d > 0)
    return {
        'pairs': len(pairs),
        'chosen_longer_pct': round(100.0 * longer / len(pairs), 1),
        'median_delta_chars': int(statistics.median(deltas)),
        'mean_chosen_chars': int(statistics.mean(len(p['chosen']) for p in pairs)),
        'mean_rejected_chars': int(statistics.mean(len(p['rejected']) for p in pairs)),
    }


def build_pairs(source: Path, limit=0, seed=0, ratio_limit=LENGTH_RATIO_LIMIT):
    stats = {'programs': 0, 'mutations_tried': 0, 'not_broken': 0,
             'length_mismatch': 0, 'pairs': 0}
    by_category = {}
    pairs = []
    verbs, _vp, _known = rc.load_catalogs()
    import random
    rng = random.Random(seed)

    for line in open(source):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        if config.is_jsonl_metadata_record(record):
            continue
        instruction = rc.prompt_text(record)
        blocks = aro_oracle.aro_blocks(rc.answer_text(record))
        if not instruction or len(blocks) != 1:
            continue
        code = blocks[0].strip()
        ok, _error = aro_oracle.check_block(code)
        if ok is not True:
            continue
        stats['programs'] += 1
        order = list(thinking.MUTATIONS)
        rng.shuffle(order)
        order.sort(key=lambda entry: by_category.get(entry[0], 0))
        for category, mutate, oracle in order:
            result = mutate(code)
            if not result:
                continue
            broken, explanation = result
            if broken.strip() == code:
                continue
            stats['mutations_tried'] += 1
            if oracle == 'catalog':
                unknown = rc.hallucinated_verbs(broken, verbs)
                if not unknown:
                    stats['not_broken'] += 1
                    continue
                reason = f'`{unknown[0]}` is not a registered action verb'
            else:
                broken_ok, broken_error = aro_oracle.check_block(broken)
                if broken_ok is not False:
                    stats['not_broken'] += 1
                    continue
                reason = thinking.first_diagnostic(broken_error)
            chosen = f'```aro\n{code}\n```'
            rejected = f'```aro\n{broken.strip()}\n```'
            ratio = max(len(chosen), len(rejected)) / max(
                1, min(len(chosen), len(rejected)))
            if ratio > ratio_limit:
                stats['length_mismatch'] += 1
                continue
            pairs.append({
                'prompt': instruction,
                'chosen': chosen,
                'rejected': rejected,
                'reason': reason,
                'reason_class': category,
                'origin': f'repair_loop:{category}',
                'oracle': oracle,
                'aro_version': aro_oracle.aro_version(),
            })
            by_category[category] = by_category.get(category, 0) + 1
            stats['pairs'] += 1
            break
        if limit and stats['pairs'] >= limit:
            break
    stats['by_category'] = by_category
    return pairs, stats


def audit(path: Path):
    rows = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        chosen, rejected = record.get('chosen'), record.get('rejected')
        # Some rows carry a message list rather than a string; what is being
        # measured is how much text each side is, either way.
        if isinstance(chosen, list):
            chosen = '\n'.join(m.get('content') or '' for m in chosen
                               if isinstance(m, dict))
        if isinstance(rejected, list):
            rejected = '\n'.join(m.get('content') or '' for m in rejected
                                 if isinstance(m, dict))
        if isinstance(chosen, str) and isinstance(rejected, str):
            rows.append({'chosen': chosen, 'rejected': rejected})
    fields = set()
    for line in open(path):
        if line.strip():
            fields |= set(json.loads(line))
    print(f'{path}')
    print(f'  fields present : {sorted(fields)}')
    print(f'  reason logged  : {"reason" in fields}')
    print(f'  origin logged  : {"origin" in fields}')
    print(f'  length bias    : {length_bias(rows)}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--audit', type=Path,
                        help='report the length bias of an existing file')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)

    if args.audit:
        audit(args.audit)
        return 0
    if not aro_oracle.aro_bin():
        print('no `aro` binary — every rejected side is rejected by the '
              'oracle, so there is nothing to do.', file=sys.stderr)
        return 2

    pairs, stats = build_pairs(args.source, args.limit, args.seed)
    print(f'{args.source}: {stats}')
    print(f'  length bias: {length_bias(pairs)}')
    print(f'  every pair carries a reason: '
          f'{all(p.get("reason") for p in pairs)}')
    if args.dry_run:
        for pair in pairs[:2]:
            print('\n--- sample ---')
            print(f'prompt  : {pair["prompt"][:100]}')
            print(f'reason  : {pair["reason"]}')
            print(f'origin  : {pair["origin"]}')
            print(f'lengths : chosen {len(pair["chosen"])} / '
                  f'rejected {len(pair["rejected"])}')
        return 0
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with open(args.out, 'w') as handle:
            for pair in pairs:
                handle.write(json.dumps(pair) + '\n')
        print(f'wrote {len(pairs)} preference pairs -> {args.out}')
        return 0
    print('nothing written — pass --out')
    return 0


if __name__ == '__main__':
    sys.exit(main())
