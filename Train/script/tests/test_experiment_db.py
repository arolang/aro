"""Unit tests for experiment_db.py (issue #422)."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from experiment_db import record_run, query_runs, best_run  # noqa: E402


class TestExperimentDb(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db = Path(self._tmp.name) / 'experiments.db'

    def tearDown(self):
        self._tmp.cleanup()

    def test_record_and_query(self):
        rid = record_run('NB17',
                         config={'lr': 1e-5, 'adapter': Path('/tmp/a')},
                         metrics={'best_val_loss': 0.17},
                         artifacts={'adapter': '/tmp/a'},
                         db_path=self.db)
        self.assertIsInstance(rid, int)
        runs = query_runs(db_path=self.db)
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]['notebook'], 'NB17')
        self.assertEqual(runs[0]['config']['lr'], 1e-5)
        self.assertEqual(runs[0]['config']['adapter'], '/tmp/a')  # Path coerced
        self.assertEqual(runs[0]['metrics']['best_val_loss'], 0.17)

    def test_best_run_min_max(self):
        record_run('NB17', {'lr': 1e-5}, {'best_val_loss': 0.20,
                                          'pass_rate': 0.5}, db_path=self.db)
        record_run('NB17', {'lr': 5e-6}, {'best_val_loss': 0.15,
                                          'pass_rate': 0.7}, db_path=self.db)
        record_run('NB20', {'round': 0}, {'pass_rate': 0.9}, db_path=self.db)

        best_loss = best_run('best_val_loss', mode='min', db_path=self.db)
        self.assertEqual(best_loss['config']['lr'], 5e-6)

        best_pass = best_run('pass_rate', mode='max', db_path=self.db)
        self.assertEqual(best_pass['notebook'], 'NB20')

        nb17_best = best_run('pass_rate', mode='max', notebook='NB17',
                             db_path=self.db)
        self.assertEqual(nb17_best['config']['lr'], 5e-6)

    def test_best_run_missing_metric(self):
        record_run('NB17', {}, {'x': 1}, db_path=self.db)
        self.assertIsNone(best_run('nonexistent', db_path=self.db))

    def test_notebook_filter(self):
        record_run('NB17', {}, {}, db_path=self.db)
        record_run('NB18', {}, {}, db_path=self.db)
        self.assertEqual(len(query_runs(notebook='NB18', db_path=self.db)), 1)

    def test_none_metrics_survive(self):
        record_run('NB17', {}, {'best_val_loss': None}, db_path=self.db)
        runs = query_runs(db_path=self.db)
        self.assertIsNone(runs[0]['metrics']['best_val_loss'])


if __name__ == '__main__':
    unittest.main()
