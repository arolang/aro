"""
Unit tests for mandatory task_type and its backfill (GitLab #782).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_task_types.py

task_type was missing on 48% of the corpus, so the type caps and the
stratified holdout ran on a guess made in a notebook. The guess lives in
config now, which is what makes it testable, and a pair cannot be saved
without one.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _load_backfill():
    spec = importlib.util.spec_from_file_location(
        'backfill_task_types', SCRIPT_DIR / 'backfill_task_types.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


backfill = _load_backfill()

MULTI_FILE = (
    'Here is the application.\n\n'
    '## openapi.yaml\n```yaml\nopenapi: 3.0.3\n```\n\n'
    '## main.aro\n```aro\n(Application-Start: Demo) {\n}\n```\n')


# ── inference ────────────────────────────────────────────────────────────────

def test_an_explicit_task_type_is_never_overwritten():
    assert config.infer_task_type(
        {'task_type': 'fim', 'instruction': 'x', 'output': '```aro\ny\n```'}) == 'fim'


def test_a_two_file_answer_is_a_multi_file_application():
    """These were filed as code_generation, which is why one such sample
    reached a 200-row holdout when there are 116 of them."""
    assert config.looks_like_multi_file_application(MULTI_FILE) is True
    assert config.infer_task_type(
        {'instruction': 'build an app', 'output': MULTI_FILE}) == 'multi_file_application'


def test_one_file_heading_is_not_a_multi_file_application():
    single = '## main.aro\n```aro\n(A: B) {\n}\n```\n'
    assert config.looks_like_multi_file_application(single) is False


def test_source_prefixes_map_to_the_caps_vocabulary():
    def infer(source):
        return config.infer_task_type(
            {'instruction': 'q?', 'output': 'a', 'source': source})
    assert infer('book_qa:TheLanguageGuide:Chapter01') == 'syntax_qa'
    assert infer('repair') == 'correction'
    assert infer('mutation') == 'code_generation'
    assert infer('spec_to_code') == 'code_generation'
    assert infer('multi_turn_refinement') == 'tool_calling'


def test_provenance_is_consulted_when_there_is_no_source_field():
    pair = {'instruction': 'q?', 'output': 'a',
            'provenance': {'generation_strategy': 'book_qa:Guide:Ch1'}}
    assert config.infer_task_type(pair) == 'syntax_qa'


def test_a_fix_this_prompt_is_a_correction():
    assert config.infer_task_type(
        {'instruction': 'Fix this ARO code:\n```aro\nx\n```',
         'output': '```aro\ny\n```'}) == 'correction'


def test_a_tool_call_trace_is_tool_calling():
    pair = {'messages': [
        {'role': 'user', 'content': 'read the file'},
        {'role': 'assistant', 'content': '<tool_call>{"name": "read"}</tool_call>'},
    ]}
    assert config.infer_task_type(pair) == 'tool_calling'


def test_nothing_inferable_returns_the_default():
    assert config.infer_task_type({'instruction': '', 'output': ''}) is None


# ── mandatory at save time ───────────────────────────────────────────────────

def test_ensure_task_type_raises_when_it_cannot_tell(monkeypatch):
    monkeypatch.setattr(config, 'REQUIRE_TASK_TYPE', True)
    with pytest.raises(config.MissingTaskType):
        config.ensure_task_type({'instruction': '', 'output': ''}, 'NB08')


def test_ensure_task_type_can_be_relaxed_for_bootstrapping(monkeypatch):
    monkeypatch.setattr(config, 'REQUIRE_TASK_TYPE', False)
    pair = config.ensure_task_type({'instruction': '', 'output': ''}, 'NB08')
    assert pair.get('task_type') is None


def test_saving_a_pair_labels_it(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'PAIRS_FILE', tmp_path / 'pairs.jsonl')
    monkeypatch.setattr(config, 'PAIR_GATE_MODE', 'off')
    config.save_notebook_pairs('NB08', [
        {'instruction': 'build an app', 'output': MULTI_FILE},
    ])
    written = [json.loads(line) for line in
               (tmp_path / 'pairs.jsonl').read_text().splitlines() if line.strip()]
    pairs = [p for p in written if '_metadata' not in p]
    assert pairs[0]['task_type'] == 'multi_file_application'


# ── the backfill ─────────────────────────────────────────────────────────────

def test_backfill_fills_and_leaves_existing_labels_alone(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text('\n'.join([
        json.dumps({'_metadata': {'artifact': 'x'}}),
        json.dumps({'instruction': 'q?', 'output': 'a', 'source': 'book_qa:G:C1'}),
        json.dumps({'instruction': 'app', 'output': MULTI_FILE}),
        json.dumps({'instruction': 'x', 'output': 'y', 'task_type': 'fim'}),
    ]) + '\n')
    before, after, filled, unresolved = backfill.backfill(corpus, write=True)
    assert before['(none)'] == 2
    assert after.get('(none)', 0) == 0
    assert filled == {'syntax_qa': 1, 'multi_file_application': 1}
    assert after['fim'] == 1
    assert unresolved == []
    rows = [json.loads(line) for line in corpus.read_text().splitlines() if line.strip()]
    assert '_metadata' in rows[0], 'the header line survives the rewrite'


def test_backfill_is_idempotent(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text(json.dumps(
        {'instruction': 'q?', 'output': 'a', 'source': 'book_qa:G:C1'}) + '\n')
    backfill.backfill(corpus, write=True)
    before, after, filled, _ = backfill.backfill(corpus, write=True)
    assert filled == {}
    assert after['syntax_qa'] == 1


def test_backfill_keeps_a_backup(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text(json.dumps({'instruction': 'q?', 'output': 'a',
                                  'source': 'book_qa:G:C1'}) + '\n')
    backfill.backfill(corpus, write=True)
    backups = list(tmp_path.glob('c.pre-task-type-backfill.*.jsonl'))
    assert len(backups) == 1


def test_census_counts_missing_labels_under_their_own_key(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text('\n'.join([
        json.dumps({'instruction': 'a', 'output': 'b', 'task_type': 'fim'}),
        json.dumps({'instruction': 'c', 'output': 'd'}),
    ]) + '\n')
    census = config.task_type_census(corpus)
    assert census == {'fim': 1, '(none)': 1}


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
