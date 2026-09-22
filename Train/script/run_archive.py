"""Archive the describable part of a pipeline run into Train/runs/<release>/.

GitLab #792. `data/`, `models/` and `release/` are gitignored and fully
regenerated — correctly so, they are gigabytes of weights. The consequence was
that a finished run left nothing behind in the repository: the released model
could not be traced to the dataset that produced it, the caps that shaped that
dataset, the gate it passed, or the code it was trained by.

This script copies the small, text-shaped summaries — never weights — into a
tracked, versioned directory, and writes `run.json` beside them recording what
was collected, what was missing, the pipeline and ARO versions, and the git
commit of each corpus root. Everything it copies is a few hundred KB at most.

    python3 Train/script/run_archive.py                       # archive current
    python3 Train/script/run_archive.py --release 2026.09.1
    python3 Train/script/run_archive.py --check               # verify an archive
    python3 Train/script/run_archive.py --dry-run             # say what it would do

`--check` re-hashes every archived file against `run.json`, so a hand-edited
summary is caught rather than believed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config  # noqa: E402  — path is set up immediately above


# What a run is expected to leave behind, as (source path, archived name,
# required?). A missing optional artifact is recorded, not an error: not every
# run distils, and not every run reaches the gate.
def artifact_plan(cfg=config):
    data = cfg.DATA_ROOT
    return [
        (data / '05_dataset' / 'stats.json',          'stats.json',            True),
        (data / '05_dataset' / 'dataset_report.md',   'dataset_report.md',     True),
        (data / '05_dataset' / 'drop_reasons.csv',    'drop_reasons.csv',      False),
        (data / '02_knowledge' / 'manifest.json',     'corpus_manifest.json',  False),
        (cfg.MODELS_DIR / 'loop_metrics.json',        'loop_metrics.json',     False),
        (cfg.RELEASE_DIR / 'promotion_gate.json',     'promotion_gate.json',   False),
        (cfg.RELEASE_DIR / 'model_manifest.json',     'model_manifest.json',   False),
        (cfg.RELEASE_DIR / 'version_history.json',    'version_history.json',  False),
    ]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _git_commit(path: Path) -> str | None:
    try:
        out = subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None


def _package_versions() -> dict:
    """Versions of the packages that decide what a run produces."""
    versions = {'python': sys.version.split()[0]}
    for name in ('mlx', 'mlx_lm', 'transformers', 'numpy'):
        try:
            import importlib.metadata as md
            versions[name] = md.version(name.replace('_', '-'))
        except Exception:                      # not installed on this host
            versions[name] = None
    return versions


def _aro_version(cfg=config) -> str | None:
    try:
        out = subprocess.run(['aro', '--version'], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return (out.stdout or out.stderr).strip() or None


def archive(release=None, dry_run=False, cfg=config, plan=None):
    """Copy this run's summaries into Train/runs/<release>/. Returns run.json."""
    dest = cfg.run_archive_dir(release)
    plan = plan if plan is not None else artifact_plan(cfg)

    collected, missing = [], []
    for src, name, required in plan:
        src = Path(src)
        if not src.is_file():
            missing.append({'artifact': name, 'expected_at': str(src),
                            'required': required})
            continue
        entry = {'artifact': name, 'source': str(src),
                 'bytes': src.stat().st_size, 'sha256': sha256(src)}
        collected.append(entry)
        if not dry_run:
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest / name)

    manifest = {
        'release':          str(release or cfg.run_archive_dir(release).name),
        'archived_at':      datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'pipeline_version': cfg.PIPELINE_VERSION,
        'type_caps_version': cfg.TYPE_CAPS_VERSION,
        'session_id':       cfg.SESSION_ID,
        'aro_version':      _aro_version(cfg),
        'packages':         _package_versions(),
        'commits': {
            'ARO-Lang':        _git_commit(cfg.ARO_ROOT),
            'ARO-Application': _git_commit(cfg.ARO_APPLICATION_ROOT),
        },
        'artifacts': collected,
        'missing':   missing,
    }

    if not dry_run:
        dest.mkdir(parents=True, exist_ok=True)
        (dest / 'run.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def check(release=None, cfg=config):
    """Verify an archive against its own run.json. Returns list of problems."""
    dest = cfg.run_archive_dir(release)
    manifest_path = dest / 'run.json'
    if not manifest_path.is_file():
        return [f'no archive at {dest} (run.json missing)']
    manifest = json.loads(manifest_path.read_text())
    problems = []
    for entry in manifest.get('artifacts', []):
        path = dest / entry['artifact']
        if not path.is_file():
            problems.append(f'{entry["artifact"]}: archived file is gone')
            continue
        if sha256(path) != entry['sha256']:
            problems.append(f'{entry["artifact"]}: sha256 does not match run.json')
    for entry in manifest.get('missing', []):
        if entry.get('required'):
            problems.append(f'{entry["artifact"]}: required artifact was never archived')
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--release', default=None,
                    help='release label (default: ARO_TRAIN_RELEASE, else PIPELINE_VERSION)')
    ap.add_argument('--check', action='store_true',
                    help='verify an existing archive instead of writing one')
    ap.add_argument('--dry-run', action='store_true',
                    help='report what would be archived without writing')
    args = ap.parse_args(argv)

    if args.check:
        problems = check(args.release)
        if problems:
            print(f'Archive {config.run_archive_dir(args.release)} FAILED:')
            for p in problems:
                print(f'  - {p}')
            return 1
        print(f'Archive {config.run_archive_dir(args.release)} OK')
        return 0

    manifest = archive(args.release, dry_run=args.dry_run)
    where = config.run_archive_dir(args.release)
    verb = 'would archive' if args.dry_run else 'archived'
    print(f'{verb} {len(manifest["artifacts"])} artifact(s) into {where}')
    for entry in manifest['artifacts']:
        print(f'  + {entry["artifact"]:<24} {entry["bytes"]:>9,} bytes')
    for entry in manifest['missing']:
        mark = 'MISSING (required)' if entry['required'] else 'absent (optional)'
        print(f'  - {entry["artifact"]:<24} {mark}: {entry["expected_at"]}')
    required_missing = [m for m in manifest['missing'] if m['required']]
    if required_missing and not args.dry_run:
        print('\nThe run is not fully describable: a required artifact is missing.')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
