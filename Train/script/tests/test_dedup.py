"""
Unit tests for the deduplication caps (GitLab #784).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_dedup.py

Deduplication used to run once, at assembly, on the first 300 characters of
the instruction — and never on the output. One commit message was the answer
to 379 different prompts. These tests cover the three caps and, in particular,
that the output-side one exists at all.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _load_dedup():
    spec = importlib.util.spec_from_file_location(
        'dedup_corpus', SCRIPT_DIR / 'dedup_corpus.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


dedup_corpus = _load_dedup()


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'PAIRS_FILE', tmp_path / 'pairs.jsonl')
    monkeypatch.setattr(config, 'PAIR_GATE_MODE', 'off')
    config._dedup_loaded['from'] = None
    config.DEDUP_STATS.clear()
    yield tmp_path / 'pairs.jsonl'
    config._dedup_loaded['from'] = None
    config.DEDUP_STATS.clear()


def _rows(path):
    if not path.exists():
        return []
    return [r for r in (json.loads(line) for line in path.read_text().splitlines()
                        if line.strip())
            if '_metadata' not in r]


def _pair(instruction, output):
    return {'instruction': instruction, 'output': output,
            'task_type': 'code_generation'}


# ── normalisation ────────────────────────────────────────────────────────────

def test_fingerprint_folds_whitespace_and_case():
    a = _pair('Log  something', 'The   Answer')
    b = _pair('log something', 'the answer')
    assert config.pair_fingerprint(a) == config.pair_fingerprint(b)


# ── the three caps ───────────────────────────────────────────────────────────

def test_an_exact_pair_is_written_once(corpus):
    written = config.save_notebook_pairs('NB08', [
        _pair('why did this change?', 'because of the fix'),
        _pair('why did this change?', 'because of the fix'),
    ])
    assert written == 1
    assert config.DEDUP_STATS['exact_pair'] == 1


def test_the_same_answer_cannot_answer_everything(corpus, monkeypatch):
    """The cap that did not exist. One commit message answered 379 prompts."""
    monkeypatch.setattr(config, 'MAX_REPEATS_PER_OUTPUT', 3)
    written = config.save_notebook_pairs('NB00_git', [
        _pair(f'why was snippet {i} changed?', 'docs(books): fix broken examples')
        for i in range(10)
    ])
    assert written == 3
    assert config.DEDUP_STATS['output_cap'] == 7


def test_the_same_prompt_cannot_have_nine_paraphrased_answers(corpus, monkeypatch):
    monkeypatch.setattr(config, 'MAX_REPEATS_PER_INSTRUCTION', 3)
    written = config.save_notebook_pairs('NB14', [
        _pair('what does this comment mean?', f'paraphrase number {i}')
        for i in range(9)
    ])
    assert written == 3
    assert config.DEDUP_STATS['instruction_cap'] == 6


def test_the_index_is_seeded_from_what_is_already_on_disk(corpus):
    """A rerun must not reintroduce what a previous run wrote."""
    config.save_notebook_pairs('NB08', [_pair('q', 'a')])
    config._dedup_loaded['from'] = None       # as a fresh process would start
    assert config.save_notebook_pairs('NB08', [_pair('q', 'a')]) == 0
    assert len(_rows(corpus)) == 1


def test_dedup_can_be_turned_off(corpus, monkeypatch):
    monkeypatch.setattr(config, 'DEDUP_EXACT_PAIRS', False)
    assert config.save_notebook_pairs('NB08', [_pair('q', 'a'), _pair('q', 'a')]) == 2


# ── the standalone cleaner ───────────────────────────────────────────────────

def _corpus_file(tmp_path, rows):
    path = tmp_path / 'c.jsonl'
    path.write_text('\n'.join(
        [json.dumps({'_metadata': {'artifact': 'x'}})]
        + [json.dumps(r) for r in rows]) + '\n')
    return path


def test_census_counts_repeats_on_both_sides(tmp_path):
    path = _corpus_file(tmp_path, [
        _pair('a', 'same'), _pair('b', 'same'), _pair('c', 'same'),
        _pair('d', 'other'),
    ])
    rows, _ = dedup_corpus.read_rows(path)
    counts = dedup_corpus.census(rows)
    assert counts['rows'] == 4
    assert counts['distinct_outputs'] == 2
    assert counts['duplicate_output_copies'] == 2
    assert counts['most_repeated_output'] == 3


def test_dedup_keeps_the_cap_and_drops_the_rest(tmp_path):
    path = _corpus_file(tmp_path, [
        _pair(f'q{i}', 'one answer to rule them all') for i in range(10)])
    rows, _ = dedup_corpus.read_rows(path)
    kept, dropped = dedup_corpus.dedup(rows, max_per_instruction=3,
                                       max_per_output=3)
    assert len(kept) == 3
    assert dropped['output_cap'] == 7


def test_dedup_keeps_file_order_by_default(tmp_path):
    path = _corpus_file(tmp_path, [
        _pair('first', 'same'), _pair('second', 'same'), _pair('third', 'same'),
        _pair('fourth', 'same')])
    rows, _ = dedup_corpus.read_rows(path)
    kept, _dropped = dedup_corpus.dedup(rows, max_per_output=2)
    assert [k['instruction'] for k in kept] == ['first', 'second']


def test_prefer_validated_keeps_the_copy_the_runtime_liked(tmp_path):
    good = _pair('q', 'a')
    good['validation'] = {'valid': True, 'run_passed': 1}
    bad = _pair('q', 'b')
    bad['validation'] = {'valid': False}
    path = _corpus_file(tmp_path, [bad, good])
    rows, _ = dedup_corpus.read_rows(path)
    kept, _dropped = dedup_corpus.dedup(rows, max_per_instruction=1,
                                        prefer_validated=True)
    assert [k['output'] for k in kept] == ['a']


def test_the_header_line_survives_a_rewrite(tmp_path):
    path = _corpus_file(tmp_path, [_pair('q', 'a'), _pair('q', 'a')])
    out = tmp_path / 'clean.jsonl'
    dedup_corpus.main([str(path), '--out', str(out)])
    lines = [json.loads(line) for line in out.read_text().splitlines() if line.strip()]
    assert '_metadata' in lines[0]
    assert len(lines) == 2


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
