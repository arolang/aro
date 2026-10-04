"""The held-out benchmark's own guards (GitLab #785).

Most of this file is one claim, tested five ways: **the benchmark is never
mined**. That claim was previously made about `eval_prompts.json` and the
4,000-prompt evaluation by nobody in particular, and it turned out to be false
— 2,679 of those answers became training pairs. A promise in a README is not a
property of a repository, so:

  * `test_marker_and_naming_are_both_in_place` — the two mechanisms exist.
  * `test_corpus_enumeration_excludes_the_benchmark` — the one enumerator
    every leakage check goes through skips it.
  * `test_assert_mineable_refuses_a_benchmark_path` — pipeline code that names
    its inputs by hand is stopped rather than warned.
  * `test_no_benchmark_prompt_appears_in_any_corpus_file` — the measurement
    itself, at the 0.85 the issue names, against every corpus file including
    the eval-derived and material sets. This is the test that fails if somebody
    ever trains on the benchmark.
  * `test_corpus_enumeration_covers_what_it_must` — because a leakage check
    that quietly stopped reading `ask_eval_pairs.jsonl` would pass forever.

Everything here is stdlib-only, so `train:unit` (python:3.12-slim, no
toolchain) runs it. The one test that needs a real `aro` carries the usual
`skipif(aro_oracle.aro_bin() is None)`, which conftest tags `needs_binary` for
`train:oracle`.
"""
import hashlib
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import pytest  # noqa: E402

import aro_oracle  # noqa: E402
import held_out_benchmark as hob  # noqa: E402
import leakage  # noqa: E402

# The shared spelling: conftest reads this exact reason off the skipif marker
# and tags the test `needs_binary`, which is how `train:oracle` selects it.
# `unittest.skipIf` would skip identically and be invisible to that hook, so
# the whole class would sit deselected in the one job that has a binary — the
# failure GitLab #900 was about.
needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

BENCH = hob.load_benchmark()
MANIFEST = hob.load_manifest()
PROMPTS = BENCH['prompts']

# The floor GitLab #785 names. Not the number of prompts that happen to be
# here — the number below which the benchmark stops being the thing that was
# asked for.
MIN_PROMPTS = 300


class TestFrozen(unittest.TestCase):
    """The set cannot move without saying so."""

    def test_verify_frozen_reports_no_problems(self):
        problems = hob.verify_frozen(BENCH, MANIFEST)
        self.assertEqual(problems, [],
                         'verify_frozen: ' + '; '.join(problems))

    def test_digest_matches_the_bytes_on_disk(self):
        actual = hashlib.sha256(hob.PROMPTS_FILE.read_bytes()).hexdigest()
        self.assertEqual(
            MANIFEST['prompts_sha256'], actual,
            'the frozen prompts changed without a version bump — that is a '
            'new benchmark, not an edit (GitLab #785)')

    def test_manifest_records_which_binary_built_it(self):
        # The repair prompts carry diagnostics the binary printed, so "which
        # aro" is part of what the benchmark IS, not metadata about it.
        self.assertTrue(MANIFEST.get('built_with_aro'))
        self.assertTrue(MANIFEST.get('version'))
        self.assertTrue(MANIFEST.get('frozen_at'))


