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

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import base_model_ab as ab  # noqa: E402
import functional_eval as fe  # noqa: E402


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

    def test_a_model_that_says_nothing_scores_zero_on_every_job(self):
        ab.generate_with = _answer_with(lambda p: ('', ''))
        summary = ab.score('stub', self.tasks)
        for job in ('question', 'write', 'fix'):
            self.assertEqual(summary['by_job'][job]['rate'], 0.0)

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
