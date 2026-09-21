"""
Unit tests for the corpus re-validator (GitLab #783) and the oracle it talks
to (GitLab #779).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_revalidate_corpus.py

Everything here is pure python: pair shapes, block classification, the static
gates, the parsing of `aro check` output. The tests that need a binary are
marked and skip themselves when there is none, so this file runs on a CI image
without a toolchain and gets sharper on one that has it.
"""

import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')


# ── which text is the answer ─────────────────────────────────────────────────

def test_answer_text_prefers_the_last_assistant_turn():
    pair = {'messages': [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'ask'},
        {'role': 'assistant', 'content': 'first'},
        {'role': 'user', 'content': 'again'},
        {'role': 'assistant', 'content': 'second'},
    ]}
    assert rc.answer_text(pair) == 'second'
    assert rc.prompt_text(pair) == 'ask'


def test_answer_text_handles_instruction_output_and_dpo_shapes():
    assert rc.answer_text({'instruction': 'i', 'output': 'o'}) == 'o'
    assert rc.answer_text({'prompt': 'p', 'chosen': 'c', 'rejected': 'r'}) == 'c'
    assert rc.prompt_text({'prompt': 'p', 'chosen': 'c'}) == 'p'


def test_pair_source_reads_provenance_first():
    assert rc.pair_source({'provenance': {'source': 'curated/http_route'},
                           'notebook': 'NB03'}) == 'curated/http_route'
    assert rc.pair_source({'notebook': 'NB08'}) == 'NB08'
    assert rc.pair_source({}) == '(unattributed)'


# ── which blocks are held to the runtime's standard ──────────────────────────

def test_negative_examples_are_skipped_not_failed():
    """A corpus that teaches what is wrong needs wrong code in it."""
    ok, reason = rc.block_is_checkable(
        'Store the <u> in the <r>.',
        preceding='This is wrong — it does not work:')
    assert ok is False
    assert reason == 'negative-example'


def test_template_and_diagram_fences_are_not_code():
    assert rc.block_is_checkable('(Name: Activity) {\n    <statements>\n}')[0] is False
    assert rc.block_is_checkable('Extract the <x> from the <y>.\n^^^^')[0] is False
    assert rc.block_is_checkable('')[0] is False


def test_real_code_is_checkable():
    ok, _ = rc.block_is_checkable('Log "hi" to the <console>.',
                                  preceding='Here is how you log:')
    assert ok is True


def test_blocks_with_context_returns_preceding_prose():
    text = 'Do not do this:\n```aro\nBroken\n```\nand this is fine:\n```aro\nGood\n```'
    blocks = list(rc.blocks_with_context(text))
    assert [code.strip() for code, _ in blocks] == ['Broken', 'Good']
    assert 'Do not do this' in blocks[0][1]


# ── the static gates ─────────────────────────────────────────────────────────

def test_hallucinated_verbs_uses_the_catalog():
    verbs, _vp, _q = rc.load_catalogs()
    assert 'reverse' in verbs, 'catalog must know Reverse (GitLab #779)'
    assert 'flip' in verbs
    code = ('Hash the <digest> from the <password>.\n'
            'Reverse the <r> for the <items>.')
    assert rc.hallucinated_verbs(code, verbs) == ['Hash']


def test_hallucinated_verbs_ignores_prose_in_comments():
    verbs, _vp, _q = rc.load_catalogs()
    code = '(* Encrypt the payload before storing it *)\nLog "x" to the <console>.'
    assert rc.hallucinated_verbs(code, verbs) == []


def test_preposition_warnings_are_read_from_the_binarys_own_output():
    output = ("<stdin>:\n  2:29: warning: Action 'Render' does not accept "
              "the preposition 'from'\n    hint: Valid prepositions for "
              "Render: to\n")
    assert rc.preposition_warnings(output) == ['Render … from']


def test_result_type_as_is_not_a_preposition():
    """`Compute the <n> as Float from <s>.` is valid; the fallback gate used
    to flag seventeen of them."""
    _verbs, vp, _q = rc.load_catalogs()
    assert rc.preposition_violations('Compute the <n> as Float from <s>.', vp) == []


def test_catalog_preposition_fallback_still_catches_store_in():
    _verbs, vp, _q = rc.load_catalogs()
    violations = rc.preposition_violations('Store the <u> in the <r>.', vp)
    assert violations and violations[0].startswith('Store … in')


def test_unknown_qualifier_detection_skips_result_types():
    _verbs, _vp, known = rc.load_catalogs()
    assert rc.unknown_qualifiers('Compute the <t: sum> from <xs>.', known) == []
    assert rc.unknown_qualifiers('Compute the <t: frobnicate> from <xs>.',
                                 known) == ['frobnicate']
    assert rc.unknown_qualifiers('Compute the <n: List <Int>> from <xs>.',
                                 known) == []


def test_free_variable_errors_are_recognised():
    assert rc.error_is_only_free_variables(
        "<stdin>:\n  1:1: error: Cannot publish undefined variable 'result'\n")
    assert not rc.error_is_only_free_variables(
        "<stdin>:\n  1:4: error: Expected 'each', but got -\n")
    assert not rc.error_is_only_free_variables('')


# ── reading a corpus ─────────────────────────────────────────────────────────

def test_read_corpus_separates_metadata_and_counts_malformed(tmp_path):
    path = tmp_path / 'corpus.jsonl'
    path.write_text('\n'.join([
        json.dumps({'_metadata': {'aro_lang_commit': 'abc'}}),
        json.dumps({'instruction': 'i', 'output': 'o'}),
        '{not json',
        json.dumps({'instruction': 'j', 'output': 'p'}),
    ]) + '\n')
    rows, metadata, malformed = rc.read_corpus(path)
    assert len(rows) == 2
    assert metadata['_metadata']['aro_lang_commit'] == 'abc'
    assert malformed == 1


