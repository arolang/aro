#!/usr/bin/env python3
"""Assemble the frozen held-out benchmark (GitLab #785).

Reads the six stratum modules beside this file and writes
`../prompts.benchmark.json` plus `../MANIFEST.json`.

Why a builder rather than hand-written JSON: the repair stratum's prompts carry
**the diagnostic the toolchain actually printed**, and the only way to be sure
of that is to run the broken program through the binary and paste what came
back. A prompt that claimed a diagnostic the checker does not produce would be
a benchmark grading a fiction.

That has a consequence worth stating plainly: re-running this builder against a
different `aro` can change the prompts, and therefore the digest. The frozen
artefact is the JSON, not this script. `MANIFEST.json` records the version of
the binary the prompts were built with, the sha256 of the JSON, and the leakage
measurement; a rebuild that changes any of them is a **new benchmark version**
and has to say so.

    python3 build.py                 # rebuild, refusing to change the digest
    python3 build.py --version 1.1.0 # rebuild as a new version
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH_DIR = HERE.parent
TRAIN_ROOT = BENCH_DIR.parent.parent
sys.path.insert(0, str(TRAIN_ROOT / 'script'))

import aro_oracle  # noqa: E402
import leakage  # noqa: E402

PROMPTS_FILE = BENCH_DIR / 'prompts.benchmark.json'
MANIFEST_FILE = BENCH_DIR / 'MANIFEST.json'

DEFAULT_VERSION = '1.0.0'

_ANSI_RE = re.compile(r'\x1b\[[0-9;]*m')
# The runtime's own log lines are stamped with the wall clock
# ("2026-10-03T20:13:22+0200 error aro: …"), so a captured diagnostic is
# different on every build and the frozen digest would never hold still. The
# stamp is replaced with a fixed one rather than removed: a prompt that shows a
# diagnostic should show the shape the developer actually sees.
_STAMP_RE = re.compile(
    r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?')
_FIXED_STAMP = '2026-01-01T00:00:00+0000'

# The runtime renders a record in its error trace straight from a Swift
# Dictionary, so the key order is whatever the hash gave it this run:
# `first = ["id": 1, "name": "einkorn"]` one build and
# `first = ["name": "einkorn", "id": 1]` the next. A prompt is a frozen
# artefact, so the pairs inside the innermost bracket groups are sorted before
# the diagnostic is pasted in. Only record literals are touched — a list's
# order is data, and sorting it would change what the diagnostic says.
_INNERMOST_RE = re.compile(r'\[([^][]*)\]')
_PAIR_RE = re.compile(r'^\s*"[^"]*":')


def _canonical_records(text):
    def one(match):
        body = match.group(1)
        parts = body.split(', ')
        if len(parts) < 2 or not all(_PAIR_RE.match(p) for p in parts):
            return match.group(0)
        return '[' + ', '.join(sorted(parts, key=str.strip)) + ']'

    return _INNERMOST_RE.sub(one, text)


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ── the real diagnostic ──────────────────────────────────────────────────────

def _run(command, code, files, binary, timeout=30):
    env = dict(os.environ)
    # Deterministic: statements otherwise overlap and interleave (ARO-0088), so
    # a runtime diagnostic could be captured in two different orders.
    env['ARO_NO_DEFER'] = '1'
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / 'main.aro').write_text(code)
        for name, content in (files or {}).items():
            target = d / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        r = subprocess.run([binary, command, str(d)], capture_output=True,
                           text=True, timeout=timeout, cwd=str(d), env=env)
    out = ((r.stdout or '') + (r.stderr or '')).strip()
    out = _ANSI_RE.sub('', out)
    out = _STAMP_RE.sub(_FIXED_STAMP, out)
    out = _canonical_records(out)
    # The temp directory is in the output of some diagnostics and is different
    # on every run; a prompt carrying it would not be frozen.
    out = out.replace(str(d), '.')
    return r.returncode, out


def _diagnostic(code, files, source, binary):
    if source == 'symptom':
        return None
    rc, out = _run('check', code, files, binary)
    if source == 'check':
        return out
    # `run`: the checker was happy (or only warned) and the failure is at run
    # time. That pairing is half the point of the stratum — `aro check`'s exit
    # code is not a promise that every statement will execute.
    _rc, run_out = _run('run', code, files, binary)
    return run_out


# ── assembling ───────────────────────────────────────────────────────────────

def build(version=DEFAULT_VERSION):
    binary = aro_oracle.require_aro_bin()
    aro_version = aro_oracle.aro_version()

    repl = _load('s_repl')
    explain = _load('s_explain')
    repair = _load('s_repair')
    nlapp = _load('s_nl_application')
    tests = _load('s_tests')
    plugin = _load('s_plugin')

    prompts = []

    # REPL: `wrap` tells the harness to put the statements inside an entry
    # point before running them, which is what the REPL itself does and what
    # gives this stratum an execution axis rather than a parse-only one.
    for pid, domain, prompt, reference, expected in repl.ROWS:
        prompts.append({
            'id': pid, 'stratum': 'repl', 'domain': domain,
            'prompt': prompt, 'grade_by': 'execution_output',
            'expected_output': expected, 'wrap': True,
            'reference': reference,
        })

    for pid, domain, prompt, reference, include, exclude in explain.ROWS:
        prompts.append({
            'id': pid, 'stratum': 'explain', 'domain': domain,
            'prompt': prompt, 'grade_by': 'doc_qa',
            'must_include': list(include), 'must_not_include': list(exclude),
            'reference': reference,
        })

    for row in repair.ROWS:
        pid, domain, framing, broken, reference, expected, source = row
        files = repair.FILES.get(pid)
        diagnostic = _diagnostic(broken, files, source, binary)
        prompt = f'{framing}\n\n```aro\n{broken.rstrip()}\n```'
        if source == 'check':
            prompt += (f'\n\n`aro check` says:\n\n```\n{diagnostic}\n```')
        elif source == 'run':
            prompt += ('\n\nIt gets past `aro check`. Running it says:\n\n'
                       f'```\n{diagnostic}\n```')
        entry = {
            'id': pid, 'stratum': 'repair', 'domain': domain,
            'prompt': prompt,
            'grade_by': ('execution_output' if expected is not None
                         else 'aro_check'),
            'reference': reference,
            'diagnostic_source': source,
        }
        if expected is not None:
            entry['expected_output'] = expected
        if files:
            entry['files'] = files
        prompts.append(entry)

    for pid, domain, prompt, reference, files, expected in nlapp.ROWS:
        entry = {
            'id': pid, 'stratum': 'nl_application', 'domain': domain,
            'prompt': prompt,
            'grade_by': ('execution_output' if expected is not None
                         else 'aro_check'),
            'reference': reference,
        }
        if expected is not None:
            entry['expected_output'] = expected
        if files:
            # An execution-graded row needs its seed data in the directory or
            # the expected output is unreachable, so those go in `files` and
            # the prompt says the file is already there. A contract-first row's
            # `openapi.yaml` must NOT go there — producing it is the task — so
            # it is carried as `reference_files`, which only `--reference`
            # reads, letting the benchmark verify itself without handing a
            # model its own answer.
            if expected is not None:
                entry['files'] = files
            else:
                entry['reference_files'] = files
        prompts.append(entry)

    for pid, domain, activity, prompt, reference in tests.ROWS:
        prompts.append({
            'id': pid, 'stratum': 'tests', 'domain': domain,
            'prompt': prompt, 'grade_by': 'aro_test',
            'answer_role': 'test',
            'files': {'main.aro': tests.entry_point(activity)},
            'reference': reference,
        })

    for pid, domain, kind, prompt, reference, include, exclude in plugin.ROWS:
        entry = {
            'id': pid, 'stratum': 'plugin', 'domain': domain,
            'prompt': prompt,
            'grade_by': ('doc_qa' if kind == 'rubric' else 'aro_check'),
            'reference': reference,
        }
        if kind == 'rubric':
            entry['must_include'] = list(include or [])
            entry['must_not_include'] = list(exclude or [])
        files = plugin.FILES.get(pid)
        if files:
            entry['reference_files'] = files
        prompts.append(entry)

    document = {
        '_doc': (
            'The frozen held-out benchmark for `aro ask` (GitLab #785). Never '
            'mined: this directory carries a .never-mine marker, this file '
            'carries .benchmark. in its name, leakage.corpus_files() excludes '
            'both, and Train/script/tests/test_held_out_benchmark.py fails if '
            'any prompt here turns up in a corpus file.'),
        'version': version,
        'frozen_at': date.today().isoformat(),
        'built_with_aro': aro_version,
        'never_mine': True,
        'prompts': prompts,
    }
    return document


def write(document, check_digest=True, exhaustive=False):
    body = json.dumps(document, indent=1, ensure_ascii=False) + '\n'
    previous_digest = None
    if PROMPTS_FILE.exists():
        previous_digest = hashlib.sha256(PROMPTS_FILE.read_bytes()).hexdigest()
    digest = hashlib.sha256(body.encode()).hexdigest()
    if (check_digest and previous_digest is not None
            and previous_digest != digest):
        print('REFUSING: the rebuilt benchmark differs from the frozen one.')
        print(f'  frozen  {previous_digest}')
        print(f'  rebuilt {digest}')
        print('A changed benchmark is a new benchmark. Re-run with '
              '--version <next> to make that explicit.')
        return 1
    PROMPTS_FILE.write_text(body)

    strata = {}
    grades = {}
    domains = {}
    for p in document['prompts']:
        strata[p['stratum']] = strata.get(p['stratum'], 0) + 1
        grades[p['grade_by']] = grades.get(p['grade_by'], 0) + 1
        if p.get('domain'):
            domains[p['domain']] = domains.get(p['domain'], 0) + 1

    # The prefix-filtered index is exact at the threshold and much faster, so
    # it is what a rebuild and the CI test use. `--exhaustive` compares every
    # pair instead: it is the only way to record a true maximum similarity
    # *below* the threshold, and "nothing above 0.85" is a much weaker claim
    # than "the closest prompt in 23,931 is 0.59".
    report = leakage.benchmark_leakage(document['prompts'],
                                       exhaustive=exhaustive)
    manifest = {
        '_doc': (
            'Freeze record for the held-out benchmark (GitLab #785). The '
            'digest is what makes "frozen" mechanical: '
            'held_out_benchmark.verify_frozen() compares it, and a test fails '
            'when the prompts file changes without a version bump — so the '
            'ruler cannot move mid-measurement, which is how 75.5 % and 67 % '
            'came to be quoted side by side.'),
        'version': document['version'],
        'frozen_at': document['frozen_at'],
        'built_with_aro': document['built_with_aro'],
        'prompts_file': PROMPTS_FILE.name,
        'prompts_sha256': digest,
        'n_prompts': len(document['prompts']),
        'strata': dict(sorted(strata.items())),
        'grades': dict(sorted(grades.items())),
        'domains': dict(sorted(domains.items())),
        'leakage': {
            'measure': 'character 3-gram Jaccard over normalised prompt text',
            'threshold': report['threshold'],
            'corpus_files': report['n_corpus_files'],
            'corpus_instructions': report['n_corpus_instructions'],
            'exhaustive': bool(exhaustive),
            'exact_collisions': report['exact'],
            'near_duplicates': report['near'],
            ('max_similarity' if exhaustive
             else 'max_similarity_lower_bound'): report['max_similarity'],
        },
    }
    MANIFEST_FILE.write_text(json.dumps(manifest, indent=1) + '\n')
    print(f'{len(document["prompts"])} prompts  sha256 {digest[:16]}…')
    for stratum, n in manifest['strata'].items():
        print(f'  {stratum:<16} {n:>4}')
    print(f'  leakage: exact={report["exact"]} near={report["near"]} '
          f'vs {report["n_corpus_instructions"]} corpus instructions')
    return 1 if report['leaked'] else 0


def _main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--version', default=None,
                    help='write this version; required when the content '
                         'changes')
    ap.add_argument('--exhaustive', action='store_true',
                    help='measure leakage with no prefix filter — minutes, '
                         'but records a true maximum similarity')
    args = ap.parse_args(argv)
    version = args.version
    if version is None and PROMPTS_FILE.exists():
        version = json.loads(PROMPTS_FILE.read_text()).get('version',
                                                           DEFAULT_VERSION)
    document = build(version or DEFAULT_VERSION)
    return write(document, check_digest=args.version is None,
                 exhaustive=args.exhaustive)


if __name__ == '__main__':
    raise SystemExit(_main())