class TestComposition(unittest.TestCase):

    def test_at_least_three_hundred_prompts(self):
        self.assertGreaterEqual(len(PROMPTS), MIN_PROMPTS)

    def test_every_stratum_is_present_and_not_a_token_gesture(self):
        counts = hob.strata_counts(PROMPTS)
        self.assertEqual(set(counts), set(hob.STRATA))
        for stratum, n in counts.items():
            # A stratum of three prompts has a resolution of 33 percentage
            # points; it would report noise and look like a measurement.
            self.assertGreaterEqual(n, 20, f'{stratum} is too thin to report')

    def test_ids_are_unique(self):
        ids = [p['id'] for p in PROMPTS]
        self.assertEqual(len(ids), len(set(ids)))

    def test_all_three_reported_axes_are_actually_reachable(self):
        # GitLab #785 asks for pass@k by `aro check`, execution pass by
        # `aro run`, and `aro test` pass. A benchmark where no task carries an
        # expected output would report the third as a dash forever.
        grades = {p['grade_by'] for p in PROMPTS}
        self.assertIn('aro_check', grades)
        self.assertIn('execution_output', grades)
        self.assertIn('aro_test', grades)
        self.assertIn('doc_qa', grades)

    def test_the_weak_domains_are_covered(self):
        # Conditionals 0 %, Throw 2 %, publish 3 %, configuration 7 %,
        # REST 19 % in the 4,000-prompt run (GitLab #797). Measuring a model
        # where the corpus is thickest is how a weakness stays invisible.
        domains = {p.get('domain') for p in PROMPTS}
        for weak in hob.WEAK_DOMAINS:
            self.assertIn(weak, domains, f'no prompts tagged {weak}')

    def test_every_code_task_ships_a_reference(self):
        # Not for scoring — `aro check`/`aro run`/`aro test` are the judges —
        # but so that `--reference` can prove the task is satisfiable. A task
        # nobody can pass is a benchmark measuring itself.
        missing = [p['id'] for p in PROMPTS if not p.get('reference')]
        self.assertEqual(missing, [])

    def test_execution_tasks_declare_an_expected_output(self):
        for p in PROMPTS:
            if p['grade_by'] == 'execution_output':
                self.assertTrue(p.get('expected_output') is not None
                                or p.get('expected_output') == '',
                                f'{p["id"]} has no expected output')

    def test_doc_qa_rubrics_are_satisfied_by_their_own_reference(self):
        # The rubric is crude by design; this is the check that it is not
        # *wrong*. A must_include phrase the correct answer does not contain
        # would mark every model down for being right.
        for p in PROMPTS:
            if p['grade_by'] != 'doc_qa':
                continue
            with self.subTest(p['id']):
                self.assertTrue(hob._rubric(p, p['reference']),
                                f'{p["id"]} fails its own rubric')

    def test_contract_first_tasks_do_not_hand_over_the_contract(self):
        # Producing the openapi.yaml is the task for a contract-first row, so
        # it lives in reference_files (read only by --reference) and must not
        # appear in `files`, which the grader puts in the directory.
        for p in PROMPTS:
            if p['stratum'] != 'nl_application':
                continue
            self.assertNotIn('openapi.yaml', p.get('files') or {},
                             f'{p["id"]} gives the model its own answer')


class TestNeverMined(unittest.TestCase):
    """The mechanism, not the promise."""

    def test_marker_and_naming_are_both_in_place(self):
        marker = hob.BENCHMARK_DIR / leakage.NEVER_MINE_MARKER
        self.assertTrue(marker.exists(), f'{marker} is missing')
        self.assertIn(leakage.BENCHMARK_NAME_INFIX, hob.PROMPTS_FILE.name)

    def test_both_mechanisms_work_on_their_own(self):
        root = leakage.train_root()
        self.assertTrue(leakage.is_never_mined(hob.PROMPTS_FILE, root))
        # The naming convention alone, for a file carried out of the directory.
        with tempfile.TemporaryDirectory() as tmp:
            stray = Path(tmp) / 'copied.benchmark.json'
            stray.write_text('{}')
            self.assertTrue(leakage.is_never_mined(stray, root))
        # The marker alone, for a file in a marked directory without the name.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / leakage.NEVER_MINE_MARKER).write_text('')
            plain = d / 'prompts.json'
            plain.write_text('{}')
            self.assertTrue(leakage.is_never_mined(plain, root))

    def test_corpus_enumeration_excludes_the_benchmark(self):
        files = {str(p) for p in leakage.corpus_files()}
        self.assertNotIn(str(hob.PROMPTS_FILE), files)
        self.assertNotIn(str(hob.MANIFEST_FILE), files)
        for path in files:
            self.assertNotIn('eval/benchmark', path)

    def test_the_marker_is_reported(self):
        marked = {p.name for p in leakage.never_mined_roots()}
        self.assertIn('benchmark', marked)

    def test_assert_mineable_refuses_a_benchmark_path(self):
        with self.assertRaises(ValueError):
            leakage.assert_mineable([hob.PROMPTS_FILE])
        # And passes everything else through unchanged.
        ordinary = leakage.corpus_files()[:3]
        self.assertEqual(leakage.assert_mineable(ordinary), ordinary)


