"""Unit tests for Train/script/curriculum.py (GitLab #806).

Run with either:
    python3 -m pytest Train/script/tests/test_curriculum.py
    python3 -m unittest discover -s Train/script/tests -v
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402
import curriculum  # noqa: E402


def sample(output, task_type=None, source=None):
    return {
        'task_type': task_type,
        'source': source,
        'messages': [{'role': 'user', 'content': 'do a thing'},
                     {'role': 'assistant', 'content': output}],
    }


ONE_LINER = sample('`Log "hi" to the <console>.` prints to stdout.')

FEATURE_SET = sample("""```aro
(Application-Start: Demo) {
    Log "hi" to the <console>.
    Return an <OK: status> for the <startup>.
}
```""")

APPLICATION = sample("""## openapi.yaml
```yaml
paths: {}
```

## main.aro
```aro
(Application-Start: API) {
    Start the <http-server> with <contract>.
}

(listUsers: API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}
```""")

REPAIR = sample('The period was missing.', task_type='correction')


class StageTest(unittest.TestCase):
    def test_a_statement_is_a_one_liner(self):
        self.assertEqual(curriculum.stage_of(ONE_LINER), 'one_liner')

    def test_one_header_is_a_feature_set(self):
        self.assertEqual(curriculum.stage_of(FEATURE_SET), 'feature_set')

    def test_two_headers_and_a_contract_is_an_application(self):
        self.assertEqual(curriculum.stage_of(APPLICATION), 'application')

    def test_task_type_wins_for_repairs(self):
        # A correction whose answer happens to be one feature set is still a
        # repair: reading a broken program presupposes reading a working one.
        r = sample(FEATURE_SET['messages'][-1]['content'],
                   task_type='correction')
        self.assertEqual(curriculum.stage_of(r), 'repair')

    def test_debugging_and_error_pattern_are_repairs(self):
        for t in ('debugging', 'error_pattern'):
            self.assertEqual(curriculum.stage_of(sample('x', task_type=t)),
                             'repair')

    def test_declared_applications_are_applications(self):
        for t in ('full_application', 'multi_file_application'):
            self.assertEqual(curriculum.stage_of(sample('x', task_type=t)),
                             'application')

    def test_a_sample_without_messages(self):
        self.assertEqual(curriculum.stage_of({'output': 'Log <x>.'}),
                         'one_liner')

    def test_every_sample_lands_on_a_known_stage(self):
        for s in (ONE_LINER, FEATURE_SET, APPLICATION, REPAIR, {}):
            self.assertIn(curriculum.stage_of(s), curriculum.CURRICULUM_STAGES)


class OrderingTest(unittest.TestCase):
    def test_repairs_come_last_and_one_liners_first(self):
        # The inversion this fixes: the assembled set is shuffled with
        # random.seed(42), so the trainer's first exposure was whatever the
        # shuffle put there.
        mixed = [REPAIR, APPLICATION, ONE_LINER, FEATURE_SET]
        ordered = curriculum.order_by_curriculum(mixed)
        stages = [curriculum.stage_of(s) for s in ordered]
        self.assertEqual(stages,
                         ['one_liner', 'feature_set', 'application', 'repair'])

    def test_nothing_is_lost_or_duplicated(self):
        mixed = [REPAIR, APPLICATION, ONE_LINER, FEATURE_SET] * 5
        ordered = curriculum.order_by_curriculum(mixed)
        self.assertEqual(len(ordered), len(mixed))
        self.assertEqual(curriculum.stage_composition(ordered),
                         curriculum.stage_composition(mixed))

    def test_it_is_deterministic(self):
        mixed = [REPAIR, APPLICATION, ONE_LINER, FEATURE_SET] * 7
        a = curriculum.order_by_curriculum(mixed)
        b = curriculum.order_by_curriculum(mixed)
        self.assertEqual([id(x) for x in a], [id(x) for x in b])

    def test_it_shuffles_within_a_stage(self):
        # Varied batches inside a rung, without a repair landing before a
        # working program.
        rows = [sample(f'`Log "{i}" to the <console>.`') for i in range(50)]
        ordered = curriculum.order_by_curriculum(rows)
        self.assertNotEqual([id(x) for x in ordered], [id(x) for x in rows])

    def test_empty(self):
        self.assertEqual(curriculum.order_by_curriculum([]), [])


class ExecutionWeightTest(unittest.TestCase):
    def test_an_nb09_pair_is_verified_by_its_captured_stdout(self):
        # NB09 stamps exec_stdout on every pair whose program it ran, and
        # nothing else in the corpus writes that key.
        s = sample('x', source='recombination')
        s['exec_stdout'] = '[Application-Start] 5\n'
        self.assertTrue(curriculum.is_execution_verified(s))

    def test_the_same_generator_without_a_run_is_not(self):
        # `source` alone cannot decide it: NB09's strategies (mutation,
        # recombination, spec_to_code, readme_to_code) are shared with
        # generators that never run anything.
        self.assertFalse(curriculum.is_execution_verified(
            sample('x', source='recombination')))

    def test_notebook_outputs_are_verified(self):
        self.assertTrue(curriculum.is_execution_verified(
            sample('x', task_type='notebook_output')))
        self.assertTrue(curriculum.is_execution_verified(
            sample('x', source='learning_notebook')))

    def test_reducer_pairs_are_verified(self):
        self.assertTrue(curriculum.is_execution_verified(
            sample('x', source='eval_reducer')))

    def test_fim_is_not_execution_verified(self):
        # Its ground truth is a validated file: it parsed, it did not run.
        self.assertFalse(curriculum.is_execution_verified(
            sample('x', task_type='fim')))

    def test_an_explicit_flag_is_honoured(self):
        s = sample('x')
        s['execution_verified'] = True
        self.assertTrue(curriculum.is_execution_verified(s))

    def test_proposal_prose_is_not_verified(self):
        # And used to carry a HIGHER source-quality score (0.95) than the
        # execution-verified sources, which fell to the 0.8 default.
        self.assertFalse(curriculum.is_execution_verified(
            sample('x', source='proposal:ARO-0001')))
        self.assertFalse(curriculum.is_execution_verified(
            sample('x', source='book_qa:chapter3')))

    def test_a_verified_pair_is_worth_two(self):
        self.assertEqual(curriculum.curriculum_weight(
            sample('x', source='learning_notebook')), 2)
        self.assertEqual(curriculum.curriculum_weight(sample('x')), 1)

    def test_weights_are_materialised_as_repetition(self):
        # mlx_lm has no per-sample loss weight, and NB17 strips the `weight`
        # field before writing its files, so repetition is the only lever.
        rows = [sample('a', source='learning_notebook'), sample('b')]
        out, added = curriculum.apply_execution_weight(rows)
        self.assertEqual(added, 1)
        self.assertEqual(len(out), 3)
        self.assertEqual(sum(1 for s in out if s is rows[0]), 2)
        self.assertEqual(sum(1 for s in out if s is rows[1]), 1)

    def test_weighting_is_deterministic(self):
        rows = [sample(str(i), source='eval_reducer') for i in range(10)]
        a, _ = curriculum.apply_execution_weight(rows)
        b, _ = curriculum.apply_execution_weight(rows)
        self.assertEqual([id(x) for x in a], [id(x) for x in b])

    def test_nothing_to_weight(self):
        rows = [sample('a'), sample('b')]
        out, added = curriculum.apply_execution_weight(rows)
        self.assertEqual(added, 0)
        self.assertEqual(len(out), 2)


class TypeCapTest(unittest.TestCase):
    def test_correction_is_no_longer_above_code_generation(self):
        # It was 4000 against 3000, with eval_derived supplying 6084 pairs, so
        # error-then-fix was the largest task type reaching training.
        self.assertLessEqual(config.TYPE_CAPS['correction'],
                             config.TYPE_CAPS['code_generation'])

    def test_the_caps_version_was_bumped(self):
        self.assertTrue(config.TYPE_CAPS_VERSION.startswith('v5'))


class DescribeTest(unittest.TestCase):
    def test_it_names_every_stage_and_the_verified_share(self):
        text = curriculum.describe(
            [ONE_LINER, FEATURE_SET, APPLICATION, REPAIR,
             sample('x', source='learning_notebook')])
        for stage in curriculum.CURRICULUM_STAGES:
            self.assertIn(stage, text)
        self.assertIn('execution-verified', text)

    def test_empty_does_not_divide_by_zero(self):
        self.assertIn('one_liner', curriculum.describe([]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
