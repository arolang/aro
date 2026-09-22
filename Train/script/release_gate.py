"""The promotion gate, as a decision procedure that can actually refuse (GitLab #796).

The gate that shipped v1.1.0 asked five questions with fixed answers: reply rate
above 50 %, empty-think below 20 %, syntax pass above 40 %, tool leakage below
2 %, URL contamination below 5 %. v1.1.0 measured a syntax pass rate of 75.5 %.
A model could therefore lose *thirty-five points* of the one capability the
model exists for and still be promoted, because 40 % is not a statement about
this model — it is a number somebody picked before there was a model to compare
against. A threshold that the current release clears by 35 points is not a gate;
it is a comment.

This module replaces the fixed floors as the load-bearing rule with the only
comparison that means anything: **the candidate against the release it would
replace, on the same prompts**. A metric fails when it is worse than the
previous release by more than the measurement's own confidence — paired per
prompt where per-prompt results exist (exact McNemar on the discordant pairs),
and by non-overlapping Wilson intervals where only aggregates were recorded.
The old absolute floors are kept, but demoted to what they always were: a net
under a total collapse, checked last and never the reason a healthy model ships.

Two capabilities the gate never measured are measured here:

  * **execution pass** — did the generated program *run* and produce what was
    asked for. `aro check` says a program parses; it says nothing about whether
    it works, and every prompt in `eval_prompts.json` was graded on parsing
    alone. The per-prompt `exec_pass` flag comes from `functional_eval.grade`
    (GitLab #813, `Train/eval/functional/tasks.json`), which runs the program
    and compares its output the way the integration harness does.
  * **tool-call format** — did the model emit `<tool_call>{...}</tool_call>`
    with valid JSON and a tool that exists, rather than a fenced shell command
    that looks like a tool call and runs nothing. The shipped system prompt
    spends 700 bytes warning against exactly that failure and the gate never
    checked whether the warning worked.

Three further ways a gate quietly stops gating are refusals here:

  * a metric that the previous release recorded and the candidate does not
    (dropping a metric must not be a way to pass);
  * a benchmark whose prompt set has drifted from the one the baseline was
    measured on (the comparison would be between two different exams);
  * a benchmark that shrank (fewer prompts means wider intervals means a
    regression that can no longer be seen).

The module is pure: it grades a results *file*, loads no model and needs no
GPU, so it is unit-testable and runs in CI. `Train/script/27_package.ipynb`
calls `evaluate()` with the sweep it just ran; `python3 release_gate.py --demo`
replays the real v1.1.0 numbers against a deliberately degraded candidate and
shows the old gate accepting what this one refuses.

Statistics come from `eval_stats` (GitLab #786) when that module is present;
until it lands the small Wilson helper below stands in, and the two agree by
construction — `tests/test_release_gate.py` asserts it when both are importable.
"""

import argparse
import json
import math
import re
import sys
from pathlib import Path

# ── Statistics ───────────────────────────────────────────────────────────────
# eval_stats.py arrives with GitLab #786 (branch train/training-eval, !591) and
# owns the interval machinery for the whole pipeline. This module prefers it and
# falls back to an equivalent local Wilson interval so the gate is not blocked on
# that merge. Both are the same formula; the fallback exists only to keep this
# file self-contained.
try:  # pragma: no cover - exercised by whichever half of the branch is present
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import eval_stats as _eval_stats
except ImportError:  # pragma: no cover
    _eval_stats = None

Z_95 = 1.959963984540054


def wilson_interval(successes, n, z=Z_95):
    """Wilson score interval for a proportion. Returns (low, high)."""
    if _eval_stats is not None:
        return _eval_stats.wilson_interval(successes, n, z)
    n = int(n)
    if n <= 0:
        return 0.0, 1.0
    successes = int(successes)
    if not 0 <= successes <= n:
        raise ValueError(f'successes {successes} out of range for n {n}')
    p = successes / n
    denom = 1.0 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    low = 0.0 if successes == 0 else max(0.0, centre - half)
    high = 1.0 if successes == n else min(1.0, centre + half)
    return low, high


