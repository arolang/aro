"""Structured experiment tracking for every stage of a pipeline run.

Originally issue #422: link each training run's configuration, metrics and
artifact paths so that "which configuration achieved the best val loss" is a
query instead of archaeology.

Extended for GitLab #812. Two things were wrong with it.

**Only four stages logged.** The database held rows from NB17, NB18, NB19 and
NB20 — the SFT pass, the preference pass and the evaluation — and nothing at
all from the warm start, the distillation, the boosters, packaging, or any of
the data stages. The data stages are the ones that decide what the model learns,
so the half of the pipeline whose decisions are hardest to reconstruct was the
half that recorded nothing. Every stage now records: the training stages
explicitly, and every data stage automatically, because
`config.save_notebook_pairs()` is the single funnel they all write pairs
through and it records the row count, the tag, the ARO version and the session
as a side effect of saving.

**The record was an untracked binary.** A SQLite file that is gitignored is not
a record of anything the repository can show you — it lived on one laptop, it
does not diff, and a review cannot read it. The database stays where it is and
stays gitignored (it is the working store, and binary), but `export_csv()`
writes a flat, sorted, diffable CSV into `Train/runs/<release>/`, and THAT is
what is committed. One row per stage-run, stable column order, so two runs can
be compared with `diff`.

    python3 Train/script/experiment_db.py --export --release 2026.09
    python3 Train/script/experiment_db.py --list
    python3 Train/script/experiment_db.py --list --stage NB17

Optional Weights & Biases mirroring: when the WANDB_PROJECT environment
variable is set AND the `wandb` package is importable, each record_run() also
logs to W&B. Absence of either is silently fine — SQLite is the source of truth.
"""

import argparse
import csv
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# ARO_TRAIN_DB redirects the store — used by the tests so a test run cannot
# write into the real one, and available to anyone wanting a scratch database.
DEFAULT_DB_PATH = Path(os.environ.get('ARO_TRAIN_DB')
                       or Path(__file__).parent.parent / 'experiments.db')

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

# Columns added for #812. Applied with ALTER TABLE so an existing database —
# including the one holding the September run's 22 rows — is upgraded rather
# than abandoned. Order matters only for readability of the CSV.
_ADDED_COLUMNS = (
    ('session_id',       'TEXT'),   # joins every stage of one pipeline run
    ('pipeline_version', 'TEXT'),
    ('hparams_version',  'TEXT'),
    ('aro_version',      'TEXT'),
    ('rows_in',          'INTEGER'),
    ('rows_out',         'INTEGER'),
    ('drop_reasons',     'TEXT'),   # JSON {reason: count}
)

CSV_COLUMNS = (
    'id', 'timestamp', 'session_id', 'notebook', 'run_name',
    'pipeline_version', 'hparams_version', 'aro_version',
    'rows_in', 'rows_out', 'drop_reasons', 'config', 'metrics', 'artifacts',
)


def _connect(db_path=None):
    db_path = Path(db_path or DEFAULT_DB_PATH)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.executescript(_SCHEMA)
    existing = {row[1] for row in conn.execute('PRAGMA table_info(runs)')}
    for name, decl in _ADDED_COLUMNS:
        if name not in existing:
            conn.execute(f'ALTER TABLE runs ADD COLUMN {name} {decl}')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_runs_session '
                 'ON runs (session_id)')
    conn.commit()
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


_ARO_VERSION = None


def aro_version():
    """`aro --version`, resolved once. None when there is no binary."""
    global _ARO_VERSION
    if _ARO_VERSION is None:
        binary = os.environ.get('ARO_BIN', 'aro')
        try:
            out = subprocess.run([binary, '--version'], capture_output=True,
                                 text=True, timeout=10)
            _ARO_VERSION = (out.stdout or out.stderr).strip() or ''
        except (OSError, subprocess.SubprocessError):
            _ARO_VERSION = ''
    return _ARO_VERSION or None


