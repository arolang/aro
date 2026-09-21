"""
Unit tests for grounded, length-matched preference pairs (GitLab #799).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_preference_pairs.py

dpo_pairs_raw.jsonl carries prompt, chosen and rejected and nothing else — no
reason, no origin — and in 68.6% of its rows the chosen answer is simply the
longer one. A preference pair should differ in the thing being preferred and
in as little else as possible.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prefs = _load('preference_pairs', '35_preference_pairs.py')

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

PROGRAM = ('(SaveUser: Example) {\n'
           '    Create the <user> with { id: 1 }.\n'
           '    Store the <user> into the <user-repository>.\n'
           '    Return an <OK: status> with <user>.\n}')


def _corpus(tmp_path, n=8):
    path = tmp_path / 'c.jsonl'
    path.write_text('\n'.join(
        json.dumps({'instruction': f'save user {i}',
                    'output': f'```aro\n{PROGRAM}\n```'})
        for i in range(n)) + '\n')
    return path


# ── the metric ───────────────────────────────────────────────────────────────

def test_length_bias_names_the_problem():
    biased = [{'chosen': 'x' * 500, 'rejected': 'x' * 20} for _ in range(4)]
    report = prefs.length_bias(biased)
    assert report['chosen_longer_pct'] == 100.0
    assert report['median_delta_chars'] == 480


def test_length_bias_of_a_matched_set_is_near_zero():
    matched = [{'chosen': 'into the repo', 'rejected': 'in the repo'},
               {'chosen': 'a.', 'rejected': 'a'},
               {'chosen': 'Compute', 'rejected': 'Process!'}]
    report = prefs.length_bias(matched)
    assert abs(report['median_delta_chars']) <= 2


def test_length_bias_on_nothing_is_nothing():
    assert prefs.length_bias([]) == {}


# ── the generator ────────────────────────────────────────────────────────────

@needs_binary
def test_every_pair_carries_a_reason_and_an_origin(tmp_path):
    pairs, _stats = prefs.build_pairs(_corpus(tmp_path))
    assert pairs
    for pair in pairs:
        assert pair['reason'], 'why the rejected side was rejected'
        assert pair['origin'].startswith('repair_loop:')
        assert pair['aro_version'] == aro_oracle.aro_version()


@needs_binary
def test_the_two_sides_are_the_same_program(tmp_path):
    """They differ by a preposition, a period, a verb — not by a paragraph."""
    pairs, _stats = prefs.build_pairs(_corpus(tmp_path))
    report = prefs.length_bias(pairs)
    assert abs(report['median_delta_chars']) <= 5
    # The two sides are within a rounding error of each other in length, so
    # length cannot be what distinguishes them. (The share of pairs where the
    # chosen side happens to be the longer one is 49.4% over the real corpus;
    # over a handful of programs it is noise, which is why the assertion is on
    # the magnitude rather than the direction.)
    drift = abs(report['mean_chosen_chars'] - report['mean_rejected_chars'])
    assert drift <= 0.02 * report['mean_chosen_chars']


@needs_binary
def test_the_rejected_side_really_is_rejected(tmp_path):
    pairs, _stats = prefs.build_pairs(_corpus(tmp_path))
    for pair in pairs:
        if pair['oracle'] != 'check':
            continue
        code = pair['rejected'].split('```aro\n')[1].rsplit('```', 1)[0]
        ok, _error = aro_oracle.check_block(code)
        assert ok is False, pair['reason']


@needs_binary
def test_the_chosen_side_really_is_accepted(tmp_path):
    pairs, _stats = prefs.build_pairs(_corpus(tmp_path))
    for pair in pairs[:5]:
        code = pair['chosen'].split('```aro\n')[1].rsplit('```', 1)[0]
        ok, error = aro_oracle.check_block(code)
        assert ok is True, error


@needs_binary
def test_a_wildly_unbalanced_pair_is_not_emitted(tmp_path):
    pairs, stats = prefs.build_pairs(_corpus(tmp_path), ratio_limit=1.0001)
    assert stats['length_mismatch'] >= 0
    for pair in pairs:
        ratio = max(len(pair['chosen']), len(pair['rejected'])) / min(
            len(pair['chosen']), len(pair['rejected']))
        assert ratio <= 1.0001


# ── the audit ────────────────────────────────────────────────────────────────

def test_audit_reads_both_string_and_message_list_rows(tmp_path, capsys):
    path = tmp_path / 'dpo.jsonl'
    path.write_text('\n'.join([
        json.dumps({'prompt': 'p', 'chosen': 'a' * 100, 'rejected': 'b' * 10}),
        json.dumps({'prompt': 'p',
                    'chosen': [{'role': 'assistant', 'content': 'a' * 100}],
                    'rejected': [{'role': 'assistant', 'content': 'b' * 10}]}),
    ]) + '\n')
    prefs.audit(path)
    out = capsys.readouterr().out
    assert 'reason logged  : False' in out
    assert "'pairs': 2" in out
    assert "'chosen_longer_pct': 100.0" in out


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
