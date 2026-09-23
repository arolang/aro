"""Unit tests for config.HPARAMS and check_hparams.py (GitLab #795)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import check_hparams as ch  # noqa: E402
import config  # noqa: E402


class TestHparamsTable(unittest.TestCase):
    def test_every_notebook_stage_exists_in_the_table(self):
        for name, (stage, _mapping) in ch.NOTEBOOK_STAGES.items():
            with self.subTest(notebook=name):
                self.assertIn(stage, config.HPARAMS)

    def test_every_stage_declares_the_shared_keys(self):
        shared = ('lora_rank', 'lora_dropout', 'lora_scale',
                  'weight_decay', 'max_seq_len', 'learning_rate',
                  'lora_layers', 'batch_size')
        for stage, row in config.HPARAMS.items():
            for key in shared:
                with self.subTest(stage=stage, key=key):
                    self.assertIn(key, row)

    def test_rank_is_the_same_everywhere(self):
        """The sweep measured rank 8; nothing has measured anything else."""
        ranks = {row['lora_rank'] for row in config.HPARAMS.values()}
        self.assertEqual(ranks, {8})

    def test_teacher_stages_agree_on_lr_and_accumulation(self):
        """#795's central contradiction: two rows for one model."""
        sft, loop = config.HPARAMS['sft'], config.HPARAMS['iterative']
        self.assertEqual(sft['learning_rate'], loop['learning_rate'])
        self.assertEqual(sft['grad_accum'], loop['grad_accum'])

    def test_hparams_returns_a_copy(self):
        row = config.hparams('sft')
        row['learning_rate'] = 999
        self.assertNotEqual(config.HPARAMS['sft']['learning_rate'], 999)

    def test_unknown_stage_names_the_known_ones(self):
        with self.assertRaises(KeyError) as ctx:
            config.hparams('finetune')
        self.assertIn('conversation', str(ctx.exception))

    def test_hparams_record_carries_provenance(self):
        rec = config.hparams_record('sft', iters=7)
        self.assertEqual(rec['stage'], 'sft')
        self.assertEqual(rec['iters'], 7)
        self.assertEqual(rec['hparams_version'], config.HPARAMS_VERSION)
        self.assertEqual(rec['effective_batch'],
                         config.HPARAMS['sft']['batch_size']
                         * config.HPARAMS['sft']['grad_accum'])


class TestChecker(unittest.TestCase):
    """The checker has to actually catch a literal coming back."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _notebook(self, name, lines):
        nb = {'cells': [{'cell_type': 'code', 'source': [l + '\n' for l in lines],
                         'metadata': {}, 'outputs': [], 'execution_count': None}],
              'metadata': {}, 'nbformat': 4, 'nbformat_minor': 5}
        (self.dir / name).write_text(json.dumps(nb))
        return name

    def test_clean_notebook_passes(self):
        name = self._notebook('x.ipynb', [
            "HP = hparams('sft')",
            "LEARNING_RATE = HP['learning_rate']",
            "cmd = ['--learning-rate', str(LEARNING_RATE)]",
        ])
        findings = ch.check_all(self.dir, {name: ('sft', {'LEARNING_RATE': 'learning_rate'})})
        self.assertEqual(findings, [])

    def test_literal_assignment_is_caught(self):
        name = self._notebook('x.ipynb', [
            "HP = hparams('sft')",
            "LEARNING_RATE = 1e-5",
        ])
        findings = ch.check_all(self.dir, {name: ('sft', {'LEARNING_RATE': 'learning_rate'})})
        self.assertEqual(len(findings), 1)
        self.assertIn('LEARNING_RATE = 1e-5', findings[0])

    def test_literal_command_line_flag_is_caught(self):
        name = self._notebook('x.ipynb', [
            "HP = hparams('sft')",
            "cmd = ['--num-layers', '16']",
        ])
        findings = ch.check_all(self.dir, {name: ('sft', {})})
        self.assertEqual(len(findings), 1)
        self.assertIn('--num-layers', findings[0])

    def test_uncovered_flag_is_left_alone(self):
        name = self._notebook('x.ipynb', [
            "HP = hparams('sft')",
            "cmd = ['--save-every', '100']",
        ])
        self.assertEqual(ch.check_all(self.dir, {name: ('sft', {})}), [])

    def test_notebook_that_never_reads_the_table_is_caught(self):
        name = self._notebook('x.ipynb', ["BATCH_SIZE = HP['batch_size']"])
        findings = ch.check_all(self.dir, {name: ('sft', {})})
        self.assertEqual(len(findings), 1)
        self.assertIn('never calls hparams', findings[0])

    def test_missing_notebook_is_reported(self):
        findings = ch.check_all(self.dir, {'gone.ipynb': ('sft', {})})
        self.assertEqual(len(findings), 1)
        self.assertIn('notebook missing', findings[0])


class TestRealNotebooks(unittest.TestCase):
    def test_the_shipped_notebooks_are_clean(self):
        """This is the CI gate, asserted here too so it fails locally first."""
        self.assertEqual(ch.check_all(), [])


if __name__ == '__main__':
    unittest.main()
