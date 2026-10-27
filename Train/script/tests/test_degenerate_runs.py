"""A run whose best iteration is inside warmup must not be fused (GitLab #788).

`experiments.db` row 12 of the 2026-08 run recorded

    {"best_val_loss": 0.612, "best_val_iter": 1, "stopped_early": true}

and was fused, trained on top of, and shipped as the teacher. The guard that
should have caught it tested `stopped_early` and `training_failed` only.

`stopped_early` alone cannot be the test, and row 1 of the same table is why:

    {"best_val_loss": 0.639, "best_val_iter": 450, "stopped_early": true}

That is a healthy run that found its minimum and then exhausted its patience
window — exactly what early stopping is for. A guard that rejects on the flag
throws it away along with the degenerate one.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from train_utils import (  # noqa: E402
    DEFAULT_WARMUP_ITERS,
    degenerate_run_reason,
    run_is_usable,
)


class TestDegenerateRuns(unittest.TestCase):

    # The two rows from the real table.

    def test_row12_the_shipped_teacher_is_rejected(self):
        metrics = {'best_val_loss': 0.612, 'best_val_iter': 1, 'stopped_early': True}
        reason = degenerate_run_reason(metrics)
        self.assertIsNotNone(reason, 'the run this issue is about must be rejected')
        self.assertIn('warmup', reason)
        self.assertFalse(run_is_usable(metrics))

    def test_row1_a_healthy_early_stop_is_kept(self):
        metrics = {'best_val_loss': 0.639, 'best_val_iter': 450, 'stopped_early': True}
        self.assertIsNone(degenerate_run_reason(metrics))
        self.assertTrue(run_is_usable(metrics))

    # The boundary, stated explicitly so a warmup change is a deliberate edit.

    def test_best_iter_just_below_warmup_is_degenerate(self):
        self.assertIsNotNone(
            degenerate_run_reason({'best_val_iter': DEFAULT_WARMUP_ITERS - 1}))

    def test_best_iter_at_warmup_is_usable(self):
        self.assertIsNone(
            degenerate_run_reason({'best_val_iter': DEFAULT_WARMUP_ITERS}))

    def test_warmup_is_configurable(self):
        metrics = {'best_val_iter': 50}
        self.assertIsNone(degenerate_run_reason(metrics, warmup=40))
        self.assertIsNotNone(degenerate_run_reason(metrics, warmup=100))

    # Explicit failure still wins, wherever it appears.

    def test_training_failed_is_rejected(self):
        reason = degenerate_run_reason({'training_failed': True, 'best_val_iter': 900})
        self.assertIsNotNone(reason)
        self.assertIn('training_failed', reason)

    def test_training_failed_false_is_not_a_rejection(self):
        self.assertIsNone(degenerate_run_reason({'best_val_loss': 0.742,
                                                 'training_failed': False}))

    # Absent information must not be read as failure: most rows predate the
    # flag, and refusing every one of them would reject the whole history.

    def test_empty_metrics_are_usable(self):
        self.assertIsNone(degenerate_run_reason({}))

    def test_non_dict_is_usable(self):
        self.assertIsNone(degenerate_run_reason(None))

    def test_unparseable_best_iter_is_not_guessed_at(self):
        self.assertIsNone(degenerate_run_reason({'best_val_iter': 'early'}))

    # `stopped_early` is only load-bearing when the best iteration is unknown.

    def test_stopped_early_without_best_iter_is_rejected(self):
        reason = degenerate_run_reason({'stopped_early': True})
        self.assertIsNotNone(reason)
        self.assertIn('best_val_iter', reason)


if __name__ == '__main__':
    unittest.main()
