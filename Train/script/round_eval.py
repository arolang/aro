#!/usr/bin/env python3
"""round_eval.py — the iterative loop's evaluation, by execution not by parse
(GitLab #787, on the grading axis of #813).

The loop's own metric is `syntax_pass_rate`: `aro check` over 60 contract
prompts. A program that parses, runs, and computes the wrong thing scores
exactly like one that is right — the same blind spot functional_eval (#813)
was built to close for the release gate, and the one the 2026-08 loop run
rode for eight rounds while debugging and code generation drifted. What was
missing was the loop-facing half: the per-round functional grade, and a ruler
checked before the loop burns hours on it.

Two ruler checks, both cheap and both required:

  * **capability** — each task's own reference solution must pass its grade.
    A benchmark whose references do not pass measures itself, not the model.
  * **fail-path** — a genuinely wrong program must fail. The wrong program
    comes from another task's reference (deterministic by sorted task order),
    never the task's own: if task B's correct answer also satisfies task A's
    grade, A's expected output does not bind, and every model bound for that
    task would score a free point the ruler cannot retract.

Tasks that fail either check are dropped from the graded set and reported,
not silently trusted. The per-round grade then runs the model over the
surviving prompts and returns the interval-bounded rate the loop's
round_metrics records as `functional_pass_rate` / `functional_n` — the keys
`select_promotion` prefers, falling back to the parse rate only for smoke
runs where the functional grade was skipped.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import functional_eval  # noqa: E402

# The loop trains code, not prose: doc_qa tasks are graded by rubric offline
# (release gate, #813) and say nothing about a generated program.
EXECUTION_GRADES = ('execution_output', 'aro_test')
JOBS = ('write', 'fix')


def execution_tasks(path=None):
    """The functional tasks a round can grade, in a stable order.

    Sorted by id so the same tasks grade in the same order every round — the
    cross-round comparison is paired, and a benchmark that reshuffles itself
    between rounds is not an instrument.
    """
    return sorted(
        (t for t in functional_eval.load_tasks(path)
         if t.get('grade_by') in EXECUTION_GRADES and t.get('job') in JOBS),
        key=lambda t: t.get('id') or '')


def _same_expectation(a, b):
    """Two tasks whose expected output normalises alike cannot discredit
    each other's rulers — the fix tasks ship the same fixed program as the
    write task it repairs, and that program is right for both questions."""
    ea = functional_eval.normalise(a.get('expected_output') or '')
    eb = functional_eval.normalise(b.get('expected_output') or '')
    return ea == eb


def ruler_report(tasks=None, timeout=functional_eval.DEFAULT_TIMEOUT):
    """Can this benchmark tell a right program from a wrong one?

    Returns {'usable': [id], 'no_reference': [id], 'unreachable': [id],
             'reference_failed': [{'id', 'reason'}],
             'vacuous': [{'id', 'accepted'}]} — `usable` is the graded set,
    the other four are the reasons a task was refused it.

    `unreachable` means the binary was missing, which is not a verdict about
    the task and may clear on the next run; `reference_failed` and `vacuous`
    are defects in the benchmark file and will not clear on their own.
    """
    tasks = execution_tasks() if tasks is None else tasks
    referenced = [t for t in tasks if t.get('reference')]
    report = {
        'usable': [],
        'no_reference': [t.get('id') for t in tasks if not t.get('reference')],
        'unreachable': [],
        'reference_failed': [],
        'vacuous': [],
    }
    for _i, task in enumerate(referenced):
        gid = task.get('id')
        own = functional_eval.grade(task, task['reference'], timeout=timeout)
        if own['passed'] is None:
            report['unreachable'].append(gid)
            continue
        if own['passed'] is not True:
            report['reference_failed'].append({'id': gid, 'reason': own['reason']})
            continue
        # Fail-path: the first foreign reference that is not answering this
        # same question, and whether this task's grade still rejects it.
        decided = False
        for wrong in referenced:
            if wrong is task or _same_expectation(task, wrong):
                continue
            decided = True
            verdict = functional_eval.grade(task, wrong['reference'],
                                            timeout=timeout)
            if verdict['passed'] is None:
                report['unreachable'].append(gid)
            elif verdict['passed'] is not False:
                report['vacuous'].append(
                    {'id': gid, 'accepted': wrong.get('id'),
                     'reason': (f"a {wrong.get('id')} program also satisfies "
                                f"this task's grade")})
            else:
                report['usable'].append(gid)
            break
        if not decided:
            # Every other reference answers the same question; capability
            # alone decides.
            report['usable'].append(gid)
    return report


def grade_model(generate, tasks=None,
                timeout=functional_eval.DEFAULT_TIMEOUT):
    """Grade one model over the execution-graded benchmark.

    generate: callable(prompt) -> the model's reply, the shape
    functional_eval.run_benchmark expects. Its ARO is extracted the same way
    the rest of the pipeline extracts it.

    Returns (summary, rows). The summary carries `ruler` — the ruler report
    the graded set was drawn from — so a reader can see which tasks stood
    behind the rate, and which were refused and why.
    """
    tasks = execution_tasks() if tasks is None else list(tasks)
    report = ruler_report(tasks, timeout=timeout)
    usable = {t['id'] for t in tasks if t.get('id') in report['usable']}
    graded = [t for t in tasks if t.get('id') in usable]
    if not graded:
        raise ValueError(
            'no functional task survived the ruler check '
            f'(reference_failed={len(report["reference_failed"])}, '
            f'vacuous={len(report["vacuous"])}, '
            f'unreachable={len(report["unreachable"])}) '
            '— the benchmark cannot grade a model right now')
    summary, rows = functional_eval.run_benchmark(graded, generate,
                                                  timeout=timeout)
    summary['ruler'] = report
    return summary, rows


def round_row(summary):
    """The keys the loop's round_metrics entries gain (mirrors `eval_n`)."""
    rate = summary.get('pass_rate') or {}
    return {'functional_pass_rate': rate.get('rate'),
            'functional_n': rate.get('n', 0)}


if __name__ == '__main__':
    # No model needed: verify the ruler itself.
    _report = ruler_report()
    for _key in ('usable', 'no_reference', 'unreachable'):
        print(f'{_key:<17}: {len(_report[_key])}')
        for _gid in _report[_key]:
            print(f'    {_gid}')
    for _key in ('reference_failed', 'vacuous'):
        print(f'{_key:<17}: {len(_report[_key])}')
        for _item in _report[_key]:
            print(f'    {_item["id"]}: {_item["reason"][:110]}')
    print(f"graded set: {len(_report['usable'])} tasks")
