"""Unit tests for Train/script/fact_check.py (GitLab #801).

Run with either:
    python3 -m pytest Train/script/tests/test_fact_check.py
    python3 -m unittest discover -s Train/script/tests -v

The first class is the point of the issue: a program the old keyword metric
scores as perfectly clean, which `aro check` rejects.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import fact_check  # noqa: E402


# The evaluation's metric, copied verbatim from 20_evaluation.ipynb cell 7 so
# the comparison below is against what actually ran, not a paraphrase of it.
def old_hallucination_score(code, known_verbs):
    verbs_found = re.findall(r'^\s+([A-Z][a-z]+)', code, re.MULTILINE)
    if not verbs_found:
        return None
    unknown = [v for v in verbs_found if v.lower() not in known_verbs]
    return len(unknown) / len(verbs_found)


# A program whose every verb is real and whose qualifier does not exist.
# `aro check` on this exact text, verified against the 0.12.0 toolchain:
#
#   3:18: error: Unknown Compute qualifier 'variance'
#     hint: Plugin qualifiers are namespaced: <spread: handle.variance>
#     hint: Run `aro actions --qualifiers` for the full set
HALLUCINATED = """(Application-Start: Report) {
    Create the <scores> with [90, 80, 70].
    Compute the <spread: variance> from the <scores>.
    Log <spread> to the <console>.
    Return an <OK: status> for the <report>.
}
"""

VALID = """(Application-Start: Report) {
    Create the <scores> with [90, 80, 70].
    Compute the <mean: avg> from the <scores>.
    Log <mean> to the <console>.
    Return an <OK: status> for the <report>.
}
"""


class TheOldMetricMissesItTest(unittest.TestCase):
    """The demonstration #801 asks for."""

    def setUp(self):
        self.catalog = fact_check.load_catalog()
        self.assertTrue(self.catalog['verbs'], 'verb catalog missing')
        self.assertTrue(self.catalog['qualifiers'], 'qualifier catalog missing')

    def test_the_old_metric_scores_the_hallucination_clean(self):
        score = old_hallucination_score(HALLUCINATED, self.catalog['verbs'])
        self.assertEqual(score, 0.0)

    def test_the_grounded_check_catches_it(self):
        findings = fact_check.grounded_findings(HALLUCINATED, self.catalog)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['kind'], 'qualifier')
        self.assertEqual(findings[0]['name'], 'variance')
        self.assertGreater(fact_check.hallucination_rate(HALLUCINATED,
                                                         self.catalog), 0.0)

    def test_and_still_passes_the_valid_program(self):
        self.assertEqual(fact_check.grounded_findings(VALID, self.catalog), [])
        self.assertEqual(fact_check.hallucination_rate(VALID, self.catalog), 0.0)

    def test_the_two_metrics_disagree_on_exactly_this_case(self):
        old = old_hallucination_score(HALLUCINATED, self.catalog['verbs'])
        new = fact_check.hallucination_rate(HALLUCINATED, self.catalog)
        self.assertEqual(old, 0.0)
        self.assertNotEqual(new, 0.0)


class VerbTest(unittest.TestCase):
    def test_an_invented_verb_is_caught(self):
        code = '(A: B) {\n    Frobnicate the <x> from the <y>.\n}'
        self.assertIn('Frobnicate', fact_check.hallucinated_verbs(code))

    def test_real_verbs_are_not(self):
        self.assertEqual(fact_check.hallucinated_verbs(VALID), [])

    def test_prose_in_comments_is_not_a_verb(self):
        code = ('(A: B) {\n'
                '    (* Frobnicate the value before returning it *)\n'
                '    Log <x> to the <console>.\n'
                '}')
        self.assertEqual(fact_check.hallucinated_verbs(code), [])


