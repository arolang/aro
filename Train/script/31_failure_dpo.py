#!/usr/bin/env python3
"""
31_failure_dpo.py — preference pairs mined from real compiler rejections.

data/generation_failures.jsonl records every candidate the generation
notebooks produced that FAILED `aro check`/`aro run` — instruction, the
failing code, and the toolchain's error (issue #am-2122ff in config). Over a
thousand of these triples sit unused: they are exactly the "rejected" half
of a preference pair, and unlike sampled negatives they are failures the
model family actually makes, on prompts we actually train on.

The "chosen" half comes from the validated corpus: a knowledge pair whose
instruction near-matches the failure's instruction (token-Jaccard ≥ 0.55)
and whose answer contains ARO code. Both halves therefore exist already —
no model is loaded, nothing is generated, and every chosen answer has been
through the pipeline's validation gates.

This is the compiler-feedback DPO loop from the literature (e.g. "Training
LLMs for Generating IEC 61131-3 Structured Text with Online Feedback",
arXiv:2410.22159; survey arXiv:2410.03981) built from data the pipeline was
already producing and throwing away.

Output: data/dpo/failure_pairs.jsonl in the same {prompt, chosen, rejected}
schema as dpo_pairs_raw.jsonl, for 19_preference_sft to merge. Rewritten
whole on each run (deterministic input → deterministic output).

Usage:
    python3 31_failure_dpo.py            # mine + write
    python3 31_failure_dpo.py --dry-run  # report only
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    DATA_ROOT, PAIRS_FILE, extract_aro_blocks,
)

FAILURES = DATA_ROOT / 'generation_failures.jsonl'
OUT = DATA_ROOT / 'dpo' / 'failure_pairs.jsonl'
MATCH_THRESHOLD = 0.55


def tokens(text: str) -> set:
    return {w for w in ''.join(
        c.lower() if c.isalnum() else ' ' for c in text).split() if len(w) > 2}


def jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def load_validated() -> list[tuple[set, str, str]]:
    """(instruction tokens, instruction, output) for corpus pairs with code."""
    rows = []
    for line in open(PAIRS_FILE):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if '_metadata' in d:
            continue
        inst, out = d.get('instruction'), d.get('output')
        if not inst or not out or '```aro' not in str(out):
            continue
        rows.append((tokens(inst), inst, out))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    if not FAILURES.exists():
        sys.exit(f'no {FAILURES} — nothing to mine')
    validated = load_validated()
    print(f'validated corpus answers with code: {len(validated)}')

    pairs, unmatched, malformed = [], 0, 0
    seen_prompts = set()
    for line in open(FAILURES):
        try:
            f = json.loads(line)
        except json.JSONDecodeError:
            malformed += 1
            continue
        inst, code = f.get('instruction'), f.get('code')
        if not inst or not code:
            malformed += 1
            continue
        # One preference pair per distinct prompt — repeated failures of the
        # same prompt add weight, not information, and skew the DPO set.
        key = inst.strip().lower()
        if key in seen_prompts:
            continue

        ftoks = tokens(inst)
        best, best_score = None, 0.0
        for vtoks, vinst, vout in validated:
            score = jaccard(ftoks, vtoks)
            if score > best_score:
                best, best_score = (vinst, vout), score
        if best is None or best_score < MATCH_THRESHOLD:
            unmatched += 1
            continue

        # The rejected answer is presented the way the model actually
        # answered — code in a fence — so the preference is over answers,
        # not over formats.
        rejected = code if '```' in code else f'```aro\n{code}\n```'
        error = str(f.get('error', ''))[:300]
        pairs.append({
            'prompt': inst,
            'chosen': best[1],
            'rejected': rejected,
            # Extra fields are ignored by trainers but keep the pair
            # auditable: why was this rejected, and how close was the match.
            'error': error,
            'match_score': round(best_score, 3),
            'origin': 'generation_failures',
        })
        seen_prompts.add(key)

    print(f'preference pairs: {len(pairs)}  '
          f'(unmatched: {unmatched}, malformed: {malformed})')

    if args.dry_run:
        print('dry run — nothing written')
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, 'w') as fh:
        for p in pairs:
            fh.write(json.dumps(p) + '\n')
    print(f'wrote {OUT}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
