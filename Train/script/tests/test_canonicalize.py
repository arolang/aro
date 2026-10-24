"""Canonicalization: the corpus spelled the way the registry spells it.

Two families of drift the language carries: alias verbs that check green
exactly like their canonical verb, and `Store ... in ...` — `in` is a
keyword, so that statement is one letter away from the one the author
meant, and the checker refuses it outright. Canonicalization is env-gated
(default OFF) so no existing pair is rewritten without a decision, and the
recovery stages apply it explicitly to their generated code.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


@pytest.fixture
def canonical_on(monkeypatch):
    monkeypatch.setenv('ARO_TRAIN_CANONICALIZE', '1')
    return monkeypatch


@pytest.fixture
def canonical_off(monkeypatch):
    monkeypatch.delenv('ARO_TRAIN_CANONICALIZE', raising=False)
    return monkeypatch


def test_off_by_default(canonical_off):
    assert config.canonicalize_enabled() is False


def test_env_turns_it_on(canonical_on):
    assert config.canonicalize_enabled() is True


def test_the_store_in_keyword_becomes_into(canonical_on):
    code = '(Fill: Repo) {\n    Store the <x> in the <repo>.\n}\n'
    out = config.canonicalize_aro_code(code)
    assert 'Store the <x> into the <repo>' in out
    assert ' in the' not in out


def test_store_in_without_an_article(canonical_on):
    code = '(Fill: Repo) {\n    Store <x> in <repo>.\n}\n'
    assert 'Store <x> into <repo>' in config.canonicalize_aro_code(code)


def test_the_storage_verbs_and_nothing_else_translate_in(canonical_on):
    # `When` guards and ordinary statements with `in` elsewhere must not be
    # rewritten — the fix is for the keyword-in-preposition-slot, not for
    # every `in` in the file.
    code = ('(Fill: Repo) {\n'
            '    Store the <x> into the <repo>.\n'
            '    Log "in stock" to the <console>.\n'
            '}\n')
    out = config.canonicalize_aro_code(code)
    assert 'into the <repo>' in out
    assert '"in stock"' in out


def test_alias_verbs_become_their_canonical(canonical_on):
    code = '(Make: App) {\n    Build the <form> for the <user>.\n    Log <x> to the <console>.\n}\n'
    out = config.canonicalize_aro_code(code)
    assert 'Create the <form> for the <user>' in out
    assert 'Build' not in out


def test_remove_and_clear_map_by_the_registry(canonical_on):
    code = '(Clean: Files) {\n    Remove the <stale> from the <bucket>.\n}\n'
    out = config.canonicalize_aro_code(code)
    assert 'Delete the <stale> from the <bucket>' in out


def test_qualifier_slots_and_object_names_are_untouched(canonical_on):
    code = ('(Build Pipeline: BP) {\n'
            '    Log <user: name> to the <console>.\n'
            '}\n')
    out = config.canonicalize_aro_code(code)
    assert '<user: name>' in out
    assert '(Build Pipeline: BP)' in out


def test_already_canonical_code_is_byte_stable(canonical_on):
    code = ('(Application-Start: KV) {\n'
            '    Create the <k> with 1.\n'
            '    Store the <k> into the <cache>.\n'
            '    Retrieve the <v> from the <cache>.\n'
            '    Log <v> to the <console>.\n'
            '}\n')
    assert config.canonicalize_aro_code(code) == code


def test_empty_and_none_pass_through(canonical_on):
    assert config.canonicalize_aro_code('') == ''
    assert config.canonicalize_aro_code(None) is None


def test_normalize_pair_leaves_output_alone_when_env_is_off(canonical_off):
    pair = {'instruction': 'store x',
            'output': '```aro\nStore the <x> in the <repo>.\n```'}
    config._normalize_pair(pair)
    assert 'in the <repo>' in pair['output']


def test_normalize_pair_canonicalizes_fenced_aro_when_env_is_on(canonical_on):
    pair = {'instruction': 'store x',
            'output': 'before\n```aro\nBuild the <f> for the <u>.\n```\nafter'}
    config._normalize_pair(pair)
    assert 'Create the <f> for the <u>' in pair['output']
    assert 'before' in pair['output'] and 'after' in pair['output']


def test_normalize_pair_never_touches_the_instruction(canonical_on):
    pair = {'instruction': 'Store the value in the map, using build tools',
            'output': '```aro\nBuild the <f> for the <u>.\n```'}
    config._normalize_pair(pair)
    assert 'Store the value in the map' in pair['instruction']
    assert 'using build tools' in pair['instruction']


def test_normalize_pair_canonicalizes_assistant_turns(canonical_on):
    pair = {'messages': [
        {'role': 'user', 'content': 'please Build it in rust'},
        {'role': 'assistant', 'content': '```aro\nBuild the <f> for the <u>.\n```'},
    ]}
    config._normalize_pair(pair)
    assert 'please Build it' in pair['messages'][0]['content']
    assert 'Create the <f>' in pair['messages'][1]['content']