class QualifierTest(unittest.TestCase):
    def test_a_namespaced_plugin_qualifier_is_allowed(self):
        code = '(A: B) {\n    Compute the <p: collections.pick-random> from <xs>.\n}'
        self.assertEqual(fact_check.hallucinated_qualifiers(code), [])

    def test_a_chain_is_checked_part_by_part(self):
        ok = '(A: B) {\n    Compute the <n: lines|length> from <t>.\n}'
        self.assertEqual(fact_check.hallucinated_qualifiers(ok), [])
        bad = '(A: B) {\n    Compute the <n: lines|nonsense> from <t>.\n}'
        self.assertEqual(fact_check.hallucinated_qualifiers(bad), ['nonsense'])

    def test_a_date_offset_is_allowed(self):
        code = '(A: B) {\n    Compute the <then: -7d> from <now>.\n}'
        self.assertEqual(fact_check.hallucinated_qualifiers(code), [])

    def test_field_accesses_are_not_qualifiers(self):
        # `<request: body>`, `<OK: status>` and `<user: email>` are open by
        # design; only the Compute slot is closed (GitLab #486), so checking
        # every `<x: y>` would flag the whole language.
        code = ('(getUser: API) {\n'
                '    Extract the <id> from the <pathParameters: id>.\n'
                '    Retrieve the <user> from the <user-repository> where <id> is <id>.\n'
                '    Return an <OK: status> with <user>.\n'
                '}')
        self.assertEqual(fact_check.hallucinated_qualifiers(code), [])

    def test_no_catalog_means_no_verdict(self):
        self.assertEqual(
            fact_check.hallucinated_qualifiers(
                HALLUCINATED, {'verbs': set(), 'actions': {}, 'qualifiers': set()}),
            [])


class RateTest(unittest.TestCase):
    def test_prose_has_no_rate(self):
        self.assertIsNone(fact_check.hallucination_rate('Just an explanation.'))

    def test_fenced_code_is_extracted(self):
        text = 'Here you go:\n\n```aro\n' + HALLUCINATED + '```\n'
        self.assertGreater(fact_check.hallucination_rate(text), 0.0)

    def test_qualifier_sites_are_in_the_denominator(self):
        # Four verbs plus one qualifier: one bad site in five.
        self.assertAlmostEqual(fact_check.hallucination_rate(HALLUCINATED), 0.2)


class InventedStatisticsTest(unittest.TestCase):
    # The recorded probe failure, verbatim from
    # data/07_eval/report.json _meta.training_meta_probe.flagged[0].
    CONFABULATION = (
        'The model achieved a 95% syntax pass rate on the training data, with '
        'only 5% of examples failing syntax checks. The training data included '
        '1000 examples, and all were syntactically valid ARO code.')

    def test_the_recorded_confabulation_is_flagged(self):
        claims = fact_check.invented_statistics(self.CONFABULATION)
        self.assertGreaterEqual(len(claims), 2)
        figures = [f for c in claims for f in c['figures']]
        self.assertTrue(any('95' in f for f in figures))
        self.assertTrue(any('1000' in f for f in figures))

    def test_the_old_metric_saw_nothing_here(self):
        # No ARO verbs in the sentence at all, so a verb-fraction metric
        # returns None and the report shows a clean 0.000 for the task.
        self.assertIsNone(fact_check.hallucination_rate(self.CONFABULATION))

    def test_a_plain_aro_answer_is_not_flagged(self):
        self.assertEqual(fact_check.invented_statistics(
            'Use `Compute the <total: sum> from <amounts>.` to add them up.'), [])

    def test_talking_about_a_users_own_training_data_app_is_not_flagged(self):
        self.assertEqual(fact_check.invented_statistics(
            'Write a feature set that stores a record in the user-repository.'),
            [])

    def test_a_claim_without_a_figure_is_not_flagged(self):
        self.assertEqual(fact_check.invented_statistics(
            'I was fine-tuned on ARO source code.'), [])

    def test_non_strings(self):
        self.assertEqual(fact_check.invented_statistics(None), [])
        self.assertEqual(fact_check.invented_statistics(42), [])

    def test_the_gate(self):
        ok, offenders = fact_check.refuses_invented_statistics(
            [('how did training go?', self.CONFABULATION),
             ('what is Compute?', 'Compute transforms a value.')])
        self.assertFalse(ok)
        self.assertTrue(all(o['prompt'] == 'how did training go?'
                            for o in offenders))

    def test_the_gate_passes_clean_replies(self):
        ok, offenders = fact_check.refuses_invented_statistics(
            ['Compute transforms a value.', 'Use Log to print.'])
        self.assertTrue(ok)
        self.assertEqual(offenders, [])