# ── the oracle itself ────────────────────────────────────────────────────────

def test_canonical_verb_keys_the_catalog_by_verb_not_type_name():
    assert aro_oracle.canonical_verb('GitCommit', ['commit']) == 'commit'
    assert aro_oracle.canonical_verb('ParseDispatch', ['parse']) == 'parse'
    assert aro_oracle.canonical_verb('WaitForEvents',
                                     ['block', 'keepalive', 'wait']) == 'wait'
    assert aro_oracle.canonical_verb('Delete',
                                     ['clear', 'delete', 'destroy', 'remove']) == 'delete'


def test_feature_set_detection_picks_the_directory_check():
    assert aro_oracle.FEATURE_SET_RE.search('(GetUser: User API) {\n}')
    assert aro_oracle.FEATURE_SET_RE.search(
        '(Double: Action takes <number>) {\n}')
    assert not aro_oracle.FEATURE_SET_RE.search('Log "hi" to the <console>.')


def test_aro_blocks_extracts_fences():
    text = 'x\n```aro\nA\n```\ny\n```python\nnope\n```\n```aro title\nB\n```'
    assert aro_oracle.aro_blocks(text) == ['A\n', 'B\n']


@needs_binary
def test_check_block_accepts_a_fragment_and_a_program():
    ok, _ = aro_oracle.check_block('Log "hi" to the <console>.')
    assert ok is True
    ok, _ = aro_oracle.check_block(
        '(Application-Start: Demo) {\n'
        '    Log "hi" to the <console>.\n'
        '    Return an <OK: status> for the <startup>.\n}')
    assert ok is True


@needs_binary
def test_check_block_survives_a_comment_banner_before_a_feature_set():
    """`aro check --syntax` trips over this shape; the directory check does
    not, which is why blocks with a feature set take that route."""
    ok, error = aro_oracle.check_block(
        '(* main.aro *)\n'
        '(Application-Start: Demo) {\n'
        '    Log "hi" to the <console>.\n'
        '    Return an <OK: status> for the <startup>.\n}')
    assert ok is True, error


@needs_binary
def test_check_block_rejects_store_in():
    ok, error = aro_oracle.check_block('Store the <u> in the <r>.')
    assert ok is False
    assert 'preposition' in error


@needs_binary
def test_check_block_rejects_an_invented_qualifier():
    ok, error = aro_oracle.check_block('Compute the <x: frobnicate> from <t>.')
    assert ok is False
    assert 'qualifier' in error.lower()


@needs_binary
def test_aro_check_alone_does_not_catch_an_invented_verb():
    """The reason the catalog gate exists next to the binary (GitLab #798):
    `aro check` is happy with a verb no action implements."""
    ok, _ = aro_oracle.check_block(
        '(Demo: Example) {\n'
        '    Create the <password> with "p".\n'
        '    Hash the <digest> from the <password>.\n'
        '    Return an <OK: status> with <digest>.\n}')
    assert ok is True
    verbs, _vp, _q = rc.load_catalogs()
    assert rc.hallucinated_verbs('Hash the <digest> from the <password>.',
                                 verbs) == ['Hash']


@needs_binary
def test_validate_pair_end_to_end(tmp_path):
    verbs, vp, known = rc.load_catalogs()
    cache = rc.CheckCache(aro_oracle.aro_bin())
    good = {'instruction': 'log', 'output': '```aro\nLog "hi" to the <console>.\n```'}
    bad = {'instruction': 'store', 'output': '```aro\nStore the <u> in the <r>.\n```'}
    assert rc.validate_pair(good, verbs, vp, known, cache)['valid'] is True
    verdict = rc.validate_pair(bad, verbs, vp, known, cache)
    assert verdict['valid'] is False
    assert rc.failure_reasons(verdict) == ['aro_check']
    assert verdict['aro_version'] == aro_oracle.aro_version()


@needs_binary
def test_main_writes_a_report_and_honours_fail_under(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text('\n'.join([
        json.dumps({'instruction': 'a',
                    'output': '```aro\nLog "hi" to the <console>.\n```'}),
        json.dumps({'instruction': 'b',
                    'output': '```aro\nStore the <u> in the <r>.\n```'}),
    ]) + '\n')
    report = tmp_path / 'report.json'
    code = rc.main([str(corpus), '--quiet', '--report', str(report),
                    '--fail-under', '90'])
    assert code == 1, 'a 50% pass rate must fail a 90% threshold'
    data = json.loads(report.read_text())
    assert data['files'][0]['pairs'] == 2
    assert data['files'][0]['failing'] == 1
    assert rc.main([str(corpus), '--quiet', '--fail-under', '10']) == 0


@needs_binary
def test_drop_failures_writes_only_the_passing_pairs(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text('\n'.join([
        json.dumps({'instruction': 'a',
                    'output': '```aro\nLog "hi" to the <console>.\n```'}),
        json.dumps({'instruction': 'b',
                    'output': '```aro\nStore the <u> in the <r>.\n```'}),
    ]) + '\n')
    out = tmp_path / 'clean.jsonl'
    rc.main([str(corpus), '--quiet', '--drop-failures', str(out)])
    kept = [json.loads(line) for line in out.read_text().splitlines() if line]
    assert [k['instruction'] for k in kept] == ['a']
    assert kept[0]['validation']['valid'] is True


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