def mcnemar_p(b, c):
    """Exact two-sided McNemar p-value for b/c discordant pairs.

    The paired test is the right one here: the candidate and the baseline answer
    the *same* prompts, so the prompts that both get right or both get wrong
    carry no information about which model is better. Only the disagreements do.
    With 105 prompts and a handful of disagreements the unpaired interval is far
    too wide to see a real regression; the paired test sees it.

    b = prompts the baseline passed and the candidate failed (regressions),
    c = prompts the candidate passed and the baseline failed (repairs).
    """
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    # Two-sided exact binomial against p = 0.5.
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) / (2.0 ** n)
    return min(1.0, 2.0 * tail)


# ── Metric definitions ───────────────────────────────────────────────────────
# `flag` is the per-prompt boolean in a sweep's `results` list. `denominator`
# says which prompts the rate is over: 'all' prompts, or only those for which
# the metric is defined (a syntax pass rate over prompts that produced no code
# is not a measurement, which is why the old gate guarded it with `with_code`).

class Metric:
    def __init__(self, name, flag, higher_is_better, denominator='all',
                 floor=None, ceiling=None, required=True):
        self.name = name
        self.flag = flag
        self.higher_is_better = higher_is_better
        self.denominator = denominator
        self.floor = floor
        self.ceiling = ceiling
        self.required = required

    def __repr__(self):  # pragma: no cover - debugging aid
        return f'<Metric {self.name}>'


# `required=False` marks the two metrics added by this issue: a baseline
# recorded before they existed cannot have them, and refusing every candidate
# until one release has shipped with them would make the gate unfixable. Once a
# baseline carries them the ordinary "metric present before, missing now" rule
# applies and they become mandatory on their own.
METRICS = [
    Metric('reply_rate',            'replied',             True,  'all',       floor=0.50),
    Metric('empty_think_rate',      'empty_think',         False, 'all',       ceiling=0.20),
    Metric('syntax_pass_rate',      'syntax_pass',         True,  'has_code',  floor=0.40),
    Metric('exec_pass_rate',        'exec_pass',           True,  'graded',    floor=0.20, required=False),
    Metric('tool_call_format_rate', 'tool_call_format_ok', True,  'tool_task', floor=0.50, required=False),
    Metric('tool_leak_rate',        'tool_leak',           False, 'all',       ceiling=0.02),
    Metric('url_contam_rate',       'url_contam',          False, 'all',       ceiling=0.05),
]

METRICS_BY_NAME = {m.name: m for m in METRICS}

# A metric may be worse than the previous release only when the paired test
# cannot distinguish the two. This is the significance level of that test, not a
# tolerance on the rate itself — there is deliberately no "it may drop by N
# points" knob, because that knob is what made the old gate unfailable.
REGRESSION_ALPHA = 0.05

# The benchmark is frozen: the candidate must answer the prompts the baseline
# answered. A sweep that shares less than this fraction of the baseline's prompt
# ids is not a comparison and the gate says so instead of comparing anyway.
MIN_PROMPT_OVERLAP = 0.90


# ── Sweep helpers ────────────────────────────────────────────────────────────

def _prompt_id(row, index=0):
    """Stable identity for one benchmark prompt.

    `id` when the sweep records one; otherwise the prompt text, which is stable
    across runs of the same frozen benchmark in a way `idx` is not — inserting a
    prompt renumbers every row after it and would silently pair each candidate
    answer against the baseline's answer to a different question.
    """
    for key in ('id', 'task_id', 'prompt'):
        v = row.get(key)
        if v:
            return str(v)
    return f'#{index}'


