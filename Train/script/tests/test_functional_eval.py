"""Unit tests for Train/script/functional_eval.py and human_eval.py
(GitLab #813).

Run with either:
    python3 -m pytest Train/script/tests/test_functional_eval.py
    python3 -m unittest discover -s Train/script/tests -v

The matching, normalisation and scoring tests are pure python. The tests that
need the `aro` toolchain skip when it is not on PATH, so this file runs on the
slim CI image alongside the rest.
"""

import csv
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import functional_eval as fe  # noqa: E402
import human_eval as he  # noqa: E402

HAS_ARO = shutil.which('aro') is not None
TASKS = Path(__file__).resolve().parents[2] / 'eval' / 'functional' / 'tasks.json'


class NormaliseTest(unittest.TestCase):
    def test_strips_the_interpreter_line_prefix(self):
        # `aro run` prefixes each line with the feature set that printed it;
        # a compiled binary does not. One expected output serves both.
        self.assertEqual(fe.normalise('[Application-Start] 42'), '42')
        self.assertEqual(fe.normalise('[Handle Order] hi'), 'hi')

    def test_strips_ansi(self):
        self.assertEqual(fe.normalise('\x1b[32mPASS\x1b[0m'), 'PASS')

    def test_strips_timings(self):
        self.assertEqual(fe.normalise('PASS  a-test (13ms)'), 'PASS  a-test')
        self.assertEqual(fe.normalise('PASS  a-test (<1ms)'), 'PASS  a-test')

    def test_substitutes_timestamps(self):
        self.assertEqual(fe.normalise('at 2026-09-21T10:11:12Z'),
                         'at __TIMESTAMP__')

    def test_trims_blank_edges_and_crlf(self):
        self.assertEqual(fe.normalise('\r\n\r\n42\r\n\r\n'), '42')


class MatchTest(unittest.TestCase):
    def test_sequence_allows_extra_framing(self):
        # The default for generated code: the answer is the contract, the
        # framing is not. A correct program that also logs a label, and the
        # interpreter's own `[OK] startup`, must not fail it.
        ok, _ = fe.matches('[Application-Start] computing...\n'
                           '[Application-Start] 42\n[OK] startup', '42')
        self.assertTrue(ok)

    def test_sequence_enforces_order(self):
        ok, why = fe.matches('b\na', 'a\nb')
        self.assertFalse(ok)
        self.assertIn('not found', why)

    def test_sequence_rejects_a_wrong_answer(self):
        ok, _ = fe.matches('[Application-Start] 41\n[OK] startup', '42')
        self.assertFalse(ok)

    def test_strict_counts_lines(self):
        self.assertTrue(fe.matches('a\nb', 'a\nb', mode='strict')[0])
        self.assertFalse(fe.matches('a\nb\nc', 'a\nb', mode='strict')[0])

    def test_occurrence_ignores_order(self):
        self.assertTrue(fe.matches('b\na', 'a\nb', mode='occurrence')[0])

    def test_placeholders(self):
        self.assertTrue(fe.matches('total: 1234', 'total: __NUMBER__')[0])
        self.assertTrue(fe.matches('id: 3f2a9c1b4e5d6a7f',
                                   'id: __ID__')[0])
        self.assertFalse(fe.matches('total: abc', 'total: __NUMBER__')[0])

    def test_a_literal_regex_character_is_escaped(self):
        self.assertTrue(fe.matches('cost: $1.50 (net)', 'cost: $1.50 (net)')[0])
        self.assertFalse(fe.matches('cost: $1X50 (net)',
                                    'cost: $1.50 (net)')[0])