class RegressionFlagTest(unittest.TestCase):
    # The recorded report's code_explanation row.
    REPORT = {
        'code_explanation': {'ft_rouge_l': 0.021, 'base_rouge_l': 0.149,
                             'ft_fact_f1': 0.0, 'base_fact_f1': 0.333,
                             'ft_token_overlap': 0.066,
                             'base_token_overlap': 0.287},
        'syntax_qa': {'ft_rouge_l': 0.299, 'base_rouge_l': 0.146},
        'code_generation': {'ft_syntax_pass_rate': 0.523,
                            'base_syntax_pass_rate': 0.154,
                            'ft_hallucination_rate': 0.019,
                            'base_hallucination_rate': 0.05},
    }

    def test_the_code_explanation_collapse_is_flagged(self):
        flags = fact_check.regression_flags(self.REPORT)
        tasks = {f['task'] for f in flags}
        self.assertIn('code_explanation', tasks)
        worst = flags[0]
        self.assertEqual(worst['task'], 'code_explanation')
        self.assertEqual(worst['metric'], 'fact_f1')

    def test_improvements_are_not_flagged(self):
        flags = fact_check.regression_flags(self.REPORT)
        self.assertNotIn('syntax_qa', {f['task'] for f in flags})

    def test_a_lower_hallucination_rate_is_an_improvement(self):
        # 0.019 vs 0.050: lower is better, so this must not read as a drop.
        flags = fact_check.regression_flags(self.REPORT)
        self.assertFalse(any(f['metric'] == 'hallucination_rate'
                             for f in flags))

    def test_a_higher_hallucination_rate_is_a_regression(self):
        flags = fact_check.regression_flags(
            {'t': {'ft_hallucination_rate': 0.4, 'base_hallucination_rate': 0.1}})
        self.assertEqual(len(flags), 1)
        self.assertAlmostEqual(flags[0]['drop'], 0.3)

    def test_a_threshold_can_be_applied(self):
        flags = fact_check.regression_flags(self.REPORT, min_drop=0.2)
        self.assertTrue(all(f['drop'] > 0.2 for f in flags))

    def test_missing_counterparts_and_nones(self):
        self.assertEqual(fact_check.regression_flags(
            {'t': {'ft_x': 0.1}, 'u': {'ft_y': None, 'base_y': 0.5},
             'v': 'not a dict'}), [])

    def test_empty(self):
        self.assertEqual(fact_check.regression_flags({}), [])
        self.assertEqual(fact_check.regression_flags(None), [])


class PrepositionTest(unittest.TestCase):
    def test_a_wrong_preposition_is_caught(self):
        # The catalog gives Log `for`, `to` and `with` — not `from`.
        code = '(A: B) {\n    Log the <x> from the <console>.\n}'
        bad = fact_check.bad_prepositions(code)
        self.assertTrue(any('Log' in b for b in bad), bad)

    def test_a_right_one_is_not(self):
        code = '(A: B) {\n    Log the <x> to the <console>.\n}'
        self.assertEqual(fact_check.bad_prepositions(code), [])

    def test_guards_are_always_allowed(self):
        code = '(A: B) {\n    Return an <OK: status> when <x>.\n}'
        self.assertEqual(fact_check.bad_prepositions(code), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
