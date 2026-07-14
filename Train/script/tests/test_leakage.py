"""Unit tests for leakage.py (issue #405)."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from leakage import (  # noqa: E402
    normalize_text, instruction_key, char_ngrams, jaccard, sample_instruction,
    reserve_holdout, verify_exclusion, leakage_report,
)


def _sample(instr, task='code_generation'):
    return {'task_type': task,
            'messages': [{'role': 'system', 'content': 'sys'},
                         {'role': 'user', 'content': instr},
                         {'role': 'assistant', 'content': 'out'}]}


class TestNormalization(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(normalize_text('  Hello\n  WORLD  '), 'hello world')

    def test_key_prefix(self):
        self.assertEqual(instruction_key('A' * 500, prefix_len=10), 'a' * 10)

    def test_sample_instruction(self):
        self.assertEqual(sample_instruction(_sample('do x')), 'do x')
        self.assertEqual(sample_instruction({'instruction': 'flat'}), 'flat')
        self.assertEqual(sample_instruction({'prompt': 'p'}), 'p')


class TestSimilarity(unittest.TestCase):
    def test_jaccard_identical(self):
        g = char_ngrams('write an aro feature set')
        self.assertEqual(jaccard(g, g), 1.0)

    def test_jaccard_disjoint(self):
        self.assertEqual(jaccard(char_ngrams('aaaa'), char_ngrams('zzzz')), 0.0)

    def test_near_duplicate_scores_high(self):
        a = char_ngrams('write an aro feature set that logs a message to the console')
        b = char_ngrams('write an aro feature set that logs the message to the console')
        self.assertGreater(jaccard(a, b), 0.8)


class TestHoldout(unittest.TestCase):
    def test_reserve_and_reapply(self):
        samples = [_sample(f'instruction number {i} does thing {i}',
                           task='code_generation' if i % 3 else 'syntax_qa')
                   for i in range(200)]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'holdout.jsonl'
            remaining, holdout = reserve_holdout(samples, path,
                                                 fraction=0.1, min_size=10,
                                                 seed=1)
            self.assertTrue(path.exists())
            self.assertGreaterEqual(len(holdout), 10)
            self.assertEqual(len(remaining) + len(holdout), 200)
            # exclusion holds
            self.assertEqual(verify_exclusion(remaining, holdout), [])
            # stratified: both task types present
            tasks = {s['task_type'] for s in holdout}
            self.assertEqual(tasks, {'code_generation', 'syntax_qa'})

            # second run re-applies the SAME holdout
            remaining2, holdout2 = reserve_holdout(samples, path,
                                                   fraction=0.1, seed=999)
            k1 = sorted(sample_instruction(s) for s in holdout)
            k2 = sorted(sample_instruction(s) for s in holdout2)
            self.assertEqual(k1, k2)
            self.assertEqual(len(remaining2), len(remaining))

    def test_collision_detection(self):
        train = [_sample('shared instruction text')]
        holdout = [_sample('shared instruction text')]
        self.assertEqual(len(verify_exclusion(train, holdout)), 1)


class TestLeakageReport(unittest.TestCase):
    def test_exact_and_near(self):
        train = ['write an aro feature set that logs a message to the console',
                 'build a user api with crud operations for the service']
        evals = {
            'clean': ['explain how repositories work in aro today'],
            'exact': ['Write an ARO feature set that logs a message to the console'],
            'near':  ['write an aro feature set that logs the message to the console'],
        }
        rep = leakage_report(train, evals, sim_threshold=0.8)
        self.assertEqual(rep['clean']['exact'], 0)
        self.assertEqual(rep['clean']['near'], 0)
        self.assertEqual(rep['exact']['exact'], 1)   # case-insensitive exact
        self.assertEqual(rep['near']['exact'], 0)
        self.assertEqual(rep['near']['near'], 1)
        self.assertEqual(rep['exact']['leak_fraction'], 1.0)

    def test_empty_eval_set(self):
        rep = leakage_report(['train text'], {'empty': []})
        self.assertEqual(rep['empty']['leak_fraction'], 0.0)


if __name__ == '__main__':
    unittest.main()
