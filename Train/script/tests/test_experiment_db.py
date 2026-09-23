"""Unit tests for experiment_db.py (issue #422, GitLab #812)."""
import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import experiment_db as edb  # noqa: E402
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


class TestEveryStageRecords(unittest.TestCase):
    """GitLab #812: data stages, sessions, and a committed CSV."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.db = self.dir / 'experiments.db'

    def tearDown(self):
        self._tmp.cleanup()

    def test_data_stage_records_rows_and_drop_reasons(self):
        edb.record_data_stage('NB32', rows_in=120, rows_out=95,
                              drop_reasons={'nondeterministic': 20, 'failed': 5},
                              db_path=self.db, source='Learning')
        run = query_runs(db_path=self.db)[0]
        self.assertEqual((run['rows_in'], run['rows_out']), (120, 95))
        self.assertEqual(run['drop_reasons']['nondeterministic'], 20)
        self.assertAlmostEqual(run['metrics']['retention'], 95 / 120)
        self.assertEqual(run['config']['source'], 'Learning')

    def test_a_data_stage_with_no_input_does_not_divide_by_zero(self):
        edb.record_data_stage('NB13', rows_in=0, rows_out=0, db_path=self.db)
        self.assertIsNone(query_runs(db_path=self.db)[0]['metrics']['retention'])

    def test_funnel_is_recorded_end_to_end(self):
        class Funnel:
            name = 'notebook_pairs'
            stages = [
                {'stage': 'cell execution', 'before': 200, 'after': 150,
                 'reasons': {'nondeterministic': 50}},
                {'stage': 'dedup', 'before': 150, 'after': 130,
                 'reasons': {'duplicate': 20}},
            ]

        edb.record_funnel('NB32', Funnel(), db_path=self.db)
        run = query_runs(db_path=self.db)[0]
        self.assertEqual((run['rows_in'], run['rows_out']), (200, 130))
        self.assertEqual(run['drop_reasons'],
                         {'cell execution:nondeterministic': 50,
                          'dedup:duplicate': 20})

    def test_session_joins_the_stages_of_one_run(self):
        for stage in ('NB03', 'NB17', 'package'):
            edb.record_run(stage, session_id='run-A', db_path=self.db)
        edb.record_run('NB03', session_id='run-B', db_path=self.db)
        self.assertEqual(len(query_runs(db_path=self.db, session_id='run-A')), 3)
        self.assertEqual(len(query_runs(db_path=self.db, session_id='run-B')), 1)

    def test_an_old_database_is_migrated_not_abandoned(self):
        """The September database has none of the new columns."""
        import sqlite3
        conn = sqlite3.connect(self.db)
        conn.executescript(
            'CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'timestamp TEXT NOT NULL, notebook TEXT NOT NULL, run_name TEXT, '
            'config TEXT NOT NULL, metrics TEXT NOT NULL, artifacts TEXT NOT NULL);')
        conn.execute("INSERT INTO runs (timestamp, notebook, run_name, config, "
                     "metrics, artifacts) VALUES ('2026-08-04T17:03:30', 'NB17', "
                     "'old', '{}', '{\"best_val_loss\": 0.17}', '{}')")
        conn.commit()
        conn.close()

        edb.record_run('NB18', db_path=self.db)
        runs = sorted(query_runs(db_path=self.db), key=lambda r: r['id'])
        self.assertEqual(len(runs), 2)
        self.assertEqual(runs[0]['metrics']['best_val_loss'], 0.17)
        self.assertIsNone(runs[0]['session_id'])       # the old row, untouched

    def test_export_csv_is_stable_and_diffable(self):
        edb.record_run('NB17', config={'b': 2, 'a': 1}, metrics={'z': 1},
                       session_id='s1', db_path=self.db)
        edb.record_data_stage('NB32', 10, 8, db_path=self.db, session_id='s1')
        path, count = edb.export_csv(self.dir / 'experiments.csv', db_path=self.db)
        self.assertEqual(count, 2)
        self.assertEqual({r['session_id'] for r in query_runs(db_path=self.db)},
                         {'s1'})

        rows = list(csv.reader(open(path)))
        self.assertEqual(tuple(rows[0]), edb.CSV_COLUMNS)
        self.assertEqual([r[0] for r in rows[1:]], ['1', '2'])   # ordered by id
        # JSON columns are key-sorted so two runs diff line by line.
        self.assertEqual(rows[1][edb.CSV_COLUMNS.index('config')],
                         '{"a": 1, "b": 2}')

        again = self.dir / 'again.csv'
        edb.export_csv(again, db_path=self.db)
        self.assertEqual(path.read_text(), again.read_text())

    def test_export_can_be_scoped_to_one_session(self):
        edb.record_run('NB17', session_id='s1', db_path=self.db)
        edb.record_run('NB17', session_id='s2', db_path=self.db)
        _, count = edb.export_csv(self.dir / 'x.csv', db_path=self.db,
                                  session_id='s2')
        self.assertEqual(count, 1)


class TestCommittedExport(unittest.TestCase):
    def test_the_september_run_is_in_the_repository(self):
        """The point of #812: the record is readable without the binary."""
        csv_path = (Path(__file__).resolve().parents[2]
                    / 'runs' / '2026.09' / 'experiments.csv')
        self.assertTrue(csv_path.is_file(), f'{csv_path} is missing')
        rows = list(csv.reader(open(csv_path)))
        self.assertEqual(tuple(rows[0]), edb.CSV_COLUMNS)
        self.assertGreater(len(rows) - 1, 0)
        stages = {r[edb.CSV_COLUMNS.index('notebook')] for r in rows[1:]}
        self.assertIn('NB17', stages)


if __name__ == '__main__':
    unittest.main()
