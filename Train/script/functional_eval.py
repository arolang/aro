"""
Functional evaluation: did the program run, and did it print what was asked?
(GitLab #813)

"Good" meant `aro check` passed. Of the 4 000 rows in the recorded `ask-eval`
run, 3 495 were judged by `aro check`, 494 by keyword and 11 not at all, and
the reason column holds nothing but the check error. The dominant failure in
that run's own analysis is "valid but wrong", which neither judge can see —
a program that parses, runs, and computes the wrong thing scores exactly like
one that is right.

The format for a stronger judgement was already written down and never
implemented. `Train/eval_prompts.json` carries an entry with

    "fixtures": {"sample.txt": "a\\nb\\nc\\n"},
    "expected_output": "3",
    "grade_by": "execution_output",

added for GitLab #486, and a search of the repository for `grade_by` outside
that one data file returns nothing. This module implements it, and
`Train/eval/functional/tasks.json` is the benchmark that uses it.

The comparison is the one `Tests/IntegrationTestsRunner` already applies to
every example in the repository, ported to python: normalise both sides —
strip ANSI, strip the interpreter's `[Feature Set]` line prefixes, collapse
timings, substitute timestamps — then match each expected line as an anchored
pattern, with a placeholder vocabulary (`__NUMBER__`, `__TIMESTAMP__`,
`__HASH__`, …) for values that cannot be fixed.

Where the harness matches the whole transcript line for line, this defaults to
`sequence`: the expected lines must appear in order, and other lines may sit
between them. The examples in the repository are fixed, so their whole output
is the contract; a generated program's contract is its answer, and a correct
program that also logs a label is still correct. `mode: strict` and
`mode: occurrence` are available per task.

Three grades, in descending strength:

  * `aro_test`   — the generated application must pass a checked-in `aro test`
                   file (ARO-0015 Given/When/Then). The strongest: it asserts
                   the program's values, not its printing.
  * `execution_output` — the program must run and print the expected output.
  * `aro_check`  — it parses. Kept only so an existing prompt set can be
                   scored on the same axis, and reported separately so a
                   headline number can never be built out of it.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_stats  # noqa: E402

DEFAULT_TIMEOUT = eval_stats.EXEC_TIMEOUT_SECONDS
TASKS_FILE = (Path(__file__).resolve().parent.parent
              / 'eval' / 'functional' / 'tasks.json')


def aro_bin():
    """The aro binary, the way the rest of the pipeline finds it."""
    return os.environ.get('ARO_BIN') or shutil.which('aro') or 'aro'


# ── Normalisation (ported from Tests/IntegrationTestsRunner/lib) ─────────────

_ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')
# The interpreter prefixes each line with the feature set that printed it; a
# compiled binary does not. One expected output has to serve both.
_PREFIX_RE = re.compile(r'^\[[A-Za-z][A-Za-z0-9 _-]*\][ \t]*')
_TIMING_RE = re.compile(r'\s*\((?:<\s*)?\d+(?:\.\d+)?\s*ms\)')
_ISO_RE = re.compile(
    r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?')
_OBJC_RE = re.compile(r'^objc\[\d+\]:.*$', re.MULTILINE)


def normalise(text):
    """Make interpreter and compiled output comparable to one expected file."""
    text = (text or '').replace('\r\n', '\n').replace('\r', '\n')
    text = _ANSI_RE.sub('', text)
    text = _OBJC_RE.sub('', text)
    lines = []
    for line in text.split('\n'):
        line = _PREFIX_RE.sub('', line.strip())
        line = _TIMING_RE.sub('', line)
        line = _ISO_RE.sub('__TIMESTAMP__', line)
        lines.append(line.rstrip())
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    return '\n'.join(lines)


# ── Placeholders ─────────────────────────────────────────────────────────────

PLACEHOLDERS = {
    '__ID__': r'[a-f0-9]{15,20}',
    '__UUID__': r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
                r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
    '__TIMESTAMP__': r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?'
                     r'(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?|__TIMESTAMP__',
    '__DATE__': r'\d{4}-\d{2}-\d{2}',
    '__NUMBER__': r'-?\d+(?:\.\d+)?',
    '__STRING__': r'.+?',
    '__HASH__': r'[a-f0-9]{32,64}',
    '__TIME__': r'\d+(?:\.\d+)?',
    '__PORT__': r'\d{2,5}',
}


def line_pattern(expected_line):
    """A regex for one expected line: literal, except for placeholders."""
    parts = re.split(r'(__[A-Z_]+__)', expected_line)
    out = []
    for part in parts:
        if part in PLACEHOLDERS:
            out.append(f'(?:{PLACEHOLDERS[part]})')
        else:
            out.append(re.escape(part))
    return ''.join(out)


def matches(actual, expected, mode='sequence'):
    """Does `actual` satisfy `expected`?

    'sequence' (default): the expected lines appear in order, other lines may
        sit between them. This is the right default for *generated* code,
        where the answer is the contract and the framing is not: a correct
        program that also logs a label is still correct, and the interpreter
        adds its own `[OK] startup` line that a compiled binary does not.
    'strict': same number of lines, in order, each anchored — what
        `Tests/IntegrationTestsRunner` applies to the fixed examples in the
        repository, where the whole transcript is the contract.
    'occurrence': every non-blank expected line appears somewhere, in any
        order.
    """
    a = normalise(actual)
    e = normalise(expected)
    if mode == 'sequence':
        a_lines = a.split('\n') if a else []
        i = 0
        for line in e.split('\n'):
            if not line.strip():
                continue
            pat = line_pattern(line)
            while i < len(a_lines) and not re.fullmatch(pat, a_lines[i]):
                i += 1
            if i >= len(a_lines):
                return False, (f'expected line {line!r} not found (in order)'
                               f'\n--- actual ---\n{a}')
            i += 1
        return True, 'expected lines present in order'

    if mode == 'occurrence':
        for line in e.split('\n'):
            if not line.strip():
                continue
            if not re.search(line_pattern(line), a, re.MULTILINE):
                return False, f'missing line: {line!r}'
        return True, 'all expected lines present'

    a_lines = a.split('\n') if a else []
    e_lines = e.split('\n') if e else []
    if len(a_lines) != len(e_lines):
        return False, (f'expected {len(e_lines)} line(s), got {len(a_lines)}'
                       f'\n--- expected ---\n{e}\n--- actual ---\n{a}')
    for i, (al, el) in enumerate(zip(a_lines, e_lines)):
        if not re.fullmatch(line_pattern(el), al):
            return False, (f'line {i + 1}: expected {el!r}, got {al!r}')
    return True, 'exact match'


# ── Running a generated program ──────────────────────────────────────────────

def _materialise(directory, code, files=None, fixtures=None):
    d = Path(directory)
    written = dict(files or {})
    if code is not None:
        written.setdefault('main.aro', code)
    for name, content in written.items():
        target = d / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    for name, content in (fixtures or {}).items():
        target = d / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    return d


def run_program(code, *, files=None, fixtures=None, timeout=DEFAULT_TIMEOUT,
                argv=None):
    """`aro run` a generated program. Returns (status, output).

    status is 'ok', 'failed', 'timeout' or 'no_binary'. Output is stdout and
    stderr concatenated, the same stream the integration harness compares.
    """
    with tempfile.TemporaryDirectory() as tmp:
        d = _materialise(tmp, code, files, fixtures)
        cmd = [aro_bin(), 'run', str(d)] + list(argv or [])
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=timeout, cwd=str(d))
        except FileNotFoundError:
            return 'no_binary', 'aro not found'
        except subprocess.TimeoutExpired:
            return 'timeout', f'no exit within {timeout}s'
        out = (r.stdout or '') + (r.stderr or '')
        return ('ok' if r.returncode == 0 else 'failed'), out


def check_program(code, *, files=None, timeout=DEFAULT_TIMEOUT):
    """`aro check`. Returns (status, output) as above."""
    with tempfile.TemporaryDirectory() as tmp:
        d = _materialise(tmp, code, files, None)
        try:
            r = subprocess.run([aro_bin(), 'check', str(d)],
                               capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            return 'no_binary', 'aro not found'
        except subprocess.TimeoutExpired:
            return 'timeout', f'no exit within {timeout}s'
        return ('ok' if r.returncode == 0 else 'failed'), \
               (r.stdout or '') + (r.stderr or '')


def run_aro_test(code, test_source, *, files=None, fixtures=None,
                 timeout=DEFAULT_TIMEOUT):
    """`aro test` the generated application against a checked-in test file.

    The strongest grade: ARO-0015 Given/When/Then asserts the program's values
    rather than its printing, so a program that computes the right answer and
    formats it differently still passes, and one that prints a plausible wrong
    number does not.
    """
    with tempfile.TemporaryDirectory() as tmp:
        d = _materialise(tmp, code, files, fixtures)
        (d / 'benchmark_tests.aro').write_text(test_source)
        try:
            r = subprocess.run([aro_bin(), 'test', str(d)],
                               capture_output=True, text=True, timeout=timeout,
                               cwd=str(d))
        except FileNotFoundError:
            return 'no_binary', 'aro not found'
        except subprocess.TimeoutExpired:
            return 'timeout', f'no exit within {timeout}s'
        out = (r.stdout or '') + (r.stderr or '')
        return ('ok' if r.returncode == 0 else 'failed'), out


# ── Grading one task ─────────────────────────────────────────────────────────

def grade(task, code, timeout=DEFAULT_TIMEOUT):
    """Grade one generated answer against one task.

    Returns {'id', 'grade_by', 'passed', 'status', 'reason', 'output'}.
    `passed` is None when the verdict could not be reached (no binary), so an
    unreachable toolchain never counts as a pass — the way it does today in
    NB21, where a missing `aro` makes every generated sample acceptable.
    """
    gid = task.get('id') or task.get('prompt', '')[:40]
    grade_by = task.get('grade_by', 'execution_output')
    files = dict(task.get('files') or {})
    fixtures = task.get('fixtures') or {}
    result = {'id': gid, 'grade_by': grade_by, 'passed': False,
              'status': None, 'reason': '', 'output': ''}

    if not (code or '').strip():
        result['status'] = 'no_code'
        result['reason'] = 'no ARO in the answer'
        return result

    if grade_by == 'aro_test':
        status, out = run_aro_test(code, task['test'], files=files,
                                   fixtures=fixtures, timeout=timeout)
        result.update(status=status, output=out[:2000])
        if status == 'no_binary':
            result['passed'] = None
            result['reason'] = 'aro binary unavailable'
        elif status != 'ok':
            result['reason'] = f'aro test {status}'
        else:
            result['passed'] = True
            result['reason'] = 'all Given/When/Then assertions passed'
        return result

    if grade_by == 'aro_check':
        status, out = check_program(code, files=files, timeout=timeout)
        result.update(status=status, output=out[:2000])
        if status == 'no_binary':
            result['passed'] = None
            result['reason'] = 'aro binary unavailable'
        else:
            result['passed'] = status == 'ok'
            result['reason'] = 'parses' if status == 'ok' else out.strip()[:300]
        return result

    status, out = run_program(code, files=files, fixtures=fixtures,
                              timeout=timeout, argv=task.get('argv'))
    result.update(status=status, output=out[:2000])
    if status == 'no_binary':
        result['passed'] = None
        result['reason'] = 'aro binary unavailable'
        return result
    if status != 'ok':
        result['reason'] = f'did not run ({status}): {out.strip()[:300]}'
        return result
    ok, why = matches(out, task['expected_output'],
                      mode=task.get('mode', 'sequence'))
    result['passed'] = ok
    result['reason'] = why
    return result


# ── Running the benchmark ────────────────────────────────────────────────────

def load_tasks(path=None):
    path = Path(path or TASKS_FILE)
    with open(path) as fh:
        data = json.load(fh)
    return data['tasks'] if isinstance(data, dict) else data


def run_benchmark(tasks, generate, timeout=DEFAULT_TIMEOUT, samples=1):
    """Grade a model over the benchmark.

    generate: callable(prompt) -> the model's reply. Its ARO is extracted the
    same way the rest of the pipeline extracts it.
    samples: generations per task, for pass@k (GitLab #786).

    Returns (summary, rows).
    """
    from eval_metrics import extract_openapi_and_aro

    rows = []
    for task in tasks:
        per_task = []
        for _ in range(max(1, samples)):
            reply = generate(task['prompt'])
            openapi, code = extract_openapi_and_aro(reply)
            t = dict(task)
            if openapi:
                t.setdefault('files', {})
                t['files'] = {**t.get('files', {}), 'openapi.yaml': openapi}
            r = grade(t, code, timeout=timeout)
            r['prompt'] = task['prompt']
            per_task.append(r)
        rows.extend(per_task)

    return summarise(rows, samples), rows


def summarise(rows, samples=1):
    """Pass rate with an interval, and pass@k where more than one sample ran."""
    judged = [r for r in rows if r['passed'] is not None]
    unreachable = len(rows) - len(judged)
    n_tasks = len({r['id'] for r in judged}) or 1
    passed = sum(1 for r in judged if r['passed'])
    summary = {
        'n_generations': len(judged),
        'n_tasks': n_tasks,
        'unreachable': unreachable,
        'pass_rate': eval_stats.proportion(passed, len(judged)) if judged else None,
        'by_grade': {},
    }
    for gb in sorted({r['grade_by'] for r in judged}):
        sub = [r for r in judged if r['grade_by'] == gb]
        summary['by_grade'][gb] = eval_stats.proportion(
            sum(1 for r in sub if r['passed']), len(sub), label=gb)
    if samples > 1:
        per_prompt = {}
        for r in judged:
            n, c = per_prompt.get(r['id'], (0, 0))
            per_prompt[r['id']] = (n + 1, c + (1 if r['passed'] else 0))
        summary['pass_at_1'] = eval_stats.aggregate_pass_at_k(
            list(per_prompt.values()), 1)
        summary['pass_at_k'] = eval_stats.aggregate_pass_at_k(
            list(per_prompt.values()), samples)
    return summary


def grade_references(tasks, timeout=DEFAULT_TIMEOUT):
    """Grade each task's own reference solution.

    A benchmark whose reference answers do not pass is measuring itself, not
    the model. This is what `--reference` runs, and it needs no model at all.
    """
    rows = []
    for task in tasks:
        ref = task.get('reference')
        if ref is None:
            rows.append({'id': task.get('id'), 'grade_by': task.get('grade_by'),
                         'passed': None, 'status': 'no_reference',
                         'reason': 'task has no reference solution',
                         'output': ''})
            continue
        r = grade(task, ref, timeout=timeout)
        rows.append(r)
    return rows


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(
        description='Run the functional benchmark (GitLab #813).')
    ap.add_argument('--tasks', default=None, help=f'default: {TASKS_FILE}')
    ap.add_argument('--reference', action='store_true',
                    help='grade the checked-in reference solutions instead of '
                         'a model — verifies the benchmark itself')
    ap.add_argument('--timeout', type=int, default=DEFAULT_TIMEOUT)
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args(argv)

    tasks = load_tasks(args.tasks)
    if not args.reference:
        print('No model runner given. Use --reference to verify the benchmark, '
              'or import run_benchmark() from a notebook with a generate() '
              'function.')
        return 2

    rows = grade_references(tasks, timeout=args.timeout)
    failed = [r for r in rows if r['passed'] is not True]
    for r in rows:
        mark = 'PASS' if r['passed'] else ('----' if r['passed'] is None else 'FAIL')
        print(f'  {mark}  {r["id"]:<34} {r["grade_by"]}')
        if args.verbose or r['passed'] is not True:
            print(f'        {r["reason"]}')
    print()
    print(f'{len(rows) - len(failed)}/{len(rows)} reference solutions pass')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(_main())
