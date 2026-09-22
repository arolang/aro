"""Unit tests for run_archive.py and the fresh-run guard (GitLab #792)."""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import config  # noqa: E402
import run_archive  # noqa: E402


def _fake_cfg(root: Path):
    """A stand-in for the config module rooted in a temp directory."""
    cfg = types.SimpleNamespace(
        DATA_ROOT=root / 'data',
        MODELS_DIR=root / 'models',
        RELEASE_DIR=root / 'release',
        ARO_ROOT=root,
        ARO_APPLICATION_ROOT=root / 'missing-app',
        PIPELINE_VERSION='test.0',
        TYPE_CAPS_VERSION='vtest',
        SESSION_ID='session-test',
        RUN_ARCHIVE_ROOT=root / 'runs',
    )
    cfg.run_archive_dir = lambda release=None: cfg.RUN_ARCHIVE_ROOT / (release or 'test.0')
    return cfg


class TestRunArchive(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.cfg = _fake_cfg(self.root)
        ds = self.root / 'data' / '05_dataset'
        ds.mkdir(parents=True)
        (ds / 'stats.json').write_text('{"samples": 3}')
        (ds / 'dataset_report.md').write_text('# report\n')

    def tearDown(self):
        self._tmp.cleanup()

    def test_archives_present_records_absent(self):
        manifest = run_archive.archive(cfg=self.cfg, plan=run_archive.artifact_plan(self.cfg))
        names = {a['artifact'] for a in manifest['artifacts']}
        self.assertEqual(names, {'stats.json', 'dataset_report.md'})
        dest = self.cfg.run_archive_dir()
        self.assertTrue((dest / 'stats.json').is_file())
        self.assertTrue((dest / 'run.json').is_file())
        # Everything the run did not produce is recorded rather than ignored.
        absent = {m['artifact'] for m in manifest['missing']}
        self.assertIn('promotion_gate.json', absent)
        self.assertIn('loop_metrics.json', absent)

    def test_manifest_records_provenance(self):
        manifest = run_archive.archive(cfg=self.cfg, plan=run_archive.artifact_plan(self.cfg))
        on_disk = json.loads((self.cfg.run_archive_dir() / 'run.json').read_text())
        self.assertEqual(on_disk['pipeline_version'], 'test.0')
        self.assertEqual(on_disk['type_caps_version'], 'vtest')
        self.assertEqual(on_disk['session_id'], 'session-test')
        self.assertIn('packages', on_disk)
        self.assertEqual(manifest['artifacts'][0]['sha256'],
                         on_disk['artifacts'][0]['sha256'])

    def test_dry_run_writes_nothing(self):
        run_archive.archive(cfg=self.cfg, dry_run=True,
                            plan=run_archive.artifact_plan(self.cfg))
        self.assertFalse(self.cfg.run_archive_dir().exists())

    def test_check_detects_tampering(self):
        run_archive.archive(cfg=self.cfg, plan=run_archive.artifact_plan(self.cfg))
        self.assertEqual(run_archive.check(cfg=self.cfg), [])
        (self.cfg.run_archive_dir() / 'stats.json').write_text('{"samples": 4}')
        problems = run_archive.check(cfg=self.cfg)
        self.assertEqual(len(problems), 1)
        self.assertIn('sha256', problems[0])

    def test_check_reports_missing_archive(self):
        problems = run_archive.check(cfg=self.cfg)
        self.assertEqual(len(problems), 1)
        self.assertIn('run.json missing', problems[0])


class TestFreshGuard(unittest.TestCase):
    """01_init must not wipe later-stage output without an explicit opt-in."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _dir_with(self, name, files=1):
        d = self.root / name
        d.mkdir(parents=True, exist_ok=True)
        for i in range(files):
            (d / f'f{i}').write_text('x')
        return d

    def test_empty_dirs_are_allowed(self):
        empty = self.root / 'empty'
        empty.mkdir()
        self.assertEqual(
            config.assert_fresh_allowed([(empty, 'NB17 checkpoints')], fresh=False), [])

    def test_missing_dirs_are_allowed(self):
        self.assertEqual(
            config.assert_fresh_allowed([(self.root / 'nope', 'NB17')], fresh=False), [])

    def test_populated_dir_refuses(self):
        d = self._dir_with('models', files=3)
        with self.assertRaises(config.NotAFreshRun) as ctx:
            config.assert_fresh_allowed([(d, 'NB18 adapters')], fresh=False)
        message = str(ctx.exception)
        self.assertIn('NB18 adapters', message)
        self.assertIn('ARO_TRAIN_FRESH=1', message)

    def test_explicit_opt_in_allows_wipe(self):
        d = self._dir_with('models', files=2)
        at_risk = config.assert_fresh_allowed([(d, 'NB18 adapters')], fresh=True)
        self.assertEqual(at_risk[0][1], 'NB18 adapters')
        self.assertEqual(at_risk[0][2], 2)

    def test_counts_files_recursively(self):
        d = self._dir_with('models', files=1)
        (d / 'nested').mkdir()
        (d / 'nested' / 'deep').write_text('y')
        at_risk = config.assert_fresh_allowed([(d, 'NB18')], fresh=True)
        self.assertEqual(at_risk[0][2], 2)


if __name__ == '__main__':
    unittest.main()
