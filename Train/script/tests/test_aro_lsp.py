"""Tests for aro_lsp.py — the action reference NB08 trains from.

The parsing and candidate-ordering logic runs without a binary. The live tests
talk to a real `aro lsp` and are skipped where there is none; they are the ones
that would catch the LSP changing shape under us, which is how NB08 broke in the
first place (it read a file that had been deleted).
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import aro_lsp  # noqa: E402
import aro_oracle  # noqa: E402

HAVE_ARO = aro_oracle.aro_bin() is not None


class TestDetailParsing(unittest.TestCase):
    """The role and description ride in the completion item's `detail`."""

    def test_role_and_description(self):
        self.assertEqual(aro_lsp._split_detail('[REQUEST] Pulls data in'),
                         ('request', 'Pulls data in'))

    def test_role_with_no_description(self):
        self.assertEqual(aro_lsp._split_detail('[OWN] '), ('own', ''))

    def test_no_role_at_all(self):
        self.assertEqual(aro_lsp._split_detail('just words'), ('', 'just words'))

    def test_empty(self):
        self.assertEqual(aro_lsp._split_detail(None), ('', ''))


class TestCandidateLines(unittest.TestCase):
    def test_the_signature_is_tried_first(self):
        candidates = aro_lsp._candidate_lines(
            'Extract', 'Extract the <id> from the <request: body>.', ['from'])
        self.assertEqual(candidates[0],
                         'Extract the <id> from the <request: body>.')

    def test_the_actions_own_prepositions_come_before_the_sweep(self):
        candidates = aro_lsp._candidate_lines('Accept', None, ['on'])
        self.assertEqual(candidates[0], 'Accept the <result> on the <source>.')
        self.assertIn('Accept the <result> from the <source>.', candidates)

    def test_no_signature_still_yields_candidates(self):
        self.assertTrue(aro_lsp._candidate_lines('Tag', None, []))

    def test_candidates_are_not_repeated(self):
        candidates = aro_lsp._candidate_lines('Store', None, ['to', 'to'])
        self.assertEqual(len(candidates), len(set(candidates)))


@unittest.skipUnless(HAVE_ARO, 'no `aro` binary')
class TestAgainstTheLiveServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with aro_lsp.AROLanguageServer() as server:
            cls.menu = aro_lsp.verb_menu(server)
            cls.extract_signature = aro_lsp.signature_for(server, 'Extract')

    def test_the_server_offers_the_core_verbs(self):
        verbs = {v.lower() for v in self.menu}
        for verb in ('extract', 'retrieve', 'compute', 'return', 'store', 'log'):
            self.assertIn(verb, verbs)

    def test_every_verb_carries_a_role(self):
        roleless = [v for v, meta in self.menu.items() if not meta['role']]
        self.assertEqual(roleless, [])

    def test_keywords_and_snippets_are_not_mistaken_for_verbs(self):
        """`when`, `for each` and the snippets share the completion list."""
        verbs = {v.lower() for v in self.menu}
        for not_a_verb in ('for each', 'while', 'break', 'feature set',
                           'http handler'):
            self.assertNotIn(not_a_verb, verbs)

    def test_signature_help_answers_for_a_verb_it_knows(self):
        self.assertIsNotNone(self.extract_signature)
        self.assertTrue(self.extract_signature.startswith('Extract'))


@unittest.skipUnless(HAVE_ARO, 'no `aro` binary')
class TestTheReference(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.actions, cls.stats = aro_lsp.action_reference()

    def test_every_example_line_parses(self):
        """The point of the exercise: a signature is written to be read, and
        seven of the server's own do not compile."""
        for action in self.actions:
            valid, output = aro_oracle.check_block(action['example_line'])
            self.assertTrue(valid, f'{action["verb"]}: {action["example_line"]}'
                                   f'\n{output}')

    def test_it_covers_the_action_vocabulary(self):
        # 71 actions are registered; `publish` is a statement form that cannot
        # stand alone, so the floor is generous rather than exact.
        self.assertGreaterEqual(len(self.actions), 60)

    def test_the_shape_nb08_consumes(self):
        for action in self.actions:
            self.assertEqual(action['verb'], action['verb'].lower())
            self.assertTrue(action['role'].isupper())
            self.assertTrue(action['example_line'].endswith(('.', '}')))

    def test_one_entry_per_action_not_per_alias(self):
        """`build`/`construct`/`create` are one action; so are `exec`/`run`."""
        verbs = [a['verb'] for a in self.actions]
        self.assertEqual(len(verbs), len(set(verbs)))
        self.assertLess(len(verbs), len(self.stats['all_verbs']))

    def test_all_verbs_includes_the_aliases(self):
        for alias in ('build', 'calculate', 'invoke', 'run'):
            self.assertIn(alias, self.stats['all_verbs'])

    def test_it_does_not_claim_http_methods_are_verbs(self):
        """The hand-written set this replaced taught `put` and `post`."""
        for not_a_verb in ('put', 'post'):
            self.assertNotIn(not_a_verb, self.stats['all_verbs'])


class TestTimeout(unittest.TestCase):
    def test_a_silent_server_raises_instead_of_hanging(self):
        server = aro_lsp.AROLanguageServer.__new__(aro_lsp.AROLanguageServer)
        server.binary = '/bin/true'
        server.timeout = 0.05
        server._replies = aro_lsp.queue.Queue()
        server._next_id = 0

        class Stdin:
            def write(self, _b): pass
            def flush(self): pass

        server._proc = type('P', (), {'stdin': Stdin()})()
        with self.assertRaises(aro_lsp.LanguageServerError):
            server.request('initialize', {})


if __name__ == '__main__':
    unittest.main()
