"""
Unit tests for the git-history miner and the source family it fixed
(GitLab #781).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_git_diff_pairs.py

36% of the corpus came from a generator that was not in the repository, paired
commit messages with unvalidated hunks, and tagged every row with its own
`path@sha` — so the share cap saw three thousand sources of one row each
instead of one source at a third of the corpus.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402


def _load_miner():
    spec = importlib.util.spec_from_file_location(
        'git_diff_pairs', SCRIPT_DIR / '33_git_diff_pairs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


miner = _load_miner()

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

BROKEN = ('(Application-Start: Demo) {\n'
          '    Create the <u> with 1.\n'
          '    Store the <u> in the <user-repository>.\n'
          '    Return an <OK: status> for the <startup>.\n}\n')
FIXED = BROKEN.replace(' in the ', ' into the ')


# ── the source family ────────────────────────────────────────────────────────

def test_a_path_and_sha_is_one_source_called_git():
    assert config.source_family(
        'aro/Examples/Examples/SystemMonitor/main.aro@78e0215e57') == 'git'
    assert config.source_family('git:aro/Examples/main.aro@78e0215e') == 'git'


def test_a_bare_path_is_still_the_comment_miner():
    assert config.source_family('/Users/kris/ARO-Application/mm/main.aro') == 'comment'
    assert config.source_quality_score('/Users/kris/x/main.aro') == 0.95


def test_git_mined_pairs_are_not_scored_as_the_default():
    """They scored 0.8 — the default — because no rule matched them at all."""
    assert config.source_quality_score('aro/Examples/main.aro@78e0215e57') == 0.6
    assert config.source_cap('aro/Examples/main.aro@78e0215e57') == 1200
    assert config.source_cap('curated/http_route') is None


def test_ordinary_prefixes_are_unaffected():
    assert config.source_family('book_qa:Guide:Chapter01') == 'book_qa'
    assert config.source_quality_score('book_qa:Guide:Chapter01') == 0.8
    assert config.source_quality_score('example:Foo') == 1.0


# ── the miner ────────────────────────────────────────────────────────────────

def _repo(tmp_path):
    def run(*args):
        subprocess.run(['git', '-C', str(tmp_path), *args], check=True,
                       capture_output=True)
    run('init', '-q', '-b', 'main')
    run('config', 'user.email', 'test@example.com')
    run('config', 'user.name', 'Test')
    return run


@needs_binary
def test_a_commit_that_fixes_a_file_becomes_a_correction(tmp_path):
    run = _repo(tmp_path)
    (tmp_path / 'main.aro').write_text(BROKEN)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'feat: add the demo')
    (tmp_path / 'main.aro').write_text(FIXED)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'fix: Store takes into, not in')

    pairs, stats = miner.build_pairs(tmp_path, limit=10)
    assert stats['correction'] == 1, stats
    assert stats['pairs'] == 2
    assert all(p['task_type'] == 'correction' for p in pairs)
    assert all(p['source'].startswith('git:') for p in pairs)
    assert config.source_family(pairs[0]['source']) == 'git'


@needs_binary
def test_the_answer_says_what_changed_and_why(tmp_path):
    run = _repo(tmp_path)
    (tmp_path / 'main.aro').write_text(BROKEN)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'feat: add the demo')
    (tmp_path / 'main.aro').write_text(FIXED)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'fix: Store takes into, not in')

    pairs, _stats = miner.build_pairs(tmp_path, limit=10)
    explanation = pairs[0]['messages'][-1]['content']
    assert 'fix: Store takes into, not in' in explanation
    assert '```diff' in explanation, 'the diff itself, not only its subject'
    assert 'aro check' in explanation, 'and why the old one was wrong'


@needs_binary
def test_a_commit_that_leaves_the_file_broken_produces_nothing(tmp_path):
    """Whatever the message claimed, an answer that does not check is not a
    fix. Nothing in the old generator asked."""
    run = _repo(tmp_path)
    (tmp_path / 'main.aro').write_text(FIXED)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'feat: add the demo')
    (tmp_path / 'main.aro').write_text(BROKEN)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'fix: definitely fixed it this time')

    pairs, stats = miner.build_pairs(tmp_path, limit=10)
    assert pairs == []
    assert stats['new_invalid'] == 1


@needs_binary
def test_whole_files_are_checked_not_hunks(tmp_path):
    """The old pairs were hunks — a single line, half a `when` clause — which
    cannot be checked at all."""
    run = _repo(tmp_path)
    (tmp_path / 'main.aro').write_text(BROKEN)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'feat: add')
    (tmp_path / 'main.aro').write_text(FIXED)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'fix: into')

    pairs, _stats = miner.build_pairs(tmp_path, limit=10)
    prompt = pairs[0]['messages'][1]['content']
    assert 'Application-Start' in prompt, 'the whole file, not the hunk'
    assert pairs[0]['validation']['old_checks'] is False
    assert pairs[0]['validation']['new_checks'] is True


def test_a_file_added_in_a_commit_has_no_before_side(tmp_path):
    run = _repo(tmp_path)
    (tmp_path / 'main.aro').write_text(FIXED)
    run('add', 'main.aro')
    run('commit', '-q', '-m', 'feat: add the demo')
    pairs, stats = miner.build_pairs(tmp_path, limit=10)
    assert pairs == []
    assert stats['no_parent'] == 1


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