class TestCorpusEnumeration(unittest.TestCase):

    def test_corpus_enumeration_covers_what_it_must(self):
        # The sets #785 names explicitly. A loader that silently stopped
        # reading these would report zero leakage forever, which is the shape
        # of the bug being fixed.
        labels = set(leakage.corpus_instructions())
        for required in ('eval_derived/ask_eval_pairs.jsonl',
                         'eval_derived/generators/errorfix.jsonl',
                         'eval_derived/probefill.jsonl',
                         'Material/curated.jsonl',
                         'Material/canonical.json',
                         'Material/prompts.txt',
                         'eval_prompts.json'):
            self.assertIn(required, labels, f'{required} is not enumerated')

    def test_instructions_are_read_out_of_every_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'flat.jsonl').write_text(
                json.dumps({'instruction': 'alpha'}) + '\n'
                + json.dumps({'prompt': 'beta'}) + '\n')
            (d / 'chat.jsonl').write_text(json.dumps({'messages': [
                {'role': 'system', 'content': 'sys'},
                {'role': 'user', 'content': 'gamma'},
                {'role': 'assistant', 'content': 'out'}]}) + '\n')
            (d / 'dpo.jsonl').write_text(json.dumps(
                {'prompt': 'delta', 'chosen': 'a', 'rejected': 'b'}) + '\n')
            (d / 'listed.json').write_text(json.dumps(
                [{'cat': 'x', 'prompt': 'epsilon'}]))
            (d / 'enveloped.json').write_text(json.dumps(
                {'cases': [{'instruction': 'zeta'}]}))
            (d / 'keyed.json').write_text(json.dumps(
                {'_doc': 'meta', 'eta': 'the answer'}))
            (d / 'lines.txt').write_text('theta\niota\n')
            found = set()
            for path in sorted(d.iterdir()):
                found.update(leakage.instructions_in_file(path))
        self.assertEqual(found, {'alpha', 'beta', 'gamma', 'delta', 'epsilon',
                                 'zeta', 'eta', 'theta', 'iota'})

    def test_a_corpus_file_with_no_instructions_is_simply_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / 'nothing.json'
            empty.write_text('{"unrelated": 1}')
            self.assertEqual(leakage.instructions_in_file(empty), [])


class TestNearDuplicateIndex(unittest.TestCase):
    """The filter has to lose nothing at the threshold."""

    def test_index_agrees_with_the_naive_scan_at_the_threshold(self):
        rng = random.Random(20260785)
        words = ['lock', 'kiln', 'hive', 'ferry', 'stake', 'bale', 'depot',
                 'tram', 'route', 'clamp', 'wheel', 'berth', 'plot']
        corpus = [' '.join(rng.choice(words) for _ in range(rng.randint(4, 12)))
                  for _ in range(400)]
        # Half the probes are perturbations of corpus entries, so some of them
        # genuinely clear 0.85; a test where nothing matches proves nothing.
        probes = [corpus[i][: -2] + ' ' + rng.choice(words)
                  for i in range(0, 200)]
        probes += [' '.join(rng.choice(words) for _ in range(6))
                   for _ in range(100)]

        index = leakage.NearDuplicateIndex(threshold=0.85)
        index.add_all(corpus, label='corpus')
        corpus_grams = [leakage.char_ngrams(c) for c in corpus]

        hits = 0
        for probe in probes:
            pg = leakage.char_ngrams(probe)
            naive = {c for c, cg in zip(corpus, corpus_grams)
                     if leakage.jaccard(pg, cg) >= 0.85}
            indexed = {text for _s, _l, text in index.matches(probe)}
            self.assertEqual(indexed, naive, f'disagreement on {probe!r}')
            hits += len(naive)
        self.assertGreater(hits, 0, 'the fixture found no near duplicates, '
                                    'so agreement proves nothing')

    def test_identical_text_is_a_match(self):
        index = leakage.NearDuplicateIndex(threshold=0.85)
        index.add('write the tests for a weighbridge net weight rule',
                  label='c')
        hits = index.matches('write the tests for a weighbridge net weight rule')
        self.assertEqual(len(hits), 1)
        self.assertAlmostEqual(hits[0][0], 1.0)

    def test_unrelated_text_is_not(self):
        index = leakage.NearDuplicateIndex(threshold=0.85)
        index.add('aaaaaaaaaaaaaaaaaaaa', label='c')
        self.assertEqual(index.matches('zzzzzzzzzzzzzzzzzzzz'), [])

    def test_empty_text_is_handled(self):
        index = leakage.NearDuplicateIndex(threshold=0.85)
        index.add('', label='c')
        self.assertEqual(len(index), 0)
        self.assertEqual(index.matches(''), [])
        self.assertIsNone(index.closest(''))


