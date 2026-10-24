"""The teacher-training stages are skipped while the teacher is inference-only.

TEACHER_IS_INFERENCE_ONLY (config.py) is a run decision: MoE fine-tuning is
training-time-risky while inference on a sparse model is stable and cheap, so
the default run never trains the teacher. The meta pipeline default-skips
stages 18/19 for that reason, the stage cells refuse a direct run, and
ARO_TRAIN_TRAIN_TEACHER=1 opts a run back in on both sides. Nothing here
executes notebooks — this is wiring, asserted in the cells that carry it, the
same way the stage-list tests assert theirs.
"""

import json
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent

META = SCRIPT_DIR / '00_META_PIPELINE.ipynb'
STAGES = {18: SCRIPT_DIR / '18_finetune.ipynb',
          19: SCRIPT_DIR / '19_preference_sft.ipynb'}


def cells(path):
    """The joined source of every cell, in order."""
    nb = json.loads(Path(path).read_text())
    return [''.join(c['source']) for c in nb['cells']]


class TestTeacherTrainingSkips(unittest.TestCase):

    def test_nb00_default_skips_are_gated_on_the_flag(self):
        driver = [src for src in cells(META)
                  if 'ARO_TRAIN_SKIP' in src and 'ARO_TRAIN_EXACT' in src]
        self.assertEqual(len(driver), 1, 'the SKIP driver cell')
        src = driver[0]
        self.assertIn("SKIP |= {'18', '19'}", src,
                      'the default skip of the teacher stages regressed')
        self.assertIn('import config', src,
                      'NB00 does not import config for itself — the flag '
                      'would be an unresolved name mid-run')
        # Gated, not unconditional, and placed after the env var is read so
        # --skip/--from still compose over it.
        i_skip = src.index("SKIP = set(os.environ.get('ARO_TRAIN_SKIP'")
        i_gate = src.index('if config.TEACHER_IS_INFERENCE_ONLY:')
        i_add = src.index("SKIP |= {'18', '19'}")
        i_from = src.index("'ARO_TRAIN_FROM'")
        self.assertTrue(i_skip < i_gate < i_add < i_from, 'wiring order')
        # The refusal to skip names the opt-in — a run that wants 18/19 has
        # to be able to find the switch from the meta pipeline's own output.
        self.assertIn('ARO_TRAIN_TRAIN_TEACHER', src)

    def test_stage_cells_refuse_a_direct_run_while_the_flag_holds(self):
        for num, path in STAGES.items():
            with self.subTest(stage=num):
                src = cells(path)[2]      # the config-reload cell
                self.assertIn('import config; importlib.reload(config)', src)
                i_gate = src.index('if TEACHER_IS_INFERENCE_ONLY:')
                # Gated on the flag (the env-derived one), not on a raw env
                # read: the semantics live in config.py in one place.
                guard = src[i_gate:]
                self.assertIn('raise SystemExit', guard)
                self.assertIn('ARO_TRAIN_TRAIN_TEACHER', guard,
                              f'stage {num}: the guard must name the opt-in')


if __name__ == '__main__':
    unittest.main()
