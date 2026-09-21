"""Unit tests for Train/script/fusion_gate.py (GitLab #791).

Run with either:
    python3 -m pytest Train/script/tests/test_fusion_gate.py
    python3 -m unittest discover -s Train/script/tests -v
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import fusion_gate as fg  # noqa: E402


class GateTest(unittest.TestCase):
    def test_an_improvement_fuses(self):
        r = fg.evaluate_fuse('thinking', {'reasons': 40.0, 'valid_code': 55.0},
                             {'reasons': 82.0, 'valid_code': 71.0}, n=120)
        self.assertTrue(r['allow'])
        self.assertIn('+42', r['reason'])

    def test_a_real_regression_blocks(self):
        # NB24 computed exactly this shape, charted it, and fused anyway.
        r = fg.evaluate_fuse('thinking', {'reasons': 70.0, 'valid_code': 65.0},
                             {'reasons': 72.0, 'valid_code': 30.0}, n=120)
        self.assertFalse(r['allow'])
        self.assertIn('valid_code', r['reason'])
        self.assertIn('refusing to fuse', r['reason'])
        self.assertTrue(r['metrics']['valid_code']['blocking'])
        self.assertFalse(r['metrics']['reasons']['blocking'])

    def test_a_drop_inside_the_budget_does_not_block(self):
        r = fg.evaluate_fuse('material', {'valid_code': 70.0},
                             {'valid_code': 68.5}, n=400)
        self.assertTrue(r['allow'])

    def test_a_large_drop_on_a_tiny_holdout_does_not_block(self):
        # The conversation booster trains on 24 rows and holds out 5. A
        # 20-point swing there is one conversation. Blocking on it would be
        # the same mistake in the other direction, so the gate passes it and
        # says the measurement could not have seen anything short of a
        # collapse.
        r = fg.evaluate_fuse('conversation', {'valid_code': 80.0},
                             {'valid_code': 60.0}, n=5)
        self.assertTrue(r['allow'])
        self.assertTrue(r['underpowered'])
        self.assertIn('floor', r['reason'])

    def test_a_collapse_blocks_even_on_a_small_holdout(self):
        r = fg.evaluate_fuse('conversation', {'valid_code': 100.0},
                             {'valid_code': 0.0}, n=20)
        self.assertFalse(r['allow'])

    def test_metrics_can_be_restricted(self):
        r = fg.evaluate_fuse('thinking', {'a': 50.0, 'b': 50.0},
                             {'a': 50.0, 'b': 5.0}, n=200, metrics=['a'])
        self.assertTrue(r['allow'])
        self.assertNotIn('b', r['metrics'])

    def test_no_common_metrics_is_a_refusal(self):
        r = fg.evaluate_fuse('x', {'a': 1.0}, {'b': 2.0}, n=100)
        self.assertFalse(r['allow'])
        self.assertIn('no metrics in common', r['reason'])

    def test_require_raises_on_a_block(self):
        with self.assertRaises(fg.FusionBlocked):
            fg.require_fuse_gate('thinking', {'valid_code': 70.0},
                                 {'valid_code': 20.0}, n=120)

    def test_require_returns_on_a_pass(self):
        r = fg.require_fuse_gate('thinking', {'valid_code': 70.0},
                                 {'valid_code': 75.0}, n=120)
        self.assertTrue(r['allow'])


class ResolveBaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def _model(self, name):
        d = self.tmp / name
        d.mkdir(parents=True)
        (d / 'config.json').write_text('{}')
        return d

    def test_picks_the_first_existing_candidate(self):
        self._model('distill')
        path, reason = fg.resolve_base(
            'thinking', [self.tmp / 'material', self.tmp / 'distill'],
            fallback='mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16')
        self.assertTrue(path.endswith('distill'))
        self.assertIn('thinking base', reason)

    def test_prefers_the_earlier_candidate(self):
        self._model('material')
        self._model('distill')
        path, _ = fg.resolve_base(
            'thinking', [self.tmp / 'material', self.tmp / 'distill'])
        self.assertTrue(path.endswith('material'))

    def test_refuses_the_silent_thirty_billion_fallback(self):
        # The whole point: with neither student directory present, NB24 used
        # to train a 30B MoE LoRA and print one line about it.
        with self.assertRaises(fg.FusionBlocked) as ctx:
            fg.resolve_base('thinking',
                            [self.tmp / 'material', self.tmp / 'distill'],
                            fallback='mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16')
        msg = str(ctx.exception)
        self.assertIn('DIFFERENT', msg)
        self.assertIn('ARO_TRAIN_ALLOW_BASE_FALLBACK', msg)

    def test_the_fallback_is_available_when_asked_for(self):
        path, reason = fg.resolve_base(
            'thinking', [self.tmp / 'material'],
            fallback='some-base', allow_fallback=True)
        self.assertEqual(path, 'some-base')
        self.assertIn('FALLBACK', reason)
        self.assertIn('not the release chain', reason)

    def test_no_candidates_and_no_fallback(self):
        with self.assertRaises(fg.FusionBlocked) as ctx:
            fg.resolve_base('material', [self.tmp / 'nope'])
        self.assertIn('Run the upstream stage', str(ctx.exception))

    def test_a_directory_without_the_marker_does_not_count(self):
        (self.tmp / 'half').mkdir()
        with self.assertRaises(fg.FusionBlocked):
            fg.resolve_base('thinking', [self.tmp / 'half'])


class LearningRateTest(unittest.TestCase):
    def test_the_material_stage_is_flagged(self):
        ok, msg = fg.check_learning_rate('material', 1e-4)
        self.assertFalse(ok)
        self.assertIn('10x', msg)
        self.assertIn('Not blocking', msg)

    def test_the_other_stages_are_not(self):
        for stage in ('thinking', 'conversation'):
            ok, _ = fg.check_learning_rate(stage, 1e-5)
            self.assertTrue(ok)

    def test_a_rate_far_below_the_chain_is_flagged_too(self):
        ok, msg = fg.check_learning_rate('x', 1e-7)
        self.assertFalse(ok)
        self.assertIn('LOWER', msg)


if __name__ == '__main__':
    unittest.main(verbosity=2)
