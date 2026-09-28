"""Shared stage plumbing: uniform `--dry-run` / `--limit`, and a notebook
executor that cannot hang forever.

GitLab #803. Two problems, one module.

**Stages could not be smoke-tested.** Each script stage grew its own flags, so
`--dry-run` meant something slightly different in each and `--limit` existed in
exactly one. There was no way to ask the pipeline "run the data path over three
items and tell me it works", which is the only kind of run CI can afford. The
options here are the same everywhere, and notebooks read them from the
environment (`ARO_TRAIN_DRY_RUN`, `ARO_TRAIN_LIMIT`) so a notebook stage answers
to the same switches as a script stage.

**A hung stage blocked forever.** The meta pipeline set every timeout to 0 —
nbconvert `-1`, subprocess `None` — because the long stages legitimately run for
hours and a wall-clock cap kept killing healthy training runs. The result was
that an actually-wedged stage (a model download stalled behind a dead
connection, a prompt waiting on stdin nobody will type) blocked the pipeline
until someone noticed, which on a multi-day run could be the next morning.

A wall clock is the wrong instrument. What separates a healthy 6-hour fine-tune
from a wedged one is not elapsed time, it is whether anything is still being
written. `run_notebook()` therefore watches the stage's log: the stage is killed
when the log stops growing for `stall_timeout` seconds (default 30 minutes),
however long it has been running. A hard `max_runtime` remains available per
stage for the few where one makes sense, and defaults to off.

That only works if the log actually reflects the stage. It did not: stages ran
under `jupyter nbconvert --execute`, which puts cell output in the output
notebook and prints nothing itself, so every log froze a second in and every
stage outliving the stall window was killed as wedged. Stages now run through
`nb_exec.py`, which streams cell output as the kernel emits it.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

DEFAULT_STALL_TIMEOUT = 30 * 60       # seconds of silence before a stage is wedged
POLL_INTERVAL = 5.0                   # how often the watchdog looks at the log
NB_EXEC = Path(__file__).with_name('nb_exec.py')   # the streaming notebook runner
_ANSI = re.compile(r'\x1b\[[0-9;]*m')     # kernel tracebacks arrive coloured


# ── Uniform stage options ───────────────────────────────────────────────────

@dataclass(frozen=True)
class StageOptions:
    """What every stage understands, however it is invoked."""

    dry_run: bool = False
    limit: int = 0                    # 0 = no limit

    @classmethod
    def from_args(cls, args):
        return cls(dry_run=bool(getattr(args, 'dry_run', False)),
                   limit=int(getattr(args, 'limit', 0) or 0))

    @classmethod
    def from_env(cls, env=None):
        """For notebook stages, which have no command line of their own."""
        env = os.environ if env is None else env
        truthy = {'1', 'true', 'yes', 'on'}
        raw_limit = (env.get('ARO_TRAIN_LIMIT') or '0').strip()
        try:
            limit = int(raw_limit)
        except ValueError:
            limit = 0
        return cls(
            dry_run=(env.get('ARO_TRAIN_DRY_RUN', '').strip().lower() in truthy),
            limit=max(0, limit),
        )

    def apply(self, items):
        """Truncate a sequence to --limit. `limit=0` means everything."""
        if self.limit <= 0:
            return items
        return list(items)[:self.limit]

    def describe(self):
        parts = []
        if self.dry_run:
            parts.append('dry-run')
        if self.limit:
            parts.append(f'limit={self.limit}')
        return ', '.join(parts) or 'full run'


def add_stage_arguments(parser):
    """Add the options every stage shares. Returns the parser."""
    parser.add_argument('--dry-run', action='store_true',
                        help='run the whole data path but save nothing')
    parser.add_argument('--limit', type=int, default=0, metavar='N',
                        help='stop after N items (0 = no limit). With --dry-run '
                             'this is the smoke test CI runs.')
    return parser


# ── Notebook executor with a stall watchdog ─────────────────────────────────

def _log_fingerprint(path: Path):
    try:
        st = path.stat()
    except OSError:
        return (0, 0.0)
    return (st.st_size, st.st_mtime)


def _signal_group(proc, sig):
    """Best-effort signal to the stage's whole process group (runner + kernel).

    Never fatal: the group may already be gone, and under test `proc` is a
    stand-in with no pid at all.
    """
    pid = getattr(proc, 'pid', None)
    if not pid:
        return
    try:
        os.killpg(os.getpgid(pid), sig)
    except (ProcessLookupError, PermissionError, OSError):
        pass


def run_notebook(name, script_dir, output_dir, kernel_name,
                 stall_timeout=DEFAULT_STALL_TIMEOUT, max_runtime=0,
                 python=None, poll_interval=POLL_INTERVAL, _clock=time.time,
                 _sleep=time.sleep, _popen=subprocess.Popen):
    """Execute `<name>.ipynb` via nb_exec, killing it only when it goes quiet.

    Returns a dict: {'status': 'done'|'failed'|'stalled'|'timeout'|'missing',
                     'error': str|None, 'duration': float, 'log': str}.

    `stall_timeout` is seconds without the log growing. `max_runtime` is a hard
    cap in seconds, 0 for none — the default, because the stages that run for
    hours are doing their job.
    """
    src = Path(script_dir) / f'{name}.ipynb'
    dest = Path(output_dir) / f'{name}.ipynb'
    log_file = Path(output_dir) / f'{name}.log'

    if not src.is_file():
        return {'status': 'missing', 'error': f'file not found: {src.name}',
                'duration': 0.0, 'log': str(log_file)}
    if kernel_name is None:
        return {'status': 'failed',
                'error': 'no Python kernel available — run the setup cell first',
                'duration': 0.0, 'log': str(log_file)}

    # `-u` plus nb_exec's own flushing is what makes the log grow while the
    # stage runs. Under `jupyter nbconvert --execute` it did not: cell output
    # went into the output notebook and nbconvert's own stdout was three lines,
    # so the watchdog below saw a frozen log for every healthy long stage and
    # killed it at the stall timeout. See nb_exec.py.
    cmd = [python or sys.executable, '-u', str(NB_EXEC),
           str(src), '--output', str(dest), '--kernel', kernel_name]

    started = _clock()
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    with open(log_file, 'w') as log:
        # Own session: a stalled stage is a runner plus a kernel holding the
        # model, and terminating only the runner leaves the kernel with the
        # memory the next stage needs. Killing the group takes both down.
        proc = _popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                      start_new_session=True)

        last_change = _clock()
        fingerprint = _log_fingerprint(log_file)
        status = None
        while True:
            if proc.poll() is not None:
                break
            _sleep(poll_interval)
            now = _clock()

            current = _log_fingerprint(log_file)
            if current != fingerprint:
                fingerprint, last_change = current, now

            if stall_timeout and (now - last_change) > stall_timeout:
                status = 'stalled'
                break
            if max_runtime and (now - started) > max_runtime:
                status = 'timeout'
                break

        if status is not None:
            _signal_group(proc, signal.SIGTERM)
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                _signal_group(proc, signal.SIGKILL)
                proc.kill()
                proc.wait()

    duration = _clock() - started
    if status == 'stalled':
        minutes = int(stall_timeout // 60)
        return {'status': 'stalled', 'duration': duration, 'log': str(log_file),
                'error': (f'no output for {minutes} min — killed. The stage was '
                          f'running for {duration / 60:.0f} min; see the log for '
                          'where it stopped.')}
    if status == 'timeout':
        return {'status': 'timeout', 'duration': duration, 'log': str(log_file),
                'error': f'exceeded the {max_runtime}s hard cap for this stage'}

    if proc.returncode != 0:
        return {'status': 'failed', 'duration': duration, 'log': str(log_file),
                'error': last_error_line(log_file)}
    return {'status': 'done', 'duration': duration, 'log': str(log_file),
            'error': None}


def last_error_line(log_file, default='see log'):
    """The most useful one-line summary of a failure from a stage log."""
    try:
        lines = Path(log_file).read_text(errors='replace').splitlines()
    except OSError:
        return default
    for line in reversed(lines):
        stripped = line.strip()
        if not stripped:
            continue
        # The runner prints the raised exception last; anything else is noise.
        if stripped.startswith(('[NbConvertApp]', '[nb_exec] executing',
                               '[nb_exec] wrote', 'Traceback')):
            continue
        if stripped.startswith('[nb_exec] FAILED: '):
            stripped = stripped[len('[nb_exec] FAILED: '):]
        return _ANSI.sub('', stripped)[:200]
    return default