def _pipeline_identity():
    """(session_id, pipeline_version) from config, without importing it eagerly."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import config
        return (config.SESSION_ID, config.PIPELINE_VERSION,
                getattr(config, 'HPARAMS_VERSION', None))
    except Exception:
        # Importing config runs model resolution; a caller that cannot afford
        # that (or a test with a stubbed environment) still gets a usable row.
        return (os.environ.get('ARO_TRAIN_SESSION'), None, None)


def record_run(notebook, config=None, metrics=None, artifacts=None,
               run_name=None, db_path=None, session_id=None,
               rows_in=None, rows_out=None, drop_reasons=None):
    """Record one stage of a run. Returns the SQLite row id.

    `notebook` is the stage tag — 'NB17', 'NB32', 'package', 'preflight'.
    Everything but the tag is optional, because a data stage has row counts
    where a training stage has losses and both belong in the same table.
    """
    config = _jsonable(config or {})
    metrics = _jsonable(metrics or {})
    artifacts = _jsonable(artifacts or {})
    drop_reasons = _jsonable(drop_reasons or {})
    ts = datetime.now().isoformat(timespec='seconds')
    if run_name is None:
        run_name = f'{notebook}-{ts}'

    ident_session, pipeline_version, hparams_version = _pipeline_identity()
    session_id = session_id or ident_session

    conn = _connect(db_path)
    try:
        cur = conn.execute(
            'INSERT INTO runs (timestamp, notebook, run_name, config, metrics, '
            'artifacts, session_id, pipeline_version, hparams_version, '
            'aro_version, rows_in, rows_out, drop_reasons) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            (ts, notebook, run_name, json.dumps(config), json.dumps(metrics),
             json.dumps(artifacts), session_id, pipeline_version,
             hparams_version, aro_version(), rows_in, rows_out,
             json.dumps(drop_reasons)),
        )
        conn.commit()
        run_id = cur.lastrowid
    finally:
        conn.close()

    _maybe_log_wandb(notebook, run_name, config, metrics)
    return run_id


def record_data_stage(notebook, rows_in, rows_out, drop_reasons=None,
                      artifacts=None, db_path=None, session_id=None, **config):
    """Record a data stage: how many rows went in, how many survived, why not.

    The data stages decide what the model is trained on, and none of them used
    to record anything (GitLab #812).
    """
    return record_run(notebook,
                      config=config,
                      metrics={'rows_in': rows_in, 'rows_out': rows_out,
                               'retention': (rows_out / rows_in) if rows_in else None},
                      artifacts=artifacts, db_path=db_path,
                      session_id=session_id,
                      rows_in=rows_in, rows_out=rows_out,
                      drop_reasons=drop_reasons)


def record_funnel(notebook, funnel, artifacts=None, db_path=None, **config):
    """Record a config.FunnelCounter: first stage in, last stage out, all
    drop reasons merged."""
    stages = getattr(funnel, 'stages', []) or []
    rows_in = stages[0]['before'] if stages else 0
    rows_out = stages[-1]['after'] if stages else 0
    reasons = {}
    for stage in stages:
        for reason, count in stage.get('reasons', {}).items():
            reasons[f"{stage['stage']}:{reason}"] = count
    return record_data_stage(notebook, rows_in, rows_out, drop_reasons=reasons,
                             artifacts=artifacts, db_path=db_path,
                             funnel=getattr(funnel, 'name', None), **config)


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


def query_runs(notebook=None, limit=50, db_path=None, session_id=None):
    """Most recent runs (optionally filtered) as dicts."""
    conn = _connect(db_path)
    try:
        columns = ('id, timestamp, notebook, run_name, config, metrics, '
                   'artifacts, session_id, pipeline_version, hparams_version, '
                   'aro_version, rows_in, rows_out, drop_reasons')
        sql = f'SELECT {columns} FROM runs'
        where, params = [], []
        if notebook:
            where.append('notebook = ?')
            params.append(notebook)
        if session_id:
            where.append('session_id = ?')
            params.append(session_id)
        if where:
            sql += ' WHERE ' + ' AND '.join(where)
        sql += ' ORDER BY id DESC LIMIT ?'
        params.append(limit)
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()

    out = []
    for row in rows:
        (rid, ts, nb, name, cfg, met, art, session, pipeline, hparams,
         aro, rows_in, rows_out, reasons) = row
        out.append({
            'id': rid, 'timestamp': ts, 'notebook': nb, 'run_name': name,
            'config': json.loads(cfg), 'metrics': json.loads(met),
            'artifacts': json.loads(art),
            'session_id': session, 'pipeline_version': pipeline,
            'hparams_version': hparams, 'aro_version': aro,
            'rows_in': rows_in, 'rows_out': rows_out,
            'drop_reasons': json.loads(reasons) if reasons else {},
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


def export_csv(path, db_path=None, session_id=None):
    """Write every run to a flat, sorted CSV. Returns (path, row count).

    This is the committed record (GitLab #812). Column order is fixed and rows
    are ordered by id, so two runs diff cleanly; the JSON columns are dumped
    with sorted keys for the same reason.
    """
    runs = sorted(query_runs(limit=1_000_000, db_path=db_path,
                             session_id=session_id),
                  key=lambda r: r['id'])
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', newline='') as fh:
        writer = csv.writer(fh)
        writer.writerow(CSV_COLUMNS)
        for run in runs:
            writer.writerow([
                run['id'], run['timestamp'], run['session_id'] or '',
                run['notebook'], run['run_name'] or '',
                run['pipeline_version'] or '', run['hparams_version'] or '',
                run['aro_version'] or '',
                '' if run['rows_in'] is None else run['rows_in'],
                '' if run['rows_out'] is None else run['rows_out'],
                json.dumps(run['drop_reasons'], sort_keys=True),
                json.dumps(run['config'], sort_keys=True),
                json.dumps(run['metrics'], sort_keys=True),
                json.dumps(run['artifacts'], sort_keys=True),
            ])
    return path, len(runs)


def _default_export_path(release=None):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import config
    return config.run_archive_dir(release) / 'experiments.csv'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--export', action='store_true',
                    help='write the committed CSV into Train/runs/<release>/')
    ap.add_argument('--release', default=None, help='release label for --export')
    ap.add_argument('--out', default=None, help='explicit CSV path for --export')
    ap.add_argument('--list', action='store_true', help='print recent runs')
    ap.add_argument('--stage', default=None, help='filter --list by stage tag')
    ap.add_argument('--session', default=None, help='filter by session id')
    ap.add_argument('--db', default=None, help='database path')
    args = ap.parse_args(argv)

    if args.export:
        out = Path(args.out) if args.out else _default_export_path(args.release)
        path, count = export_csv(out, db_path=args.db, session_id=args.session)
        print(f'wrote {count} run(s) to {path}')
        return 0

    runs = query_runs(notebook=args.stage, limit=50, db_path=args.db,
                      session_id=args.session)
    if not runs:
        print('no runs recorded')
        return 0
    print(f'{"id":>4}  {"timestamp":<19}  {"stage":<14}  {"rows":>9}  session')
    for run in runs:
        rows = ('—' if run['rows_out'] is None
                else f"{run['rows_in'] or 0}→{run['rows_out']}")
        print(f'{run["id"]:>4}  {run["timestamp"]:<19}  {run["notebook"]:<14}  '
              f'{rows:>9}  {run["session_id"] or "—"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
