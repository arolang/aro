"""Unit tests for the pure-python helpers in Train/script/config.py.

Covers the helpers added for the train::infra issues:
  #382 — build_artifact_metadata / JSONL metadata header
  #384 — backup_pairs_file / clean_notebook_pairs / rollback_notebook_pairs
  #385 — corpus_preflight / ARO_APPLICATION_PATH resolution
  #387 — NearDuplicateIndex
  #406 — TYPE_CAPS + TYPE_CAPS_VERSION
  #408 — stamp_provenance / record_run_metadata / save_notebook_pair wiring
  #409 — FunnelCounter

Run with:  python3 -m unittest discover -s Train/script/tests -v
(or from Train/script/tests:  python3 test_config_helpers.py)
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import config  # noqa: E402


class ConfigHelperTest(unittest.TestCase):
    """Base class that redirects config's file paths into a temp dir."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='aro_config_test_'))
        self._saved = {
            'PAIRS_FILE': config.PAIRS_FILE,
            'BACKUP_DIR': config.BACKUP_DIR,
            'RUNS_DIR': config.RUNS_DIR,
            '_RUN_RECORDED': config._RUN_RECORDED,
            'CLEAN_ON_RESTART': config.CLEAN_ON_RESTART,
        }
        config.PAIRS_FILE = self.tmp / 'knowledge_pairs.jsonl'
        config.BACKUP_DIR = self.tmp / 'backups'
        config.RUNS_DIR = self.tmp / 'runs'
        config._RUN_RECORDED = False
        config.CLEAN_ON_RESTART = True

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(config, k, v)

    def _read_records(self):
        return [json.loads(l) for l in config.PAIRS_FILE.read_text().splitlines() if l.strip()]


class TestArtifactMetadata(ConfigHelperTest):
    def test_metadata_fields(self):
        meta = config.build_artifact_metadata(num_source_files=7, extra={'artifact': 'x'})
        for key in ('generated_at', 'session_id', 'pipeline_version',
                    'aro_lang_commit', 'aro_app_commit'):
            self.assertIn(key, meta)
        self.assertEqual(meta['num_source_files'], 7)
        self.assertEqual(meta['artifact'], 'x')
        self.assertEqual(meta['session_id'], config.SESSION_ID)
        # ARO-Lang is a git checkout — the commit must resolve.
        self.assertTrue(meta['aro_lang_commit'])

    def test_jsonl_header_detection(self):
        header = json.loads(config._pairs_metadata_line(num_pairs=3))
        self.assertTrue(config.is_jsonl_metadata_record(header))
        self.assertFalse(config.is_jsonl_metadata_record({'instruction': 'x', 'output': 'y'}))
        self.assertFalse(config.is_jsonl_metadata_record(
            {'_metadata': {}, 'instruction': 'x'}))


class TestProvenance(ConfigHelperTest):
    def test_stamp_provenance(self):
        pair = {'instruction': 'i', 'output': 'o', 'source': 'mutation'}
        config.stamp_provenance(pair, 'NB07')
        prov = pair['provenance']
        self.assertEqual(prov['session_id'], config.SESSION_ID)
        self.assertEqual(prov['model_version'], config.MODEL_ID)
        self.assertEqual(prov['notebook'], 'NB07')
        self.assertEqual(prov['generation_strategy'], 'mutation')
        self.assertNotIn('lineage', prov)

    def test_stamp_preserves_existing_and_lineage(self):
        pair = {'instruction': 'i', 'output': 'o',
                'provenance': {'session_id': 'old-session'}}
        config.stamp_provenance(pair, 'NB04', generation_strategy='variant',
                                lineage={'variant_of': 'example:Foo'})
        prov = pair['provenance']
        self.assertEqual(prov['session_id'], 'old-session')  # never rewritten
        self.assertEqual(prov['generation_strategy'], 'variant')
        self.assertEqual(prov['lineage'], {'variant_of': 'example:Foo'})

    def test_save_pair_stamps_and_records_run(self):
        config.save_notebook_pair('NBTEST', {'instruction': 'do x', 'output': 'c', 'source': 's1'})
        recs = self._read_records()
        # flagged metadata first line (issue #382)
        self.assertTrue(config.is_jsonl_metadata_record(recs[0]))
        self.assertEqual(recs[1]['notebook'], 'NBTEST')
        self.assertEqual(recs[1]['provenance']['generation_strategy'], 's1')
        # run snapshot written (issue #408)
        runs = list(config.RUNS_DIR.glob('*.json'))
        self.assertEqual(len(runs), 1)
        info = json.loads(runs[0].read_text())
        self.assertEqual(info['session_id'], config.SESSION_ID)
        self.assertEqual(info['type_caps_version'], config.TYPE_CAPS_VERSION)


