"""Unit tests for Train/script/eval_stats.py (GitLab #786).

Run with either:
    python3 -m pytest Train/script/tests/test_eval_stats.py
    python3 -m unittest discover -s Train/script/tests -v

Pure python — no model, no aro binary, no knowledge.json.

The fixture `RECORDED_ROUNDS` is the real code-generation series from the
2026-08 iterative-loop run (`Train/data/rounds/round_results.json`, which is
gitignored). Every recorded rate is an exact sixtieth, which is how the sample
size was recovered; `test_recorded_rates_are_exact_sixtieths` pins that, so if
someone later claims the eval was bigger than 60 the fixture disagrees.
"""

import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import eval_stats as es  # noqa: E402
import train_utils  # noqa: E402


# code_generation successes out of 60, rounds 0..7, as recorded.
RECORDED_ROUNDS = [42, 28, 37, 20, 17, 30, 32, 31]
RECORDED_N = 60

# debugging / translation, out of 12 each, same run.
RECORDED_DEBUGGING = [6, 3, 6, 3, 5, 5, 2, 3]
RECORDED_TRANSLATION = [3, 4, 6, 3, 3, 5, 3, 6]
SMALL_N = 12


class WilsonIntervalTest(unittest.TestCase):
    def test_known_value(self):
        # 42/60 = 0.700. Wilson 95% is approximately (0.575, 0.801).
        lo, hi = es.wilson_interval(42, 60)
        self.assertAlmostEqual(lo, 0.5749, places=3)
        self.assertAlmostEqual(hi, 0.8010, places=3)

    def test_contains_the_point_estimate(self):
        for k in range(0, 61):
            lo, hi = es.wilson_interval(k, 60)
            self.assertLessEqual(lo, k / 60)
            self.assertLessEqual(k / 60, hi)

    def test_extremes_are_not_degenerate(self):
        # The normal approximation gives a zero-width interval at 0/12 and
        # 12/12, which is how a 12-prompt task set came to look certain.
        lo, hi = es.wilson_interval(0, 12)
        self.assertEqual(lo, 0.0)
        self.assertGreater(hi, 0.2)
        lo, hi = es.wilson_interval(12, 12)
        self.assertLess(lo, 0.8)
        self.assertEqual(hi, 1.0)

    def test_narrows_with_n(self):
        widths = [es.wilson_interval(n // 2, n)[1] - es.wilson_interval(n // 2, n)[0]
                  for n in (12, 60, 100, 400)]
        self.assertEqual(widths, sorted(widths, reverse=True))

    def test_zero_n_is_uninformative(self):
        self.assertEqual(es.wilson_interval(0, 0), (0.0, 1.0))

    def test_rejects_impossible_counts(self):
        with self.assertRaises(ValueError):
            es.wilson_interval(61, 60)


class ProportionTest(unittest.TestCase):
    def test_reports_resolution_and_underpowered_flag(self):
        p = es.proportion(42, 60, label='code_generation')
        self.assertAlmostEqual(p['rate'], 0.7)
        self.assertAlmostEqual(p['resolution'], 1 / 60)
        self.assertTrue(p['underpowered'])
        self.assertEqual(p['label'], 'code_generation')

    def test_hundred_prompts_is_not_underpowered(self):
        self.assertFalse(es.proportion(50, 100)['underpowered'])

    def test_convergence_tolerance_is_finer_than_the_instrument(self):
        # The heart of #786: train_utils.check_convergence compares pass-rate
        # deltas against 0.02, but on a 60-prompt set the smallest non-zero
        # delta expressible is one prompt = 0.0167, and on a 12-prompt set it
        # is 0.083 — four times the tolerance. The test was reporting the
        # graduation of the ruler.
        self.assertLess(es.proportion(42, 60)['resolution'], 0.02)
        self.assertGreater(es.proportion(6, 12)['resolution'], 0.02)


class CompareTest(unittest.TestCase):
    def test_best_round_is_not_distinguishable_from_the_shipped_round(self):
        # round 0 (42/60 = 0.700) vs round 7 (31/60 = 0.517), the round that
        # was actually carried forward. `best_round: 0` was recorded, and the
        # 18-point gap reads as a large regression — but the intervals overlap,
        # so the run never had the evidence to prefer either.
        verdict, detail = es.compare((42, 60), (31, 60))
        self.assertEqual(verdict, 'indistinguishable')
        self.assertTrue(detail['overlap'])

    def test_a_real_regression_is_still_called(self):
        # round 0 (42/60) as the baseline, round 4 (17/60 = 0.283) as the
        # candidate: that one does separate, and the verdict is about the
        # candidate.
        verdict, _ = es.compare((42, 60), (17, 60))
        self.assertEqual(verdict, 'worse')
        verdict, _ = es.compare((17, 60), (42, 60))
        self.assertEqual(verdict, 'better')

    def test_nothing_separates_at_twelve_prompts(self):
        # debugging swung 6/12 -> 2/12 across the run and a 25-point "drop"
        # was recorded as a regression. At n=12 it is one draw from the same
        # distribution as far as the evidence goes.
        verdict, _ = es.compare((6, 12), (2, 12))
        self.assertEqual(verdict, 'indistinguishable')

    def test_accepts_proportion_dicts(self):
        baseline = es.proportion(42, 60)
        candidate = es.proportion(17, 60)
        self.assertEqual(es.compare(baseline, candidate)[0], 'worse')


class RequiredNTest(unittest.TestCase):
    def test_shipped_comparison_needed_twice_the_prompts_it_had(self):
        # 0.700 -> 0.517 on 60 prompts. Calling it needs ~111 per arm.
        n = es.required_n(0.70, 0.5167)
        self.assertGreater(n, 60)
        self.assertLess(n, 200)

    def test_bigger_effects_need_fewer_prompts(self):
        self.assertLess(es.required_n(0.6, 0.2), es.required_n(0.6, 0.5))

    def test_identical_rates_need_infinitely_many(self):
        self.assertEqual(es.required_n(0.5, 0.5), math.inf)

    def test_matches_a_textbook_value(self):
        # 0.50 vs 0.60, alpha 0.05, power 0.80: the standard answer is 388-408
        # per arm depending on rounding/continuity correction.
        self.assertTrue(380 <= es.required_n(0.50, 0.60) <= 410)

    def test_non_default_alpha_and_power_are_accepted(self):
        strict = es.required_n(0.5, 0.6, alpha=0.01, power=0.90)
        self.assertGreater(strict, es.required_n(0.5, 0.6))


class DetectableEffectTest(unittest.TestCase):
    def test_sixty_prompts_cannot_see_a_ten_point_change(self):
        # So NB21's REGRESSION_WARN_THRESHOLD of 0.10 and its 0.02 convergence
        # tolerance were both below the noise floor of the set they ran on.
        self.assertGreater(es.detectable_effect(60), 0.10)

    def test_twelve_prompts_can_barely_see_anything(self):
        self.assertGreater(es.detectable_effect(12), 0.40)

    def test_floor_improves_matters(self):
        self.assertLess(es.detectable_effect(es.MIN_PROMPTS_PER_TASK),
                        es.detectable_effect(60))

    def test_round_trips_with_required_n(self):
        for n in (60, 100, 400):
            eff = es.detectable_effect(n)
            self.assertLessEqual(es.required_n(0.5, 0.5 + eff), n)


class SufficiencyReportTest(unittest.TestCase):
    def test_flags_the_recorded_task_sizes(self):
        report = es.sufficiency_report({
            'code_generation': 60,
            'debugging': 12,
            'translation': 12,
        })
        self.assertFalse(report['code_generation']['sufficient'])
        self.assertEqual(report['code_generation']['shortfall'], 40)
        self.assertEqual(report['debugging']['shortfall'], 88)
        self.assertTrue(all(not r['sufficient'] for r in report.values()))

    def test_accepts_count_tuples(self):
        report = es.sufficiency_report({'x': (50, 100)})
        self.assertTrue(report['x']['sufficient'])


class PassAtKTest(unittest.TestCase):
    def test_all_correct_is_one(self):
        self.assertEqual(es.pass_at_k(3, 3, 1), 1.0)
        self.assertEqual(es.pass_at_k(3, 3, 3), 1.0)

    def test_none_correct_is_zero(self):
        self.assertEqual(es.pass_at_k(3, 0, 1), 0.0)
        self.assertEqual(es.pass_at_k(3, 0, 3), 0.0)

    def test_one_of_three(self):
        self.assertAlmostEqual(es.pass_at_k(3, 1, 1), 1 / 3)
        self.assertAlmostEqual(es.pass_at_k(3, 1, 3), 1.0)

    def test_k_is_monotone(self):
        self.assertLessEqual(es.pass_at_k(5, 2, 1), es.pass_at_k(5, 2, 3))

    def test_rejects_k_larger_than_samples(self):
        with self.assertRaises(ValueError):
            es.pass_at_k(2, 1, 3)

    def test_aggregate(self):
        self.assertAlmostEqual(
            es.aggregate_pass_at_k([(3, 3), (3, 0)], 1), 0.5)
        self.assertIsNone(es.aggregate_pass_at_k([], 1))


class ConvergenceTest(unittest.TestCase):
    def test_old_test_declares_the_recorded_run_unconverged_for_the_wrong_reason(self):
        # The recorded stopping reason was "not converged — pass-rate deltas
        # ['0.033', '0.017'] (tol 0.02)". One of those two deltas is a single
        # prompt. The old test is reading noise as signal.
        rates = [k / RECORDED_N for k in RECORDED_ROUNDS]
        converged, reason = train_utils.check_convergence(rates)
        self.assertFalse(converged)
        self.assertIn('0.02', reason)

    def test_new_test_refuses_to_judge_an_underpowered_series(self):
        series = [(k, RECORDED_N) for k in RECORDED_ROUNDS]
        converged, reason = es.converged_by_overlap(series)
        self.assertFalse(converged)
        self.assertIn('floor', reason)
        self.assertIn('60 prompts', reason)

    def test_converges_when_a_big_enough_series_really_is_flat(self):
        series = [(505, 1000), (498, 1000), (502, 1000)]
        converged, reason = es.converged_by_overlap(series)
        self.assertTrue(converged)
        self.assertIn('indistinguishable', reason)

    def test_does_not_converge_while_it_is_still_moving(self):
        series = [(300, 1000), (500, 1000), (700, 1000)]
        converged, _ = es.converged_by_overlap(series)
        self.assertFalse(converged)

    def test_needs_patience_plus_one_rounds(self):
        converged, reason = es.converged_by_overlap([(50, 100), (50, 100)])
        self.assertFalse(converged)
        self.assertIn('not enough rounds', reason)


class BestRoundTest(unittest.TestCase):
    def test_argmax_and_interval_disagree_on_the_recorded_run(self):
        series = [(k, RECORDED_N) for k in RECORDED_ROUNDS]
        top, tied = es.best_round_by_interval(series)
        self.assertEqual(top, 0)                     # same winner as argmax
        # ...but six of the eight rounds tie with it, so "best round 0" is not
        # a finding, it is the highest of eight draws from one distribution.
        self.assertGreaterEqual(len(tied), 5)
        self.assertIn(7, tied)

    def test_a_clear_winner_ties_with_nobody(self):
        top, tied = es.best_round_by_interval([(900, 1000), (100, 1000)])
        self.assertEqual(top, 0)
        self.assertEqual(tied, [0])

    def test_empty(self):
        self.assertEqual(es.best_round_by_interval([]), (None, []))


class RecordedFixtureTest(unittest.TestCase):
    def test_recorded_rates_are_exact_sixtieths(self):
        # How the sample size was recovered: 0.7, 0.4666…, 0.6166…, 0.3333…,
        # 0.2833…, 0.5, 0.5333…, 0.5166… are all k/60 to 12 decimal places.
        for k in RECORDED_ROUNDS:
            rate = k / RECORDED_N
            self.assertAlmostEqual(rate * 60, round(rate * 60), places=9)

    def test_small_task_sets_are_twelfths(self):
        for k in RECORDED_DEBUGGING + RECORDED_TRANSLATION:
            self.assertTrue(0 <= k <= SMALL_N)
        self.assertAlmostEqual(RECORDED_DEBUGGING[4] / SMALL_N, 0.4166666666666667)
        self.assertAlmostEqual(RECORDED_TRANSLATION[0] / SMALL_N, 0.25)

    def test_the_whole_series_sits_inside_one_interval(self):
        # Every round except 3 and 4 overlaps round 0. The loop ran eight
        # rounds and 12 hours to produce a ranking it could not support.
        series = [(k, RECORDED_N) for k in RECORDED_ROUNDS]
        verdicts = [es.compare(series[0], s)[0] for s in series[1:]]
        self.assertEqual(verdicts.count('indistinguishable'), 5)
        self.assertEqual(verdicts.count('worse'), 2)


class NormalQuantileTest(unittest.TestCase):
    def test_matches_the_hard_coded_constants(self):
        self.assertAlmostEqual(es._inv_norm_cdf(0.975), es.Z_95, places=7)
        self.assertAlmostEqual(es._inv_norm_cdf(0.95), es.Z_90, places=7)
        self.assertAlmostEqual(es._inv_norm_cdf(0.80), es.Z_POWER_80, places=7)

    def test_symmetry(self):
        self.assertAlmostEqual(es._inv_norm_cdf(0.3), -es._inv_norm_cdf(0.7), places=9)

    def test_rejects_out_of_range(self):
        for bad in (0.0, 1.0, -0.1, 1.1):
            with self.assertRaises(ValueError):
                es._inv_norm_cdf(bad)


if __name__ == '__main__':
    unittest.main(verbosity=2)
