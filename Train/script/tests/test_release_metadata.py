"""Tests for the released model's ARO provenance (GitLab #807).

The manifest's job is to let someone holding the artefact answer "which ARO is
this model for?". These tests pin the two halves of that: the derivation of
`min_cli_version` from the repository rather than from imagination, and the
hashes that let a CLI notice the language moved underneath the model.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import release_metadata as rm  # noqa: E402


class FakeGit:
    """A git that answers from a table instead of a repository.

    `introduced` maps a searched string to the commit that introduced it;
    `contained` maps a commit to the tags containing it.
    """

    def __init__(self, tags, introduced, contained, head='deadbeef',
                 describe='0.12.1-15-gabcdef'):
        self.tags = tags
        self.introduced = introduced
        self.contained = contained
        self.head = head
        self.describe = describe
        self.calls = []

    def __call__(self, args, cwd=None):
        self.calls.append(args)
        if 'rev-parse' in args:
            return self.head + '\n'
        if 'describe' in args:
            return self.describe + '\n'
        if args[3:5] == ['tag', '--contains']:
            return '\n'.join(self.contained.get(args[5], [])) + '\n'
        if 'tag' in args and '--list' in args:
            return '\n'.join(self.tags) + '\n'
        if 'log' in args:
            needle = args[args.index('-S') + 1]
            commit = self.introduced.get(needle)
            return (commit + '\n') if commit else ''
        return ''


REAL_TAGS = ['0.10.0', '0.10.1', '0.11.0', '0.11.3', '0.11.6', '0.12.0', '0.12.1',
             # noise the derivation has to ignore
             'v0.1.0-beta.4', 'v0.2.2-beta.10', 'intellij-v1.4.2', '4.StaticFiles']


def repo_like_the_real_one():
    """The shape the ARO-Lang repository actually has: every `aro ask` tool
    landed in one commit that first appears in 0.10.0, and the default model id
    became the 6-bit build later, in 0.11.3."""
    introduced = {f'name: "{t}"': 'ask0001' for t in rm.ASK_TOOLS}
    introduced['ARO-Lang/aro-coder-6bit'] = 'rename01'
    contained = {
        'ask0001': ['0.10.0', '0.10.1', '0.11.0', '0.11.3', '0.11.6', '0.12.0', '0.12.1'],
        'rename01': ['0.11.3', '0.11.6', '0.12.0', '0.12.1'],
    }
    return FakeGit(REAL_TAGS, introduced, contained)


class TestMinCliVersion(unittest.TestCase):
    def test_it_is_the_later_of_the_two_constraints(self):
        git = repo_like_the_real_one()
        version, basis = rm.derive_min_cli_version('ARO-Lang/aro-coder-6bit', run=git)
        self.assertEqual(version, '0.11.3')
        self.assertEqual(basis['tool_vocabulary'], '0.10.0')
        self.assertEqual(basis['default_model_id'], '0.11.3')
        self.assertEqual(basis['tools_located'], len(rm.ASK_TOOLS))

    def test_a_tool_that_shipped_later_raises_the_floor(self):
        git = repo_like_the_real_one()
        git.introduced['name: "aro_build"'] = 'late0001'
        git.contained['late0001'] = ['0.12.0', '0.12.1']
        version, basis = rm.derive_min_cli_version('ARO-Lang/aro-coder-6bit', run=git)
        self.assertEqual(basis['tool_vocabulary'], '0.12.0')
        self.assertEqual(version, '0.12.0')

    def test_pre_release_and_non_version_tags_are_not_cli_releases(self):
        git = repo_like_the_real_one()
        self.assertEqual(rm.semver_tags(run=git),
                         ['0.10.0', '0.10.1', '0.11.0', '0.11.3', '0.11.6',
                          '0.12.0', '0.12.1'])

    def test_an_unanswerable_repository_yields_null_not_a_guess(self):
        git = FakeGit([], {}, {})
        version, basis = rm.derive_min_cli_version('ARO-Lang/aro-coder-6bit', run=git)
        self.assertIsNone(version)
        manifest = rm.build_manifest(
            model_id='ARO-Lang/aro-coder-6bit', source_label='x', base_model='b',
            quantization='6-bit', checksum='c', size_bytes=1, built_at='t',
            system_prompt='p', run=git)
        self.assertIsNone(manifest['min_cli_version'])
        self.assertIn('rather than guessed',
                      manifest['min_cli_version_basis']['reason'])

    def test_the_old_manifest_value_is_not_a_version_this_project_has(self):
        # The shipped manifest said 1.0.0. Whatever the right answer is, it is
        # not a release that exists: the derivation can only return a tag.
        git = repo_like_the_real_one()
        version, _ = rm.derive_min_cli_version('ARO-Lang/aro-coder-6bit', run=git)
        self.assertIn(version, rm.semver_tags(run=git))
        self.assertNotEqual(version, '1.0.0')


class TestManifest(unittest.TestCase):
    def manifest(self, **kw):
        git = kw.pop('run', None) or repo_like_the_real_one()
        base = dict(model_id='ARO-Lang/aro-coder-6bit', source_label='conversation_boosted',
                    base_model='mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16',
                    quantization='6-bit', checksum='45a5680524fdfc49',
                    size_bytes=7178922017, built_at='2026-08-10T07:15:45+00:00',
                    system_prompt='You are an expert ARO coding assistant.')
        base.update(kw)
        return rm.build_manifest(run=git, **base)

    def test_it_records_the_language_the_model_was_trained_for(self):
        m = self.manifest()
        for key in ('aro_version', 'aro_commit', 'catalog_hash', 'corpus_hash',
                    'system_prompt_hash', 'min_cli_version',
                    'min_cli_version_basis', 'manifest_schema'):
            self.assertIn(key, m)
        self.assertEqual(m['aro_version'], '0.12.1-15-gabcdef')
        self.assertEqual(m['aro_commit'], 'deadbeef')
        self.assertEqual(m['min_cli_version'], '0.11.3')

    def test_it_keeps_every_key_the_old_manifest_had(self):
        # The CLI reads this file; dropping a field it looks for would be a
        # different bug from the one being fixed.
        old_keys = {'model_id', 'source_label', 'base_model', 'quantization',
                    'checksum', 'size_bytes', 'built_at', 'cli_command',
                    'min_cli_version'}
        self.assertLessEqual(old_keys, set(self.manifest()))

    def test_it_serialises(self):
        json.loads(json.dumps(self.manifest()))

    def test_the_prompt_hash_tracks_the_prompt(self):
        a = self.manifest(system_prompt='one')
        b = self.manifest(system_prompt='two')
        self.assertNotEqual(a['system_prompt_hash'], b['system_prompt_hash'])


class TestHashes(unittest.TestCase):
    ACTIONS = {'log': {'role': 'export', 'prepositions': ['to'], 'verbs': ['Log'],
                       'description': 'writes a line'}}
    QUALS = {'length': {'builtin': True}, 'trim': {'builtin': True}}

    def test_catalog_hash_is_stable_under_reordering(self):
        a = rm.catalog_hash(self.ACTIONS, self.QUALS)
        b = rm.catalog_hash(dict(self.ACTIONS),
                            {'trim': {'builtin': True}, 'length': {'builtin': True}})
        self.assertEqual(a, b)

    def test_catalog_hash_ignores_documentation_churn(self):
        edited = {'log': dict(self.ACTIONS['log'], description='writes a line to a sink')}
        self.assertEqual(rm.catalog_hash(self.ACTIONS, self.QUALS),
                         rm.catalog_hash(edited, self.QUALS))

    def test_catalog_hash_changes_when_a_qualifier_appears(self):
        more = dict(self.QUALS, **{'sha256': {'builtin': True}})
        self.assertNotEqual(rm.catalog_hash(self.ACTIONS, self.QUALS),
                            rm.catalog_hash(self.ACTIONS, more))

    def test_catalog_hash_changes_when_a_preposition_changes(self):
        moved = {'log': dict(self.ACTIONS['log'], prepositions=['to', 'with'])}
        self.assertNotEqual(rm.catalog_hash(self.ACTIONS, self.QUALS),
                            rm.catalog_hash(moved, self.QUALS))

    def test_the_real_catalogues_hash(self):
        h = rm.catalog_hash_from_files()
        self.assertRegex(h, r'^[0-9a-f]{16}$')

    def test_corpus_hash_distinguishes_missing_from_empty(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'corpus.jsonl'
            absent = rm.corpus_hash([p])
            p.write_text('')
            empty = rm.corpus_hash([p])
            p.write_text('{"a": 1}\n')
            full = rm.corpus_hash([p])
        self.assertNotEqual(absent, empty)
        self.assertNotEqual(empty, full)


class TestCatalogDrift(unittest.TestCase):
    def test_silent_when_they_agree(self):
        self.assertIsNone(rm.catalog_drift({'catalog_hash': 'abc'}, 'abc'))

    def test_silent_when_either_side_is_unknown(self):
        self.assertIsNone(rm.catalog_drift({}, 'abc'))
        self.assertIsNone(rm.catalog_drift({'catalog_hash': 'abc'}, None))

    def test_names_both_hashes_when_they_differ(self):
        msg = rm.catalog_drift({'catalog_hash': 'abc'}, 'xyz')
        self.assertIn('abc', msg)
        self.assertIn('xyz', msg)


if __name__ == '__main__':
    unittest.main()
