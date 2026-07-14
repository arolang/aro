"""
Structured experiment tracking (issue #422).

Every training run (NB17 full fine-tune, NB18 preference pass, NB20 loop
rounds, NB21 distillation) records its configuration, metrics and artifact
paths into a local SQLite database at Train/experiments.db. This links the
per-run PNG/CSV/meta.json artifacts, making "which configuration achieved
the best val loss" a query instead of archaeology.

Optional Weights & Biases mirroring: when the WANDB_PROJECT environment
variable is set AND the `wandb` package is importable, each record_run()
also logs to W&B. Absence of either is silently fine — SQLite is the
source of truth.

Usage:
    from experiment_db import record_run, query_runs, best_run
    record_run('NB17', config={...}, metrics={'best_val_loss': 0.17},
               artifacts={'adapter': '/path/to/adapter'})
    best_run('best_val_loss', mode='min', notebook='NB17')
"""

import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path

DEFAULT_DB_PATH = Path(__file__).parent.parent / 'experiments.db'

_SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    notebook  TEXT NOT NULL,
    run_name  TEXT,
    config    TEXT NOT NULL,   -- JSON
    metrics   TEXT NOT NULL,   -- JSON
    artifacts TEXT NOT NULL    -- JSON
);
CREATE INDEX IF NOT EXISTS idx_runs_notebook ON runs (notebook);
"""


def _connect(db_path=None):
    db_path = Path(db_path or DEFAULT_DB_PATH)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.executescript(_SCHEMA)
    return conn


def _jsonable(obj):
    """Coerce config/metric values into JSON-safe types (Paths → str)."""
    if isinstance(obj, dict):
        return {str(k): _jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_jsonable(v) for v in obj]
    if isinstance(obj, Path):
        return str(obj)
    if isinstance(obj, (str, int, float, bool)) or obj is None:
        return obj
    return str(obj)


def record_run(notebook, config, metrics, artifacts=None, run_name=None,
               db_path=None):
    """Record one training/eval run. Returns the SQLite row id."""
    config = _jsonable(config or {})
    metrics = _jsonable(metrics or {})
    artifacts = _jsonable(artifacts or {})
    ts = datetime.now().isoformat(timespec='seconds')
    if run_name is None:
        run_name = f'{notebook}-{ts}'

    conn = _connect(db_path)
    try:
        cur = conn.execute(
            'INSERT INTO runs (timestamp, notebook, run_name, config, metrics, artifacts) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (ts, notebook, run_name, json.dumps(config), json.dumps(metrics),
             json.dumps(artifacts)),
        )
        conn.commit()
        run_id = cur.lastrowid
    finally:
        conn.close()

    _maybe_log_wandb(notebook, run_name, config, metrics)
    return run_id


def _maybe_log_wandb(notebook, run_name, config, metrics):
    """Mirror the run to Weights & Biases when configured; never raises."""
    project = os.environ.get('WANDB_PROJECT')
    if not project:
        return
    try:
        import wandb  # noqa: F401 — optional dependency
    except ImportError:
        return
    try:
        run = wandb.init(project=project, name=run_name,
                         config=dict(config, notebook=notebook),
                         reinit=True)
        # Only numeric/bool metrics are meaningful to W&B charts.
        numeric = {k: v for k, v in metrics.items()
                   if isinstance(v, (int, float, bool))}
        if numeric:
            run.log(numeric)
        run.finish()
    except Exception as e:  # W&B is best-effort — never break training
        print(f'[experiment_db] W&B logging failed (non-fatal): {e}')


def query_runs(notebook=None, limit=50, db_path=None):
    """Most recent runs (optionally filtered by notebook) as dicts."""
    conn = _connect(db_path)
    try:
        sql = ('SELECT id, timestamp, notebook, run_name, config, metrics, artifacts '
               'FROM runs')
        params = []
        if notebook:
            sql += ' WHERE notebook = ?'
            params.append(notebook)
        sql += ' ORDER BY id DESC LIMIT ?'
        params.append(limit)
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()
    out = []
    for rid, ts, nb, name, cfg, met, art in rows:
        out.append({
            'id': rid, 'timestamp': ts, 'notebook': nb, 'run_name': name,
            'config': json.loads(cfg), 'metrics': json.loads(met),
            'artifacts': json.loads(art),
        })
    return out


def best_run(metric, mode='min', notebook=None, db_path=None):
    """Run with the best value of `metric` ('min' or 'max'). None if no run
    has that metric."""
    runs = query_runs(notebook=notebook, limit=10_000, db_path=db_path)
    scored = [(r['metrics'][metric], r) for r in runs
              if isinstance(r['metrics'].get(metric), (int, float))]
    if not scored:
        return None
    scored.sort(key=lambda x: x[0], reverse=(mode == 'max'))
    return scored[0][1]