class TestBackupAndRollback(ConfigHelperTest):
    def _seed(self):
        config.save_notebook_pairs('NBA', [
            {'instruction': 'a1', 'output': 'o1'},
            {'instruction': 'a2', 'output': 'o2'},
        ])
        config.save_notebook_pairs('NBB', [{'instruction': 'b1', 'output': 'o3'}])

    def test_clean_backs_up_then_removes(self):
        self._seed()
        removed = config.clean_notebook_pairs('NBA')
        self.assertEqual(removed, 2)
        backups = config.list_pairs_backups()
        self.assertEqual(len(backups), 1)
        # backup contains the removed rows
        backed = [json.loads(l) for l in backups[0].read_text().splitlines() if l.strip()]
        self.assertEqual(sum(1 for r in backed if r.get('notebook') == 'NBA'), 2)
        # current file keeps NBB and a fresh metadata header
        recs = self._read_records()
        self.assertTrue(config.is_jsonl_metadata_record(recs[0]))
        tags = [r.get('notebook') for r in recs[1:]]
        self.assertEqual(tags, ['NBB'])

    def test_rollback_restores_tag(self):
        self._seed()
        config.clean_notebook_pairs('NBA')
        restored = config.rollback_notebook_pairs('NBA')
        self.assertEqual(restored, 2)
        tags = sorted(r.get('notebook') for r in self._read_records()
                      if not config.is_jsonl_metadata_record(r))
        self.assertEqual(tags, ['NBA', 'NBA', 'NBB'])

    def test_rollback_without_backup(self):
        self.assertEqual(config.rollback_notebook_pairs('NOPE'), 0)

    def test_clean_noop_when_tag_absent(self):
        self._seed()
        self.assertEqual(config.clean_notebook_pairs('NBC'), 0)
        self.assertEqual(config.list_pairs_backups(), [])

    def test_clean_respects_flag(self):
        self._seed()
        config.CLEAN_ON_RESTART = False
        self.assertEqual(config.clean_notebook_pairs('NBA'), 0)

    def test_backup_pruning(self):
        self._seed()
        config.PAIRS_BACKUP_KEEP_saved = config.PAIRS_BACKUP_KEEP
        try:
            config.PAIRS_BACKUP_KEEP = 3
            for _ in range(5):
                config.backup_pairs_file(reason='prune-test')
            self.assertEqual(len(config.list_pairs_backups()), 3)
        finally:
            config.PAIRS_BACKUP_KEEP = config.PAIRS_BACKUP_KEEP_saved
            del config.PAIRS_BACKUP_KEEP_saved


class TestFunnelCounter(ConfigHelperTest):
    def test_stages_and_markdown(self):
        f = config.FunnelCounter('t')
        f.record_stage('merge', 100, 120)                       # gain stage
        f.record_stage('dedup', 120, 90, {'duplicate': 30})
        f.record_stage('caps', 90, 80, {'cap_exceeded:qa': 10})
        d = f.to_dict()
        self.assertEqual(len(d['stages']), 3)
        self.assertEqual(d['stages'][1]['dropped'], 30)
        self.assertEqual(d['stages'][0]['dropped'], 0)          # gains clamp to 0
        md = f.render_markdown()
        self.assertIn('| dedup | 120 | 90 | -30 | 75.0% | duplicate=30 |', md)

    def test_drop_csv(self):
        f = config.FunnelCounter('t')
        f.record_stage('a', 10, 8, {'r1': 2})
        f.record_stage('b', 8, 7)   # dropped without reasons → 'unspecified'
        path = f.write_drop_csv(self.tmp / 'drops.csv')
        rows = path.read_text().splitlines()
        self.assertEqual(rows[0], 'stage,reason,count')
        self.assertIn('a,r1,2', rows)
        self.assertIn('b,unspecified,1', rows)


class TestNearDuplicateIndex(unittest.TestCase):
    def test_detects_near_duplicates(self):
        idx = config.NearDuplicateIndex(threshold=0.9)
        idx.add('Write a complete ARO application that logs hello world to the console')
        self.assertTrue(idx.seen(
            'Write a complete ARO application that logs hello world to the console please'))
        self.assertFalse(idx.seen('Build an HTTP server with two endpoints for users'))

    def test_check_and_add(self):
        idx = config.NearDuplicateIndex(threshold=0.9)
        self.assertFalse(idx.check_and_add('first unique instruction about repositories'))
        self.assertTrue(idx.check_and_add('first unique instruction about repositories'))

    def test_empty_text(self):
        idx = config.NearDuplicateIndex()
        self.assertFalse(idx.seen(''))
        idx.add('')
        self.assertFalse(idx.seen(''))


class TestTypeCaps(unittest.TestCase):
    def test_caps_present_and_versioned(self):
        self.assertIsInstance(config.TYPE_CAPS, dict)
        self.assertIn('code_generation', config.TYPE_CAPS)
        self.assertEqual(config.TYPE_CAPS['code_generation'], 1200)
        self.assertIsNone(config.DEFAULT_TYPE_CAP)
        self.assertTrue(config.TYPE_CAPS_VERSION.startswith('v'))


class TestCorpusPreflight(unittest.TestCase):
    def test_report_shape(self):
        report = config.corpus_preflight(require_application=False, raise_on_missing=False)
        self.assertIn('Examples/', report)
        self.assertTrue(report['Examples/']['exists'])
        self.assertIn('ARO-Application', report)

    def test_missing_required_raises(self):
        saved = config.ARO_APPLICATION_ROOT
        try:
            config.ARO_APPLICATION_ROOT = Path('/nonexistent/ARO-Application')
            with self.assertRaises(FileNotFoundError):
                config.corpus_preflight(require_application=True, raise_on_missing=True)
        finally:
            config.ARO_APPLICATION_ROOT = saved


if __name__ == '__main__':
    unittest.main(verbosity=2)
