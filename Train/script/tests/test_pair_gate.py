"""
Unit tests for the save-time runtime gate (GitLab #780).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_pair_gate.py

The gate used to run at one stage only, so pairs carrying verbs no action
implements reached the corpus through every other door. These tests hold the
door: everything written through save_notebook_pair(s) is asked, and the
per-source table exists so a bad source cannot hide inside a good average.
"""

import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

GOOD = '```aro\nLog "hi" to the <console>.\n```'
INVENTED_VERB = '```aro\nHash the <digest> from the <password>.\n```'
BAD_PREPOSITION = '```aro\nStore the <u> in the <r>.\n```'
REVERSE = '```aro\nReverse the <r> for the <items>.\n```'


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A throwaway PAIRS_FILE plus clean gate counters."""
    monkeypatch.setattr(config, 'PAIRS_FILE', tmp_path / 'pairs.jsonl')
    config.PAIR_GATE_BY_SOURCE.clear()
    config.PAIR_GATE_STATS.clear()
    yield tmp_path / 'pairs.jsonl'
    config.PAIR_GATE_BY_SOURCE.clear()
    config.PAIR_GATE_STATS.clear()


def _written(path):
    if not path.exists():
        return []
    return [r for r in (json.loads(line) for line in path.read_text().splitlines()
                        if line.strip())
            if '_metadata' not in r]


def _answer(pair):
    messages = pair.get('messages')
    if messages:
        return messages[-1].get('content') or ''
    return pair.get('output') or ''


@needs_binary
def test_the_gate_drops_an_invented_verb_from_any_stage(corpus):
    """`Hash` is not an action. `aro check` accepts it; the catalog does not."""
    written = config.save_notebook_pairs('NB00_git', [
        {'instruction': 'log', 'output': GOOD, 'source': 'git'},
        {'instruction': 'hash', 'output': INVENTED_VERB, 'source': 'git'},
    ])
    assert written == 1
    kept = _written(corpus)
    assert len(kept) == 1
    assert 'Log' in _answer(kept[0])


@needs_binary
def test_the_gate_drops_a_preposition_the_runtime_rejects(corpus):
    assert config.save_notebook_pair(
        'NB08', {'instruction': 'store', 'output': BAD_PREPOSITION}) is False
    assert _written(corpus) == []


@needs_binary
def test_valid_reverse_is_kept(corpus):
    """The catalog was two verbs short, so this was dropped as hallucinated
    (GitLab #779)."""
    assert config.save_notebook_pair(
        'NB08', {'instruction': 'reverse', 'output': REVERSE}) is True
    assert len(_written(corpus)) == 1


@needs_binary
def test_written_pairs_carry_the_verdict_and_the_version(corpus):
    config.save_notebook_pair('NB08', {'instruction': 'log', 'output': GOOD})
    kept = _written(corpus)[0]
    assert kept['validation']['valid'] is True
    assert kept['validation']['aro_version'] == aro_oracle.aro_version()


@needs_binary
def test_per_source_pass_rates_are_recorded(corpus, capsys):
    config.save_notebook_pairs('NB00_git', [
        {'instruction': 'a', 'output': GOOD, 'source': 'curated'},
        {'instruction': 'b', 'output': INVENTED_VERB, 'source': 'git-diff'},
        {'instruction': 'c', 'output': BAD_PREPOSITION, 'source': 'git-diff'},
    ])
    snapshot = config.pair_gate_report()
    assert snapshot['curated']['seen'] == 1
    assert snapshot['curated']['passed'] == 1
    assert snapshot['git-diff']['seen'] == 2
    assert snapshot['git-diff'].get('passed', 0) == 0
    assert 'per-source pass rate' in capsys.readouterr().out


def test_gate_off_writes_everything(corpus, monkeypatch):
    monkeypatch.setattr(config, 'PAIR_GATE_MODE', 'off')
    written = config.save_notebook_pairs('NB08', [
        {'instruction': 'hash', 'output': INVENTED_VERB},
    ])
    assert written == 1


def test_static_mode_needs_no_binary(corpus, monkeypatch):
    """A host with no toolchain still gets the catalog gates."""
    monkeypatch.setattr(config, 'PAIR_GATE_MODE', 'static')
    assert config.save_notebook_pair(
        'NB08', {'instruction': 'hash', 'output': INVENTED_VERB}) is False
    assert config.save_notebook_pair(
        'NB08', {'instruction': 'log', 'output': GOOD}) is True


def test_validate_pair_aro_never_raises_on_a_malformed_pair():
    """A gate that dies on one bad row stops a pipeline that should merely
    have dropped it."""
    assert config.validate_pair_aro({}).get('valid') is True
    assert config.validate_pair_aro({'output': None}).get('valid') is True


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