# The sweep stores the reply *text* under `reply` and, since this issue, an
# explicit `replied` boolean beside it. Reading the text as a truth value works
# but does not survive the history file, which drops the text; the alias keeps
# both shapes readable and is the only legacy accommodation in this module.
_FLAG_ALIASES = {'replied': ('replied', 'reply')}


def _raw(row, flag):
    """The recorded value of one per-prompt flag, or None when it was not
    recorded. Absence is not failure: a metric the sweep never measured is
    undefined for that prompt, not a zero."""
    for key in _FLAG_ALIASES.get(flag, (flag,)):
        if key in row:
            return row[key]
    return None


def _defined(row, metric):
    """Is `metric` measurable for this prompt?"""
    if metric.denominator not in ('all', 'has_code', 'graded', 'tool_task'):
        raise ValueError(f'unknown denominator {metric.denominator!r}')
    if _raw(row, metric.flag) is None:
        return False
    if metric.denominator == 'has_code':
        return bool(row.get('has_code'))
    if metric.denominator == 'tool_task':
        return bool(row.get('tool_task'))
    return True


def counts(sweep, metric):
    """(successes, n) for one metric over a sweep's per-prompt results.

    "Success" always means the good outcome, so a rate where lower is better is
    counted as its complement and every comparison below runs in one direction.
    """
    rows = sweep.get('results') or []
    n = 0
    k = 0
    for i, row in enumerate(rows):
        if not _defined(row, metric):
            continue
        n += 1
        value = bool(_raw(row, metric.flag))
        if value == metric.higher_is_better:
            k += 1
    return k, n


def rate(sweep, metric):
    """Measured rate for one metric, in the direction the metric is reported.

    Per-prompt results are authoritative. Falling back to the recorded aggregate
    lets the gate read historical entries that predate per-prompt storage.
    """
    k, n = counts(sweep, metric)
    if n:
        good = k / n
        return good if metric.higher_is_better else 1.0 - good
    v = sweep.get(metric.name)
    return float(v) if isinstance(v, (int, float)) else None


def _metric_n(sweep, metric):
    _, n = counts(sweep, metric)
    if n:
        return n
    # Historical aggregate-only entries: recover the denominator the old gate used.
    if metric.denominator == 'has_code':
        return int(sweep.get('with_code') or 0)
    if metric.denominator == 'all':
        return int(sweep.get('total') or 0)
    return 0


def _good_counts(sweep, metric):
    """(successes, n) even for an aggregate-only sweep, by reconstruction."""
    k, n = counts(sweep, metric)
    if n:
        return k, n
    n = _metric_n(sweep, metric)
    r = rate(sweep, metric)
    if r is None or n == 0:
        return None
    good = r if metric.higher_is_better else 1.0 - r
    return int(round(good * n)), n


def paired_flags(baseline, candidate, metric):
    """Align two sweeps by prompt id and return (b, c, pairs).

    b = baseline good, candidate bad; c = baseline bad, candidate good.
    """
    base_rows = {_prompt_id(r, i): r for i, r in enumerate(baseline.get('results') or [])}
    cand_rows = {_prompt_id(r, i): r for i, r in enumerate(candidate.get('results') or [])}
    b = c = pairs = 0
    for key, cand in cand_rows.items():
        base = base_rows.get(key)
        if base is None:
            continue
        if not (_defined(base, metric) and _defined(cand, metric)):
            continue
        base_good = bool(_raw(base, metric.flag)) == metric.higher_is_better
        cand_good = bool(_raw(cand, metric.flag)) == metric.higher_is_better
        pairs += 1
        if base_good and not cand_good:
            b += 1
        elif cand_good and not base_good:
            c += 1
    return b, c, pairs


def prompt_overlap(baseline, candidate):
    """Fraction of the baseline's prompts the candidate also answered."""
    base_ids = {_prompt_id(r, i) for i, r in enumerate(baseline.get('results') or [])}
    cand_ids = {_prompt_id(r, i) for i, r in enumerate(candidate.get('results') or [])}
    if not base_ids:
        return 1.0
    return len(base_ids & cand_ids) / len(base_ids)


