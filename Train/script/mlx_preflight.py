"""Fail fast when the installed mlx cannot LoRA-train a mixture-of-experts model.

GitLab #793. `ISSUE-MLX.md` records the crash: LoRA on
`Qwen3-Coder-30B-A3B-Instruct` dies inside the first validation pass with

    RuntimeError: [metal::Device] Unable to load function
    steel_gather_mm_rhs_nax_nt_float32_float32_bm64_bn128_bk128_wm2_wn4

because mlx's shipped metallib instantiated the `rhs_nax` gather kernels only
for float16 and bfloat16. Dense models never call `gather_mm`, so everything
looked fine until the teacher — the one model the pipeline exists to train —
was reached, hours into a run.

The workaround was building mlx from source with a one-line patch. Nothing
installed that build and nothing checked for it, while `pip install --upgrade`
in training.sh was free to replace it with a stock wheel.

**The situation has moved on**: the float32 instantiation is present in the
metallib shipped with mlx 0.32.2, which is why requirements.txt now floors mlx
there rather than pinning a private build. But a floor is a claim about a
version string, and the thing that actually matters is whether the kernel is in
the metallib this interpreter will load — a downgrade, a cached wheel, a second
venv or a hand-built mlx can each make the version and the metallib disagree.
So this preflight looks in the metallib.

    python3 Train/script/mlx_preflight.py            # ~1s, no GPU work
    python3 Train/script/mlx_preflight.py --lora     # + one real LoRA iteration
    python3 Train/script/mlx_preflight.py --json     # machine-readable

Exit status is 0 when training can proceed, 1 when it cannot, and 2 when the
check could not be performed (not Apple Silicon, mlx not installed) — CI and
Linux hosts treat 2 as "not applicable".
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ISSUE_DOC = 'Train/ISSUE-MLX.md'

# The kernel family whose float32 instantiation was missing. Matching the
# family prefix rather than one full name keeps the check valid across the tile
# shapes mlx picks for different GPUs — the traceback named bm64_bn128_bk128,
# but a different device asks for a different tile of the same family.
KERNEL_FAMILY = b'steel_gather_mm_rhs_nax'
KERNEL_DTYPE = b'float32_float32'

# The version the crash was reported against was 0.31.1. Both mlx installs
# reachable on the machine this was written on — 0.31.2 and 0.32.2 — already
# ship the float32 instantiation, so the fix landed upstream within a patch
# release of the report. KERNEL_FIXED_IN is therefore the correctness floor;
# REQUIREMENTS_FLOOR is the stricter version requirements.txt asks for because
# that is the one the lock file records and the last release trained with.
# Below the correctness floor is a failure. Between the two, with the kernel
# actually present, is a warning: the run will work, but it is not the
# environment the release was built in.
KERNEL_FIXED_IN = (0, 31, 2)
REQUIREMENTS_FLOOR = (0, 32, 2)

# Small MoE model used by --lora. Same architecture family as the teacher, so it
# routes through gather_mm, but it is a download rather than a 60 GB one.
SMOKE_MODEL = 'mlx-community/Qwen3-30B-A3B-4bit'


class Unavailable(RuntimeError):
    """The check cannot be performed on this host (not a failure)."""


def _parse_version(text):
    parts = []
    for chunk in str(text).split('.')[:3]:
        # Leading digits only: '0rc1' is release 0, not 01.
        digits = ''
        for c in chunk:
            if not c.isdigit():
                break
            digits += c
        parts.append(int(digits) if digits else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def mlx_version():
    try:
        import importlib.metadata as md
        return md.version('mlx')
    except Exception as exc:                      # not installed
        raise Unavailable(f'mlx is not installed ({exc})') from exc


def metallib_path():
    """Path to the metallib the installed mlx will load."""
    try:
        import mlx  # noqa: F401 — imported for its package location only
    except Exception as exc:
        raise Unavailable(f'mlx cannot be imported ({exc})') from exc
    # A namespace package has __file__ = None; mlx installed as a wheel does
    # not, but a stray empty `mlx/` directory on sys.path is enough to produce
    # one, and that must read as "cannot tell", never as "broken".
    roots = []
    if getattr(mlx, '__file__', None):
        roots.append(Path(mlx.__file__).resolve().parent)
    roots.extend(Path(p).resolve() for p in getattr(mlx, '__path__', []))

    for root in roots:
        candidates = sorted(root.glob('lib/*.metallib')) + sorted(root.glob('*.metallib'))
        if candidates:
            return candidates[0]
    raise Unavailable('no .metallib found under ' +
                      (', '.join(str(r) for r in roots) or 'the mlx package'))


def kernel_variants(path: Path):
    """Dtype suffixes the gather kernels were instantiated for."""
    blob = path.read_bytes()
    found = set()
    start = 0
    while True:
        i = blob.find(KERNEL_FAMILY, start)
        if i < 0:
            break
        window = blob[i:i + 120]
        for dtype in (b'float32_float32', b'float16_float16', b'bfloat16_bfloat16'):
            if dtype in window:
                found.add(dtype.decode().split('_')[0])
        start = i + 1
    return found


def check_kernel():
    """(ok, detail). ok False means LoRA on a MoE teacher will crash."""
    path = metallib_path()
    variants = kernel_variants(path)
    if not variants:
        # No gather kernels at all: either a very old mlx or a metallib we do
        # not understand. Do not claim it is broken; say we could not tell.
        raise Unavailable(f'no {KERNEL_FAMILY.decode()} kernels found in {path} — '
                          'cannot tell whether MoE LoRA will work')
    return ('float32' in variants), {
        'metallib': str(path),
        'gather_kernel_dtypes': sorted(variants),
    }


def lora_smoke_test(model=SMOKE_MODEL, timeout=1800):
    """One real LoRA iteration on a MoE model. Returns (ok, detail)."""
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        sample = {'messages': [{'role': 'user', 'content': 'Hello'},
                               {'role': 'assistant', 'content': 'World'}]}
        for name in ('train.jsonl', 'valid.jsonl'):
            (d / name).write_text(json.dumps(sample) + '\n')
        cmd = [sys.executable, '-m', 'mlx_lm', 'lora',
               '--model', model, '--data', str(d), '--train',
               '--num-layers', '4', '--iters', '1', '--batch-size', '1',
               '--val-batches', '1', '--adapter-path', str(d / 'adapter')]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=timeout, cwd=str(d))
        except subprocess.TimeoutExpired:
            return False, {'lora_smoke': 'timeout', 'model': model}
        except OSError as exc:
            raise Unavailable(f'could not run mlx_lm ({exc})') from exc
        tail = (proc.stdout + proc.stderr).strip().splitlines()[-8:]
        return proc.returncode == 0, {'lora_smoke': 'ok' if proc.returncode == 0
                                      else 'failed',
                                      'model': model,
                                      'output_tail': tail}


def preflight(run_lora=False):
    """Run the checks. Returns a report dict; raises Unavailable when N/A."""
    if platform.system() != 'Darwin':
        raise Unavailable(f'mlx is Apple-Silicon only; this host is {platform.system()}')

    version = mlx_version()
    report = {'mlx_version': version, 'machine': platform.machine(),
              'checks': {}, 'ok': True, 'reasons': [], 'warnings': []}

    parsed = _parse_version(version)
    if parsed < KERNEL_FIXED_IN:
        report['ok'] = False
        report['reasons'].append(
            f'mlx {version} predates {".".join(map(str, KERNEL_FIXED_IN))}, the '
            'first release shipping the float32 gather kernel')
    elif parsed < REQUIREMENTS_FLOOR:
        report['warnings'].append(
            f'mlx {version} is below the {".".join(map(str, REQUIREMENTS_FLOOR))} '
            'floor in Train/requirements.txt — the kernel is there, but this is '
            'not the version the lock file records')

    kernel_ok, detail = check_kernel()
    report['checks']['gather_kernel'] = detail
    if not kernel_ok:
        report['ok'] = False
        report['reasons'].append(
            'the installed metallib has no float32 steel_gather_mm_rhs_nax kernel — '
            'LoRA on the MoE teacher will crash in its first validation pass')

    if run_lora:
        lora_ok, detail = lora_smoke_test()
        report['checks']['lora'] = detail
        if not lora_ok:
            report['ok'] = False
            report['reasons'].append('a one-iteration LoRA run on a MoE model failed')

    return report


def _record(report):
    """Record the mlx version with the run, so an archive says what trained it."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from experiment_db import record_run
        record_run('preflight',
                   config={'mlx_version': report.get('mlx_version'),
                           'machine': report.get('machine')},
                   metrics={'ok': bool(report.get('ok'))},
                   artifacts=report.get('checks', {}))
    except Exception as exc:                      # never block a run on bookkeeping
        print(f'[mlx_preflight] could not record to experiments.db: {exc}',
              file=sys.stderr)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--lora', action='store_true',
                    help=f'also run one LoRA iteration on {SMOKE_MODEL} (downloads it)')
    ap.add_argument('--json', action='store_true', help='emit the report as JSON')
    ap.add_argument('--no-record', action='store_true',
                    help='skip writing the result to experiments.db')
    args = ap.parse_args(argv)

    try:
        report = preflight(run_lora=args.lora)
    except Unavailable as exc:
        if args.json:
            print(json.dumps({'ok': None, 'unavailable': str(exc)}, indent=2))
        else:
            print(f'mlx preflight: not applicable — {exc}')
        return 2

    if not args.no_record:
        _record(report)

    if args.json:
        print(json.dumps(report, indent=2))
    elif report['ok']:
        dtypes = ', '.join(report['checks']['gather_kernel']['gather_kernel_dtypes'])
        print(f'mlx preflight OK — mlx {report["mlx_version"]}, '
              f'gather kernels: {dtypes}')
        if args.lora:
            print(f'  one LoRA iteration on {SMOKE_MODEL}: ok')
        for warning in report['warnings']:
            print(f'  warning: {warning}')
    else:
        print(f'mlx preflight FAILED — mlx {report["mlx_version"]}')
        for reason in report['reasons']:
            print(f'  - {reason}')
        print(f'\nThis is the crash documented in {ISSUE_DOC}. Training the MoE '
              'teacher will not work with this build.')
        print('Fix: Train/.venv/bin/pip install -U "mlx>=0.32.2" "mlx-metal>=0.32.2"')
        print(f'     — or build mlx from source with the patch in {ISSUE_DOC}.')
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
