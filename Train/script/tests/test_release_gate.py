"""Tests for the promotion gate (GitLab #796).

The point of these is not that the gate passes a good model — the old one did
that too. It is that the gate *refuses*: each test below is a model that the
pre-#796 thresholds would have promoted, together with the reason the new gate
will not.
"""
import json
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from release_gate import (  # noqa: E402
    METRICS, METRICS_BY_NAME, MIN_PROMPT_OVERLAP, V1_1_0_METRICS,
    V1_1_0_TOTAL, V1_1_0_WITH_CODE, GateReport, counts, evaluate,
    history_entry, mcnemar_p, old_gate_breaches, paired_flags,
    previous_release, prompt_overlap, rate, tool_call_format,
    tool_call_format_ok, wilson_interval, _synthetic_sweep,
)


def sweep(n=105, with_code=94, syntax=None, exec_pass=None, tool_ok=None,
          reply=1.0, empty_think=0.0, tool_leak=0.0, url_contam=0.0,
          seed=7, tool_tasks=0):
    """A sweep with per-prompt rows drawn to hit the requested rates.

    Prompts are shuffled with a fixed seed so passes and failures interleave;
    a baseline and a candidate built with different seeds therefore disagree on
    a realistic scatter of prompts rather than a clean prefix.
    """
    rng = random.Random(seed)
    rows = []
    def picks(rate_, m):
        idx = list(range(m))
        rng.shuffle(idx)
        return set(idx[:int(round(rate_ * m))])
    syn_ok = picks(syntax, with_code) if syntax is not None else set()
    exe_ok = picks(exec_pass, with_code) if exec_pass is not None else set()
    tool_ok_set = picks(tool_ok, tool_tasks) if tool_ok is not None else set()
    reply_ok = picks(reply, n)
    think_bad = picks(empty_think, n)
    leak = picks(tool_leak, n)
    contam = picks(url_contam, n)
    for i in range(n):
        has_code = i < with_code
        row = {
            'id': f'p{i:03d}',
            'replied': i in reply_ok,
            'empty_think': i in think_bad,
            'has_code': has_code,
            'tool_leak': i in leak,
            'url_contam': i in contam,
        }
        if has_code and syntax is not None:
            row['syntax_pass'] = i in syn_ok
        if has_code and exec_pass is not None:
            row['exec_pass'] = i in exe_ok
        if i < tool_tasks:
            row['tool_task'] = True
            if tool_ok is not None:
                row['tool_call_format_ok'] = i in tool_ok_set
        rows.append(row)
    return {'total': n, 'with_code': with_code, 'results': rows}


V1_1_0 = sweep(syntax=V1_1_0_METRICS['syntax_pass_rate'], seed=1)


class TestTheGateRefuses(unittest.TestCase):
    """Each case: old gate says yes, new gate says no."""

    def test_syntax_collapse_that_still_clears_the_old_floor(self):
        # The headline case from the issue: v1.1.0 measured 75.5%, the old floor
        # was 40%, so a model at 45% was promotable. It no longer is.
        candidate = sweep(syntax=0.45, seed=2)
        self.assertEqual(old_gate_breaches(candidate), [],
                         'precondition: the old gate must accept this model')
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('syntax_pass_rate regressed' in b for b in report.breaches),
                        report.breaches)
        self.assertEqual(report.comparison, 'paired')

    def test_execution_collapse_with_syntax_intact(self):
        # A model that writes programs which parse and do not run. The old gate
        # had no execution metric at all, so this was invisible to it.
        baseline = sweep(syntax=0.75, exec_pass=0.70, seed=1)
        candidate = sweep(syntax=0.75, exec_pass=0.25, seed=2)
        self.assertEqual(old_gate_breaches(candidate), [])
        report = evaluate(candidate, baseline, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('exec_pass_rate' in b for b in report.breaches), report.breaches)

    def test_tool_call_format_collapse(self):
        baseline = sweep(syntax=0.75, tool_tasks=40, tool_ok=0.90, seed=1)
        candidate = sweep(syntax=0.75, tool_tasks=40, tool_ok=0.20, seed=2)
        self.assertEqual(old_gate_breaches(candidate), [])
        report = evaluate(candidate, baseline, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('tool_call_format_rate' in b for b in report.breaches),
                        report.breaches)

    def test_dropping_a_metric_is_not_a_way_to_pass(self):
        baseline = sweep(syntax=0.75, exec_pass=0.70, seed=1)
        candidate = sweep(syntax=0.75, seed=2)            # no exec_pass recorded
        report = evaluate(candidate, baseline, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('may not be dropped' in b for b in report.breaches),
                        report.breaches)

    def test_benchmark_drift_is_refused_rather_than_compared(self):
        candidate = sweep(syntax=0.80, seed=2)
        for row in candidate['results']:
            row['id'] = 'x' + row['id']               # a different exam entirely
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('benchmark drift' in b for b in report.breaches),
                        report.breaches)

    def test_shrinking_the_benchmark_is_refused(self):
        candidate = sweep(n=40, with_code=36, syntax=0.80, seed=2)
        for i, row in enumerate(candidate['results']):
            row['id'] = V1_1_0['results'][i]['id']    # same prompts, fewer of them
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertFalse(report.passed)
        self.assertTrue(any('benchmark shrank' in b for b in report.breaches),
                        report.breaches)

    def test_total_collapse_still_trips_the_absolute_floor(self):
        candidate = sweep(syntax=0.10, seed=2)
        report = evaluate(candidate, None)
        self.assertFalse(report.passed)
        self.assertTrue(any('absolute floor' in b for b in report.breaches),
                        report.breaches)

    def test_unpaired_regression_against_an_aggregate_only_baseline(self):
        # v1.1.0 as it is actually recorded on disk: gate_metrics, no per-prompt
        # results. The comparison degrades to intervals and still refuses.
        baseline = dict(V1_1_0_METRICS)
        baseline['total'] = V1_1_0_TOTAL
        baseline['with_code'] = V1_1_0_WITH_CODE
        candidate = sweep(syntax=0.45, seed=2)
        report = evaluate(candidate, baseline, baseline_version='1.1.0')
        self.assertEqual(report.comparison, 'unpaired')
        self.assertFalse(report.passed)
        self.assertTrue(any('interval for the candidate' in b for b in report.breaches),
                        report.breaches)


