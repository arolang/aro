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