# ── Tool-call format ─────────────────────────────────────────────────────────
# The system prompt tells the model that a tool only runs when emitted as
# `<tool_call>{"name": ..., "arguments": {...}}</tool_call>`, and warns at length
# against printing the call inside a ```bash fence where it does nothing. Nothing
# measured whether the model obeyed. These two functions do, on the reply text.

_TOOL_CALL_RE = re.compile(r'<tool_call>\s*(\{.*?\})\s*</tool_call>', re.S)
_FENCED_IMPOSTOR_RE = re.compile(
    r'```(?:bash|sh|shell|console)?\s*\n[^\n`]*\b'
    r'(?:aro_mcp_\w+|mcp_\w+|functions\.\w+|read_file|write_file|edit_file|list_dir|'
    r'search_project|aro_check|aro_run|aro_build|aro_test|parse_aro|list_actions|'
    r'list_proposals|read_proposal|create_plugin|write_openapi|generate_docs|run_shell)\b',
    re.S)

# The tools `aro ask` actually registers (Sources/AROAsk/Tools + Retrieval).
KNOWN_TOOLS = frozenset({
    'read_file', 'write_file', 'edit_file', 'list_dir', 'grep', 'search_project',
    'aro_check', 'aro_run', 'aro_build', 'aro_test', 'parse_aro', 'list_actions',
    'list_proposals', 'read_proposal', 'create_plugin', 'write_openapi',
    'generate_docs', 'run_shell', 'aro_knowledge',
})


def tool_call_format(reply, known_tools=KNOWN_TOOLS):
    """Classify how a reply tried to call a tool.

    Returns one of:
      'ok'              a well-formed call to a tool that exists;
      'malformed'       `<tool_call>` present but the JSON or the name is wrong;
      'fenced_impostor' a tool name printed as a shell command — the failure the
                        system prompt warns about, which looks like success to a
                        reader and runs nothing;
      'absent'          no attempt to call a tool.
    """
    text = reply or ''
    saw_call = False
    for raw in _TOOL_CALL_RE.findall(text):
        saw_call = True
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return 'malformed'
        name = payload.get('name')
        if name not in known_tools:
            return 'malformed'
        if not isinstance(payload.get('arguments', {}), dict):
            return 'malformed'
    if saw_call:
        return 'ok'
    if '<tool_call>' in text:
        # The tag opened but nothing inside it parsed as a JSON object: the
        # model meant to call a tool and emitted something the CLI cannot run.
        return 'malformed'
    if _FENCED_IMPOSTOR_RE.search(text):
        return 'fenced_impostor'
    return 'absent'


def tool_call_format_ok(reply, known_tools=KNOWN_TOOLS):
    """Did a reply that was meant to call a tool call it in a form that runs?"""
    return tool_call_format(reply, known_tools) == 'ok'


# ── The gate ─────────────────────────────────────────────────────────────────

class GateReport:
    def __init__(self):
        self.breaches = []
        self.metrics = {}
        self.baseline_version = None
        self.comparison = 'none'

    @property
    def passed(self):
        return not self.breaches

    def to_dict(self):
        return {
            'passed': self.passed,
            'breaches': list(self.breaches),
            'metrics': self.metrics,
            'baseline_version': self.baseline_version,
            'comparison': self.comparison,
        }

    def summary(self):
        lines = [f'comparison: {self.comparison}'
                 + (f' vs v{self.baseline_version}' if self.baseline_version else '')]
        for name, m in self.metrics.items():
            cur = m.get('candidate')
            base = m.get('baseline')
            cur_s = f'{cur:.1%}' if isinstance(cur, float) else '—'
            base_s = f'{base:.1%}' if isinstance(base, float) else '—'
            lines.append(f'  {name:<22} {cur_s:>7}  (previous {base_s:>7})  {m.get("verdict", "")}')
        if self.breaches:
            lines.append('REFUSED:')
            lines.extend(f'  - {b}' for b in self.breaches)
        else:
            lines.append('PASSED')
        return '\n'.join(lines)