class GradeWithoutToolchainTest(unittest.TestCase):
    def test_an_empty_answer_fails_without_running_anything(self):
        r = fe.grade({'id': 'x', 'expected_output': '1'}, '   ')
        self.assertFalse(r['passed'])
        self.assertEqual(r['status'], 'no_code')

    def test_a_missing_binary_is_not_a_pass(self):
        # NB21's aro_check returns None when the binary is missing and
        # generate_with_repair treats None as a pass. Here `passed` is None,
        # and `summarise` excludes it from the denominator instead of
        # counting it either way.
        original = fe.aro_bin
        fe.aro_bin = lambda: '/nonexistent/aro-binary'
        try:
            r = fe.grade({'id': 'x', 'expected_output': '1'},
                         '(A: B) { Log "1" to the <console>. }')
            self.assertIsNone(r['passed'])
            self.assertEqual(r['status'], 'no_binary')
        finally:
            fe.aro_bin = original


class SummariseTest(unittest.TestCase):
    def test_reports_an_interval_not_a_bare_rate(self):
        rows = [{'id': f't{i}', 'grade_by': 'execution_output',
                 'passed': i < 7} for i in range(10)]
        s = fe.summarise(rows)
        self.assertAlmostEqual(s['pass_rate']['rate'], 0.7)
        self.assertLess(s['pass_rate']['low'], 0.7)
        self.assertGreater(s['pass_rate']['high'], 0.7)
        self.assertTrue(s['pass_rate']['underpowered'])

    def test_grades_are_reported_separately(self):
        # So a headline number can never be assembled out of `aro check`
        # passes, which is exactly how 67% was arrived at.
        rows = [{'id': 'a', 'grade_by': 'execution_output', 'passed': False},
                {'id': 'b', 'grade_by': 'aro_check', 'passed': True}]
        s = fe.summarise(rows)
        self.assertEqual(s['by_grade']['execution_output']['rate'], 0.0)
        self.assertEqual(s['by_grade']['aro_check']['rate'], 1.0)

    def test_unreachable_rows_are_excluded_not_counted(self):
        rows = [{'id': 'a', 'grade_by': 'x', 'passed': True},
                {'id': 'b', 'grade_by': 'x', 'passed': None}]
        s = fe.summarise(rows)
        self.assertEqual(s['unreachable'], 1)
        self.assertEqual(s['pass_rate']['n'], 1)

    def test_pass_at_k(self):
        rows = [{'id': 'a', 'grade_by': 'x', 'passed': True},
                {'id': 'a', 'grade_by': 'x', 'passed': False},
                {'id': 'b', 'grade_by': 'x', 'passed': False},
                {'id': 'b', 'grade_by': 'x', 'passed': False}]
        s = fe.summarise(rows, samples=2)
        self.assertAlmostEqual(s['pass_at_1'], 0.25)
        self.assertAlmostEqual(s['pass_at_k'], 0.5)


