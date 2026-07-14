"""
Held-out set management and train/eval leakage detection (issue #405).

Used by NB16 (dataset assembly), NB19 (evaluation) and NB20 (iterative loop):

  - reserve_holdout()  — carve out a persistent held-out evaluation set
    BEFORE any training split, stratified by task type. Once written, the
    same held-out set is reused on every subsequent NB16 run and its
    samples are verifiably removed from the train/valid/test pools.
  - leakage_report()   — instruction-prefix (exact, normalised) and
    character-3-gram Jaccard (near-duplicate) overlap between the training
    instructions and every evaluation set.

No external dependencies — the "embedding similarity" check is a character
n-gram Jaccard, which catches paraphrase-level template reuse (the actual
leakage mode of this pipeline: synthetic prompts built from the same
templates) without pulling in an embedding model.
"""

import json
import random
import re
from pathlib import Path

DEFAULT_PREFIX_LEN = 120
DEFAULT_SIM_THRESHOLD = 0.85

_WS_RE = re.compile(r'\s+')


def normalize_text(text):
    """Lowercase + collapse whitespace — canonical form for overlap keys."""
    return _WS_RE.sub(' ', (text or '').strip().lower())


def instruction_key(text, prefix_len=DEFAULT_PREFIX_LEN):
    return normalize_text(text)[:prefix_len]


def char_ngrams(text, n=3):
    t = normalize_text(text)
    if len(t) < n:
        return {t} if t else set()
    return {t[i:i + n] for i in range(len(t) - n + 1)}


def jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    if inter == 0:
        return 0.0
    return inter / (len(a) + len(b) - inter)


def sample_instruction(sample):
    """Extract the user instruction from a messages-format or flat sample."""
    msgs = sample.get('messages')
    if msgs:
        for m in msgs:
            if m.get('role') == 'user':
                return m.get('content', '')
    return sample.get('instruction', '') or sample.get('prompt', '')


# ── Held-out set management ──────────────────────────────────────────────────

def reserve_holdout(samples, holdout_path, fraction=0.05, min_size=30,
                    seed=1234, prefix_len=DEFAULT_PREFIX_LEN):
    """Reserve (or re-apply) a persistent held-out evaluation set.

    First run: samples `fraction` of `samples` (at least min_size, stratified
    by task_type) into `holdout_path` and returns the remainder.

    Subsequent runs: loads the existing file and removes every sample whose
    normalised instruction prefix matches a held-out instruction — so the
    held-out set stays fixed across dataset rebuilds and is verifiably
    excluded from train/valid/test.

    Returns (remaining_samples, holdout_samples).
    """
    holdout_path = Path(holdout_path)

    if holdout_path.exists():
        holdout = []
        with open(holdout_path) as f:
            for line in f:
                if line.strip():
                    holdout.append(json.loads(line))
        holdout_keys = {instruction_key(sample_instruction(s), prefix_len)
                        for s in holdout}
        remaining = [s for s in samples
                     if instruction_key(sample_instruction(s), prefix_len)
                     not in holdout_keys]
        return remaining, holdout

    # First run: stratified draw by task_type.
    rng = random.Random(seed)
    by_task = {}
    for s in samples:
        by_task.setdefault(s.get('task_type', 'unknown'), []).append(s)

    target = max(min_size, int(len(samples) * fraction))
    holdout = []
    # proportional per-task quota, at least 1 per non-tiny task
    for task, group in sorted(by_task.items()):
        quota = max(1, round(target * len(group) / max(1, len(samples))))
        quota = min(quota, len(group))
        holdout.extend(rng.sample(group, quota))
    # trim overshoot deterministically
    rng.shuffle(holdout)
    holdout = holdout[:target] if len(holdout) > target else holdout

    holdout_keys = {instruction_key(sample_instruction(s), prefix_len)
                    for s in holdout}
    remaining = [s for s in samples
                 if instruction_key(sample_instruction(s), prefix_len)
                 not in holdout_keys]

    holdout_path.parent.mkdir(parents=True, exist_ok=True)
    with open(holdout_path, 'w') as f:
        for s in holdout:
            f.write(json.dumps(s) + '\n')
    return remaining, holdout


def verify_exclusion(train_samples, holdout_samples,
                     prefix_len=DEFAULT_PREFIX_LEN):
    """Return the list of train samples that collide with the held-out set
    (should be empty)."""
    holdout_keys = {instruction_key(sample_instruction(s), prefix_len)
                    for s in holdout_samples}
    return [s for s in train_samples
            if instruction_key(sample_instruction(s), prefix_len) in holdout_keys]


# ── Leakage detection ────────────────────────────────────────────────────────

def leakage_report(train_texts, eval_sets, prefix_len=DEFAULT_PREFIX_LEN,
                   sim_threshold=DEFAULT_SIM_THRESHOLD, max_examples=5):
    """Overlap report between training instructions and evaluation prompts.

    train_texts: list of raw training instruction strings.
    eval_sets:   {set_name: [raw prompt strings]}.

    For each eval set reports:
      exact:   prompts whose normalised prefix appears verbatim in train
      near:    prompts with char-3-gram Jaccard >= sim_threshold vs any
               train instruction (excluding exact hits)

    Returns {set_name: {'n', 'exact', 'near', 'leak_fraction', 'examples'}}.
    """
    train_keys = {instruction_key(t, prefix_len) for t in train_texts}
    train_grams = [(instruction_key(t, prefix_len), char_ngrams(t)) for t in train_texts]

    report = {}
    for name, prompts in eval_sets.items():
        exact = 0
        near = 0
        examples = []
        for p in prompts:
            key = instruction_key(p, prefix_len)
            if key in train_keys:
                exact += 1
                if len(examples) < max_examples:
                    examples.append({'type': 'exact', 'prompt': p[:160]})
                continue
            grams = char_ngrams(p)
            best = 0.0
            best_train = ''
            for tk, tg in train_grams:
                s = jaccard(grams, tg)
                if s > best:
                    best = s
                    best_train = tk
                    if best >= 0.999:
                        break
            if best >= sim_threshold:
                near += 1
                if len(examples) < max_examples:
                    examples.append({'type': 'near', 'similarity': round(best, 3),
                                     'prompt': p[:160], 'train': best_train[:160]})
        n = len(prompts)
        report[name] = {
            'n': n,
            'exact': exact,
            'near': near,
            'leak_fraction': round((exact + near) / n, 4) if n else 0.0,
            'examples': examples,
        }
    return report


def print_leakage_report(report, warn_fraction=0.05):
    """Pretty-print a leakage_report(); returns True when any set exceeds
    warn_fraction leaked."""
    flagged = False
    for name, r in report.items():
        status = 'ok'
        if r['leak_fraction'] > warn_fraction:
            status = f'WARN — {r["leak_fraction"]:.1%} leaked'
            flagged = True
        print(f'  {name:<16} n={r["n"]:>5}  exact={r["exact"]:>4}  '
              f'near={r["near"]:>4}  leaked={r["leak_fraction"]:.1%}  [{status}]')
        for ex in r['examples']:
            if ex['type'] == 'exact':
                print(f'      exact: {ex["prompt"][:100]!r}')
            else:
                print(f'      near ({ex["similarity"]}): {ex["prompt"][:80]!r}')
    return flagged
