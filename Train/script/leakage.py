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
import math
import random
import re
import sys
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


# ═════════════════════════════════════════════════════════════════════════════
# The held-out benchmark, and why this file grew (GitLab #785)
# ═════════════════════════════════════════════════════════════════════════════
#
# Everything above compares a holdout against the training set *inside one
# assembled dataset*. That is a real check, and it is not the one that matters,
# because the holdout is carved out of the same generated material: a prompt
# reserved from `ask_eval_pairs.jsonl` is held out from the split while 5,000
# of its siblings — same templates, same entities, paraphrased answers — stay
# in train. `reserve_holdout` then verifies the one row is absent and reports
# no leakage.
#
# Worse, the two numbers the project quotes were never put through even that.
# `Train/eval_prompts.json` (the release gate's 105 prompts, the 75.5 % figure)
# shares templates with `Train/Material/`, and the 4,000-prompt evaluation that
# produced the 67 % figure was folded back into training wholesale — 2,679 good
# answers became `code_generation` pairs and 1,160 repaired bad answers became
# feedback pairs. The model has paraphrased answers for the prompts it is
# graded on, so neither figure is a measurement of generalisation.
#
# What follows is the enforcement for a benchmark that sits *outside* all of
# that:
#
#   * `corpus_files()` / `corpus_instructions()` — every instruction the
#     pipeline could possibly train on, enumerated from one place, with the
#     benchmark mechanically excluded (marker file + naming convention).
#   * `NearDuplicateIndex` — exact character-3-gram Jaccard at a threshold,
#     fast enough to gate on. The nested loop in `leakage_report` above takes
#     ~3.5 minutes for 300 prompts against 22,800 corpus instructions, and a
#     check nobody waits for is a check nobody runs.
#   * `benchmark_leakage()` — the report, against every corpus file including
#     the eval-derived and material sets, at the 0.85 the issue names.
#
# The measure is a *character* 3-gram Jaccard rather than an embedding
# similarity, for the reason the module docstring already gives: the leakage
# mode of this pipeline is template reuse, and template reuse is lexical.

# The threshold GitLab #785 names. Not a tunable: it is the number the
# benchmark's claim of novelty is stated at, so a run that wants a different
# one is making a different claim and has to say so on the command line.
BENCHMARK_SIM_THRESHOLD = 0.85

# A directory holding this file is never mined. The marker is the mechanism —
# a promise in a README is not enforceable — and `corpus_files()` is the single
# enumerator the leakage gate and the benchmark tests both go through, so
# dropping the marker into a directory removes it from the mineable set
# everywhere at once.
NEVER_MINE_MARKER = '.never-mine'

# Belt and braces for a file copied *out* of a marked directory: a corpus file
# whose name carries this infix is excluded wherever it sits. The benchmark's
# data files are named that way, so both the marker and the convention have to
# be defeated for a benchmark prompt to reach a corpus.
BENCHMARK_NAME_INFIX = '.benchmark.'

# Corpus files, by extension. `.txt` is in because `Train/Material/prompts.txt`
# is one prompt per line, and a plain-text prompt list is exactly the kind of
# file a JSON-shaped check forgets.
_CORPUS_SUFFIXES = ('.jsonl', '.json', '.txt')

# Not corpus: lockfiles and the catalogs generated from the binary. Listed
# rather than inferred, so an unrecognised JSON file counts as corpus by
# default — the failure to avoid is a mineable file no leakage check looked at.
_CORPUS_SKIP_NAMES = frozenset({
    'aro_action_catalog.json', 'aro_action_verbs.json',
    'aro_qualifier_catalog.json',
    'requirements.txt', 'requirements.lock.darwin-py312.txt',
})

# `data/`, `Reports/` and `runs/` hold generated artefacts: the assembled
# dataset, run reports, archived runs. They are gitignored, so they differ
# machine to machine and a gate that read them would not be reproducible. They
# are also derived — every instruction in the assembled dataset came from one
# of the files that *are* enumerated, so gating the sources gates the product.
_CORPUS_SKIP_DIRS = frozenset({
    '.git', '__pycache__', '.ipynb_checkpoints', 'node_modules',
    'Reports', 'runs', 'data',
})


def train_root(start=None):
    """The `Train/` directory, resolved from this file rather than the cwd."""
    if start is not None:
        return Path(start)
    return Path(__file__).resolve().parent.parent