class BenchmarkFileTest(unittest.TestCase):
    def setUp(self):
        self.tasks = fe.load_tasks(TASKS)

    def test_every_task_is_well_formed(self):
        ids = set()
        for t in self.tasks:
            self.assertNotIn(t['id'], ids, f'duplicate id {t["id"]}')
            ids.add(t['id'])
            self.assertTrue(t['prompt'].strip())
            self.assertIn(t['grade_by'], ('execution_output', 'aro_test',
                                          'aro_check', 'doc_qa'))
            self.assertIn(t.get('job', 'write'), ('write', 'fix', 'question'))
            if t['grade_by'] == 'execution_output':
                self.assertIn('expected_output', t)
            if t['grade_by'] == 'aro_test':
                self.assertIn('test', t)
            if t['grade_by'] == 'doc_qa':
                self.assertIn('must_include', t)
            self.assertIn('reference', t, f'{t["id"]} has no reference')

    def test_the_benchmark_is_not_all_one_grade(self):
        grades = {t['grade_by'] for t in self.tasks}
        self.assertIn('execution_output', grades)
        self.assertIn('aro_test', grades)

    def test_no_task_is_graded_by_parsing_alone(self):
        # The whole point of #813: `aro check` is kept as a mode for scoring
        # existing prompt sets on the same axis, but nothing in THIS benchmark
        # may use it.
        self.assertNotIn('aro_check', {t['grade_by'] for t in self.tasks})

    @unittest.skipUnless(HAS_ARO, 'needs the aro toolchain')
    def test_every_reference_solution_passes(self):
        # A benchmark whose own answers do not pass is measuring itself.
        rows = fe.grade_references(self.tasks)
        failed = [(r['id'], r['reason']) for r in rows if r['passed'] is not True]
        self.assertEqual(failed, [], f'{len(failed)} reference(s) fail')

    @unittest.skipUnless(HAS_ARO, 'needs the aro toolchain')
    def test_a_wrong_answer_is_rejected(self):
        # The case `aro check` cannot see: valid ARO, runs cleanly, wrong
        # number.
        task = next(t for t in self.tasks if t['id'] == 'arithmetic-total')
        wrong = ('(Application-Start: Arithmetic) {\n'
                 '    Compute the <total> from 7 + 6.\n'
                 '    Log <total> to the <console>.\n'
                 '    Return an <OK: status> for the <startup>.\n'
                 '}\n')
        r = fe.grade(task, wrong)
        self.assertEqual(r['status'], 'ok')       # it ran
        self.assertFalse(r['passed'])             # and it is still wrong

    @unittest.skipUnless(HAS_ARO, 'needs the aro toolchain')
    def test_a_program_that_parses_but_does_not_run_is_rejected(self):
        task = next(t for t in self.tasks if t['id'] == 'arithmetic-total')
        broken = ('(Application-Start: Arithmetic) {\n'
                  '    Log <never-bound> to the <console>.\n'
                  '    Return an <OK: status> for the <startup>.\n'
                  '}\n')
        r = fe.grade(task, broken)
        self.assertFalse(r['passed'])


class DeclaredButUnimplementedTest(unittest.TestCase):
    """eval_prompts.json has carried a `grade_by: execution_output` entry with
    fixtures and an expected output since GitLab #486, and a grep for
    `grade_by` anywhere else in the repository returned nothing. It is read
    now."""

    PROMPTS = Path(__file__).resolve().parents[2] / 'eval_prompts.json'

    def setUp(self):
        with open(self.PROMPTS) as fh:
            self.graded = [t for t in json.load(fh) if t.get('grade_by')]

    def test_there_is_at_least_one_such_entry(self):
        self.assertTrue(self.graded)

    def test_functional_eval_understands_every_grade_it_declares(self):
        for t in self.graded:
            self.assertIn(t['grade_by'],
                          ('execution_output', 'aro_test', 'aro_check'))

    @unittest.skipUnless(HAS_ARO, 'needs the aro toolchain')
    def test_their_reference_answers_pass(self):
        for r in fe.grade_references([t for t in self.graded
                                      if t.get('reference')]):
            self.assertTrue(r['passed'], f'{r["id"]}: {r["reason"]}')


class HumanSliceTest(unittest.TestCase):
    PROMPTS = [{'cat': 'a', 'prompt': f'prompt a{i}'} for i in range(60)] + \
              [{'cat': 'b', 'prompt': f'prompt b{i}'} for i in range(5)]

    def test_the_slice_is_stratified(self):
        prompts = [{'id': f'p{i:04d}', 'category': p['cat'],
                    'prompt': p['prompt']}
                   for i, p in enumerate(self.PROMPTS)]
        sampled, composition = he.draw_slice(prompts, size=20)
        self.assertEqual(len(sampled), 20)
        # The five-prompt category is not swamped by the sixty-prompt one.
        self.assertEqual(composition['b'], 5)

    def test_the_slice_is_reproducible(self):
        prompts = [{'id': f'p{i:04d}', 'category': p['cat'],
                    'prompt': p['prompt']}
                   for i, p in enumerate(self.PROMPTS)]
        a, _ = he.draw_slice(prompts, size=20)
        b, _ = he.draw_slice(prompts, size=20)
        self.assertEqual([r['id'] for r in a], [r['id'] for r in b])

    def test_the_sheet_round_trips(self):
        prompts = [{'id': 'p1', 'category': 'a', 'prompt': 'do a thing'}]
        with tempfile.TemporaryDirectory() as tmp:
            path = he.write_sheet(prompts, Path(tmp) / 'sheet.csv')
            rows = he.read_sheet(path)
        self.assertEqual(rows[0]['id'], 'p1')
        self.assertEqual(rows[0]['correct'], '')
        self.assertEqual(list(rows[0].keys()), list(he.COLUMNS))