def evaluate(candidate, baseline=None, baseline_version=None,
             alpha=REGRESSION_ALPHA, metrics=METRICS):
    """Decide whether `candidate` may be promoted over `baseline`.

    `candidate` and `baseline` are sweep dicts: `total`, optional `with_code`,
    and a `results` list of per-prompt records. `baseline` may be None for the
    very first release, in which case only the absolute floors and the presence
    checks apply — and the report says so, so nobody mistakes an unpaired pass
    for a comparison.
    """
    report = GateReport()
    report.baseline_version = baseline_version
    has_pairs = False

    if baseline is not None:
        overlap = prompt_overlap(baseline, candidate)
        cand_n = len(candidate.get('results') or []) or int(candidate.get('total') or 0)
        base_n = len(baseline.get('results') or []) or int(baseline.get('total') or 0)
        if baseline.get('results') and candidate.get('results'):
            has_pairs = overlap >= MIN_PROMPT_OVERLAP
            if not has_pairs:
                report.breaches.append(
                    f'benchmark drift: the candidate answered {overlap:.0%} of the '
                    f'prompts v{baseline_version or "?"} was measured on '
                    f'(minimum {MIN_PROMPT_OVERLAP:.0%}) — the two numbers are not '
                    'comparable, so this is not a release decision that can be made')
        if base_n and cand_n < base_n:
            report.breaches.append(
                f'benchmark shrank from {base_n} prompts to {cand_n}: a smaller set '
                'widens every interval and hides the regressions this gate exists '
                'to catch')
        report.comparison = 'paired' if has_pairs else 'unpaired'
    else:
        report.comparison = 'first-release'

    for metric in metrics:
        entry = {}
        cand_rate = rate(candidate, metric)
        base_rate = rate(baseline, metric) if baseline is not None else None
        entry['candidate'] = cand_rate
        entry['baseline'] = base_rate

        # A metric the previous release measured and this one does not.
        if base_rate is not None and cand_rate is None:
            report.breaches.append(
                f'{metric.name} is missing from the candidate sweep but v'
                f'{baseline_version or "?"} recorded {base_rate:.1%} — a metric '
                'may not be dropped to pass the gate')
            entry['verdict'] = 'missing'
            report.metrics[metric.name] = entry
            continue

        if cand_rate is None:
            if metric.required and baseline is None:
                report.breaches.append(
                    f'{metric.name} was not measured; the gate cannot certify a '
                    'model on metrics it does not have')
                entry['verdict'] = 'missing'
            else:
                entry['verdict'] = 'not measured'
            report.metrics[metric.name] = entry
            continue

        # ── Non-regression, the load-bearing rule ─────────────────────────────
        verdict = 'no baseline'
        if base_rate is not None:
            worse = (cand_rate < base_rate) if metric.higher_is_better else (cand_rate > base_rate)
            if not worse:
                verdict = 'not worse'
            elif has_pairs:
                b, c, pairs = paired_flags(baseline, candidate, metric)
                p = mcnemar_p(b, c)
                entry.update({'regressions': b, 'repairs': c, 'pairs': pairs, 'p': p})
                if p < alpha:
                    verdict = 'REGRESSION'
                    delta = abs(cand_rate - base_rate)
                    report.breaches.append(
                        f'{metric.name} regressed against v{baseline_version or "?"}: '
                        f'{base_rate:.1%} → {cand_rate:.1%} ({delta:.1%} worse); '
                        f'{b} prompts got worse and {c} got better on the same '
                        f'benchmark (exact McNemar p={p:.4f} < {alpha})')
                else:
                    verdict = 'worse, within noise'
            else:
                cand_counts = _good_counts(candidate, metric)
                base_counts = _good_counts(baseline, metric)
                if cand_counts and base_counts:
                    lo, hi = wilson_interval(*cand_counts)
                    base_good = base_counts[0] / base_counts[1] if base_counts[1] else 0.0
                    entry.update({'candidate_low': lo, 'candidate_high': hi})
                    # "Worse by more than its confidence interval": the baseline
                    # point estimate sits outside the candidate's interval.
                    if hi < base_good:
                        verdict = 'REGRESSION'
                        report.breaches.append(
                            f'{metric.name} regressed against v{baseline_version or "?"}: '
                            f'{base_rate:.1%} → {cand_rate:.1%}, and the whole 95% '
                            f'interval for the candidate ({lo:.1%}–{hi:.1%}) lies '
                            'below the previous release')
                    else:
                        verdict = 'worse, within noise'
                else:
                    verdict = 'worse, not comparable'

        # ── Absolute floors, demoted to a collapse net ────────────────────────
        if metric.floor is not None and cand_rate < metric.floor:
            report.breaches.append(
                f'{metric.name} {cand_rate:.1%} is below the absolute floor '
                f'{metric.floor:.0%}')
            verdict = 'FLOOR' if verdict != 'REGRESSION' else verdict
        if metric.ceiling is not None and cand_rate > metric.ceiling:
            report.breaches.append(
                f'{metric.name} {cand_rate:.1%} is above the absolute ceiling '
                f'{metric.ceiling:.0%}')
            verdict = 'CEILING' if verdict != 'REGRESSION' else verdict

        entry['verdict'] = verdict
        report.metrics[metric.name] = entry

    return report