def is_never_mined(path, root=None):
    """True when `path` is, or sits under, something marked never-mine.

    Both mechanisms are checked because they fail differently: the marker
    protects a directory and travels with the directory, the name protects a
    file and travels with the file.
    """
    path = Path(path)
    root = Path(root) if root is not None else train_root()
    if BENCHMARK_NAME_INFIX in path.name:
        return True
    probe = path if path.is_dir() else path.parent
    while True:
        if (probe / NEVER_MINE_MARKER).exists():
            return True
        if probe == root or probe.parent == probe:
            return False
        probe = probe.parent


def never_mined_roots(root=None):
    """Every directory under Train/ that carries the marker."""
    root = Path(root) if root is not None else train_root()
    return sorted(p.parent for p in root.rglob(NEVER_MINE_MARKER))


def assert_mineable(paths, root=None):
    """Raise when any of `paths` is a never-mined file.

    For pipeline code that assembles a corpus from an explicit list of files.
    `corpus_files()` plus the test that walks it is the enforcement the
    benchmark rests on, but a notebook naming its inputs by hand goes through
    neither — one call here turns "we agreed not to train on the benchmark"
    into something that stops the run.
    """
    root = Path(root) if root is not None else train_root()
    bad = [str(p) for p in paths if is_never_mined(p, root)]
    if bad:
        raise ValueError(
            'refusing to mine the held-out benchmark (GitLab #785): '
            + ', '.join(bad))
    return list(paths)


def corpus_files(root=None):
    """Every file under Train/ the pipeline could train on, benchmark excluded.

    Enumerated rather than listed: a corpus file added to a notebook's FILES
    without being added to a leakage check is #785's own bug, one layer up.
    Anything with a corpus extension counts unless it is explicitly skipped,
    so a new generator's output is gated the day it lands.
    """
    root = Path(root) if root is not None else train_root()
    out = []
    for path in sorted(root.rglob('*')):
        if not path.is_file():
            continue
        if path.suffix not in _CORPUS_SUFFIXES:
            continue
        if path.name in _CORPUS_SKIP_NAMES or path.name.startswith('.'):
            continue
        if set(path.relative_to(root).parts[:-1]) & _CORPUS_SKIP_DIRS:
            continue
        if is_never_mined(path, root):
            continue
        out.append(path)
    return out


def _texts_from_record(rec):
    """Every instruction-shaped string in one corpus record.

    Corpus rows come in six shapes across this pipeline: `instruction`,
    `prompt`, `messages` (chat), `chosen`/`rejected` (DPO, where the prompt is
    its own key), the `cases`/`pairs` envelopes the seed files use, and the
    `prompt` key of a Material capture. A loader that knew only `instruction`
    would report zero leakage against `conversations.jsonl` and
    `antihallucination_dpo.jsonl` — which is the failure this exists to not
    have.
    """
    out = []
    if not isinstance(rec, dict):
        return [rec] if isinstance(rec, str) else out
    for key in ('instruction', 'prompt', 'question', 'input'):
        value = rec.get(key)
        if isinstance(value, str) and value.strip():
            out.append(value)
    msgs = rec.get('messages')
    if isinstance(msgs, list):
        for m in msgs:
            if isinstance(m, dict) and m.get('role') == 'user':
                content = m.get('content')
                if isinstance(content, str) and content.strip():
                    out.append(content)
    return out


_ENVELOPE_KEYS = ('tasks', 'cases', 'pairs', 'prompts', 'rows', 'examples')


def instructions_in_file(path):
    """The instruction strings in one corpus file, whatever shape it is in."""
    path = Path(path)
    try:
        raw = path.read_text(errors='replace')
    except OSError:
        return []
    if path.suffix == '.txt':
        # One prompt per line (Train/Material/prompts.txt).
        return [ln.strip() for ln in raw.splitlines() if ln.strip()]
    texts = []
    if path.suffix == '.jsonl':
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                texts.extend(_texts_from_record(json.loads(line)))
            except json.JSONDecodeError:
                continue
        return texts
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if isinstance(data, list):
        for rec in data:
            texts.extend(_texts_from_record(rec))
        return texts
    if isinstance(data, dict):
        envelope = False
        for key in _ENVELOPE_KEYS:
            value = data.get(key)
            if isinstance(value, list):
                envelope = True
                for rec in value:
                    texts.extend(_texts_from_record(rec))
        if envelope:
            return texts
        own = _texts_from_record(data)
        if own:
            return own
        # Train/Material/canonical.json: the prompt IS the key and the answer
        # is the value. Underscore keys are metadata.
        if data and all(isinstance(v, str) for v in data.values()):
            return [k for k in data if not k.startswith('_')]
    return texts


