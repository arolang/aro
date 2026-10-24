"""
Unit tests for the generation heartbeat in config.py.

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_generation_heartbeat.py

The pipeline kills a stage that prints nothing for too long, and the data
notebooks loop over one LLM call per item for hours. The heartbeat speaks
while tokens are arriving, and only then, so a stalled generation is still
caught.
"""

import sys
import types
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _fake_mlx(monkeypatch, tokens):
    module = types.ModuleType('mlx_lm.generate')
    module.stream_generate = lambda *a, **k: iter(range(tokens))
    monkeypatch.setitem(sys.modules, 'mlx_lm.generate', module)
    return module


def test_it_reports_while_tokens_arrive(monkeypatch, capsys):
    module = _fake_mlx(monkeypatch, tokens=3)
    monkeypatch.setattr(config, 'GENERATION_HEARTBEAT_SECONDS', 1e-9)
    config._install_generation_heartbeat()
    assert list(module.stream_generate()) == [0, 1, 2]
    assert '[llm] generating' in capsys.readouterr().out


def test_it_is_silent_when_no_tokens_arrive(monkeypatch, capsys):
    module = _fake_mlx(monkeypatch, tokens=0)
    monkeypatch.setattr(config, 'GENERATION_HEARTBEAT_SECONDS', 1e-9)
    config._install_generation_heartbeat()
    assert list(module.stream_generate()) == []
    assert capsys.readouterr().out == ''


def test_reloading_config_does_not_wrap_twice(monkeypatch):
    module = _fake_mlx(monkeypatch, tokens=1)
    config._install_generation_heartbeat()
    wrapped = module.stream_generate
    config._install_generation_heartbeat()
    assert module.stream_generate is wrapped


if __name__ == '__main__':
    import pytest
    sys.exit(pytest.main([__file__, '-q']))