class TestLeakageGate(unittest.TestCase):
    """The measurement #785 asks for."""

    @classmethod
    def setUpClass(cls):
        cls.report = leakage.benchmark_leakage(PROMPTS)

    def test_no_benchmark_prompt_appears_in_any_corpus_file(self):
        self.assertEqual(
            self.report['exact'], 0,
            'a benchmark prompt appears verbatim in a corpus file: '
            + json.dumps(self.report['violations'][:3], indent=1))
        self.assertEqual(
            self.report['near'], 0,
            'a benchmark prompt is a character-3-gram near-duplicate '
            f'(>= {leakage.BENCHMARK_SIM_THRESHOLD}) of a corpus '
            'instruction: '
            + json.dumps(self.report['violations'][:3], indent=1))

    def test_the_gate_is_measured_against_a_real_corpus(self):
        # A gate that passes because it read nothing is the failure mode this
        # whole issue is about, one layer up.
        self.assertGreater(self.report['n_corpus_instructions'], 20000)
        self.assertGreater(self.report['n_corpus_files'], 200)

    def test_the_threshold_is_the_one_the_issue_names(self):
        self.assertEqual(leakage.BENCHMARK_SIM_THRESHOLD, 0.85)
        self.assertEqual(self.report['threshold'], 0.85)

    def test_the_manifest_records_the_same_measurement(self):
        recorded = MANIFEST['leakage']
        self.assertEqual(recorded['threshold'], 0.85)
        self.assertEqual(recorded['exact_collisions'], 0)
        self.assertEqual(recorded['near_duplicates'], 0)

    def test_the_gate_would_notice_a_leak(self):
        # Prove the gate can fail, by asking it about a prompt lifted out of
        # the corpus. A gate nobody has seen refuse is a gate nobody should
        # trust — the fixed-floor release gate (GitLab #796) was exactly that.
        instructions = leakage.corpus_instructions()
        lifted = next(t for texts in instructions.values() for t in texts
                      if len(t) > 60)
        report = leakage.benchmark_leakage(
            [{'id': 'planted', 'prompt': lifted}], instructions=instructions)
        self.assertGreater(report['leaked'], 0)