# ── Version history ──────────────────────────────────────────────────────────

def previous_release(history, skip_version=None):
    """The most recent entry in `version_history.json` that can be compared to.

    Returns (entry, sweep) where `sweep` is the stored per-prompt benchmark when
    the entry has one and the aggregate `gate_metrics` otherwise. v1.1.0 stored
    only aggregates, so the first candidate graded against it gets the unpaired
    comparison and every release after that gets the paired one.
    """
    for entry in reversed(history or []):
        if skip_version and entry.get('version') == skip_version:
            continue
        sweep = entry.get('benchmark')
        if not sweep:
            gm = entry.get('gate_metrics') or {}
            if not gm:
                continue
            sweep = dict(gm)
            sweep.setdefault('total', entry.get('total'))
            sweep.setdefault('with_code', entry.get('with_code'))
        return entry, sweep
    return None, None


def history_entry(version, sweep, **extra):
    """The record to append to `version_history.json` for a release.

    The per-prompt results go in so the *next* release gets a paired comparison
    instead of the interval-only one this release had to settle for.
    """
    entry = dict(extra)
    entry['version'] = version
    entry['gate_metrics'] = {
        m.name: rate(sweep, m) for m in METRICS if rate(sweep, m) is not None
    }
    entry['benchmark'] = {
        'total': sweep.get('total') or len(sweep.get('results') or []),
        'with_code': sweep.get('with_code'),
        'results': [
            {k: v for k, v in row.items() if k != 'reply'}
            for row in (sweep.get('results') or [])
        ],
    }
    return entry


# ── CLI ──────────────────────────────────────────────────────────────────────

# The real v1.1.0 gate metrics, from Train/release/version_history.json. Used by
# --demo to show, on the shipped numbers rather than invented ones, that the old
# thresholds accept a model that has lost a third of its syntax pass rate.
V1_1_0_METRICS = {
    'reply_rate': 1.0,
    'empty_think_rate': 0.0,
    'syntax_pass_rate': 0.7553191489361702,
    'tool_leak_rate': 0.0,
    'url_contam_rate': 0.0,
}
V1_1_0_TOTAL = 105
V1_1_0_WITH_CODE = 94