class TestTheGatePasses(unittest.TestCase):
    """It must also not refuse everything — a gate that always fails is as
    useless as one that never does."""

    def test_an_equal_model_passes(self):
        candidate = sweep(syntax=V1_1_0_METRICS['syntax_pass_rate'], seed=1)
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertTrue(report.passed, report.breaches)

    def test_an_improved_model_passes(self):
        candidate = sweep(syntax=0.88, seed=3)
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertTrue(report.passed, report.breaches)
        self.assertEqual(report.metrics['syntax_pass_rate']['verdict'], 'not worse')

    def test_a_one_prompt_wobble_is_noise_not_a_regression(self):
        # 71/94 vs 70/94 is a single prompt. The gate must say "within noise",
        # not refuse the release — the old 0.02-style flat tolerances could not
        # tell that apart from a real change.
        candidate = sweep(syntax=V1_1_0_METRICS['syntax_pass_rate'], seed=1)
        flipped = next(r for r in candidate['results'] if r.get('syntax_pass'))
        flipped['syntax_pass'] = False
        report = evaluate(candidate, V1_1_0, baseline_version='1.1.0')
        self.assertTrue(report.passed, report.breaches)
        self.assertEqual(report.metrics['syntax_pass_rate']['verdict'],
                         'worse, within noise')

    def test_first_release_has_no_baseline_and_says_so(self):
        report = evaluate(sweep(syntax=0.75, seed=1), None)
        self.assertTrue(report.passed, report.breaches)
        self.assertEqual(report.comparison, 'first-release')


class TestStatistics(unittest.TestCase):
    def test_mcnemar_symmetric_and_bounded(self):
        self.assertEqual(mcnemar_p(0, 0), 1.0)
        self.assertEqual(mcnemar_p(3, 3), 1.0)
        self.assertAlmostEqual(mcnemar_p(5, 0), mcnemar_p(0, 5))
        self.assertLess(mcnemar_p(10, 0), 0.05)
        self.assertGreater(mcnemar_p(3, 1), 0.05)

    def test_wilson_stays_inside_the_unit_interval(self):
        for k, n in [(0, 12), (12, 12), (1, 3), (94, 94), (0, 0)]:
            lo, hi = wilson_interval(k, n)
            self.assertGreaterEqual(lo, 0.0)
            self.assertLessEqual(hi, 1.0)
            self.assertLessEqual(lo, hi)

    def test_matches_eval_stats_when_that_module_is_present(self):
        try:
            import eval_stats
        except ImportError:
            self.skipTest('eval_stats (GitLab #786) not on this branch yet')
        for k, n in [(0, 12), (7, 12), (75, 94), (94, 94)]:
            self.assertEqual(wilson_interval(k, n), eval_stats.wilson_interval(k, n))


class TestToolCallFormat(unittest.TestCase):
    def test_well_formed_call(self):
        reply = 'Sure.\n<tool_call>{"name": "aro_check", "arguments": {"path": "./App"}}</tool_call>'
        self.assertEqual(tool_call_format(reply), 'ok')
        self.assertTrue(tool_call_format_ok(reply))

    def test_fenced_shell_impostor_is_not_ok(self):
        # This is the failure the shipped system prompt spends 700 bytes warning
        # about, and which nothing measured: it looks like a tool call to a
        # reader and runs nothing.
        reply = 'Let me check it:\n```bash\naro_mcp_aro_check /path/to/App\n```'
        self.assertEqual(tool_call_format(reply), 'fenced_impostor')
        self.assertFalse(tool_call_format_ok(reply))

    def test_unknown_tool_is_malformed(self):
        reply = '<tool_call>{"name": "compile_everything", "arguments": {}}</tool_call>'
        self.assertEqual(tool_call_format(reply), 'malformed')

    def test_broken_json_is_malformed(self):
        reply = '<tool_call>{"name": "aro_check", "arguments": </tool_call>'
        self.assertEqual(tool_call_format(reply), 'malformed')

    def test_plain_answer_is_absent_not_a_failure(self):
        self.assertEqual(tool_call_format('ARO has no Tail action.'), 'absent')


