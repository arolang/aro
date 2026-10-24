"""round_eval — the loop's execution-grounded round evaluation.

The grader is faked here; the live test at the bottom checks the REAL
benchmark's ruler against the real binary (capability + fail-path on all 21
execution-graded tasks), which is the part that must never silently rot.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import functional_eval  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'round_eval', SCRIPT_DIR / 'round_eval.py')
round_eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(round_eval)


def task(uid, prompt='p', expected='42',
         reference='(Application-Start: A) { Log "x" to the <console>. }', **kw):
    t = {'id': uid, 'grade_by': 'execution_output', 'job': 'write',
         'prompt': prompt, 'expected_output': expected,
         'reference': reference}
    t.update(kw)
    return t


def grade_fake(pass_own=None, pass_foreign=None):
    """A functional_eval.grade stand-in with per-role verdicts.

    pass_own: code == the task's reference   (the capability probe)
    pass_foreign: code == another task's reference (the fail-path probe)
    """

    def grade(t, code, timeout=None):
        own = code == t.get('reference')
        passed = pass_own if own else pass_foreign
        return {'id': t.get('id'), 'grade_by': t.get('grade_by'),
                'job': t.get('job'), 'passed': passed,
                'status': 'ok', 'reason': 'fake', 'output': 'OUT'}
    return grade


@pytest.fixture
def tasks():
    return [task('a-task'),
            task('b-task', reference='(Application-Start: B) {}', expected='7')]


# ── the task set ─────────────────────────────────────────────────────────────

def test_execution_tasks_drop_prose_and_sort(tmp_path, monkeypatch):
    graded, prose = task('z-last'), task('m-prose', grade_by='doc_qa',
                                         job='question')
    monkeypatch.setattr(functional_eval, 'load_tasks',
                        lambda path=None: [graded, prose, task('a-first')])
    out = round_eval.execution_tasks()
    assert [t['id'] for t in out] == ['a-first', 'z-last']


def test_execution_tasks_read_the_real_benchmark():
    out = round_eval.execution_tasks()
    assert len(out) == 21
    assert {t['grade_by'] for t in out} <= {'execution_output', 'aro_test'}
    ids = [t['id'] for t in out]
    assert ids == sorted(ids)
    assert 'log-hello' in ids and 'fix-rebind-immutable' in ids


# ── the ruler ────────────────────────────────────────────────────────────────

def test_a_healthy_ruler_passes_both_probes(tasks, monkeypatch):
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(True, False))
    report = round_eval.ruler_report(tasks)
    assert report['usable'] == ['a-task', 'b-task']
    assert report['vacuous'] == [] and report['reference_failed'] == []
    assert report['no_reference'] == [] and report['unreachable'] == []


def test_a_ruler_that_accepts_a_foreign_answer_is_vacuous(tasks, monkeypatch):
    # The fail-path probe: task a's grade also swallows b-task's correct
    # program — the expected output does not bind, and every model would
    # score a free point the ruler cannot retract.
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(True, True))
    report = round_eval.ruler_report(tasks)
    assert report['usable'] == []
    assert report['vacuous'] == [
        {'id': 'a-task', 'accepted': 'b-task',
         'reason': "a b-task program also satisfies this task's grade"},
        {'id': 'b-task', 'accepted': 'a-task',
         'reason': "a a-task program also satisfies this task's grade"}]


def test_a_failed_reference_refuses_the_task(tasks, monkeypatch):
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(False, False))
    report = round_eval.ruler_report(tasks)
    assert report['usable'] == []
    assert [r['id'] for r in report['reference_failed']] == ['a-task', 'b-task']


def test_a_missing_binary_is_unreachable_never_a_verdict(tasks, monkeypatch):
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(None, None))
    report = round_eval.ruler_report(tasks)
    assert report['usable'] == []
    assert report['unreachable'] == ['a-task', 'b-task']


def test_a_task_without_reference_is_listed_and_unused(monkeypatch):
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(True, False))
    report = round_eval.ruler_report([task('has-ref'), task('bare', reference=None)])
    assert report['no_reference'] == ['bare']
    assert report['usable'] == ['has-ref']


def test_same_expectation_tasks_do_not_discredit_each_other(monkeypatch):
    # The fix tasks ship the same fixed program as the write task they
    # repair — a correct program for one question is also the correct answer
    # to the other's grade, so that pairing is skipped, and the probe moves
    # on to a genuinely foreign one.
    twin_a = task('a', expected='42', reference='(Application-Start: A) {}')
    twin_b = task('b', expected='42', reference='(Application-Start: B) {}')
    other = task('c', expected='7', reference='(Application-Start: C) {}')
    refs = {t['reference']: t['id'] for t in (twin_a, twin_b, other)}
    probes = []                      # (graded task, whose program, own?)

    def grade(t, code, timeout=None):
        owner = refs[code]
        own = owner == t['id']
        probes.append((t['id'], owner, own))
        return {'id': t['id'], 'grade_by': 'execution_output', 'job': 'write',
                'passed': own, 'status': 'ok',
                'reason': 'matches' if own else 'no', 'output': 'OUT'}
    monkeypatch.setattr(functional_eval, 'grade', grade)
    report = round_eval.ruler_report([twin_a, twin_b, other])
    assert len(report['vacuous']) == 0
    assert set(report['usable']) == {'a', 'b', 'c'}
    # a's fail-path probe skipped b (same expected) and graded against c.
    foreign_for_a = [(owner, own) for (uid, owner, own) in probes
                     if uid == 'a' and not own]
    assert foreign_for_a == [('c', False)]


# ── grading a model ──────────────────────────────────────────────────────────

def test_grade_model_grades_only_usable_tasks(tasks, monkeypatch):
    calls = {}

    def run_benchmark(graded, generate, timeout=None):
        calls['graded'] = graded
        return ({'pass_rate': {'rate': 0.5, 'n': 1, 'low': 0.0, 'high': 1.0},
                 'by_job': {}}, [])
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(True, False))
    monkeypatch.setattr(functional_eval, 'run_benchmark', run_benchmark)
    summary, _rows = round_eval.grade_model(lambda p: 'answer', tasks)
    assert [t['id'] for t in calls['graded']] == ['a-task', 'b-task']
    assert summary['ruler']['vacuous'] == []
    assert summary['pass_rate']['n'] == 1


def test_grade_model_excludes_a_vacuous_task(monkeypatch):
    seen = {}

    def run_benchmark(graded, generate, timeout=None):
        seen['ids'] = [t['id'] for t in graded]
        return ({'pass_rate': {'rate': 0.5, 'n': 1}, 'by_job': {}}, [])

    # a's ruler binds (a foreign program fails); b's does not (it accepts a's
    # program, so no verdict about a model through b is trustworthy).
    def grade(t, code, timeout=None):
        if code == t.get('reference'):
            passed = True
        else:
            passed = t['id'] == 'b'
        return {'id': t['id'], 'grade_by': 'execution_output', 'job': 'write',
                'passed': passed, 'status': 'ok',
                'reason': 'fake', 'output': 'OUT'}
    monkeypatch.setattr(functional_eval, 'grade', grade)
    monkeypatch.setattr(functional_eval, 'run_benchmark', run_benchmark)
    summary, _rows = round_eval.grade_model(
        lambda p: 'answer',
        [task('a'), task('b', reference='(Application-Start: B) {}', expected='7')])
    assert seen['ids'] == ['a']
    assert [v['id'] for v in summary['ruler']['vacuous']] == ['b']


def test_grade_model_refuses_to_grade_when_the_ruler_is_entirely_loose(monkeypatch):
    # Nothing usable — every task's grade also accepts a foreign answer —
    # so there is no verdict a model could earn through this benchmark.
    monkeypatch.setattr(functional_eval, 'grade', grade_fake(True, True))
    with pytest.raises(ValueError, match='vacuous=2'):
        round_eval.grade_model(
            lambda p: 'answer',
            [task('a'), task('b', reference='(Application-Start: B) {}', expected='7')])


def test_round_row_mirrors_the_eval_n_pattern():
    summary = {'pass_rate': {'rate': 0.75, 'n': 21}}
    assert round_eval.round_row(summary) == {
        'functional_pass_rate': 0.75, 'functional_n': 21}
    assert round_eval.round_row({}) == {
        'functional_pass_rate': None, 'functional_n': 0}


# ── the real benchmark, against the real binary ──────────────────────────────

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')


@needs_binary
def test_the_real_ruler_is_healthy():
    report = round_eval.ruler_report()
    assert report['reference_failed'] == [], report['reference_failed']
    assert report['vacuous'] == [], report['vacuous']
    assert report['unreachable'] == [], report['unreachable']
    assert len(report['usable']) == 21


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