OLD_GATE = {
    'reply_rate': ('min', 0.50),
    'empty_think_rate': ('max', 0.20),
    'syntax_pass_rate': ('min', 0.40),
    'tool_leak_rate': ('max', 0.02),
    'url_contam_rate': ('max', 0.05),
}


def old_gate_breaches(sweep):
    """What the pre-#796 gate would have said. Kept so the demo and the tests
    can show the two verdicts side by side rather than asserting an improvement
    nobody can see."""
    out = []
    for name, (kind, bound) in OLD_GATE.items():
        metric = METRICS_BY_NAME[name]
        v = rate(sweep, metric)
        if v is None:
            continue
        if kind == 'min' and v < bound:
            out.append(f'{name} {v:.1%} < {bound:.0%}')
        if kind == 'max' and v > bound:
            out.append(f'{name} {v:.1%} > {bound:.0%}')
    return out


def _synthetic_sweep(n, with_code, syntax_pass, exec_pass=None, seed=0):
    """A sweep with a given pass rate, for the demo and the tests."""
    rows = []
    passes = int(round(syntax_pass * with_code))
    exec_passes = None if exec_pass is None else int(round(exec_pass * with_code))
    for i in range(n):
        has_code = i < with_code
        row = {
            'id': f'p{i:03d}',
            'replied': True,
            'empty_think': False,
            'has_code': has_code,
            'tool_leak': False,
            'url_contam': False,
        }
        if has_code:
            row['syntax_pass'] = i < passes
            if exec_passes is not None:
                row['exec_pass'] = i < exec_passes
        rows.append(row)
    return {'total': n, 'with_code': with_code, 'results': rows}


def _demo():
    """Replay v1.1.0 against a candidate that lost a third of its syntax pass."""
    baseline = _synthetic_sweep(V1_1_0_TOTAL, V1_1_0_WITH_CODE,
                                V1_1_0_METRICS['syntax_pass_rate'])
    candidate = _synthetic_sweep(V1_1_0_TOTAL, V1_1_0_WITH_CODE, 0.45)

    print('Baseline  v1.1.0    syntax pass '
          f'{V1_1_0_METRICS["syntax_pass_rate"]:.1%} ({V1_1_0_WITH_CODE} code blocks)')
    print('Candidate v1.2.0    syntax pass 45.0%')
    print()
    old = old_gate_breaches(candidate)
    print('pre-#796 gate:  ' + ('REFUSED: ' + '; '.join(old) if old
                                else 'PASSED — 45.0% clears the 40% floor'))
    report = evaluate(candidate, baseline, baseline_version='1.1.0')
    print()
    print('post-#796 gate:')
    print(report.summary())
    # The demo succeeds when it demonstrates the point: the old gate waved this
    # model through and the new one refuses it.
    demonstrated = (not old) and (not report.passed)
    print()
    print('demonstration: ' + ('the old gate accepted what this gate refuses'
                               if demonstrated else 'FAILED to demonstrate'))
    return 0 if demonstrated else 1


def _main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--candidate', help='promotion_gate.json for the candidate model')
    ap.add_argument('--history', help='version_history.json holding previous releases')
    ap.add_argument('--json', action='store_true', help='print the report as JSON')
    ap.add_argument('--demo', action='store_true',
                    help='replay the real v1.1.0 numbers against a degraded candidate')
    args = ap.parse_args(argv)

    if args.demo:
        return _demo()
    if not args.candidate:
        ap.error('--candidate is required (or use --demo)')

    candidate = json.loads(Path(args.candidate).read_text())
    baseline = version = None
    if args.history and Path(args.history).exists():
        history = json.loads(Path(args.history).read_text())
        entry, baseline = previous_release(history)
        version = (entry or {}).get('version')

    report = evaluate(candidate, baseline, baseline_version=version)
    print(json.dumps(report.to_dict(), indent=2) if args.json else report.summary())
    return 0 if report.passed else 1


if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(_main())