def corpus_instructions(root=None):
    """{relative path: [instruction, …]} over every mineable corpus file."""
    root = Path(root) if root is not None else train_root()
    out = {}
    for path in corpus_files(root):
        texts = instructions_in_file(path)
        if texts:
            out[str(path.relative_to(root))] = texts
    return out


# ── Near-duplicate index ─────────────────────────────────────────────────────

class NearDuplicateIndex:
    """Exact character-3-gram Jaccard lookup at a fixed threshold.

    Why an index at all: the enforcement #785 asks for is 300 benchmark
    prompts against every corpus file — 22,800 instructions and climbing. The
    pairwise loop in `leakage_report` above takes ~3.5 minutes on that, which
    is how a check ends up run once by hand and never again.

    The filter is the standard prefix filter for Jaccard (Bayardo, Xiao):
    order every n-gram by how many documents contain it and index only each
    document's rarest `len - ceil(t*len) + 1` grams. Two sets whose Jaccard is
    at least `t` must share at least one gram inside those prefixes, so a
    candidate set built from them loses nothing at or above the threshold.
    Pairs *below* the threshold can be missed, which is why `closest()`
    documents its answer as a lower bound and why the audit path
    (`--exhaustive`) exists.
    """

    def __init__(self, threshold=BENCHMARK_SIM_THRESHOLD, n=3):
        self.threshold = float(threshold)
        self.n = n
        self._texts = []
        self._labels = []
        self._grams = []
        self._postings = None
        self._df = {}

    def add(self, text, label=''):
        grams = char_ngrams(text, self.n)
        if not grams:
            return
        self._texts.append(text)
        self._labels.append(label)
        self._grams.append(grams)
        self._postings = None

    def add_all(self, texts, label=''):
        for t in texts:
            self.add(t, label)

    def __len__(self):
        return len(self._texts)

    @property
    def labels(self):
        return list(dict.fromkeys(self._labels))

    def _prefix_len(self, size):
        """How many of the rarest grams to index (or probe) at this size.

        `ceil(t*size)` is the smallest overlap any partner at the threshold can
        have with a set of this size, so everything past that many of the
        commonest grams can be dropped.
        """
        return max(1, size - math.ceil(self.threshold * size) + 1)

    def _build(self):
        if self._postings is not None:
            return
        df = {}
        for grams in self._grams:
            for g in grams:
                df[g] = df.get(g, 0) + 1
        self._df = df
        postings = {}
        for i, grams in enumerate(self._grams):
            ordered = sorted(grams, key=lambda g: (df[g], g))
            for g in ordered[:self._prefix_len(len(grams))]:
                postings.setdefault(g, []).append(i)
        self._postings = postings

    def _candidates(self, grams):
        self._build()
        size = len(grams)
        ordered = sorted(grams, key=lambda g: (self._df.get(g, 0), g))
        # Length band: |a ∩ b| <= min(|a|, |b|), so a partner more than 1/t
        # times longer, or t times shorter, cannot reach t however much it
        # shares.
        lo = self.threshold * size
        hi = size / self.threshold
        seen = set()
        for g in ordered[:self._prefix_len(size)]:
            for i in self._postings.get(g, ()):
                if i not in seen and lo <= len(self._grams[i]) <= hi:
                    seen.add(i)
        return seen

    def matches(self, text):
        """Every indexed text with Jaccard >= threshold, best first.

        Exact: the prefix filter discards only pairs that provably fall below
        the threshold.
        """
        grams = char_ngrams(text, self.n)
        if not grams:
            return []
        hits = [(jaccard(grams, self._grams[i]), self._labels[i],
                 self._texts[i]) for i in self._candidates(grams)]
        hits = [h for h in hits if h[0] >= self.threshold]
        hits.sort(key=lambda h: -h[0])
        return hits

    def closest(self, text):
        """(similarity, label, text) for the nearest candidate, or None.

        A **lower bound** on the true maximum: exact at or above the threshold,
        and whatever the filter happened to surface below it. Printed as
        `< threshold` rather than as a number when it falls short, so nobody
        quotes a filtered maximum as the benchmark's distance from the corpus.
        """
        grams = char_ngrams(text, self.n)
        if not grams:
            return None
        best = None
        for i in self._candidates(grams):
            s = jaccard(grams, self._grams[i])
            if best is None or s > best[0]:
                best = (s, self._labels[i], self._texts[i])
        return best


