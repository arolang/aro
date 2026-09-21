"""
Curriculum ordering and execution weighting for the SFT dataset (GitLab #806).

Two things decided what the model saw most of, and neither was a choice about
teaching.

**Order.** `17_dataset_assembly` shuffles the assembled set with
`random.seed(42)` and shuffles the training split again after the verb-floor
up-sampling. mlx_lm reads the file top to bottom, so the model's first exposure
to ARO was whatever the shuffle put first — book and proposal prose as often as
a program. The evaluation shows the shape that produces: one-liners pass 58 %
while feature sets pass 75 %, which is the wrong way round for a language whose
one-liners are the simplest thing in it.

**Proportion.** `TYPE_CAPS` bounded `correction` at 4000 and `code_generation`
at 3000, and `eval_derived/` supplies 6084 correction pairs (5440 from
`ask_eval_pairs.jsonl`, 642 from `antihallucination.jsonl`, two more elsewhere)
against far fewer validated programs. Error-then-fix was the single largest
task type reaching training, and the cap was applied first-N-wins in insertion
order, so which 4000 survived was decided by the order the generators happened
to append.

There is also no way for a verified pair to count for more than an unverified
one. `SOURCE_QUALITY_SCORES` produces a `weight` field, but
`17_dataset_assembly` writes the mlx files as
`[{'messages': s['messages']} for s in train]` — the weight is stripped before
training ever sees it, and it was only ever a keep-probability for
over-represented sources anyway. Execution-verified sources (NB09's REPL pairs,
NB32's twice-executed notebook cells, `reducer.jsonl`) are not in
`SOURCE_QUALITY_SCORES` at all, so they take the 0.8 default — below the 0.95
given to unverified proposal prose.

This module supplies the order and the weight. mlx_lm has no per-sample loss
weight, so weighting is materialised as repetition, which is the only lever the
trainer actually has.
"""

import random
import re

# ── Stages ───────────────────────────────────────────────────────────────────
# Simplest first. A stage is a rung, not a category: `stage_of` maps a sample
# to the first rung it belongs on, so the file the trainer reads goes from one
# statement, to one feature set, to several files, and only then to repairs —
# which are the hardest thing in the set, because reading a broken program
# presupposes being able to read a working one.
CURRICULUM_STAGES = (
    'one_liner',           # a single statement, or a question about one
    'feature_set',         # one complete feature set
    'application',         # several feature sets / several files / a contract
    'repair',              # error -> fix, and anything correction-shaped
)

STAGE_INDEX = {name: i for i, name in enumerate(CURRICULUM_STAGES)}

# Task types that are repairs whatever their code looks like.
_REPAIR_TYPES = frozenset({'correction', 'debugging', 'error_pattern'})

# Task types that are applications by declaration.
_APPLICATION_TYPES = frozenset({'full_application', 'multi_file_application'})

_FEATURESET_RE = re.compile(r'\(\s*[\w\- ]+\s*:\s*[^)]+\)\s*\{')
_FENCE_RE = re.compile(r'```(?:aro|yaml)', re.IGNORECASE)


def _assistant_text(sample):
    msgs = sample.get('messages') or []
    for m in reversed(msgs):
        if m.get('role') == 'assistant':
            return m.get('content') or ''
    return sample.get('output') or ''


def stage_of(sample):
    """Which rung of the curriculum a sample belongs on."""
    task = (sample.get('task_type') or '').lower()
    if task in _REPAIR_TYPES:
        return 'repair'
    if task in _APPLICATION_TYPES:
        return 'application'

    text = _assistant_text(sample)
    headers = len(_FEATURESET_RE.findall(text))
    if headers >= 2 or '## openapi.yaml' in text.lower() or text.count('## ') >= 2:
        return 'application'
    if headers == 1:
        return 'feature_set'
    return 'one_liner'


# ── Execution-verified sources ───────────────────────────────────────────────
# Pairs whose answer was produced or confirmed by running the program, not by
# parsing it. These are the only rows in the corpus that carry evidence the
# code does what the prompt asked, and they were weighted below unverified
# prose.
#
# The markers are the ones the generators actually stamp, checked against the
# corpus rather than guessed:
#   * `exec_stdout` — NB09 writes it on every pair whose program it ran, and
#     nothing else does. It is the strongest marker in the corpus.
#   * source `learning_notebook` — NB32, whose answers are the captured output
#     of two independent `aro repl --json` sessions that agreed.
#   * source `eval_reducer` — eval_derived/reducer.jsonl, verified to run.
#   * an explicit `execution_verified` flag, for anything added later.
#
# `fim` is deliberately NOT here: its ground truth is a validated file, which
# means it parsed, not that it ran.
EXECUTION_VERIFIED_SOURCES = frozenset({
    'learning_notebook',
    'eval_reducer',
    'repl_execution',
})

