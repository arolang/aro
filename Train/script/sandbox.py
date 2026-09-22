"""Run generated ARO programs somewhere they cannot write into the repository.

GitLab #804. The pipeline executes model output. Several stages generate an ARO
program, write it to a temp directory and run `aro run <tmpdir>` — but the
subprocess inherited the pipeline's own working directory, and the ARO runtime
resolves a relative path against the process working directory. So a generated

    Log "started" to the <file: "app.log">.

landed in `Train/script/app.log`. It did: `app.log`, `test.txt`, `decoded.txt`,
`encoded.txt` and a fabricated `events.jsonl` were all sitting untracked in
`Train/script`, each written by a program a language model wrote. Nothing had
gone wrong for that to happen — that is the ordinary behaviour of a relative
path, and the next generated program could as easily have named
`../script/config.py`.

`sandboxed_run()` is the one way the pipeline should execute anything it
generated.

What a generated program CAN reach afterwards:

  * its own directory, `workdir` — the temp directory holding main.aro, its
    contract, and anything it writes. Relative paths resolve here, so a
    `Log … to the <file: "app.log">` lands here and is deleted with it.
  * `$HOME`, which is `workdir/home`, and `$TMPDIR`, which is `workdir/tmp` —
    both inside the same temp tree. A program looking for a config file or a
    scratch file finds an empty one of its own.
  * the `aro` binary and the shared libraries it links, read-only, like any
    executable.

What it CANNOT reach:

  * the repository, by any relative path. It has no idea where the checkout is:
    the working directory is not in it, `$HOME` is not the operator's, and the
    environment is an allowlist, so the ARO_* and HF_* variables naming real
    paths are not passed through.
  * the operator's real `$HOME`, shell history, SSH keys, cloud credentials, or
    Hugging Face token.
  * the network, in the ordinary case: every proxy variable points at a closed
    port on loopback and the offline switches of the libraries in reach are
    set. This is a deterrent, not a jail — a program that opens a socket
    directly is not stopped by an environment variable. Say so plainly rather
    than claim an isolation this does not implement. The pipeline's own gate
    (`eval_metrics.is_safely_runnable`) is what keeps programs that start
    servers or make requests from being run at all.

  * ABSOLUTE paths are not blocked. `Write … to the <file: "/tmp/x">` writes to
    /tmp. Containing that needs OS-level sandboxing, which is a separate piece
    of work; what this closes is the path that was actually being taken.
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import tempfile
from pathlib import Path

# Environment variables a generated program may keep. Everything else is
# dropped: an allowlist is the only kind of environment filter that stays
# correct when someone adds a new variable to their shell profile.
ENV_ALLOWLIST = (
    'PATH',            # find the aro binary
    'LANG', 'LC_ALL', 'LC_CTYPE',
    'TERM',
    'TZ',
    'DYLD_LIBRARY_PATH', 'LD_LIBRARY_PATH',   # aro's own shared libraries
)

# Pointed at a closed port on loopback: a library that honours proxy settings
# fails immediately instead of reaching the internet.
_DEAD_PROXY = 'http://127.0.0.1:1'

OFFLINE_ENV = {
    'http_proxy': _DEAD_PROXY, 'HTTP_PROXY': _DEAD_PROXY,
    'https_proxy': _DEAD_PROXY, 'HTTPS_PROXY': _DEAD_PROXY,
    'all_proxy': _DEAD_PROXY, 'ALL_PROXY': _DEAD_PROXY,
    'no_proxy': '', 'NO_PROXY': '',
    'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1',
    'ARO_OFFLINE': '1',
}


def sandbox_env(workdir: Path, allow_network=False, extra=None, base=None):
    """The environment a generated program runs in."""
    base = os.environ if base is None else base
    env = {k: base[k] for k in ENV_ALLOWLIST if k in base}

    home = Path(workdir) / 'home'
    tmp = Path(workdir) / 'tmp'
    env['HOME'] = str(home)
    env['TMPDIR'] = str(tmp)
    env['TMP'] = str(tmp)
    env['TEMP'] = str(tmp)
    env['XDG_CACHE_HOME'] = str(home / '.cache')
    env['XDG_CONFIG_HOME'] = str(home / '.config')
    env['XDG_DATA_HOME'] = str(home / '.local' / 'share')
    env['PWD'] = str(workdir)

    if not allow_network:
        env.update(OFFLINE_ENV)
    if extra:
        env.update({str(k): str(v) for k, v in extra.items()})
    return env


def prepare_workdir(workdir) -> Path:
    """Create the directory and the private HOME/TMPDIR inside it."""
    workdir = Path(workdir)
    for path in (workdir, workdir / 'home', workdir / 'tmp'):
        path.mkdir(parents=True, exist_ok=True)
    return workdir


def sandboxed_run(argv, workdir, timeout=10, allow_network=False,
                  env_extra=None, _runner=subprocess.run, **kwargs):
    """Run `argv` with `workdir` as its world. Returns a CompletedProcess.

    Always passes `cwd` and a built environment — never the inherited one.
    `subprocess.TimeoutExpired` and `FileNotFoundError` propagate; callers
    already distinguish "the program failed" from "there is no aro binary".
    """
    workdir = prepare_workdir(workdir)
    return _runner(
        [str(a) for a in argv],
        cwd=str(workdir),
        env=sandbox_env(workdir, allow_network=allow_network, extra=env_extra),
        capture_output=True, text=True, timeout=timeout,
        **kwargs)


@contextlib.contextmanager
def program_dir(main_aro=None, extra_files=None, prefix='aro-generated-'):
    """A throwaway directory holding a generated program, ready to run.

    Created under the system temp root, never under the checkout, so even a
    program that escapes its working directory by one `..` lands in a temp
    tree rather than in `Train/script`.
    """
    with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
        workdir = prepare_workdir(Path(tmp))
        if main_aro is not None:
            (workdir / 'main.aro').write_text(main_aro)
        for name, content in (extra_files or {}).items():
            target = workdir / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        yield workdir


@contextlib.contextmanager
def mirrored_dir(source, prefix='aro-mirror-'):
    """A throwaway copy of `source`, for running code that reads its siblings.

    The `.repl` course cells are executed with their own notebook's directory
    as the working directory so they can open the sample data next to them —
    which also meant a cell writing a file wrote into `Learning/`, and the
    file then survived into the second verification pass and changed its
    output. Running against a copy keeps the reads and loses the writes.
    """
    import shutil
    source = Path(source)
    with tempfile.TemporaryDirectory(prefix=prefix) as tmp:
        workdir = Path(tmp) / source.name
        shutil.copytree(source, workdir, symlinks=False)
        yield prepare_workdir(workdir)


def run_program_dir(argv_head, main_aro=None, extra_files=None, timeout=10,
                    allow_network=False):
    """Write a program to a throwaway directory and run `argv_head + [dir]`.

    The shape every caller wants: `run_program_dir(['aro', 'run'], code)`.
    """
    with program_dir(main_aro, extra_files) as workdir:
        return sandboxed_run(list(argv_head) + [str(workdir)], workdir,
                             timeout=timeout, allow_network=allow_network)
