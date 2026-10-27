#!/usr/bin/env python3
"""The frozen held-out benchmark, and the harness that scores it (GitLab #785).

Two numbers were being quoted about this model. Neither was a measurement.

The release gate's 75.5 % syntax-pass came from `Train/eval_prompts.json`,
whose 105 prompts share templates with the curated material in
`Train/Material/`. The 67 % evaluation came from a 4,000-prompt `aro ask` run
that was then folded back into training: `Train/eval_derived/README.md` records
2,679 good answers promoted to `code_generation` pairs and 1,160 repaired bad
answers promoted to feedback pairs, 8,536 rows in `ask_eval_pairs.jsonl`. The
probe set has paraphrased answers in `probefill.jsonl` *by design* — the file
says so, and says it is deliberate. `leakage.py`'s existing check compares a
holdout against the training set inside one assembled dataset, which cannot see
any of that.

So there was no untouched benchmark, and the project could not tell whether the
model had learned ARO or memorised the prompts it would be graded on.

This module is the replacement:

  * `Train/eval/benchmark/prompts.benchmark.json` — a versioned, frozen,
    stratified set of prompts written for this purpose, none of which appears
    in any mineable corpus file at character-3-gram Jaccard 0.85 or above
    (`leakage.benchmark_leakage`, and `MANIFEST.json` records the measurement).
  * `verify_frozen()` — the set is frozen by digest, so changing a prompt
    without bumping the version fails a test rather than silently moving the
    measurement.
  * `score()` — pass@1 and pass@5 by `aro check`, execution pass by `aro run`,
    and `aro test` pass for the tasks that carry tests, per stratum and
    overall.

**It is never mined.** That is mechanical, not a convention anybody has to
remember: the directory carries a `.never-mine` marker and the data files carry
`.benchmark.` in their names, `leakage.corpus_files()` excludes both, and
`Train/script/tests/test_held_out_benchmark.py` fails if any benchmark prompt
turns up in any corpus file. `leakage.assert_mineable()` is there for pipeline
code that names its inputs by hand and so goes through neither.

**It ships reference answers.** The argument against is real: a reference answer
is a correct answer sitting in the repository, and a correct answer sitting in
the repository is what got mined last time. The argument for won: a benchmark
whose own references do not pass is measuring the benchmark rather than the
model, and `--reference` is the only way to find a task whose expected output
was wrong when it was written. Scoring never reads them — `aro check`, `aro run`
and `aro test` are the judges — so the references are documentation of
satisfiability, not a scoring key, and the exclusion that protects the prompts
protects them identically.

**The harness needs no model.** `--generations` scores a file of candidate
answers, which is how a model is scored once there is one; `--stub` scores a
synthetic set through a replay oracle, which proves the arithmetic with neither
a model nor a binary; `--reference` scores what is checked in.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import eval_stats  # noqa: E402
import functional_eval  # noqa: E402

TRAIN_ROOT = SCRIPT_DIR.parent
BENCHMARK_DIR = TRAIN_ROOT / 'eval' / 'benchmark'
PROMPTS_FILE = BENCHMARK_DIR / 'prompts.benchmark.json'
MANIFEST_FILE = BENCHMARK_DIR / 'MANIFEST.json'

# The six strata GitLab #785 names. A benchmark that is 90 % one-liners would
# report a single number that moved for reasons nobody could attribute, so the
# stratum is part of every row and every report line.
STRATA = (
    'nl_application',   # natural language → application, with openapi.yaml
    'repair',           # a program plus the diagnostic it produces → the fix
    'explain',          # a question about ARO, answered in prose
    'repl',             # one statement, or a few, with no feature set
    'plugin',           # plugin authoring: manifest, host language, call site
    'tests',            # ARO-0015 Given/When/Then is the contract
)

# The weak domains the 4,000-prompt evaluation measured and GitLab #797
# catalogued: conditionals 0 %, `Throw` 2 %, `publish` 3 %, configuration 7 %,
# REST 19 %. Tagged per prompt so the report can say whether a model improved
# where it was actually bad, rather than where the corpus is thickest.
WEAK_DOMAINS = ('conditionals', 'throw', 'publish', 'configuration', 'rest')

GRADES = ('aro_check', 'execution_output', 'aro_test', 'doc_qa')

# Axes, strongest last. `aro check` says a program parses and nothing more; a
# run says it does what was asked; `aro test` asserts values rather than
# printing. Reporting them separately is the point — "75.5 % syntax pass" was
# one axis quoted as if it were the capability.
AXES = ('check', 'run', 'test', 'rubric')

DEFAULT_RUN_TIMEOUT = 15
DEFAULT_TEST_TIMEOUT = 30


# ── Loading and freezing ─────────────────────────────────────────────────────

def digest(path=None) -> str:
    """sha256 of the prompts file, bytes as committed.

    The freeze is a digest rather than a promise: `MANIFEST.json` records it,
    and a test compares. Editing a prompt is then a two-file change that shows
    up in review as what it is — a new benchmark version — instead of a silent
    change of ruler mid-measurement, which is how 75.5 % and 67 % came to be
    quoted side by side.
    """
    path = Path(path or PROMPTS_FILE)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_benchmark(path=None) -> dict:
    path = Path(path or PROMPTS_FILE)
    with open(path) as fh:
        data = json.load(fh)
    data.setdefault('_path', str(path))
    return data


def load_manifest(path=None) -> dict:
    with open(Path(path or MANIFEST_FILE)) as fh:
        return json.load(fh)


def verify_frozen(bench=None, manifest=None, prompts_path=None) -> list[str]:
    """Structural and freeze problems with the benchmark. Empty means fine.

    Returned rather than raised so a test can print all of them at once; a
    benchmark with eleven malformed rows should not be diagnosed eleven runs in
    a row.
    """
    prompts_path = Path(prompts_path or PROMPTS_FILE)
    bench = bench if bench is not None else load_benchmark(prompts_path)
    manifest = manifest if manifest is not None else load_manifest()
    problems = []

    actual = digest(prompts_path)
    if manifest.get('prompts_sha256') != actual:
        problems.append(
            f'MANIFEST.json records prompts_sha256 '
            f'{manifest.get("prompts_sha256")!r} but the file hashes to '
            f'{actual!r} — the frozen set changed without a version bump')
    if manifest.get('version') != bench.get('version'):
        problems.append(
            f'version disagrees: manifest {manifest.get("version")!r} vs '
            f'prompts {bench.get("version")!r}')

    prompts = bench.get('prompts') or []
    if not prompts:
        problems.append('no prompts')
        return problems
    if manifest.get('n_prompts') != len(prompts):
        problems.append(f'manifest n_prompts {manifest.get("n_prompts")} != '
                        f'{len(prompts)} rows')

    seen = set()
    for i, p in enumerate(prompts):
        where = p.get('id') or f'row {i}'
        for field in ('id', 'stratum', 'prompt', 'grade_by'):
            if not p.get(field):
                problems.append(f'{where}: missing {field}')
        if p.get('id') in seen:
            problems.append(f'{where}: duplicate id')
        seen.add(p.get('id'))
        if p.get('stratum') not in STRATA:
            problems.append(f'{where}: unknown stratum {p.get("stratum")!r}')
        if p.get('grade_by') not in GRADES:
            problems.append(f'{where}: unknown grade_by {p.get("grade_by")!r}')
        if p.get('grade_by') == 'execution_output' and not p.get('expected_output'):
            problems.append(f'{where}: execution_output with no expected_output')
        if p.get('grade_by') == 'aro_test':
            # Either the answer is the application and `test` is the contract,
            # or `answer_role: test` makes the answer the test file and
            # `files['main.aro']` the application it runs beside.
            if p.get('answer_role') == 'test':
                if not (p.get('files') or {}).get('main.aro'):
                    problems.append(f'{where}: answer_role test with no '
                                    'files["main.aro"] to run beside')
            elif not p.get('test'):
                problems.append(f'{where}: aro_test with no test source')
        if p.get('grade_by') == 'doc_qa' and not p.get('must_include'):
            problems.append(f'{where}: doc_qa with no must_include')
        if p.get('grade_by') != 'doc_qa' and p.get('must_include'):
            problems.append(f'{where}: must_include on a code task')

    counted = strata_counts(prompts)
    declared = manifest.get('strata') or {}
    for stratum, n in counted.items():
        if declared.get(stratum) != n:
            problems.append(f'manifest strata[{stratum}] {declared.get(stratum)} '
                            f'!= {n} rows')
    for stratum in STRATA:
        if not counted.get(stratum):
            problems.append(f'stratum {stratum} is empty — '
                            'GitLab #785 names all six')
    return problems


def strata_counts(prompts) -> dict:
    out = {}
    for p in prompts:
        out[p.get('stratum', 'unknown')] = out.get(p.get('stratum', 'unknown'), 0) + 1
    return dict(sorted(out.items()))


# ── Oracles ──────────────────────────────────────────────────────────────────

def extract_answer(reply: str):
    """(openapi.yaml, aro code) from a model reply.

    The same extraction the rest of the pipeline uses, so a reply that scores
    here scores the same way in NB19 — and so a model is not penalised for
    prose around its code, which is what `aro ask` actually emits.
    """
    from eval_metrics import extract_openapi_and_aro

    # Imported here rather than at module scope: eval_metrics pulls in the
    # evaluation stack, and `--verify` has to run on a slim image with none of
    # it (the `train:unit` job), where only the freeze and leakage checks are
    # asked for.
    return extract_openapi_and_aro(reply or '')


def _rubric(task, answer) -> bool:
    """A prose answer against must_include / must_not_include.

    Crude on purpose, and the same rubric `functional_eval.grade` applies: it
    needs no judge model, it is reproducible, and the failure it catches is the
    confident wrong answer — a `must_not_include` naming the plausible wrong
    action catches exactly that.
    """
    text = (answer or '').lower()
    if not text.strip():
        return False
    if any(p.lower() not in text for p in task.get('must_include', [])):
        return False
    if any(p.lower() in text for p in task.get('must_not_include', [])):
        return False
    return True


_ENTRY_POINT_WRAP = ('(Application-Start: Benchmark) {\n%s\n'
                     '    Return an <OK: status> for the <startup>.\n}\n')


def _runnable(task, code):
    """The answer as something `aro run` can execute.

    A REPL task's answer is a run of statements with no feature set, which is
    what makes it a REPL task. Wrapping it in an entry point is what the REPL
    itself does, and it is what lets the repl stratum be graded on *execution*
    rather than only on parsing — which matters, because "parses" is the axis
    that produced the 75.5 % nobody could interpret.
    """
    if not task.get('wrap'):
        return code
    if aro_oracle.FEATURE_SET_RE.search(code or ''):
        return code
    body = '\n'.join('    ' + ln.strip() if ln.strip() else ''
                     for ln in (code or '').strip().splitlines())
    return _ENTRY_POINT_WRAP % body


class BinaryOracle:
    """The `aro` binary as the judge: check, run, test.

    `None` on an axis means the question was not asked — no binary, or the
    task declares no expected output, or the program is a server with no
    completion to observe. Never that the answer was fine: NB21 counted a
    missing binary as a pass, and that is the shape of mistake this whole issue
    is about.
    """

    def __init__(self, binary=None, run_timeout=DEFAULT_RUN_TIMEOUT,
                 test_timeout=DEFAULT_TEST_TIMEOUT):
        self.binary = binary or aro_oracle.aro_bin()
        self.run_timeout = run_timeout
        self.test_timeout = test_timeout

    # The run and test axes need an application *directory*, because a
    # contract-first answer is two files and an `aro test` answer is three.
    # aro_oracle.run_block/test_block build a directory from one block plus
    # extras but gate on the block itself carrying an Application-Start or a
    # Test feature set, which the benchmark's test tasks deliberately do not —
    # the test file is the checked-in contract, not part of the answer.
    def _run_dir(self, command, code, extra_files, timeout, argv=None):
        env = dict(os.environ)
        # Deterministic output: statements otherwise overlap and interleave
        # (ARO-0088), so two runs of one answer can produce two transcripts.
        env['ARO_NO_DEFER'] = '1'
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'main.aro').write_text(code)
            for name, content in (extra_files or {}).items():
                target = d / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            cmd = [self.binary, command, str(d)] + list(argv or [])
            try:
                r = subprocess.run(cmd, capture_output=True, text=True,
                                   timeout=timeout, cwd=str(d), env=env)
            except subprocess.TimeoutExpired:
                return False, f'timeout after {timeout}s'
            except OSError as exc:
                return None, f'aro_not_runnable: {exc}'
            return (r.returncode == 0,
                    ((r.stdout or '') + (r.stderr or '')).strip()[:4000])

    def judge(self, task, answer) -> dict:
        row = {axis: None for axis in AXES}
        row['reason'] = ''
        if task.get('grade_by') == 'doc_qa':
            row['rubric'] = _rubric(task, answer)
            row['reason'] = ('covered the required points' if row['rubric']
                             else 'missed a required point or said a wrong one')
            return row

        openapi, code = extract_answer(answer)
        extra = dict(task.get('files') or {})
        extra.update(task.get('fixtures') or {})
        if openapi:
            extra['openapi.yaml'] = openapi
        if not (code or '').strip():
            row['check'] = False
            row['reason'] = 'no ARO in the answer'
            return row

        if self.binary is None:
            row['reason'] = 'no aro binary — nothing was asked'
            return row

        if task.get('answer_role') == 'test':
            # The answer is the test file and `files['main.aro']` is the
            # application. Handing both to check_block would write the answer
            # to main.aro and then overwrite it with the extra of the same
            # name, and then add a synthetic entry point on top — two
            # Application-Starts, and every row in the stratum failing for a
            # reason that was the harness's.
            app = (task.get('files') or {}).get('main.aro', '')
            beside = {k: v for k, v in extra.items() if k != 'main.aro'}
            beside['benchmark_tests.aro'] = code
            check_ok, check_out = self._run_dir('check', app, beside,
                                                self.run_timeout)
        else:
            check_ok, check_out = aro_oracle.check_block(
                code, binary=self.binary, extra_files=extra)
        row['check'] = check_ok
        if check_ok is not True:
            row['reason'] = (check_out or '').strip()[:300] or 'aro check failed'
            return row
        row['reason'] = 'parses'

        if task.get('expected_output') is not None:
            ran, output = self._run_dir('run', _runnable(task, code), extra,
                                        self.run_timeout,
                                        argv=task.get('argv'))
            row['ran'] = ran
            if ran is None:
                row['reason'] = output
            elif not ran:
                row['run'] = False
                row['reason'] = f'did not run: {output[:300]}'
            else:
                ok, why = functional_eval.matches(
                    output, task['expected_output'],
                    mode=task.get('mode', 'sequence'))
                row['run'] = ok
                row['reason'] = why[:300]

        if task.get('test') or task.get('answer_role') == 'test':
            # `answer_role: test` inverts the usual arrangement: the answer IS
            # the ARO-0015 test file and the application is checked in. That is
            # the only direction that works today — ARO-0015 §2.2's `When the
            # <result> from the <feature-set>.` does not execute in this
            # runtime ("Cannot when the … from the …"), and neither does an
            # `Application.<Name>` call inside a test feature set, so a
            # checked-in test cannot reach a generated application's code.
            # Measured against the binary this benchmark was frozen on; worth
            # its own issue, and not this benchmark's to fix.
            if task.get('answer_role') == 'test':
                app = (task.get('files') or {}).get('main.aro', '')
                tests = {k: v for k, v in extra.items() if k != 'main.aro'}
                tests['benchmark_tests.aro'] = code
                passed, output = self._run_dir('test', app, tests,
                                               self.test_timeout)
            else:
                tests = dict(extra)
                tests['benchmark_tests.aro'] = task['test']
                passed, output = self._run_dir('test', code, tests,
                                               self.test_timeout)
            # `aro test` exits 0 when it finds nothing to run, so an answer
            # that forgot the `Test` business-activity suffix would otherwise
            # score as a pass for having produced no tests at all.
            if passed and 'No tests found' in output:
                passed = False
                output = ('no test feature set in the answer — the business '
                          'activity has to end in Test or Tests')
            row['test'] = passed
            if passed is False:
                row['reason'] = f'aro test failed: {output[:300]}'
            elif passed:
                row['reason'] = 'Given/When/Then assertions passed'
        return row


class ReplayOracle:
    """A canned verdict per (task id, answer), for tests and for `--stub`.

    The harness has to be provable without a model and without a toolchain, or
    the reporting is as unaudited as the numbers it replaces. `train:unit` runs
    on python:3.12-slim with no `aro`; this is how the pass@k arithmetic and
    the per-stratum aggregation are tested there.
    """

    def __init__(self, verdicts, default=None):
        self.verdicts = verdicts
        self.default = default or {axis: None for axis in AXES}

    def judge(self, task, answer) -> dict:
        key = (task.get('id'), answer)
        row = self.verdicts.get(key)
        if row is None:
            row = self.verdicts.get(task.get('id'))
        row = dict(row if row is not None else self.default)
        for axis in AXES:
            row.setdefault(axis, None)
        row.setdefault('reason', 'replayed')
        return row


# ── Scoring ──────────────────────────────────────────────────────────────────

def strongest_axis(row, task):
    """Which axis this task's verdict should be summarised by.

    `aro test` over `aro run` over the rubric over `aro check`: the strongest
    judgement the task supports. A headline built from `check` alone is how
    "valid but wrong" — 161 recorded cases in the run this replaces — scored
    the same as correct.
    """
    for axis in ('test', 'run', 'rubric', 'check'):
        if row.get(axis) is not None:
            return axis
    return None


def score(tasks, generations, oracle=None, samples=None):
    """Grade candidate answers against the benchmark.

    `generations` maps task id → list of answers (one per sample). A task with
    no answers is scored as a miss on its primary axis, not skipped: a model
    that declines to answer has not passed.

    Returns (summary, rows).
    """
    oracle = oracle or BinaryOracle()
    by_id = {t['id']: t for t in tasks}
    rows = []
    for task_id, task in by_id.items():
        answers = generations.get(task_id)
        if answers is None:
            answers = []
        if isinstance(answers, str):
            answers = [answers]
        if not answers:
            axis = ('rubric' if task.get('grade_by') == 'doc_qa' else 'check')
            rows.append({'id': task_id, 'stratum': task.get('stratum'),
                         'domain': task.get('domain'),
                         'grade_by': task.get('grade_by'), 'sample': 0,
                         **{a: (False if a == axis else None) for a in AXES},
                         'reason': 'no answer offered'})
            continue
        for i, answer in enumerate(answers):
            row = oracle.judge(task, answer)
            row.update({'id': task_id, 'stratum': task.get('stratum'),
                        'domain': task.get('domain'),
                        'grade_by': task.get('grade_by'), 'sample': i})
            rows.append(row)
    return summarise(rows, by_id, samples=samples), rows


def _axis_rate(rows, axis, label=None):
    judged = [r for r in rows if r.get(axis) is not None]
    if not judged:
        return None
    return eval_stats.proportion(sum(1 for r in judged if r[axis]),
                                 len(judged), label=label)


def _pass_at_k(rows, axis, k):
    """pass@k over tasks on one axis, or None when k samples do not exist.

    Reported as None rather than as pass@1 when only one sample was generated.
    pass@5 off a greedy decode is not a smaller pass@5, it is not a pass@5.
    """
    per_task = {}
    for r in rows:
        if r.get(axis) is None:
            continue
        n, c = per_task.get(r['id'], (0, 0))
        per_task[r['id']] = (n + 1, c + (1 if r[axis] else 0))
    if not per_task:
        return None
    if any(n < k for n, _ in per_task.values()):
        return None
    return eval_stats.aggregate_pass_at_k(list(per_task.values()), k)


def summarise(rows, tasks_by_id=None, samples=None):
    """Per-axis rates and pass@k, overall / per stratum / per weak domain."""
    tasks_by_id = tasks_by_id or {}
    n_samples = samples or max(
        [1] + [r['sample'] + 1 for r in rows if 'sample' in r])

    def block(subset, label):
        out = {'label': label,
               'n_tasks': len({r['id'] for r in subset}),
               'n_generations': len(subset)}
        for axis in AXES:
            out[axis] = _axis_rate(subset, axis, label=f'{label}/{axis}')
        # pass@1 and pass@5 are reported on `aro check` because that is what
        # GitLab #785 asks for and what the 75.5 % figure measured, so the two
        # are comparable — and on the strongest axis available, because the
        # check figure alone is the one that misled.
        out['check_pass_at_1'] = _pass_at_k(subset, 'check', 1)
        out['check_pass_at_5'] = _pass_at_k(subset, 'check', 5)
        strong = []
        for r in subset:
            axis = strongest_axis(r, None)
            if axis is not None:
                strong.append({'id': r['id'], 'strongest': r[axis]})
        out['strongest'] = _axis_rate(strong, 'strongest',
                                      label=f'{label}/strongest')
        out['strongest_pass_at_1'] = _pass_at_k(strong, 'strongest', 1)
        out['strongest_pass_at_5'] = _pass_at_k(strong, 'strongest', 5)
        out['unreachable'] = sum(
            1 for r in subset if all(r.get(a) is None for a in AXES))
        return out

    summary = {'n_samples_per_task': n_samples,
               'aro_version': aro_oracle.aro_version(),
               'overall': block(rows, 'overall'),
               'by_stratum': {}, 'by_domain': {}, 'by_grade': {}}
    for stratum in sorted({r.get('stratum') for r in rows if r.get('stratum')}):
        summary['by_stratum'][stratum] = block(
            [r for r in rows if r.get('stratum') == stratum], stratum)
    for domain in sorted({r.get('domain') for r in rows if r.get('domain')}):
        summary['by_domain'][domain] = block(
            [r for r in rows if r.get('domain') == domain], domain)
    for grade in sorted({r.get('grade_by') for r in rows if r.get('grade_by')}):
        summary['by_grade'][grade] = block(
            [r for r in rows if r.get('grade_by') == grade], grade)
    return summary


def _fmt(p):
    if p is None:
        return '      -'
    return f'{p["rate"]:>6.1%} ({p["successes"]}/{p["n"]})'


def _fmt_k(v):
    return '    -' if v is None else f'{v:>5.1%}'


def print_summary(summary):
    print(f'aro {summary["aro_version"]}   '
          f'{summary["n_samples_per_task"]} sample(s) per task')
    print()
    header = (f'  {"":<16} {"aro check":>18} {"aro run":>18} '
              f'{"aro test":>18} {"explain":>18}  '
              f'{"chk p@1":>8} {"chk p@5":>8}')
    print(header)
    print('  ' + '-' * (len(header) - 2))

    def line(label, b):
        print(f'  {label:<16} {_fmt(b["check"]):>18} {_fmt(b["run"]):>18} '
              f'{_fmt(b["test"]):>18} {_fmt(b["rubric"]):>18}  '
              f'{_fmt_k(b["check_pass_at_1"]):>8} '
              f'{_fmt_k(b["check_pass_at_5"]):>8}')

    line('overall', summary['overall'])
    print()
    for stratum, b in summary['by_stratum'].items():
        line(stratum, b)
    if summary['by_domain']:
        print()
        print('  by domain (* = a weak domain from GitLab #797)')
        for domain, b in summary['by_domain'].items():
            line(('* ' if domain in WEAK_DOMAINS else '  ') + domain, b)
    unreachable = summary['overall']['unreachable']
    if unreachable:
        print()
        print(f'  {unreachable} generation(s) could not be judged at all '
              '(no binary) — not counted as passes')


# ── Inputs ───────────────────────────────────────────────────────────────────

def load_generations(path):
    """Candidate answers, as JSONL or JSON.

    Accepts `{"id": …, "output": …}` one row per sample (repeat the id for
    pass@k) and `{"id": …, "outputs": [...]}`. Taking a file rather than
    calling a model is deliberate: the harness has to be runnable against
    whatever produced the answers — a notebook, a different model, a human —
    and has to be provable with no model at all.
    """
    path = Path(path)
    raw = path.read_text()
    out = {}

    def absorb(rec):
        if not isinstance(rec, dict):
            return
        task_id = rec.get('id') or rec.get('task_id')
        if not task_id:
            return
        if isinstance(rec.get('outputs'), list):
            out.setdefault(task_id, []).extend(str(o) for o in rec['outputs'])
        else:
            answer = rec.get('output', rec.get('answer', rec.get('reply')))
            if answer is not None:
                out.setdefault(task_id, []).append(str(answer))

    if path.suffix == '.jsonl':
        for line in raw.splitlines():
            if line.strip():
                absorb(json.loads(line))
        return out
    data = json.loads(raw)
    for rec in (data if isinstance(data, list) else data.get('generations', [])):
        absorb(rec)
    return out


def reference_generations(tasks):
    """Each task's own reference answer, as a generations map.

    A reference is checked in as bare ARO; the scorer extracts from a model
    reply, so it is wrapped in the fence a reply would carry. Tasks with no
    reference are absent, and `score` records them as unanswered rather than
    as passes.
    """
    out = {}
    for task in tasks:
        ref = task.get('reference')
        if ref is None:
            continue
        if task.get('grade_by') == 'doc_qa':
            out[task['id']] = [ref]
        else:
            out[task['id']] = [f'```aro\n{ref}\n```']
            contract = (task.get('reference_files') or {}).get('openapi.yaml')
            if contract:
                out[task['id']] = [
                    f'```yaml\n{contract}\n```\n\n```aro\n{ref}\n```']
    return out


def stub_generations(tasks):
    """A synthetic candidate set: right, wrong, and silent.

    Proves the reporting discriminates without a model and without a binary —
    every third task answers correctly, every third answers with something
    that cannot pass, and every third says nothing. Used by `--stub` and by
    the unit tests, paired with `ReplayOracle`.
    """
    gens, verdicts = {}, {}
    for i, task in enumerate(tasks):
        axis = 'rubric' if task.get('grade_by') == 'doc_qa' else 'check'
        if i % 3 == 0:
            gens[task['id']] = ['correct']
            verdicts[(task['id'], 'correct')] = {axis: True}
        elif i % 3 == 1:
            gens[task['id']] = ['wrong']
            verdicts[(task['id'], 'wrong')] = {axis: False}
        # i % 3 == 2: no answer at all
    return gens, verdicts


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    ap = argparse.ArgumentParser(
        description='The frozen held-out benchmark (GitLab #785).')
    ap.add_argument('--prompts', default=None, help=f'default: {PROMPTS_FILE}')
    ap.add_argument('--verify', action='store_true',
                    help='check the freeze, the structure and the leakage gate')
    ap.add_argument('--reference', action='store_true',
                    help='score the checked-in reference answers (needs a binary)')
    ap.add_argument('--generations', default=None,
                    help='JSONL of {"id", "output"} candidate answers')
    ap.add_argument('--stub', action='store_true',
                    help='score a synthetic set through a replay oracle — '
                         'proves the harness with no model and no binary')
    ap.add_argument('--stratum', default=None, help='score one stratum only')
    ap.add_argument('--samples', type=int, default=None)
    ap.add_argument('--json', default=None, help='write the report here')
    ap.add_argument('--rows', default=None, help='write per-generation rows here')
    args = ap.parse_args(argv)

    bench = load_benchmark(args.prompts)
    tasks = bench['prompts']
    if args.stratum:
        tasks = [t for t in tasks if t.get('stratum') == args.stratum]

    if args.verify:
        import leakage
        problems = verify_frozen(bench, prompts_path=args.prompts)
        print(f'{bench["version"]}  {len(bench["prompts"])} prompts  '
              f'sha256 {digest(args.prompts)[:16]}…')
        print('  strata: ' + ', '.join(
            f'{k}={v}' for k, v in strata_counts(bench['prompts']).items()))
        for problem in problems:
            print(f'  PROBLEM  {problem}')
        print()
        report = leakage.benchmark_leakage(bench['prompts'])
        leaked = leakage.print_benchmark_leakage(report)
        return 1 if (problems or leaked) else 0

    if args.stub:
        gens, verdicts = stub_generations(tasks)
        oracle = ReplayOracle(verdicts)
    elif args.reference:
        gens, oracle = reference_generations(tasks), BinaryOracle()
        if oracle.binary is None:
            print('no `aro` binary — set ARO_BIN or build one. '
                  'Refusing to report a score nothing judged.')
            return 2
    elif args.generations:
        gens, oracle = load_generations(args.generations), BinaryOracle()
        if oracle.binary is None:
            print('no `aro` binary — set ARO_BIN or build one. '
                  'Refusing to report a score nothing judged.')
            return 2
    else:
        ap.error('one of --verify, --reference, --generations or --stub')

    summary, rows = score(tasks, gens, oracle=oracle, samples=args.samples)
    print_summary(summary)
    if args.json:
        Path(args.json).write_text(json.dumps(summary, indent=2))
    if args.rows:
        with open(args.rows, 'w') as fh:
            for r in rows:
                fh.write(json.dumps(r) + '\n')

    if args.reference:
        failed = [r for r in rows
                  if any(r.get(a) is False for a in AXES)]
        missing = [t['id'] for t in tasks if t['id'] not in gens]
        for r in failed:
            print(f'  FAIL {r["id"]:<22} {r.get("reason", "")[:120]}')
        print()
        print(f'{len(rows) - len(failed)}/{len(rows)} reference answers pass; '
              f'{len(missing)} task(s) ship no reference')
        return 1 if failed else 0
    return 0


if __name__ == '__main__':
    raise SystemExit(_main())
