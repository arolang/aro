"""Execute one pipeline notebook, streaming its cell output as it is produced.

Why this exists instead of `jupyter nbconvert --execute`.

`nbconvert --execute` collects every cell's stdout into the *output notebook*
and prints none of it. Its own stdout is three lines: "Converting…" at the
start, "Writing N bytes" at the end. The meta pipeline's stall watchdog
(`stage_runner.run_notebook`) decides a stage is wedged when its log stops
growing — so under nbconvert the log of a perfectly healthy stage stops growing
one second in and stays frozen until the stage finishes. Every stage that runs
longer than the stall window was killed as "stalled" no matter how much it
printed: `06_llm_knowledge_extraction`, which drives a 30B model over the
Examples, the Book and the Proposals, died at exactly 30 minutes with an empty
log. The short stages survived only by finishing inside the window.

`training.sh` had already hit the same wall for the *orchestrator* and worked
around it by converting the meta notebook to a script and running it under
`python -u`. That trick does not transfer to the child notebooks — they need a
real kernel — so this module does the equivalent through nbclient: the same
execution nbconvert performs, with each stream/result/error message echoed to
stdout the moment the kernel emits it. The watchdog then watches what it was
always meant to watch.

The executed notebook is written to `--output` whether or not a cell raised,
which nbconvert does not do; the half-executed copy is the first thing anyone
debugging a failed stage wants.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import nbformat
from nbclient import NotebookClient
from nbclient.exceptions import CellExecutionError

PREFIX = '[nb_exec]'
ANSI = re.compile(r'\x1b\[[0-9;]*m')     # the kernel colours its tracebacks


def _echo(text: str) -> None:
    """Write through to stdout immediately — this is the watchdog's heartbeat."""
    sys.stdout.write(text)
    if not text.endswith('\n'):
        sys.stdout.write('\n')
    sys.stdout.flush()


def _render(output) -> str:
    """The terminal rendering of one cell output, or '' for nothing printable."""
    kind = output.get('output_type')
    if kind == 'stream':
        return output.get('text', '')
    if kind in ('execute_result', 'display_data'):
        return output.get('data', {}).get('text/plain', '')
    if kind == 'error':
        traceback = '\n'.join(output.get('traceback', []))
        head = f'{output.get("ename", "Error")}: {output.get("evalue", "")}'
        return f'{traceback}\n{head}' if traceback else head
    return ''


class StreamingClient(NotebookClient):
    """A NotebookClient that narrates. Identical execution, visible progress."""

    def process_message(self, msg, cell, cell_index):
        output = super().process_message(msg, cell, cell_index)
        if output is not None:
            text = _render(output)
            if text:
                _echo(text.rstrip('\n'))
        return output


def execute(src: Path, dest: Path, kernel: str, timeout: int = -1) -> int:
    notebook = nbformat.read(src, as_version=4)
    total = sum(1 for c in notebook.cells if c.cell_type == 'code')
    _echo(f'{PREFIX} executing {src.name} ({total} code cells, kernel={kernel})')

    client = StreamingClient(
        notebook,
        kernel_name=kernel,
        timeout=timeout,
        allow_errors=False,
        # The kernel's cwd. nbconvert sets this to the notebook's directory and
        # the notebooks rely on it: they resolve config.py and every data path
        # from `Path('.')`.
        resources={'metadata': {'path': str(src.parent)}},
    )

    status = 0
    try:
        client.execute()
    except CellExecutionError as exc:
        # The traceback has already been streamed by process_message; this is
        # the one-line summary the pipeline's log reader picks up.
        # Uncoloured: this line is what the pipeline lifts into its one-line
        # failure summary on the terminal. The coloured traceback above it stays
        # coloured for whoever reads the log.
        summary = ANSI.sub('', str(exc).strip().splitlines()[-1])
        _echo(f'{PREFIX} FAILED: {summary}')
        status = 1
    finally:
        dest.parent.mkdir(parents=True, exist_ok=True)
        nbformat.write(notebook, dest)
        _echo(f'{PREFIX} wrote {dest}')
    return status


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('notebook', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--kernel', required=True)
    parser.add_argument('--timeout', type=int, default=-1,
                        help='per-cell timeout in seconds; -1 (default) for '
                             'none — the stall watchdog is the time limit.')
    args = parser.parse_args(argv)

    if not args.notebook.is_file():
        _echo(f'{PREFIX} FAILED: no such notebook: {args.notebook}')
        return 2
    return execute(args.notebook, args.output, args.kernel, args.timeout)


if __name__ == '__main__':
    sys.exit(main())