class TestScoring(unittest.TestCase):
    """The reporting harness, proved against a stub rather than a model."""

    def _tasks(self, n=6, grade='aro_check'):
        return [{'id': f't{i}', 'stratum': 'repl', 'domain': 'numbers',
                 'grade_by': grade, 'prompt': 'p'} for i in range(n)]

    def test_axis_rate_and_pass_at_one(self):
        tasks = self._tasks(4)
        gens = {'t0': ['a'], 't1': ['a'], 't2': ['a'], 't3': ['a']}
        oracle = hob.ReplayOracle({
            't0': {'check': True}, 't1': {'check': True},
            't2': {'check': False}, 't3': {'check': False}})
        summary, rows = hob.score(tasks, gens, oracle=oracle)
        self.assertEqual(len(rows), 4)
        self.assertEqual(summary['overall']['check']['successes'], 2)
        self.assertEqual(summary['overall']['check']['n'], 4)
        self.assertAlmostEqual(summary['overall']['check_pass_at_1'], 0.5)

    def test_pass_at_five_needs_five_samples(self):
        tasks = self._tasks(2)
        one = {'t0': ['a'], 't1': ['a']}
        oracle = hob.ReplayOracle({'t0': {'check': True},
                                   't1': {'check': False}})
        summary, _ = hob.score(tasks, one, oracle=oracle)
        self.assertIsNone(summary['overall']['check_pass_at_5'],
                          'pass@5 off one sample is not a smaller pass@5, it '
                          'is not a pass@5')

        five = {'t0': ['a'] * 5, 't1': ['a'] * 5}
        summary, _ = hob.score(tasks, five, oracle=oracle)
        self.assertAlmostEqual(summary['overall']['check_pass_at_5'], 0.5)

    def test_pass_at_five_rewards_one_success_in_five(self):
        tasks = self._tasks(1)
        gens = {'t0': ['good', 'bad', 'bad', 'bad', 'bad']}
        oracle = hob.ReplayOracle({('t0', 'good'): {'check': True},
                                   ('t0', 'bad'): {'check': False}})
        summary, _ = hob.score(tasks, gens, oracle=oracle)
        self.assertAlmostEqual(summary['overall']['check_pass_at_1'], 0.2)
        self.assertAlmostEqual(summary['overall']['check_pass_at_5'], 1.0)

    def test_an_unanswered_task_is_a_miss_not_a_skip(self):
        tasks = self._tasks(2)
        oracle = hob.ReplayOracle({'t0': {'check': True}})
        summary, rows = hob.score(tasks, {'t0': ['a']}, oracle=oracle)
        self.assertEqual(summary['overall']['check']['n'], 2)
        self.assertEqual(summary['overall']['check']['successes'], 1)
        silent = next(r for r in rows if r['id'] == 't1')
        self.assertIs(silent['check'], False)
        self.assertEqual(silent['reason'], 'no answer offered')

    def test_an_unjudgeable_generation_is_never_a_pass(self):
        # NB21 counted a missing binary as a pass. None on every axis has to
        # stay out of the numerator AND out of the denominator, and be
        # reported as unreachable.
        tasks = self._tasks(1)
        oracle = hob.ReplayOracle({}, default={a: None for a in hob.AXES})
        summary, _ = hob.score(tasks, {'t0': ['a']}, oracle=oracle)
        self.assertIsNone(summary['overall']['check'])
        self.assertEqual(summary['overall']['unreachable'], 1)

    def test_axes_are_reported_separately(self):
        tasks = [{'id': 'c', 'stratum': 'repl', 'grade_by': 'aro_check',
                  'prompt': 'p'},
                 {'id': 'r', 'stratum': 'repl', 'grade_by': 'execution_output',
                  'prompt': 'p'},
                 {'id': 't', 'stratum': 'tests', 'grade_by': 'aro_test',
                  'prompt': 'p'}]
        oracle = hob.ReplayOracle({
            'c': {'check': True},
            'r': {'check': True, 'run': False},
            't': {'check': True, 'test': True}})
        summary, _ = hob.score(tasks, {'c': ['a'], 'r': ['a'], 't': ['a']},
                               oracle=oracle)
        self.assertEqual(summary['overall']['check']['successes'], 3)
        self.assertEqual(summary['overall']['run']['successes'], 0)
        self.assertEqual(summary['overall']['test']['successes'], 1)
        # The strongest available axis is what a headline should quote: the
        # run task failed, so it must not read as a pass.
        self.assertEqual(summary['overall']['strongest']['successes'], 2)

    def test_per_stratum_and_per_domain_blocks_exist(self):
        tasks = [{'id': 'a', 'stratum': 'repl', 'domain': 'throw',
                  'grade_by': 'aro_check', 'prompt': 'p'},
                 {'id': 'b', 'stratum': 'tests', 'domain': 'rest',
                  'grade_by': 'aro_check', 'prompt': 'p'}]
        oracle = hob.ReplayOracle({'a': {'check': True},
                                   'b': {'check': False}})
        summary, _ = hob.score(tasks, {'a': ['x'], 'b': ['x']}, oracle=oracle)
        self.assertEqual(set(summary['by_stratum']), {'repl', 'tests'})
        self.assertEqual(set(summary['by_domain']), {'throw', 'rest'})
        self.assertEqual(summary['by_stratum']['repl']['check']['rate'], 1.0)
        self.assertEqual(summary['by_stratum']['tests']['check']['rate'], 0.0)

    def test_the_stub_set_discriminates(self):
        # `--stub` is the harness's proof of life with no model and no binary:
        # a third right, a third wrong, a third silent.
        gens, verdicts = hob.stub_generations(PROMPTS)
        summary, rows = hob.score(PROMPTS, gens,
                                  oracle=hob.ReplayOracle(verdicts))
        self.assertEqual(len(rows), len(PROMPTS))
        rate = summary['overall']['strongest']['rate']
        self.assertGreater(rate, 0.25)
        self.assertLess(rate, 0.45)

    def test_generations_are_read_from_both_file_shapes(self):
        with tempfile.TemporaryDirectory() as tmp:
            one = Path(tmp) / 'g.jsonl'
            one.write_text(json.dumps({'id': 'a', 'output': 'x'}) + '\n'
                           + json.dumps({'id': 'a', 'output': 'y'}) + '\n'
                           + json.dumps({'id': 'b', 'outputs': ['p', 'q']})
                           + '\n')
            loaded = hob.load_generations(one)
        self.assertEqual(loaded, {'a': ['x', 'y'], 'b': ['p', 'q']})

    def test_rubric_rejects_the_confident_wrong_answer(self):
        task = {'id': 'x', 'grade_by': 'doc_qa',
                'must_include': ['business activity'],
                'must_not_include': ['visible across the whole application']}
        self.assertTrue(hob._rubric(
            task, 'It reaches the same business activity.'))
        self.assertFalse(hob._rubric(
            task, 'It is visible across the whole application.'))
        self.assertFalse(hob._rubric(task, ''))

    def test_bare_statements_are_wrapped_before_they_are_run(self):
        task = {'id': 'x', 'wrap': True}
        wrapped = hob._runnable(task, 'Log "hi" to the <console>.')
        self.assertIn('Application-Start', wrapped)
        self.assertIn('Log "hi" to the <console>.', wrapped)
        # An answer that already brought its own feature set is left alone.
        own = '(Application-Start: X) {\n    Return an <OK: status> for '
        own += 'the <startup>.\n}\n'
        self.assertEqual(hob._runnable(task, own), own)
        self.assertEqual(hob._runnable({'id': 'y'}, 'Log "hi".'), 'Log "hi".')