class TestHistory(unittest.TestCase):
    def test_history_entry_stores_per_prompt_results_for_the_next_release(self):
        entry = history_entry('1.2.0', sweep(syntax=0.80, seed=4), checksum='abc')
        self.assertEqual(entry['version'], '1.2.0')
        self.assertEqual(entry['checksum'], 'abc')
        self.assertEqual(len(entry['benchmark']['results']), 105)
        self.assertNotIn('reply', entry['benchmark']['results'][0],
                         'reply text must not be copied into the history file')
        self.assertIn('syntax_pass_rate', entry['gate_metrics'])

    def test_round_trip_gives_the_next_release_a_paired_comparison(self):
        entry = history_entry('1.2.0', sweep(syntax=0.80, seed=4))
        history = json.loads(json.dumps([entry]))
        found, baseline = previous_release(history)
        self.assertEqual(found['version'], '1.2.0')
        report = evaluate(sweep(syntax=0.45, seed=5), baseline, baseline_version='1.2.0')
        self.assertEqual(report.comparison, 'paired')
        self.assertFalse(report.passed)

    def test_real_v1_1_0_history_shape_is_readable(self):
        # The file as it exists today: aggregates only, no benchmark key.
        history = [{
            'version': '1.1.0',
            'checksum': '45a5680524fdfc49',
            'gate_metrics': dict(V1_1_0_METRICS),
        }]
        entry, baseline = previous_release(history)
        self.assertEqual(entry['version'], '1.1.0')
        self.assertAlmostEqual(rate(baseline, METRICS_BY_NAME['syntax_pass_rate']),
                               0.7553191489361702)


class TestPlumbing(unittest.TestCase):
    def test_counts_use_the_right_denominator(self):
        s = sweep(n=10, with_code=4, syntax=0.5, seed=1)
        k, n = counts(s, METRICS_BY_NAME['syntax_pass_rate'])
        self.assertEqual(n, 4)
        self.assertEqual(k, 2)
        k, n = counts(s, METRICS_BY_NAME['reply_rate'])
        self.assertEqual(n, 10)

    def test_lower_is_better_metrics_are_counted_as_their_complement(self):
        s = sweep(n=10, with_code=10, syntax=1.0, tool_leak=0.3, seed=1)
        self.assertAlmostEqual(rate(s, METRICS_BY_NAME['tool_leak_rate']), 0.3)

    def test_prompts_pair_by_id_not_position(self):
        base = sweep(n=4, with_code=4, syntax=1.0, seed=1)
        cand = sweep(n=4, with_code=4, syntax=1.0, seed=1)
        cand['results'].reverse()
        cand['results'][0]['syntax_pass'] = False      # p003 now fails
        b, c, pairs = paired_flags(base, cand, METRICS_BY_NAME['syntax_pass_rate'])
        self.assertEqual((b, c, pairs), (1, 0, 4))

    def test_prompt_overlap(self):
        self.assertEqual(prompt_overlap(V1_1_0, V1_1_0), 1.0)
        other = sweep(syntax=0.7, seed=2)
        for row in other['results']:
            row['id'] = 'z' + row['id']
        self.assertEqual(prompt_overlap(V1_1_0, other), 0.0)
        self.assertGreater(MIN_PROMPT_OVERLAP, 0.5)

    def test_report_serialises(self):
        report = evaluate(sweep(syntax=0.45, seed=2), V1_1_0, baseline_version='1.1.0')
        payload = json.loads(json.dumps(report.to_dict()))
        self.assertFalse(payload['passed'])
        self.assertTrue(payload['breaches'])
        self.assertIsInstance(report.summary(), str)

    def test_every_metric_has_a_denominator_the_code_understands(self):
        s = _synthetic_sweep(4, 4, 1.0, exec_pass=1.0)
        for m in METRICS:
            counts(s, m)        # raises on an unknown denominator


class TestDemo(unittest.TestCase):
    def test_demo_exits_zero_because_it_demonstrates_a_refusal(self):
        from release_gate import _main
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = _main(['--demo'])
        self.assertEqual(code, 0)
        out = buf.getvalue()
        self.assertIn('PASSED — 45.0% clears the 40% floor', out)
        self.assertIn('REGRESSION', out)


if __name__ == '__main__':
    unittest.main()
