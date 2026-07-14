"""Unit tests for train_utils.py (issues #392, #412, #420, #421, #423)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from train_utils import (  # noqa: E402
    lr_schedule_config, find_resume_checkpoint, resolve_resume,
    check_convergence, detect_regressions, per_task_trends,
    select_min_max_checkpoint, best_round, source_to_task_type,
)


class TestLrSchedule(unittest.TestCase):
    def test_cosine_basic(self):
        cfg = lr_schedule_config(1e-5, 800)
        self.assertEqual(cfg['name'], 'cosine_decay')
        self.assertEqual(cfg['arguments'][:2], [1e-5, 800])
        self.assertAlmostEqual(cfg['arguments'][2], 1e-6)
        self.assertNotIn('warmup', cfg)

    def test_warmup(self):
        cfg = lr_schedule_config(1e-5, 800, warmup=40)
        self.assertEqual(cfg['warmup'], 40)
        self.assertEqual(cfg['arguments'][1], 760)   # decay over the rest
        self.assertAlmostEqual(cfg['warmup_init'], 1e-6)

    def test_mlx_build_schedule_compat(self):
        # The dict must be consumable by mlx_lm's build_schedule.
        try:
            from mlx_lm.tuner.utils import build_schedule
        except ImportError:
            self.skipTest('mlx_lm not installed')
        fn = build_schedule(lr_schedule_config(1e-5, 100, warmup=10))
        import mlx.core as mx
        first = float(fn(mx.array(0)))
        mid = float(fn(mx.array(50)))
        last = float(fn(mx.array(100)))
        self.assertLess(first, 1e-5)        # warming up
        self.assertGreater(mid, last)        # decaying


class TestResume(unittest.TestCase):
    def _mk(self, tmp, names):
        for n in names:
            (Path(tmp) / n).write_bytes(b'x')

    def test_no_checkpoints(self):
        with tempfile.TemporaryDirectory() as tmp:
            ckpt, done = find_resume_checkpoint(tmp)
            self.assertIsNone(ckpt)
            self.assertEqual(done, 0)

    def test_latest_selected(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mk(tmp, ['0000100_adapters.safetensors',
                           '0000300_adapters.safetensors',
                           '0000200_adapters.safetensors',
                           'adapters.safetensors'])
            ckpt, done = find_resume_checkpoint(tmp)
            self.assertEqual(done, 300)
            self.assertEqual(ckpt.name, '0000300_adapters.safetensors')

    def test_resolve_partial_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mk(tmp, ['0000300_adapters.safetensors'])
            f, iters, msg = resolve_resume(tmp, 800, fallback_adapter='warm')
            self.assertEqual(Path(f).name, '0000300_adapters.safetensors')
            self.assertEqual(iters, 500)
            self.assertIn('RESUME', msg)

    def test_resolve_complete_run_starts_fresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mk(tmp, ['0000800_adapters.safetensors'])
            f, iters, msg = resolve_resume(tmp, 800, fallback_adapter='warm')
            self.assertEqual(f, 'warm')
            self.assertEqual(iters, 800)
            self.assertIn('NOT resuming', msg)

    def test_resolve_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mk(tmp, ['0000300_adapters.safetensors'])
            f, iters, _ = resolve_resume(tmp, 800, fallback_adapter='warm',
                                         enabled=False)
            self.assertEqual(f, 'warm')
            self.assertEqual(iters, 800)

    def test_resolve_missing_dir(self):
        f, iters, _ = resolve_resume('/nonexistent/dir/xyz', 100,
                                     fallback_adapter=None)
        self.assertIsNone(f)
        self.assertEqual(iters, 100)


class TestConvergence(unittest.TestCase):
    def test_too_few_rounds(self):
        conv, _ = check_convergence([0.5, 0.51], patience=2)
        self.assertFalse(conv)

    def test_flat_converges(self):
        conv, reason = check_convergence([0.40, 0.60, 0.61, 0.60],
                                         val_losses=[0.9, 0.5, 0.495, 0.5],
                                         patience=2)
        self.assertTrue(conv, reason)

    def test_still_improving(self):
        conv, _ = check_convergence([0.2, 0.35, 0.5, 0.65], patience=2)
        self.assertFalse(conv)

    def test_pass_flat_but_loss_moving(self):
        conv, _ = check_convergence([0.6, 0.6, 0.6],
                                    val_losses=[0.9, 0.7, 0.5],
                                    patience=2)
        self.assertFalse(conv)

    def test_none_val_losses_ignored(self):
        conv, _ = check_convergence([0.6, 0.6, 0.6],
                                    val_losses=[None, None, None],
                                    patience=2)
        self.assertTrue(conv)


class TestRegressions(unittest.TestCase):
    def test_detects_drop(self):
        hist = [{'code_generation': 0.5, 'debugging': 0.6},
                {'code_generation': 0.7, 'debugging': 0.65},
                {'code_generation': 0.75, 'debugging': 0.40}]
        regs = detect_regressions(hist, threshold=0.10)
        self.assertEqual(len(regs), 1)
        self.assertEqual(regs[0]['task'], 'debugging')
        self.assertAlmostEqual(regs[0]['drop'], 0.25)

    def test_no_regression(self):
        hist = [{'a': 0.5}, {'a': 0.55}]
        self.assertEqual(detect_regressions(hist, threshold=0.10), [])

    def test_single_round_no_history(self):
        self.assertEqual(detect_regressions([{'a': 0.1}]), [])

    def test_trends(self):
        hist = [{'a': 0.5}, {'a': 0.6, 'b': 0.3}]
        t = per_task_trends(hist)
        self.assertEqual(t['a'], [0.5, 0.6])
        self.assertEqual(t['b'], [None, 0.3])


class TestCheckpointSelection(unittest.TestCase):
    def test_min_max(self):
        losses = {
            'c1': {'code': 0.20, 'qa': 0.90},   # great majority, awful minority
            'c2': {'code': 0.30, 'qa': 0.45},   # balanced -> min-max winner
        }
        name, stats = select_min_max_checkpoint(losses)
        self.assertEqual(name, 'c2')
        self.assertAlmostEqual(stats['max_loss'], 0.45)

    def test_tie_broken_by_mean(self):
        losses = {
            'c1': {'a': 0.5, 'b': 0.5},
            'c2': {'a': 0.5, 'b': 0.2},
        }
        name, _ = select_min_max_checkpoint(losses)
        self.assertEqual(name, 'c2')

    def test_empty(self):
        self.assertEqual(select_min_max_checkpoint({}), (None, None))


class TestMisc(unittest.TestCase):
    def test_best_round(self):
        metrics = [{'round': -1, 'syntax_pass_rate': 0.1},
                   {'round': 0, 'syntax_pass_rate': 0.5},
                   {'round': 1, 'syntax_pass_rate': 0.7},
                   {'round': 2, 'syntax_pass_rate': 0.6}]
        self.assertEqual(best_round(metrics)['round'], 1)
        self.assertIsNone(best_round([{'round': -1, 'syntax_pass_rate': 0.1}]))

    def test_source_to_task_type(self):
        self.assertEqual(source_to_task_type('book_qa:ch1'), 'syntax_qa')
        self.assertEqual(source_to_task_type('wiki:Actions'), 'syntax_qa')
        self.assertEqual(source_to_task_type('repair:x'), 'debugging')
        self.assertEqual(source_to_task_type('example:Calculator'),
                         'code_generation')
        self.assertEqual(source_to_task_type(None), 'code_generation')


if __name__ == '__main__':
    unittest.main()