def build_corpus_index(root=None, threshold=BENCHMARK_SIM_THRESHOLD,
                       instructions=None):
    """A NearDuplicateIndex over every mineable corpus instruction."""
    instructions = (instructions if instructions is not None
                    else corpus_instructions(root))
    index = NearDuplicateIndex(threshold=threshold)
    for label, texts in instructions.items():
        index.add_all(texts, label=label)
    return index


# ── The benchmark gate ───────────────────────────────────────────────────────

def benchmark_leakage(prompts, root=None,
                      threshold=BENCHMARK_SIM_THRESHOLD,
                      prefix_len=DEFAULT_PREFIX_LEN,
                      instructions=None, exhaustive=False,
                      max_examples=20):
    """Is any benchmark prompt a near-duplicate of anything mineable?

    `prompts` is a list of `{'id', 'prompt'}` dicts (bare strings also work).
    An empty `violations` is the only acceptable result: a benchmark with one
    leaked prompt is a benchmark with an unknown number of leaked prompts —
    the one that was caught is evidence about the generator, not about the
    rest of the set.

    `exhaustive=True` compares every pair with no filtering. Minutes rather
    than seconds, and the only way to report a true maximum similarity *below*
    the threshold — which is the number worth recording when a benchmark is
    frozen, because "nothing above 0.85" and "nothing above 0.52" are very
    different claims.
    """
    root = Path(root) if root is not None else train_root()
    instructions = (instructions if instructions is not None
                    else corpus_instructions(root))
    items = [{'id': p.get('id', ''), 'prompt': p.get('prompt', '')}
             if isinstance(p, dict) else {'id': '', 'prompt': p}
             for p in prompts]

    report = {
        'threshold': threshold,
        'n_prompts': len(items),
        'n_corpus_files': len(instructions),
        'n_corpus_instructions': sum(len(v) for v in instructions.values()),
        'exhaustive': bool(exhaustive),
        'exact': 0,
        'near': 0,
        'violations': [],
        'per_file': {label: {'n': len(texts), 'violations': 0,
                             'max_similarity': None}
                     for label, texts in instructions.items()},
        'max_similarity': None,
        'nearest': [],
    }

    # Exact is kept separate from near for the same reason leakage_report
    # keeps them separate: an exact prefix collision is a copied prompt, and
    # it needs no similarity number to be a defect.
    exact_keys = {}
    for label, texts in instructions.items():
        for t in texts:
            exact_keys.setdefault(instruction_key(t, prefix_len), label)

    if exhaustive:
        grams = {label: [(t, char_ngrams(t)) for t in texts]
                 for label, texts in instructions.items()}

        def scan(prompt):
            pg = char_ngrams(prompt)
            best = None
            per_file = {}
            for label, entries in grams.items():
                file_best = None
                for t, tg in entries:
                    s = jaccard(pg, tg)
                    if file_best is None or s > file_best[0]:
                        file_best = (s, label, t)
                if file_best is not None:
                    per_file[label] = file_best
                    if best is None or file_best[0] > best[0]:
                        best = file_best
            return best, per_file
    else:
        index = build_corpus_index(root, threshold, instructions)

        def scan(prompt):
            return index.closest(prompt), {}

    worst = None
    for item in items:
        prompt = item['prompt']
        key = instruction_key(prompt, prefix_len)
        if key in exact_keys:
            label = exact_keys[key]
            report['exact'] += 1
            report['per_file'][label]['violations'] += 1
            if len(report['violations']) < max_examples:
                report['violations'].append({
                    'id': item['id'], 'type': 'exact', 'similarity': 1.0,
                    'prompt': prompt[:200], 'corpus_file': label,
                    'corpus_instruction': '',
                })
            continue
        best, per_file = scan(prompt)
        for label, (s, _lbl, _t) in per_file.items():
            cur = report['per_file'][label]['max_similarity']
            if cur is None or s > cur:
                report['per_file'][label]['max_similarity'] = round(s, 4)
        if best is None:
            continue
        sim, label, corpus_text = best
        if worst is None or sim > worst[0]:
            worst = (sim, item['id'], label, corpus_text, prompt)
        if sim >= threshold:
            report['near'] += 1
            report['per_file'][label]['violations'] += 1
            if len(report['violations']) < max_examples:
                report['violations'].append({
                    'id': item['id'], 'type': 'near',
                    'similarity': round(sim, 4),
                    'prompt': prompt[:200], 'corpus_file': label,
                    'corpus_instruction': corpus_text[:200],
                })
        else:
            report['nearest'].append({'id': item['id'],
                                      'similarity': round(sim, 4),
                                      'corpus_file': label})

    if worst is not None:
        report['max_similarity'] = round(worst[0], 4)
        report['max_similarity_detail'] = {
            'id': worst[1], 'corpus_file': worst[2],
            'prompt': worst[4][:200], 'corpus_instruction': worst[3][:200],
        }
    report['nearest'] = sorted(report['nearest'],
                               key=lambda r: -r['similarity'])[:max_examples]
    report['leaked'] = report['exact'] + report['near']
    return report


