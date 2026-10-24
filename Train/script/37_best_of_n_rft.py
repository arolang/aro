#!/usr/bin/env python3
"""37_best_of_n_rft.py — rejection sampling (best-of-N) over the GEN_TODO pool.

Stage 36 repairs one generation per prompt; the repair loop inherits the
first draft's shape, because the model is told exactly what the checker
objected to and fixes that. This stage takes the other road through the
same pool: sample the model N independent times per prompt, grade every
candidate exactly as stage 36 grades (check → run → tests → contract), and
keep the first passing candidate. Independent draws cost more generation
per prompt, but they are not anchored to a bad first draft, and every kept
row is a sample the student can train directly on — selection, not
correction. That is the RFT (rejection-sampling fine-tuning) recipe, and
its being the same grade gate as stage 36 is deliberate: the meaning of
"kept" must not drift between the two stages, so they share the code
rather than the prose.

To this end, 37 grades through the imported 36.grade_application() rather
than through its own copy of the gate — the same trick 34/35 use with
handle_oracle_outcome: nothing is kept that the toolchain did not verify,
and the acceptance bar cannot drift between the two stages.

    python3 Train/script/37_best_of_n_rft.py --dry-run
    python3 Train/script/37_best_of_n_rft.py --samples 4 --n 120
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402

import importlib.util


def _load_full_application_stage():
    """36 holds the framing, the extraction, and the grade gate; both
    stages must agree on what an acceptable candidate is."""
    spec = importlib.util.spec_from_file_location(
        'full_app', SCRIPT_DIR / '36_full_application_pairs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


full_app = _load_full_application_stage()

DEFAULT_TAG = 'NB37_rft'
JOURNAL_NAME = 'nb37_journal.jsonl'
DEFAULT_SAMPLES = 4


def _draw(chat_fn, instruction):
    """One independent candidate: a system prompt, the ask, no repair.

    Returns ((main_aro, openapi), raw_output). The canonicalizer runs here
    for the same reason as in stage 36 — what survives to be graded must be
    canonical, not the alias the model happened to spell.
    """
    system_prompt = getattr(chat_fn, 'system_prompt', None)
    messages = [{'role': 'user', 'content': instruction}]
    if system_prompt:
        messages = [{'role': 'system', 'content': system_prompt}] + messages
    output = chat_fn(messages)
    return full_app._canonicalize(*full_app.extract_answer(output)), output


def best_of_n(prompts, chat_fn, *, samples=DEFAULT_SAMPLES, novel=None):
    """(rows, stats). One row per prompt that had a passing candidate.

    Every candidate is graded, not just until the first pass — the grade
    tallies across all N samples say where generation actually fails,
    which is the diagnostic a bigger N (or a repair stage on the specific
    failure) rides on. `novel` is a config.NearDuplicateIndex the caller
    seeds with the existing corpus; a prompt the corpus already answers
    near-verbatim contributes nothing to the student.
    """
    samples = max(1, samples)
    stats = {'prompts': 0, 'candidates': 0, 'no_candidates': 0,
             'kept': 0, 'no_accepted': 0, 'dropped_novelty': 0,
             'dropped_check': 0, 'dropped_run': 0, 'dropped_tests': 0,
             'dropped_contract': 0, 'by_kind': {}}
    rows = []
    for prompt in prompts:
        stats['prompts'] += 1
        if novel is not None and novel.seen(prompt):
            stats['dropped_novelty'] += 1
            continue
        instruction, is_contract = full_app.build_instruction(prompt)
        kind = 'contract' if is_contract else 'program'
        accepted = None
        for candidate in range(samples):
            stats['candidates'] += 1
            (main_aro, openapi), _raw = _draw(chat_fn, instruction)
            if not (main_aro or '').strip():
                stats['no_candidates'] += 1
                continue
            ok, reason, grade = full_app.grade_application(main_aro, openapi)
            if not ok:
                key = ('dropped_check' if reason.startswith('check failed')
                       or reason.startswith('no ```aro block')
                       else 'dropped_run'
                       if reason.startswith('passes check but does not run')
                       else 'dropped_tests' if reason.startswith('colocated tests')
                       else 'dropped_contract'
                       if reason.startswith('openapi contract')
                       else 'dropped_check')
                stats[key] += 1
                continue
            if accepted is None:
                accepted = (main_aro, openapi, candidate, reason, grade)
        _journal(prompt, kept=accepted is not None, kind=kind,
                 samples=samples,
                 reason=(accepted[3] if accepted
                         else f'no passing candidate out of {samples}'))
        if novel is not None:
            novel.add(prompt)
        if accepted is None:
            stats['no_accepted'] += 1
            continue
        main_aro, openapi, candidate, reason, grade = accepted
        stats['kept'] += 1
        stats['by_kind'][kind] = stats['by_kind'].get(kind, 0) + 1
        if openapi:
            output = (f'## openapi.yaml\n```yaml\n{openapi}\n```\n\n'
                      f'## main.aro\n```aro\n{main_aro.strip()}\n```')
        else:
            output = main_aro.strip()
        rows.append({
            'instruction': instruction,
            'output': output,
            'task_type': 'full_application',
            'source': 'best_of_n',
            '_best_of_n': {
                'prompt': prompt, 'kind': kind, 'reason': reason,
                'grade': grade, 'samples': samples, 'candidate': candidate,
                'openapi': bool(openapi),
            },
        })
    return rows, stats


def _journal(prompt, kept, reason, kind, samples):
    """One line per prompt, like stage 36's journal — an interrupted run's
    record, so a rerun does not pay to regenerate a prompt by accident."""
    path = config.RUNS_DIR / JOURNAL_NAME
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(json.dumps({'prompt': prompt, 'kept': kept,
                                 'reason': reason[:300], 'kind': kind,
                                 'samples': samples}) + '\n')
    except OSError:                               # pragma: no cover
        pass


def corpus_novel_index() -> config.NearDuplicateIndex:
    """A novelty index seeded with every instruction the corpus already has.

    The RFT pool overlaps the corpus by design (the model has seen the
    shapes); the point of the filter is not to retrain what the corpus
    already says, but to catch the prompt whose better answers still say
    nothing new. The GEN_TODO prompts themselves join the index as they are
    tried, so the two stages running back to back do not reprint each other.
    """
    import leakage
    index = config.NearDuplicateIndex(threshold=0.9)
    for _file, texts in leakage.corpus_instructions().items():
        for text in texts:
            index.add(text)
    return index


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--prompts', type=Path, default=None,
                        help='prompt file (one per line); default GEN_TODO.md')
    parser.add_argument('--n', type=int, default=0,
                        help='try at most this many prompts (default all)')
    parser.add_argument('--samples', type=int, default=DEFAULT_SAMPLES,
                        help='independent draws per prompt (default 4)')
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--model', default=None,
                        help='model dir or HF id; default config.MODEL_ID')
    parser.add_argument('--temperature', type=float, default=0.8,
                        help='higher than the repair stage: spread matters '
                             'more than a polished first draft')
    parser.add_argument('--out', type=Path, default=None,
                        help='write pairs as jsonl here; the corpus is not touched')
    parser.add_argument('--no-save', action='store_true',
                        help='report only, write nothing')
    parser.add_argument('--dry-run', action='store_true',
                        help='print the pool and the framing, and stop')
    args = parser.parse_args(argv)

    prompts = full_app.prompt_pool(args.prompts, args.n, args.seed)
    print(f'prompt pool: {len(prompts)} prompts, {args.samples} samples each')
    if args.dry_run:
        for p in prompts[:5]:
            instruction, is_contract = full_app.build_instruction(p)
            print(f'  [{"contract" if is_contract else "program":8s}] '
                  f'{instruction.splitlines()[0][:110]}')
        return 0
    if not aro_oracle.aro_bin():
        print('no `aro` binary — nothing here is kept without it.',
              file=sys.stderr)
        return 2
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)

    chat_fn = full_app.make_chat_fn(args.model or config.MODEL_ID,
                                    temperature=args.temperature)
    if chat_fn is None:
        return 2

    print('seeding the novelty index from the corpus...', flush=True)
    novel = corpus_novel_index()
    rows, stats = best_of_n(prompts, chat_fn, samples=args.samples, novel=novel)
    print(stats)
    print(f'kept {stats["kept"]}/{stats["prompts"]} prompts '
          f'({stats["no_accepted"]} with no passing candidate out of '
          f'{args.samples}, {stats["dropped_novelty"]} near-duplicates)')
    if args.out:
        with open(args.out, 'w') as fh:
            for row in rows:
                fh.write(json.dumps(row) + '\n')
        print(f'wrote {len(rows)} pairs -> {args.out}')
        return 0
    if args.no_save:
        print('nothing written (--no-save)')
        return 0
    written = config.save_notebook_pairs(DEFAULT_TAG, rows)
    print(f'saved {written}/{len(rows)} pairs to the corpus ({DEFAULT_TAG})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