class HumanScoreTest(unittest.TestCase):
    def _row(self, **kw):
        row = {c: '' for c in he.COLUMNS}
        row['id'] = kw.pop('id', 'p1')
        row.update(kw)
        return row

    def test_na_is_excluded_not_counted_as_a_pass(self):
        rows = [self._row(id='a', correct='yes', idiomatic='n/a',
                          complete='yes', safe='yes'),
                self._row(id='b', correct='no', idiomatic='n/a',
                          complete='yes', safe='yes', note='wrong total')]
        result = he.score_sheet(rows)
        self.assertEqual(result['axes']['idiomatic']['n'], 0)
        self.assertEqual(result['axes']['correct']['n'], 2)
        self.assertAlmostEqual(result['axes']['correct']['rate'], 0.5)

    def test_all_four_counts_na_as_satisfied(self):
        rows = [self._row(id='a', correct='yes', idiomatic='n/a',
                          complete='yes', safe='yes')]
        self.assertAlmostEqual(he.score_sheet(rows)['all_four']['rate'], 1.0)

    def test_a_hundred_rows_is_still_reported_as_underpowered_below_the_floor(self):
        rows = [self._row(id=f'p{i}', correct='yes') for i in range(50)]
        self.assertTrue(he.score_sheet(rows)['axes']['correct']['underpowered'])

    def test_an_unrated_row_is_a_problem(self):
        problems = he.validate_sheet([self._row(id='a')])
        self.assertTrue(any('not rated' in p for p in problems))

    def test_an_incorrect_verdict_needs_a_note(self):
        # The note is the only record of WHY, and "valid but wrong" is the
        # failure this slice exists to catch.
        problems = he.validate_sheet(
            [self._row(id='a', correct='no', idiomatic='yes',
                       complete='yes', safe='yes')])
        self.assertTrue(any('no note' in p for p in problems))

    def test_a_bad_verdict_word_is_a_problem(self):
        problems = he.validate_sheet(
            [self._row(id='a', correct='maybe')])
        self.assertTrue(any('expected yes, no or n/a' in p for p in problems))

    def test_a_clean_sheet_has_no_problems(self):
        rows = [self._row(id='a', correct='yes', idiomatic='yes',
                          complete='yes', safe='yes'),
                self._row(id='b', correct='no', idiomatic='yes',
                          complete='n/a', safe='yes', note='computed 41')]
        self.assertEqual(he.validate_sheet(rows), [])

    def test_comparing_two_releases(self):
        prev = [self._row(id=f'p{i}', correct='yes' if i < 20 else 'no',
                          note='x') for i in range(200)]
        curr = [self._row(id=f'p{i}', correct='yes' if i < 150 else 'no',
                          note='x') for i in range(200)]
        verdict, _ = he.compare_sheets(curr, prev)['correct']
        self.assertEqual(verdict, 'better')

    def test_a_small_difference_is_indistinguishable(self):
        prev = [self._row(id=f'p{i}', correct='yes' if i < 50 else 'no',
                          note='x') for i in range(100)]
        curr = [self._row(id=f'p{i}', correct='yes' if i < 53 else 'no',
                          note='x') for i in range(100)]
        verdict, _ = he.compare_sheets(curr, prev)['correct']
        self.assertEqual(verdict, 'indistinguishable')


class RubricTest(unittest.TestCase):
    RUBRIC = Path(__file__).resolve().parents[2] / 'eval' / 'human' / 'RUBRIC.md'

    def test_the_rubric_exists_and_names_every_axis(self):
        text = self.RUBRIC.read_text()
        for axis in he.AXES:
            self.assertIn(axis, text)