EXECUTION_VERIFIED_TASKS = frozenset({
    'notebook_output',     # the answer IS a captured run
    'notebook_cell',
})

# How much more an execution-verified pair is worth than an unverified one.
EXECUTION_WEIGHT = 2


def is_execution_verified(sample):
    """Was this pair's answer confirmed by running something?"""
    if sample.get('execution_verified'):
        return True
    if sample.get('exec_stdout') is not None:
        return True
    src = str(sample.get('source') or '').lower().split(':')[0]
    if src in EXECUTION_VERIFIED_SOURCES:
        return True
    return str(sample.get('task_type') or '').lower() in EXECUTION_VERIFIED_TASKS


def curriculum_weight(sample, execution_weight=EXECUTION_WEIGHT):
    """How many copies of this sample the trainer should see."""
    return execution_weight if is_execution_verified(sample) else 1


def apply_execution_weight(samples, execution_weight=EXECUTION_WEIGHT,
                           seed=806):
    """Materialise the weight as repetition.

    mlx_lm has no per-sample loss weight and `17_dataset_assembly` strips the
    `weight` field before writing its files, so repetition is the only lever
    that reaches training. Copies are inserted rather than appended in a block,
    so a weighted sample does not become a run of identical rows.

    Returns (weighted_samples, n_added).
    """
    rng = random.Random(seed)
    out = []
    added = 0
    for s in samples:
        out.append(s)
        for _ in range(max(1, curriculum_weight(s, execution_weight)) - 1):
            out.append(s)
            added += 1
    rng.shuffle(out)
    return out, added


# ── Ordering ─────────────────────────────────────────────────────────────────

def order_by_curriculum(samples, seed=806):
    """Stage order, shuffled within each stage.

    Shuffling inside a stage keeps the batch composition varied without letting
    a repair land before the model has seen a working program. Deterministic:
    the same input gives the same file, which is what makes two runs
    comparable.
    """
    rng = random.Random(seed)
    buckets = {name: [] for name in CURRICULUM_STAGES}
    for s in samples:
        buckets[stage_of(s)].append(s)
    out = []
    for name in CURRICULUM_STAGES:
        bucket = buckets[name]
        rng.shuffle(bucket)
        out.extend(bucket)
    return out


def stage_composition(samples):
    """{stage: count}, in curriculum order — for the dataset report."""
    counts = {name: 0 for name in CURRICULUM_STAGES}
    for s in samples:
        counts[stage_of(s)] += 1
    return counts


def describe(samples):
    """A one-paragraph summary for the assembly log."""
    comp = stage_composition(samples)
    total = sum(comp.values()) or 1
    parts = [f'{name} {comp[name]} ({100 * comp[name] / total:.0f}%)'
             for name in CURRICULUM_STAGES]
    verified = sum(1 for s in samples if is_execution_verified(s))
    return (f'curriculum: ' + ' -> '.join(parts)
            + f'; execution-verified {verified} '
              f'({100 * verified / total:.0f}%), weighted {EXECUTION_WEIGHT}x')


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse
    import json

    ap = argparse.ArgumentParser(
        description='Report the curriculum shape of an assembled dataset '
                    '(GitLab #806).')
    ap.add_argument('dataset', help='a JSONL of {"messages": [...], ...}')
    ap.add_argument('--limit', type=int, default=None)
    args = ap.parse_args(argv)

    samples = []
    with open(args.dataset) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            samples.append(json.loads(line))
            if args.limit and len(samples) >= args.limit:
                break

    print(f'{len(samples)} samples')
    print(describe(samples))
    print()
    print('first 20 samples as the file currently orders them:')
    for s in samples[:20]:
        print(f'  {stage_of(s):<14} {(s.get("task_type") or "?"):<20} '
              f'{(s.get("source") or "?")[:40]}')
    return 0


if __name__ == '__main__':
    raise SystemExit(_main())
