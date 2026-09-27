#!/usr/bin/env python3
"""Score candidate base models on the three jobs `aro ask` has to do.

GitLab #794.

The question the issue asks — "is a dense base as good as the 30B MoE?" —
could not be answered before, because the frozen benchmark scored one thing
(does the generated program parse) and `aro ask` has to do three:

  1. answer a question *about* ARO;
  2. write a program from a description;
  3. fix a broken one.

`Train/eval/functional/tasks.json` now carries all three, tagged with `job`,
and `functional_eval.summarise` reports a pass rate per job. This driver runs
that benchmark once per candidate and prints them side by side, so the choice
is made on evidence rather than on which model someone already downloaded.

It deliberately does **not** train anything. Comparing bases before any
fine-tuning is the cheap half of the experiment and it is the half that has
never been run; a base that cannot answer a question about ARO after reading
the proposals in its prompt will not learn to from LoRA on 16 layers.

Usage:

    python3 base_model_ab.py                     # every candidate in config
    python3 base_model_ab.py --models a b        # named candidates only
    python3 base_model_ab.py --out ab.json       # machine-readable

Each candidate is generated in a subprocess (`gen_eval.py` already does this)
so the model is unloaded before the next one loads — otherwise the second
candidate OOMs on any machine that could hold the first.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402
import functional_eval as fe  # noqa: E402


def candidates(selected=None):
    """The (label, model id) pairs to score."""
    all_of_them = config.base_model_candidates()
    if not selected:
        return all_of_them
    by_label = dict(all_of_them)
    missing = [s for s in selected if s not in by_label]
    if missing:
        raise SystemExit(
            f"unknown candidate(s): {', '.join(missing)}. "
            f"known: {', '.join(by_label)}")
    return [(s, by_label[s]) for s in selected]


def generate_with(model_id, prompts, *, max_tokens=800, timeout=1800):
    """Answer every prompt with `model_id`, in a subprocess.

    Returns a list of answers in prompt order, or `None` if the model could
    not be run at all — which is reported as "not scored" rather than as a
    score of zero. A model that will not load has not failed the benchmark.
    """
    payload = SCRIPT_DIR / '.ab_prompts.json'
    result = SCRIPT_DIR / '.ab_result.json'
    payload.write_text(json.dumps(prompts))
    cmd = [sys.executable, str(SCRIPT_DIR / 'gen_eval.py'),
           '--model', model_id,
           '--prompts', str(payload),
           '--out', str(result),
           '--max-tokens', str(max_tokens),
           '--temp', '0.0']
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    finally:
        payload.unlink(missing_ok=True)

    if proc.returncode != 0 or not result.exists():
        sys.stderr.write(f'[ab] {model_id} could not be run:\n{proc.stderr[-2000:]}\n')
        result.unlink(missing_ok=True)
        return None

    data = json.loads(result.read_text())
    result.unlink(missing_ok=True)
    return [(r.get('completion', ''), r.get('aro', ''))
            for r in data.get('results', [])]


def score(model_id, tasks, *, timeout=fe.DEFAULT_TIMEOUT):
    """Run the whole benchmark against one model."""
    answers = generate_with(model_id, [t['prompt'] for t in tasks])
    if answers is None:
        return None
    rows = []
    for task, (completion, aro) in zip(tasks, answers):
        # `write` and `fix` answers are programs, and the model wraps them in
        # prose; a `question` answer *is* the prose.
        graded = completion if task.get('grade_by') == 'doc_qa' else aro
        rows.append(fe.grade(task, graded, timeout=timeout))
    return fe.summarise(rows)


def _rate(summary, job):
    entry = (summary or {}).get('by_job', {}).get(job)
    # `eval_stats.proportion` returns the rate under the key `rate`, with the
    # Wilson interval beside it.
    return None if not entry else entry.get('rate')


def render(results):
    """A table, because the point is the comparison."""
    jobs = ('question', 'write', 'fix')
    width = max(len(label) for label, _ in results) if results else 10
    header = f'{"candidate":<{width}}  ' + '  '.join(f'{j:>9}' for j in jobs) + '   overall'
    lines = [header, '-' * len(header)]
    for label, summary in results:
        if summary is None:
            lines.append(f'{label:<{width}}  ' + '  '.join(f'{"—":>9}' for _ in jobs)
                         + '   not scored')
            continue
        cells = []
        for j in jobs:
            r = _rate(summary, j)
            cells.append('—'.rjust(9) if r is None else f'{r * 100:8.1f}%')
        overall = summary.get('pass_rate') or {}
        o = overall.get('rate')
        lines.append(f'{label:<{width}}  ' + '  '.join(cells)
                     + ('   —' if o is None else f'   {o * 100:.1f}%'))
    return '\n'.join(lines)


def _main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--models', nargs='*', default=None,
                    help='candidate labels to score (default: all)')
    ap.add_argument('--tasks', default=None, help='benchmark file')
    ap.add_argument('--out', default=None, help='write results as JSON')
    ap.add_argument('--timeout', type=int, default=fe.DEFAULT_TIMEOUT)
    args = ap.parse_args(argv)

    tasks = fe.load_tasks(args.tasks)
    jobs = sorted({t.get('job', 'write') for t in tasks})
    print(f'{len(tasks)} tasks covering: {", ".join(jobs)}\n')

    results = []
    for label, model_id in candidates(args.models):
        print(f'[ab] scoring {label} ({model_id}) …', flush=True)
        results.append((label, score(model_id, tasks, timeout=args.timeout)))

    print()
    print(render(results))

    if args.out:
        Path(args.out).write_text(json.dumps(
            {label: summary for label, summary in results}, indent=2))
        print(f'\nwrote {args.out}')

    # Not scoring a candidate is not the same as it failing, so it is not an
    # error exit — but every candidate failing to run is.
    return 0 if any(s is not None for _, s in results) else 1


if __name__ == '__main__':
    raise SystemExit(_main())
