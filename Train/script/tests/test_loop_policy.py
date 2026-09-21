"""Unit tests for Train/script/loop_policy.py (GitLab #787).

Run with either:
    python3 -m pytest Train/script/tests/test_loop_policy.py
    python3 -m unittest discover -s Train/script/tests -v

`RECORDED_RUN` is the 2026-08 iterative-loop record, trimmed to the fields the
policy reads. The run's own conclusion is in the fixture: `best_round: 0`,
eight rounds trained, round 7 carried forward. These tests pin what the policy
would have decided instead.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import loop_policy  # noqa: E402


N = 60

RECORDED_RUN = [
    {'round': -1, 'syntax_pass_rate': 0.0, 'eval_n': N},
    {'round': 0, 'syntax_pass_rate': 42 / N, 'eval_n': N},
    {'round': 1, 'syntax_pass_rate': 28 / N, 'eval_n': N},
    {'round': 2, 'syntax_pass_rate': 37 / N, 'eval_n': N},
    {'round': 3, 'syntax_pass_rate': 20 / N, 'eval_n': N},
    {'round': 4, 'syntax_pass_rate': 17 / N, 'eval_n': N},
    {'round': 5, 'syntax_pass_rate': 30 / N, 'eval_n': N},
    {'round': 6, 'syntax_pass_rate': 32 / N, 'eval_n': N},
    {'round': 7, 'syntax_pass_rate': 31 / N, 'eval_n': N},
]


class PromotionTest(unittest.TestCase):
    def test_the_recorded_run_promotes_round_zero_not_round_seven(self):
        d = loop_policy.select_promotion(RECORDED_RUN)
        self.assertTrue(d['promote'])
        self.assertEqual(d['round'], 0)

    def test_and_names_the_rounds_that_bought_nothing(self):
        # Rounds 1, 2, 5, 6 and 7 are indistinguishable from round 0 at 95%.
        # Rounds 3 and 4 are distinguishably worse. Either way, nothing after
        # round 0 improved anything the evaluation can see — which is the
        # finding the loop had in hand and did not act on.
        d = loop_policy.select_promotion(RECORDED_RUN)
        self.assertEqual(d['wasted_rounds'], [1, 2, 5, 6, 7])

    def test_a_flat_loop_promotes_nothing(self):
        # Every round a draw against the model it started from: keep the
        # starting model, do not fuse, say why.
        flat = [{'round': -1, 'syntax_pass_rate': 0.50, 'eval_n': 200}]
        flat += [{'round': i, 'syntax_pass_rate': 0.51, 'eval_n': 200}
                 for i in range(3)]
        d = loop_policy.select_promotion(flat)
        self.assertFalse(d['promote'])
        self.assertIsNone(d['round'])
        self.assertIn('distinguishably better', d['reason'])

    def test_a_loop_that_degrades_promotes_nothing(self):
        degrading = [{'round': -1, 'syntax_pass_rate': 0.80, 'eval_n': 200}]
        degrading += [{'round': i, 'syntax_pass_rate': r, 'eval_n': 200}
                      for i, r in enumerate((0.60, 0.50, 0.40))]
        d = loop_policy.select_promotion(degrading)
        self.assertFalse(d['promote'])
        self.assertIn('Keeping the baseline', d['reason'])

    def test_a_real_improvement_is_promoted(self):
        good = [{'round': -1, 'syntax_pass_rate': 0.40, 'eval_n': 200}]
        good += [{'round': i, 'syntax_pass_rate': r, 'eval_n': 200}
                 for i, r in enumerate((0.55, 0.70))]
        d = loop_policy.select_promotion(good)
        self.assertTrue(d['promote'])
        self.assertEqual(d['round'], 1)

    def test_a_statistically_real_but_trivial_win_is_not_promoted(self):
        # Separated intervals on a huge eval, but a 1-point gain is not worth
        # a fuse: MIN_PROMOTION_GAIN is the second, absolute floor.
        tiny = [{'round': -1, 'syntax_pass_rate': 0.500, 'eval_n': 40000},
                {'round': 0, 'syntax_pass_rate': 0.510, 'eval_n': 40000}]
        d = loop_policy.select_promotion(tiny)
        self.assertFalse(d['promote'])

    def test_a_rate_without_a_sample_size_is_refused(self):
        # #786's rule, enforced here: an n-less rate cannot be compared.
        d = loop_policy.select_promotion(
            [{'round': -1, 'syntax_pass_rate': 0.4},
             {'round': 0, 'syntax_pass_rate': 0.9}])
        self.assertFalse(d['promote'])
        self.assertIn('sample size', d['reason'])

    def test_no_trained_rounds(self):
        d = loop_policy.select_promotion([{'round': -1, 'syntax_pass_rate': 0.4,
                                           'eval_n': 100}])
        self.assertFalse(d['promote'])
        self.assertIn('no trained rounds', d['reason'])


class PromotedModelDirTest(unittest.TestCase):
    def _run_dir(self, rounds, present):
        tmp = Path(tempfile.mkdtemp())
        (tmp / 'rounds').mkdir()
        with open(tmp / 'rounds' / 'round_results.json', 'w') as fh:
            json.dump({'rounds': rounds}, fh)
        for r in present:
            d = tmp / 'iterative' / f'round_{r}' / 'fused'
            d.mkdir(parents=True)
            (d / 'config.json').write_text('{}')
        return tmp

    def test_picks_the_promoted_round_not_the_last_one(self):
        # The bug this replaces: NB22's find_best_teacher sorted round_*/fused
        # by round number and took rounds[-1]. With the recorded run on disk
        # that is round 7, while the record in the same tree says round 0.
        tmp = self._run_dir(RECORDED_RUN, present=range(8))
        path, reason = loop_policy.promoted_model_dir(
            tmp / 'iterative', tmp / 'rounds' / 'round_results.json')
        self.assertIsNotNone(path)
        self.assertTrue(path.endswith('round_0/fused'))
        self.assertNotIn('round_7', path)
        self.assertIn('beats the baseline', reason)

    def test_returns_none_when_nothing_earned_promotion(self):
        flat = [{'round': -1, 'syntax_pass_rate': 0.5, 'eval_n': 200},
                {'round': 0, 'syntax_pass_rate': 0.5, 'eval_n': 200},
                {'round': 1, 'syntax_pass_rate': 0.5, 'eval_n': 200}]
        tmp = self._run_dir(flat, present=range(2))
        path, reason = loop_policy.promoted_model_dir(
            tmp / 'iterative', tmp / 'rounds' / 'round_results.json')
        self.assertIsNone(path)
        self.assertIn('distinguishably better', reason)

    def test_missing_record_is_not_silently_the_last_round(self):
        tmp = Path(tempfile.mkdtemp())
        path, reason = loop_policy.promoted_model_dir(
            tmp / 'iterative', tmp / 'round_results.json')
        self.assertIsNone(path)
        self.assertIn('cannot tell which round is best', reason)

    def test_promoted_round_with_no_weights_on_disk(self):
        tmp = self._run_dir(RECORDED_RUN, present=[7])
        path, reason = loop_policy.promoted_model_dir(
            tmp / 'iterative', tmp / 'rounds' / 'round_results.json')
        self.assertIsNone(path)
        self.assertIn('no config.json', reason)


class RoundBudgetTest(unittest.TestCase):
    def test_default_is_two(self):
        self.assertEqual(loop_policy.DEFAULT_MAX_ROUNDS, 2)

    def test_sixty_prompts_cannot_justify_eight_rounds(self):
        self.assertLess(loop_policy.recommend_max_rounds(60), 8)

    def test_a_bigger_eval_justifies_fewer_rounds_of_waiting(self):
        self.assertLessEqual(loop_policy.recommend_max_rounds(400),
                             loop_policy.recommend_max_rounds(60))

    def test_never_zero(self):
        self.assertGreaterEqual(loop_policy.recommend_max_rounds(10), 1)


class _Index:
    """Stand-in for config.NearDuplicateIndex."""

    def __init__(self, seen=()):
        self.seen_texts = list(seen)

    def check_and_add(self, text):
        if text in self.seen_texts:
            return True
        self.seen_texts.append(text)
        return False


PROGRAM = """(Application-Start: Demo) {
    Log "hi" to the <console>.
    Return an <OK: status> for the <startup>.
}
"""


class AcceptSampleTest(unittest.TestCase):
    def test_empty_is_rejected(self):
        ok, reason = loop_policy.accept_sample('   ')
        self.assertFalse(ok)
        self.assertEqual(reason, 'empty')

    def test_near_duplicate_is_rejected(self):
        idx = _Index([PROGRAM])
        ok, reason = loop_policy.accept_sample(PROGRAM, novelty_index=idx,
                                               run_program=None)
        self.assertFalse(ok)
        self.assertIn('near-duplicate', reason)

    def test_a_program_that_parses_but_does_not_run_is_rejected(self):
        # The old filter was `aro check` alone, so this sample joined the
        # corpus the next round trained on.
        ok, reason = loop_policy.accept_sample(
            PROGRAM, run_program=lambda _c: (False, 'Undefined variable: x'))
        self.assertFalse(ok)
        self.assertIn('does not run', reason)

    def test_a_program_that_runs_is_accepted(self):
        ok, reason = loop_policy.accept_sample(
            PROGRAM, run_program=lambda _c: (True, 'hi'))
        self.assertTrue(ok)
        self.assertEqual(reason, 'accepted')

    def test_a_missing_binary_does_not_silently_accept(self):
        # NB21's aro_check returns (None, 'aro_not_found') when the binary is
        # absent and generate_with_repair treats that as a pass, so a whole
        # round could be accepted unverified.
        ok, reason = loop_policy.accept_sample(
            PROGRAM, run_program=lambda _c: (None, 'aro_not_found'))
        self.assertFalse(ok)
        self.assertIn('unavailable', reason)

    def test_execution_can_be_made_advisory(self):
        ok, reason = loop_policy.accept_sample(
            PROGRAM, run_program=lambda _c: (False, 'boom'),
            require_execution=False)
        self.assertTrue(ok)
        self.assertIn('execution not required', reason)

    def test_unrunnable_programs_skip_the_execution_check(self):
        # A server program never terminates, so `is_safely_runnable` excludes
        # it and the sample is judged on novelty alone.
        server = ('(Application-Start: S) {\n'
                  '    Start the <http-server> with <contract>.\n'
                  '    Keepalive the <application> for the <events>.\n'
                  '}\n')
        called = []
        ok, reason = loop_policy.accept_sample(
            server, run_program=lambda c: called.append(c) or (False, 'x'))
        self.assertTrue(ok)
        self.assertEqual(called, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