class DocQAGradingTest(unittest.TestCase):
    """`aro ask` has to answer questions about ARO, not only write programs.

    Graded against a rubric rather than a judge model: reproducible, needs no
    second model, and `must_not_include` is aimed at the failure that matters —
    the confident wrong answer (GitLab #794).
    """

    TASK = {
        'id': 'q-publish-scope',
        'grade_by': 'doc_qa',
        'job': 'question',
        'must_include': ['publish', 'business activity'],
        'must_not_include': ['visible everywhere'],
    }

    def test_an_answer_covering_every_point_passes(self):
        r = fe.grade(self.TASK, 'Use Publish; it reaches the same business activity.')
        self.assertTrue(r['passed'])

    def test_matching_is_case_insensitive(self):
        r = fe.grade(self.TASK, 'PUBLISH exports it to the Business Activity.')
        self.assertTrue(r['passed'], r['reason'])

    def test_a_missing_point_fails_and_says_which(self):
        r = fe.grade(self.TASK, 'Use Publish.')
        self.assertFalse(r['passed'])
        self.assertIn('business activity', r['reason'])

    def test_a_confidently_wrong_answer_fails(self):
        # The whole point of must_not_include: this one says everything the
        # rubric asks for and then contradicts it.
        r = fe.grade(self.TASK,
                     'Use Publish in the business activity; it is visible everywhere.')
        self.assertFalse(r['passed'])
        self.assertIn('wrong', r['reason'])

    def test_an_empty_answer_is_not_reported_as_missing_code(self):
        # "no ARO in the answer" is the wrong complaint for a prose question.
        r = fe.grade(self.TASK, '   ')
        self.assertFalse(r['passed'])
        self.assertEqual(r['reason'], 'said nothing')


class PerJobSummaryTest(unittest.TestCase):
    """A single pass rate hides which of the three jobs moved."""

    def test_summary_reports_each_job_separately(self):
        rows = [
            {'id': 'a', 'grade_by': 'execution_output', 'job': 'write', 'passed': True},
            {'id': 'b', 'grade_by': 'execution_output', 'job': 'write', 'passed': True},
            {'id': 'c', 'grade_by': 'execution_output', 'job': 'fix', 'passed': False},
            {'id': 'd', 'grade_by': 'doc_qa', 'job': 'question', 'passed': True},
        ]
        summary = fe.summarise(rows)
        self.assertEqual(set(summary['by_job']), {'write', 'fix', 'question'})
        # A model that writes perfectly and cannot fix anything must not look
        # like a 75% model and nothing else.
        self.assertEqual(summary['by_job']['write']['successes'], 2)
        self.assertEqual(summary['by_job']['fix']['successes'], 0)

    def test_a_row_without_a_job_counts_as_write(self):
        # Every task predating GitLab #794 is a "write a program" task.
        summary = fe.summarise([
            {'id': 'a', 'grade_by': 'execution_output', 'passed': True},
        ])
        self.assertIn('write', summary['by_job'])


class BenchmarkCoversAllThreeJobsTest(unittest.TestCase):
    """The shipped benchmark must actually exercise the three jobs."""

    def test_every_job_has_tasks(self):
        tasks = fe.load_tasks()
        jobs = {t.get('job', 'write') for t in tasks}
        self.assertEqual(jobs, {'write', 'fix', 'question'},
                         'the benchmark decides which base model we train on; '
                         'it has to score all three things aro ask does')

    def test_every_question_task_has_a_rubric_and_a_reference(self):
        for t in fe.load_tasks():
            if t.get('grade_by') == 'doc_qa':
                self.assertTrue(t.get('must_include'), t['id'])
                # The reference answer is what proves the rubric is satisfiable;
                # a typo in must_include would otherwise never pass and nobody
                # would notice.
                self.assertTrue(t.get('reference'), t['id'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
