"""Test-suite guards for the Train pipeline.

Keeps a test run from writing into the real experiment store: experiment_db
resolves its path from ARO_TRAIN_DB when set, and a stage helper that records
as a side effect (config.save_notebook_pairs) would otherwise append rows to
Train/experiments.db every time the suite ran (GitLab #812).
"""
import os
import tempfile

_TMP = tempfile.TemporaryDirectory(prefix='aro-train-tests-')
os.environ.setdefault('ARO_TRAIN_DB', os.path.join(_TMP.name, 'experiments.db'))


# ── the binary-gated tests are selectable ────────────────────────────────────
# Seven files mark tests `skipif(aro_oracle.aro_bin() is None)`. That is the
# right behaviour for a slim image, but it made those tests assert nothing in
# CI, where no job had a binary — a test whose premise had gone stale failed
# only on developers' machines for a release (GitLab #900).
#
# Tagging them centrally rather than editing each file keeps the marker and
# the skip in one place, and means a new binary-gated test is selected by
# `-m needs_binary` as soon as it carries the usual skipif. The tag is read off
# the skip reason the files already share.
import pytest

_BINARY_SKIP_REASON = 'no `aro` binary available'


def pytest_configure(config):
    config.addinivalue_line(
        'markers',
        'needs_binary: needs a real `aro` binary; `train:oracle` runs these')


def pytest_collection_modifyitems(items):
    for item in items:
        for marker in item.iter_markers('skipif'):
            if marker.kwargs.get('reason') == _BINARY_SKIP_REASON:
                item.add_marker(pytest.mark.needs_binary)
                break
