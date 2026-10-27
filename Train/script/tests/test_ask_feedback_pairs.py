"""38_ask_feedback_pairs — RepairSeed exports, re-validated before they train.

The stage's contract is the export's own claim ("this side failed, that side
passed") checked again against the current binary, every side extracted the
way the exporter did (fenced ```aro blocks), and a pair that no longer obeys
its claim dropped with its reason counted. The fixtures re-use stage 36's
program fixtures and Tests the flat triple shape 35's audit reads.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'ask_pairs', SCRIPT_DIR / '38_ask_feedback_pairs.py')
ask = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ask)

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

# The two sides of one repair, in answer form (prose around fenced code) —
# what an ask session records.
GOOD_ANSWER = ('```aro\n'
               '(Application-Start: Min) {\n'
               '    Create the <threshold> with 3.\n'
               '    Log "ready" to the <console>.\n'
               '}\n```')
BROKEN_ANSWER = ('```aro\n'
                 '(Application-Start: Min) {\n'
                 '    Frobnicate the <widget> with the <gizmo>.\n'
                 '}\n```')
PASSABLE_ANSWER = ('```aro\n'
                   '(Application-Start: Min) {\n'
                   '    Create the <threshold> with 3.\n'
                   '    Log "ready" to the <console>.\n'
                   '}\n```')


def seed_file(tmp_path, seeds, name='ask_repairs_2026_10.jsonl'):
    path = tmp_path / name
    with open(path, 'w') as fh:
        for s in seeds:
            fh.write(json.dumps({
                'prompt': 'write a threshold check',
                'rejected': s['rejected'],
                'chosen': s['chosen'],
                'diagnostic_class': s.get('diagnostic_class', 'unknown_verb'),
                'attempts': s.get('attempts', 2),
                'timestamp': s.get('timestamp', '2026-10-20T09:00:00Z'),
                'origin': 'ask_feedback',
            }) + '\n')
    return path


# ── the happy pair ───────────────────────────────────────────────────────────

@needs_binary
def test_a_pair_whose_claim_is_still_true_is_exported(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER,
                          'diagnostic_class': 'unknown_verb'}])
    pairs, corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert stats['exported'] == 1
    pair = pairs[0]
    assert pair['prompt'] == 'write a threshold check'
    assert pair['reason_class'] == 'unknown_verb'
    assert pair['origin'] == 'ask_feedback:unknown_verb'
    assert pair['attempts'] == 2
    assert 'Frobnicate' in pair['rejected']
    assert 'aro_version' in pair


@needs_binary
def test_the_reason_quotes_the_checkers_own_complaint(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER}])
    pairs, _corrections, _stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert 'verb' in pairs[0]['reason'].lower()


@needs_binary
def test_the_correction_row_mirrors_the_pair(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER}])
    pairs, corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert stats['exported'] == 1 and len(corrections) == 1
    row = corrections[0]
    assert row['task_type'] == 'correction'
    assert row['source'].startswith('ask_feedback:')
    assert 'Frobnicate' in row['instruction']
    assert 'does not check clean' in row['instruction']
    assert 'threshold' in row['output']
    provenance = row['_ask_feedback']
    assert provenance['diagnostic_class'] == 'unknown_verb'
    assert provenance['origin'] == 'ask_feedback'
    assert provenance['attempts'] == 2


# ── the drops, with their reasons counted ───────────────────────────────────

@needs_binary
def test_a_fix_that_no_longer_checks_is_dropped_as_still_failing(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': BROKEN_ANSWER}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert pairs == []
    assert stats['dropped_still_fails'] == 1


@needs_binary
def test_a_rejected_side_that_now_passes_is_dropped(tmp_path):
    seed_file(tmp_path, [{'rejected': PASSABLE_ANSWER, 'chosen': GOOD_ANSWER}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert pairs == []
    assert stats['dropped_broken_already_passed'] == 1


@needs_binary
def test_a_rejected_side_without_aro_is_dropped(tmp_path):
    seed_file(tmp_path, [{'rejected': 'I could not produce a program.',
                          'chosen': GOOD_ANSWER}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert pairs == []
    assert stats['dropped_no_aro'] == 1


@needs_binary
def test_a_chosen_side_without_aro_is_dropped(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': 'no code here.'}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert pairs == []
    assert stats['dropped_no_aro'] == 1


@needs_binary
def test_a_seed_still_carrying_a_user_path_is_refused(tmp_path):
    leaked = ('```aro\n'
              '(Application-Start: Min) {\n'
              '    Log "see /Users/Someone/Projects/private/main.aro" '
              'to the <console>.\n'
              '}\n```')
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': leaked}])
    pairs, _corrections, stats = ask.build_rows(tmp_path)
    assert pairs == []
    assert stats['dropped_paths'] == 1


def test_the_username_itself_is_refused():
    assert ask._names_a_person(
        ('see my folder kris-scratch for details',), 'kris')
    assert not ask._names_a_person(
        ('a Knoxville note is fine',), 'kris')


@needs_binary
def test_duplicate_seeds_count_once(tmp_path):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER},
                         {'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert len(pairs) == 1
    assert stats['exported'] == 1
    assert stats['dropped_duplicate'] == 1


@needs_binary
def test_empty_sides_count_as_empty(tmp_path):
    seed_file(tmp_path, [{'rejected': '', 'chosen': GOOD_ANSWER},
                         {'rejected': BROKEN_ANSWER, 'chosen': ''}])
    pairs, _corrections, stats = ask.build_rows(
        tmp_path, username='not-a-real-username-long-enough')
    assert pairs == []
    assert stats['dropped_empty'] == 2


# ── CLI plumbing ─────────────────────────────────────────────────────────────

def test_no_seed_directory_is_answered_not_raised(tmp_path, capsys):
    rc = ask.main(['--seeds', str(tmp_path / 'absent'), '--no-save'])
    out = capsys.readouterr()
    assert rc == 0
    assert 'export-training' in out.err


def test_missing_binary_refuses(tmp_path, capsys, monkeypatch):
    if aro_oracle.aro_bin():
        pytest.skip('a binary is present; this asserts the no-binary path')
    rc = ask.main(['--seeds', str(tmp_path), '--no-save'])
    assert rc == 2
    assert 'no `aro` binary' in capsys.readouterr().err


@needs_binary
def test_writes_dpo_rows_and_appends_correction_rows(tmp_path, monkeypatch):
    seed_file(tmp_path, [{'rejected': BROKEN_ANSWER, 'chosen': GOOD_ANSWER}])
    out = tmp_path / 'out' / 'ask_feedback_pairs.jsonl'
    saved = {}
    monkeypatch.setattr(ask.config, 'save_notebook_pairs',
                        lambda tag, rows, **kw: saved.setdefault('n', len(rows)) or len(rows))
    rc = ask.main(['--seeds', str(tmp_path), '--out', str(out)])
    assert rc == 0
    lines = [line for line in open(out) if line.strip()]
    assert len(lines) == 1
    record = json.loads(lines[0])
    assert record['reason_class'] == 'unknown_verb'
    assert saved['n'] == 1


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