@needs_binary
class TestAgainstTheBinary(unittest.TestCase):
    """What the benchmark claims about itself, asked of the toolchain.

    A benchmark whose own reference answers do not pass is measuring the
    benchmark, not the model — and every reference here was authored against
    the binary precisely so this can be asserted rather than hoped.
    """

    def test_every_reference_answer_passes(self):
        oracle = hob.BinaryOracle()
        gens = hob.reference_generations(PROMPTS)
        self.assertEqual(len(gens), len(PROMPTS))
        _summary, rows = hob.score(PROMPTS, gens, oracle=oracle)
        failed = [(r['id'], r.get('reason', '')[:160]) for r in rows
                  if any(r.get(a) is False for a in hob.AXES)]
        self.assertEqual(failed, [], 'reference answers that do not pass: '
                                     + json.dumps(failed, indent=1))

    def test_an_invented_verb_fails_the_check_axis(self):
        # The other half of the proof: the oracle has to be able to say no.
        #
        # The trailing period matters and is not pedantry — `aro check
        # --syntax` accepts `Grab the <x> from the <nowhere>` (no period)
        # without a word, and rejects the same line with one as "'Grab' is not
        # a verb of any action". An unterminated statement appears to parse as
        # nothing at all. Measured on the binary this benchmark was frozen on,
        # and it is one reason the repl stratum is graded on execution as well
        # as on parsing.
        oracle = hob.BinaryOracle()
        broken = '```aro\nGrab the <x> from the <nowhere>.\n```'
        for stratum in ('repl', 'nl_application'):
            task = next(p for p in PROMPTS if p['stratum'] == stratum)
            with self.subTest(stratum):
                row = oracle.judge(task, broken)
                self.assertIs(row['check'], False, row.get('reason'))

    def test_a_right_looking_wrong_answer_fails_the_execution_axis(self):
        # The failure `aro check` cannot see, and the reason the run axis
        # exists: a program that parses, runs, and answers something else.
        oracle = hob.BinaryOracle()
        task = next(p for p in PROMPTS if p['stratum'] == 'repl'
                    and p.get('expected_output'))
        row = oracle.judge(task, '```aro\nLog "not the answer" to the '
                                 '<console>.\n```')
        self.assertIs(row['check'], True, row.get('reason'))
        self.assertIs(row['run'], False, row.get('reason'))

    def test_a_test_asserting_the_wrong_value_fails(self):
        oracle = hob.BinaryOracle()
        task = next(p for p in PROMPTS if p['id'] == 'tests-001')
        row = oracle.judge(task, '```aro\n(wrong: Pricing Test) {\n'
                                 '    Given the <subtotal> with 200.\n'
                                 '    Compute the <discount> from '
                                 '<subtotal> * 0.1.\n'
                                 '    Then the <discount> with 999.\n}\n```')
        self.assertIs(row['check'], True, row.get('reason'))
        self.assertIs(row['test'], False, row.get('reason'))

    def test_a_test_answer_without_a_test_activity_is_not_a_pass(self):
        # `aro test` exits 0 when it finds nothing to run, so "I wrote no
        # tests" must not score as "my tests passed".
        oracle = hob.BinaryOracle()
        task = next(p for p in PROMPTS if p.get('answer_role') == 'test')
        answer = ('```aro\n(not-a-test: Pricing) {\n'
                  '    Given the <a> with 1.\n'
                  '    Then the <a> with 1.\n}\n```')
        row = oracle.judge(task, answer)
        self.assertIs(row['test'], False, row.get('reason'))


if __name__ == '__main__':
    unittest.main()
