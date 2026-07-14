"""Unit tests for eval_metrics.py (issues #417, #418, #419)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from eval_metrics import (  # noqa: E402
    lcs_length, rouge_l, concept_overlap, concepts_in_text, kb_concepts,
    stratified_sample, expected_operations, semantic_expectation_score,
    featureset_keyword_match, code_verbs, is_safely_runnable,
    extract_openapi_and_aro,
)

KB = {'actions': [
    {'verbs': ['Log'], 'prepositions': ['to'], 'role': 'EXPORT'},
    {'verbs': ['Read', 'Retrieve'], 'prepositions': ['from'], 'role': 'REQUEST'},
    {'verbs': ['Compute'], 'prepositions': ['from'], 'role': 'OWN'},
    {'verbs': ['Store'], 'prepositions': ['to'], 'role': 'EXPORT'},
    {'verbs': ['Return'], 'prepositions': ['for', 'with'], 'role': 'RESPONSE'},
]}
KB_VERBS = {'log', 'read', 'retrieve', 'compute', 'store', 'return'}


class TestRougeL(unittest.TestCase):
    def test_identical(self):
        self.assertAlmostEqual(rouge_l('the cat sat', 'the cat sat'), 1.0)

    def test_disjoint(self):
        self.assertEqual(rouge_l('alpha beta', 'gamma delta'), 0.0)

    def test_empty(self):
        self.assertEqual(rouge_l('', 'something'), 0.0)
        self.assertEqual(rouge_l('something', ''), 0.0)

    def test_subsequence(self):
        # ref 4 tokens, cand 5 tokens, lcs = 4 -> p=4/5, r=1, f1=8/9
        f1 = rouge_l('a b c d', 'a x b c d')
        self.assertAlmostEqual(f1, 2 * (4 / 5) * 1.0 / (4 / 5 + 1.0))

    def test_paraphrase_beats_disjoint(self):
        ref = 'use the Log action to write output to the console'
        close = 'you should use the Log action to print to the console'
        far = 'bananas are yellow fruit'
        self.assertGreater(rouge_l(ref, close), rouge_l(ref, far))

    def test_lcs(self):
        self.assertEqual(lcs_length(list('abcde'), list('ace')), 3)
        self.assertEqual(lcs_length([], list('abc')), 0)


class TestConceptOverlap(unittest.TestCase):
    def test_kb_concepts(self):
        c = kb_concepts(KB)
        self.assertIn('log', c)
        self.assertIn('retrieve', c)

    def test_full_overlap(self):
        c = kb_concepts(KB)
        ref = 'Use Log and Compute for this.'
        self.assertAlmostEqual(concept_overlap(ref, ref, c), 1.0)

    def test_no_reference_concepts(self):
        c = kb_concepts(KB)
        self.assertIsNone(concept_overlap('no concepts here at all', 'Log it', c))

    def test_partial(self):
        c = kb_concepts(KB)
        ref = 'Use Log and Compute.'         # {log, compute}
        cand = 'Use Log only.'                # {log}
        # precision 1/1, recall 1/2 -> f1 = 2/3
        self.assertAlmostEqual(concept_overlap(ref, cand, c), 2 / 3)

    def test_word_boundaries(self):
        c = {'log'}
        self.assertEqual(concepts_in_text('catalogue of things', c), set())
        self.assertEqual(concepts_in_text('Log the value', c), {'log'})


class TestStratifiedSample(unittest.TestCase):
    def _make(self, counts):
        out = []
        for t, n in counts.items():
            out.extend({'task_type': t, 'i': i} for i in range(n))
        return out

    def test_minority_kept(self):
        samples = self._make({'a': 100, 'b': 100, 'c': 10})
        picked, comp = stratified_sample(samples, 60, seed=0)
        self.assertEqual(len(picked), 60)
        self.assertEqual(comp['c'], 10)          # minority fully kept
        self.assertEqual(comp['a'], 25)
        self.assertEqual(comp['b'], 25)

    def test_budget_none(self):
        samples = self._make({'a': 5, 'b': 3})
        picked, comp = stratified_sample(samples, None, seed=0)
        self.assertEqual(len(picked), 8)
        self.assertEqual(comp, {'a': 5, 'b': 3})

    def test_budget_larger_than_data(self):
        samples = self._make({'a': 4})
        picked, comp = stratified_sample(samples, 100, seed=0)
        self.assertEqual(len(picked), 4)

    def test_deterministic(self):
        samples = self._make({'a': 50, 'b': 50})
        p1, _ = stratified_sample(samples, 20, seed=7)
        p2, _ = stratified_sample(samples, 20, seed=7)
        self.assertEqual([s['i'] for s in p1], [s['i'] for s in p2])


class TestSemanticChecks(unittest.TestCase):
    def test_expected_operations(self):
        exp = expected_operations('Read a file and log its contents', KB_VERBS)
        flat = set().union(*exp)
        self.assertIn('log', flat)
        self.assertIn('read', flat)

    def test_score_full(self):
        code = ('(Show File: Demo) {\n'
                '    Read the <content> from the <file: "a.txt">.\n'
                '    Log <content> to the <console>.\n'
                '    Return an <OK: status> for the <run>.\n'
                '}')
        score, n_exp, n_hit = semantic_expectation_score(
            'Read a file and log its contents', code, KB_VERBS)
        self.assertEqual(score, 1.0)
        self.assertEqual(n_exp, n_hit)

    def test_score_miss(self):
        code = ('(Nothing: Demo) {\n'
                '    Return an <OK: status> for the <run>.\n'
                '}')
        score, n_exp, n_hit = semantic_expectation_score(
            'Compute the hash and log it', code, KB_VERBS)
        self.assertIsNotNone(score)
        self.assertLess(score, 1.0)

    def test_score_none_when_no_expectations(self):
        score, _, _ = semantic_expectation_score('do something vague', '', KB_VERBS)
        self.assertIsNone(score)

    def test_code_verbs(self):
        code = '    Log <x> to the <console>.\n    Compute the <y> from <x>.'
        self.assertEqual(code_verbs(code), {'log', 'compute'})

    def test_featureset_keyword_match(self):
        code = '(Order Tracker: Order API) {\n    Return an <OK: status>.\n}'
        self.assertTrue(featureset_keyword_match(
            'Build an order tracking service', code))
        self.assertFalse(featureset_keyword_match(
            'Build a weather dashboard please', code))
        self.assertIsNone(featureset_keyword_match('anything', 'no featureset'))


class TestRunnableGate(unittest.TestCase):
    def test_safe(self):
        code = ('(Application-Start: X) {\n'
                '    Log "hi" to the <console>.\n'
                '    Return an <OK: status> for the <run>.\n}')
        self.assertTrue(is_safely_runnable(code))

    def test_keepalive_blocked(self):
        code = ('(Application-Start: X) {\n'
                '    Keepalive the <application> for the <events>.\n}')
        self.assertFalse(is_safely_runnable(code))

    def test_server_blocked(self):
        code = ('(Application-Start: X) {\n'
                '    Start the <http-server> with <contract>.\n}')
        self.assertFalse(is_safely_runnable(code))

    def test_no_app_start_blocked(self):
        self.assertFalse(is_safely_runnable('(getUser: API) { }'))


class TestExtraction(unittest.TestCase):
    def test_extract_both(self):
        text = ('## openapi.yaml\n```yaml\nopenapi: 3.0.3\n```\n'
                '## main.aro\n```aro\n(A: B) { }\n```')
        openapi, aro = extract_openapi_and_aro(text)
        self.assertIn('openapi', openapi)
        self.assertIn('(A: B)', aro)

    def test_extract_aro_only(self):
        openapi, aro = extract_openapi_and_aro('```aro\n(A: B) { }\n```')
        self.assertIsNone(openapi)
        self.assertIsNotNone(aro)

    def test_extract_nothing(self):
        openapi, aro = extract_openapi_and_aro('just prose')
        self.assertIsNone(openapi)
        self.assertIsNone(aro)


if __name__ == '__main__':
    unittest.main()