def print_benchmark_leakage(report, verbose=False):
    """Print a benchmark_leakage() report. True when anything leaked."""
    mode = 'exhaustive' if report.get('exhaustive') else 'indexed'
    print(f'benchmark leakage — character 3-gram Jaccard >= '
          f'{report["threshold"]}  [{mode}]')
    print(f'  {report["n_prompts"]} benchmark prompts vs '
          f'{report["n_corpus_instructions"]} instructions in '
          f'{report["n_corpus_files"]} corpus files')
    if report['max_similarity'] is None:
        print('  highest similarity : nothing reached the filter floor '
              f'(< {report["threshold"]})')
    else:
        detail = report.get('max_similarity_detail') or {}
        bound = '' if report.get('exhaustive') else ' (lower bound)'
        print(f'  highest similarity : {report["max_similarity"]}{bound}'
              f'  [{detail.get("id", "")} vs {detail.get("corpus_file", "")}]')
    print(f'  exact collisions   : {report["exact"]}')
    print(f'  near duplicates    : {report["near"]}')
    if verbose:
        for label in sorted(report['per_file']):
            info = report['per_file'][label]
            mx = info['max_similarity']
            print(f'    {label:<54} n={info["n"]:>6}  '
                  f'max={mx if mx is not None else "-":<8} '
                  f'violations={info["violations"]}')
        for near in report['nearest'][:10]:
            print(f'    nearest {near["similarity"]:<8} {near["id"]:<16} '
                  f'{near["corpus_file"]}')
    for v in report['violations']:
        print(f'  LEAK [{v["type"]}] {v["similarity"]} {v["id"]}: '
              f'{v["prompt"][:90]!r}')
        if v['corpus_instruction']:
            print(f'       in {v["corpus_file"]}: '
                  f'{v["corpus_instruction"][:90]!r}')
    return report['leaked'] > 0


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(
        description='Train/eval leakage checks (GitLab #405, #785).')
    ap.add_argument('--benchmark', default=None,
                    help='benchmark prompts file (default: the frozen '
                         'held-out benchmark under Train/eval/benchmark)')
    ap.add_argument('--threshold', type=float,
                    default=BENCHMARK_SIM_THRESHOLD)
    ap.add_argument('--exhaustive', action='store_true',
                    help='compare every pair with no prefix filter — minutes, '
                         'but reports a true maximum similarity')
    ap.add_argument('--list-corpus', action='store_true',
                    help='print the mineable corpus files and stop')
    ap.add_argument('--json', default=None, help='write the report here')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args(argv)

    root = train_root()

    if args.list_corpus:
        instructions = corpus_instructions(root)
        total = 0
        for label in sorted(instructions):
            n = len(instructions[label])
            total += n
            print(f'  {label:<58} {n:>7}')
        print(f'  {"TOTAL":<58} {total:>7}')
        print()
        for marked in never_mined_roots(root):
            print(f'  never mined: {marked.relative_to(root)}')
        return 0

    import held_out_benchmark

    bench = held_out_benchmark.load_benchmark(args.benchmark)
    report = benchmark_leakage(bench['prompts'], root=root,
                               threshold=args.threshold,
                               exhaustive=args.exhaustive)
    flagged = print_benchmark_leakage(report, verbose=args.verbose)
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2))
    return 1 if flagged else 0


if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    raise SystemExit(_main())
