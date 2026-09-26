#!/usr/bin/env python3
"""The base-model A/B driver — GitLab #794.

The issue asks whether a dense base is as good as the 30B MoE. That could not
be answered before: the frozen benchmark scored one thing, and `aro ask` has
to do three. These tests cover the driver that answers it — not the models,
which need a GPU, but the plumbing that decides what the numbers mean.

The one that matters most is `test_a_perfect_model_scores_100_on_every_job`:
if a model answering every task with that task's own reference does not score
100%, the harness is broken and every comparison drawn from it is worthless.
"""

import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import base_model_ab as ab  # noqa: E402
import functional_eval as fe  # noqa: E402


def _aro_available():
    """Whether an `aro` binary is actually runnable here.

    `train:unit` runs in `python:3.12-slim`, which has no Swift and no `aro`.
    Every execution-graded row then comes back `passed=None` — correctly, since
    an unreachable toolchain must never count as a pass — so `by_job` carries
    only the `question` rows, and asserting on `write` raises KeyError. The
    grading logic that needs no binary is still worth covering there.
    """
    exe = shutil.which(fe.aro_bin()) or (
        fe.aro_bin() if os.path.exists(fe.aro_bin()) else None)
    if not exe:
        return False
    try:
        return subprocess.run([exe, '--version'], capture_output=True,
                              timeout=20).returncode == 0
    except Exception:
        return False


ARO = _aro_available()
NEEDS_ARO = unittest.skipUnless(ARO, 'no aro binary: execution-graded jobs cannot run')


def _answer_with(mapping):
    """A stub generator: prompt → (completion, extracted aro)."""
    def generate(model_id, prompts, **kwargs):
        return [mapping(p) for p in prompts]
    return generate


class CandidateSelectionTest(unittest.TestCase):

    def test_default_is_every_configured_candidate(self):
        self.assertEqual(ab.candidates(), ab.config.base_model_candidates())

    def test_candidates_can_be_named(self):
        label = ab.config.base_model_candidates()[0][0]
        self.assertEqual([c[0] for c in ab.candidates([label])], [label])

    def test_an_unknown_candidate_is_refused_by_name(self):
        # Silently scoring nothing because of a typo is the worst outcome here:
        # the run looks finished and decides nothing.
        with self.assertRaises(SystemExit) as caught:
            ab.candidates(['no-such-model'])
        self.assertIn('no-such-model', str(caught.exception))

    def test_the_candidate_list_is_dense_first(self):
        # The point of the experiment. If someone drops the dense candidates
        # the A/B cannot answer the question the issue asks.
        labels = [c[0] for c in ab.config.base_model_candidates()]
        self.assertIn('qwen3-14b', labels)
        self.assertIn('qwen2.5-coder-14b', labels)


class ScoringTest(unittest.TestCase):

    def setUp(self):
        self.tasks = fe.load_tasks()
        self.by_prompt = {t['prompt']: t for t in self.tasks}
        self._real_generate = ab.generate_with

    def tearDown(self):
        ab.generate_with = self._real_generate

    @NEEDS_ARO
    def test_a_perfect_model_scores_100_on_every_job(self):
        # Answer each task with its own reference. Anything less than 100%
        # means the harness is wrong, not the model.
        ab.generate_with = _answer_with(
            lambda p: (self.by_prompt[p].get('reference', ''),
                       self.by_prompt[p].get('reference', '')))
        summary = ab.score('stub', self.tasks)
        for job in ('question', 'write', 'fix'):
            self.assertEqual(summary['by_job'][job]['rate'], 1.0,
                             f'{job} should be perfect against its own references')

    @NEEDS_ARO
    def test_a_model_that_says_nothing_scores_zero_on_every_job(self):
        ab.generate_with = _answer_with(lambda p: ('', ''))
        summary = ab.score('stub', self.tasks)
        for job in ('question', 'write', 'fix'):
            self.assertEqual(summary['by_job'][job]['rate'], 0.0)

    @NEEDS_ARO
    def test_writing_well_and_debugging_badly_is_visible(self):
        # The reason the summary is per job: these two are different results
        # and a single pass rate cannot tell them apart.
        def answer(prompt):
            task = self.by_prompt[prompt]
            if task.get('job') == 'fix':
                return ('', '')
            ref = task.get('reference', '')
            return (ref, ref)

        ab.generate_with = _answer_with(answer)
        summary = ab.score('stub', self.tasks)
        self.assertEqual(summary['by_job']['write']['rate'], 1.0)
        self.assertEqual(summary['by_job']['fix']['rate'], 0.0)


    def test_question_scoring_needs_no_toolchain(self):
        # Runs everywhere, including the Linux `train:unit` image with no Swift
        # in it: a prose answer is graded against a rubric, not by running
        # anything. This is the coverage that survives when ARO is unavailable.
        questions = [t for t in self.tasks if t.get('grade_by') == 'doc_qa']
        self.assertTrue(questions, 'the benchmark must carry question tasks')
        ab.generate_with = _answer_with(
            lambda p: (self.by_prompt[p].get('reference', ''),) * 2)
        summary = ab.score('stub', questions)
        self.assertEqual(summary['by_job']['question']['rate'], 1.0)

    def test_a_model_that_cannot_be_run_is_not_scored_zero(self):
        # "Would not load" and "answered everything wrong" are different facts.
        ab.generate_with = lambda *a, **k: None
        self.assertIsNone(ab.score('stub', self.tasks))


class RenderTest(unittest.TestCase):

    def test_an_unscored_candidate_says_so_rather_than_showing_a_number(self):
        table = ab.render([('broken', None)])
        self.assertIn('not scored', table)
        self.assertNotIn('0.0%', table)

    def test_every_job_has_a_column(self):
        table = ab.render([('x', None)])
        for job in ('question', 'write', 'fix'):
            self.assertIn(job, table)


if __name__ == '__main__':
    unittest.main(verbosity=2)
