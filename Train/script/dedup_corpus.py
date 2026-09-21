#!/usr/bin/env python3
"""Take the repeats out of a corpus that already has them (GitLab #784).

Deduplication ran once, at assembly, on the first 300 characters of the
instruction plus a Jaccard threshold — and never on outputs. What survived:

  * 284 repeated instructions across 131 distinct prompts,
  * 199 byte-identical (instruction, output) pairs,
  * 2 710 repeated *answers* across 706 distinct outputs — one commit message
    is the answer to 379 different prompts,
  * comment_pairs.jsonl: 23 057 rows sharing 1 149 distinct outputs, because
    the comment stage writes nine paraphrases in each direction.

Three caps, in the order they apply: an exact (instruction, output) pair is
written once; an instruction appears at most N times; an answer appears at most
N times. The third is the one that was missing and the one that matters —
twenty copies of the same answer is what memorisation looks like in a dataset.

    python3 Train/script/dedup_corpus.py CORPUS                 # report only
    python3 Train/script/dedup_corpus.py CORPUS --write         # rewrite
    python3 Train/script/dedup_corpus.py CORPUS --out clean.jsonl
    python3 Train/script/dedup_corpus.py CORPUS --max-per-output 2

Which copy survives matters: pairs are kept in file order, so the first
occurrence stays and the paraphrases that follow it go. Pass
--prefer-validated to keep the copy the runtime liked best instead.
"""
from __future__ import annotations

import argparse
import collections
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402

DEFAULT_CORPUS = config.DATA_ROOT / '02_knowledge' / 'knowledge_pairs.jsonl'


def read_rows(path: Path):
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
    return rows, header


def census(rows):
    instructions = collections.Counter()
    outputs = collections.Counter()
    pairs = collections.Counter()
    for record in rows:
        instruction, output = config.pair_fingerprint(record)
        instructions[instruction] += 1
        outputs[output] += 1
        pairs[(instruction, output)] += 1
    return {
        'rows': len(rows),
        'distinct_instructions': len(instructions),
        'distinct_outputs': len(outputs),
        'duplicate_instruction_copies': sum(c - 1 for c in instructions.values() if c > 1),
        'duplicate_output_copies': sum(c - 1 for c in outputs.values() if c > 1),
        'duplicate_pair_copies': sum(c - 1 for c in pairs.values() if c > 1),
        'most_repeated_output': outputs.most_common(1)[0][1] if outputs else 0,
    }


def _validation_rank(record):
    """A validated pair outranks an unvalidated one, and a run outranks a
    check. Used only with --prefer-validated."""
    validation = record.get('validation') or {}
    return (1 if validation.get('valid') else 0,
            validation.get('run_passed', 0),
            validation.get('check_passed', 0))


def dedup(rows, max_per_instruction=3, max_per_output=3,
          prefer_validated=False):
    order = list(range(len(rows)))
    if prefer_validated:
        order.sort(key=lambda i: (-_validation_rank(rows[i])[0],
                                  -_validation_rank(rows[i])[1], i))
    seen_pairs = set()
    instructions = collections.Counter()
    outputs = collections.Counter()
    keep = set()
    dropped = collections.Counter()
    for i in order:
        instruction, output = config.pair_fingerprint(rows[i])
        if (instruction, output) in seen_pairs:
            dropped['exact_pair'] += 1
            continue
        if max_per_instruction and instructions[instruction] >= max_per_instruction:
            dropped['instruction_cap'] += 1
            continue
        if max_per_output and outputs[output] >= max_per_output:
            dropped['output_cap'] += 1
            continue
        seen_pairs.add((instruction, output))
        instructions[instruction] += 1
        outputs[output] += 1
        keep.add(i)
    kept = [rows[i] for i in range(len(rows)) if i in keep]
    return kept, dropped


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('corpus', nargs='?', type=Path, default=DEFAULT_CORPUS)
    parser.add_argument('--write', action='store_true',
                        help='rewrite the corpus in place (backup kept)')
    parser.add_argument('--out', type=Path, help='write the cleaned corpus here')
    parser.add_argument('--max-per-instruction', type=int,
                        default=config.MAX_REPEATS_PER_INSTRUCTION)
    parser.add_argument('--max-per-output', type=int,
                        default=config.MAX_REPEATS_PER_OUTPUT)
    parser.add_argument('--prefer-validated', action='store_true',
                        help='when copies differ, keep the one the runtime '
                             'liked best rather than the first')
    args = parser.parse_args(argv)

    if not args.corpus.exists():
        print(f'{args.corpus}: not found', file=sys.stderr)
        return 2

    rows, header = read_rows(args.corpus)
    before = census(rows)
    kept, dropped = dedup(rows, args.max_per_instruction, args.max_per_output,
                          args.prefer_validated)
    after = census(kept)

    print(f'{args.corpus}')
    print(f'  caps: {args.max_per_instruction} per instruction, '
          f'{args.max_per_output} per output')
    width = max(len(k) for k in before)
    print(f'  {"":<{width}} {"before":>10} {"after":>10}')
    for key in before:
        print(f'  {key:<{width}} {before[key]:>10} {after[key]:>10}')
    print(f'  dropped: {sum(dropped.values())}  {dict(dropped)}')

    target = args.out
    if args.write:
        target = args.corpus
        backup = args.corpus.with_suffix(
            f'.pre-dedup.{datetime.now().strftime("%Y%m%dT%H%M%S")}.jsonl')
        shutil.copy2(args.corpus, backup)
        print(f'  backup: {backup.name}')
    if target:
        with open(target, 'w') as handle:
            if header:
                handle.write(json.dumps(header) + '\n')
            for record in kept:
                handle.write(json.dumps(record) + '\n')
        print(f'  wrote {len(kept)} rows -> {target}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
