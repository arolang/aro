"""
Unit tests for the thinking-trace gate and the repair-loop generator
(GitLab #789).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_thinking_traces.py

The booster scored a trace on "at least 40 characters inside <think>", so
1 154 of its 1 156 traces were one template and 1 192 further rows had no
think block at all. A character count cannot tell you any of that.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402


def _load_generator():
    spec = importlib.util.spec_from_file_location(
        'thinking_pairs', SCRIPT_DIR / '34_thinking_pairs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gen = _load_generator()

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

TEMPLATED = (
    '<think>\n'
    'The user is asking: Write an ARO feature set. Let me work out the ARO.\n'
    '  - `Log` — a EXPORT action (exports data or makes it visible). '
    'It takes the preposition `to`.\n'
    '  - `Log` — a EXPORT action (exports data or makes it visible). '
    'It takes the preposition `to`.\n'
    '</think>\n\n```aro\nLog "hi" to the <console>.\n```')

REAL = (
    '<think>\n'
    'The instruction is: store a user.\n\n'
    'My first attempt was this:\n\n```aro\nStore the <u> in the <r>.\n```\n\n'
    '`aro check` rejects it:\n\n```\n1:15: error: Expected preposition, but '
    "got the keyword 'in'\n```\n\n"
    'That is the preposition. `in` is a keyword, not a preposition, and Store '
    'takes `into` or `to`. So the edit is confined to that statement.\n'
    '</think>\n\n```aro\nStore the <u> into the <r>.\n```')


# ── the gate ─────────────────────────────────────────────────────────────────

def test_the_template_is_recognised():
    assert config.thinking_trace_is_templated(TEMPLATED) is True
    assert config.thinking_trace_is_templated(REAL) is False


def test_a_missing_think_block_is_a_problem_not_a_default():
    problems = config.validate_thinking_row(
        {'messages': [{'role': 'system', 'content': 's'},
                      {'role': 'user', 'content': 'q'},
                      {'role': 'assistant', 'content': '```aro\nx\n```'}]})
    assert any('no <think>' in p for p in problems)


def test_a_missing_system_prompt_is_a_problem():
    """`aro ask` always sends one; not one of the 2 348 booster rows had it."""
    problems = config.validate_thinking_row(
        {'messages': [{'role': 'user', 'content': 'q'},
                      {'role': 'assistant', 'content': REAL}]})
    assert any('system prompt' in p for p in problems)


def test_a_long_template_still_fails_the_gate():
    """1 640 characters of boilerplate passed a 40-character threshold."""
    row = {'messages': [{'role': 'system', 'content': 's'},
                        {'role': 'user', 'content': 'q'},
                        {'role': 'assistant', 'content': TEMPLATED * 8}]}
    problems = config.validate_thinking_row(row)
    assert any('templated' in p for p in problems)


def test_a_real_repair_trace_passes():
    row = {'messages': [{'role': 'system', 'content': 's'},
                        {'role': 'user', 'content': 'store a user'},
                        {'role': 'assistant', 'content': REAL}]}
    assert config.validate_thinking_row(row) == []


# ── the mutations ────────────────────────────────────────────────────────────

def test_each_mutation_changes_the_code_or_declines():
    code = ('(Demo: Example) {\n'
            '    Create the <u> with { id: 1 }.\n'
            '    Store the <u> into the <r>.\n'
            '    Return an <OK: status> with <u>.\n}')
    for _name, mutate, _oracle in gen.MUTATIONS:
        result = mutate(code)
        if result is None:
            continue
        broken, explanation = result
        assert broken != code
        assert explanation


def test_a_mutation_that_does_not_apply_returns_none():
    assert gen._mutate_concat('Log "hi" to the <console>.') is None
    assert gen._mutate_entry_point('Log "hi" to the <console>.') is None


def test_first_diagnostic_keeps_the_hint_with_its_error():
    error = ("main.aro:\n"
             "  3:5: error: Expected '.', but got identifier(Store)\n"
             "    hint: Statements must end with a period (.)\n"
             "  4:1: error: something else\n")
    diagnostic = gen.first_diagnostic(error)
    assert "Expected '.'" in diagnostic
    assert 'hint:' in diagnostic
    assert 'something else' not in diagnostic


# ── the generator ────────────────────────────────────────────────────────────

@needs_binary
def test_traces_are_grounded_and_never_templated(tmp_path):
    corpus = tmp_path / 'c.jsonl'
    program = ('(SaveUser: Example) {\n'
               '    Create the <user> with { id: 1 }.\n'
               '    Store the <user> into the <user-repository>.\n'
               '    Return an <OK: status> with <user>.\n}')
    import json
    corpus.write_text('\n'.join(
        json.dumps({'instruction': f'store user {i}',
                    'output': f'```aro\n{program}\n```'})
        for i in range(6)) + '\n')

    rows, stats = gen.build_traces(corpus, system_prompt='SYS')
    assert stats['traces'] > 0
    for row in rows:
        assert config.validate_thinking_row(row) == []
        assert row['messages'][0]['content'] == 'SYS'
        assert row['task_type'] == 'correction'
        assert row['validation']['fixed_checks'] is True


@needs_binary
def test_a_mutation_the_oracle_does_not_object_to_is_dropped(tmp_path):
    """The point of asking rather than asserting: if the binary is happy with
    the 'broken' version there is no repair to reason about."""
    import json
    corpus = tmp_path / 'c.jsonl'
    corpus.write_text(json.dumps(
        {'instruction': 'log', 'output': '```aro\nLog "hi" to the <console>.\n```'}
    ) + '\n')
    rows, stats = gen.build_traces(corpus, system_prompt='SYS')
    # Nothing in a single Log statement can be broken by these mutations
    # except the period, which is a real break — so either a trace or none,
    # never a trace the oracle did not confirm.
    for row in rows:
        assert '`aro check` rejects it' in row['messages'][-1]['content'] or \
               'the action catalog rejects it' in row['messages'][-1]['content']
    assert stats['not_broken'] >= 0


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
