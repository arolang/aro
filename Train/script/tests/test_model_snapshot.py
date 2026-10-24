"""
Unit tests for config.complete_local_snapshot.

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_model_snapshot.py

load_model and model_prefetch.py use it to decide whether the model can be
loaded from disk without asking the Hub. A snapshot missing a shard must
not count as complete, or a stage would load half a model.
"""

import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _snapshot(tmp_path, shards_present):
    (tmp_path / 'config.json').write_text('{}')
    (tmp_path / 'model.safetensors.index.json').write_text(json.dumps(
        {'weight_map': {'a': 'm-1.safetensors', 'b': 'm-2.safetensors'}}))
    for name in shards_present:
        (tmp_path / name).write_text('x')
    return str(tmp_path)


def test_every_shard_present_is_complete(tmp_path):
    path = _snapshot(tmp_path, ['m-1.safetensors', 'm-2.safetensors'])
    assert config.complete_local_snapshot(path) == path


def test_a_missing_shard_is_incomplete(tmp_path):
    assert config.complete_local_snapshot(
        _snapshot(tmp_path, ['m-1.safetensors'])) is None


def test_an_unindexed_single_file_model_is_complete(tmp_path):
    (tmp_path / 'config.json').write_text('{}')
    (tmp_path / 'model.safetensors').write_text('x')
    assert config.complete_local_snapshot(str(tmp_path)) == str(tmp_path)


def test_an_uncached_repo_id_is_incomplete():
    assert config.complete_local_snapshot('nobody/no-such-model-xyz') is None


if __name__ == '__main__':
    import pytest
    sys.exit(pytest.main([__file__, '-q']))
