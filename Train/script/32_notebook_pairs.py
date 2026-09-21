#!/usr/bin/env python3
"""
32_notebook_pairs.py — training pairs from the Learning `.repl` notebooks.

`Learning/` is a 29-notebook ARO course (ARO-0091 notebooks: markdown prose
between live code cells) and until now the training pipeline could not see
it. That is a double gap:

1. **Corpus.** The course is the best-written explanatory ARO prose we own —
   every concept introduced, motivated, and immediately demonstrated by code
   that a validator proves still runs. `29_multimodel_doc_qa.py` mines the
   Book and Proposals; nothing mined the notebooks.
2. **Skill.** `aro ask` is asked about notebooks, and is asked *inside* them
   (SOLARO opens a `.repl` as a notebook; `aro kernel install` puts the same
   session behind JupyterLab / DataSpell / VS Code). A model that has never
   seen a `.repl` cell cannot answer "what does this cell print?", cannot
   write the next cell of a session, and cannot emit a notebook cell in the
   file's own JSON shape. Whole-program generation does not transfer: a cell
   is bare statements against accumulated session state, not a feature set.

So the ground truth here is not the file — it is a **real run**. Every code
cell is executed through `aro repl --json` (the same server the kernel and
the SOLARO notebook drive), in one session per notebook, in source order, and
the captured `stream` / `display` messages become the expected output. Stored
outputs in the file are ignored: most shipped notebooks carry `"outputs": []`,
and a stored output that has drifted from what the language now does is worse
than none.

Every notebook is run **twice** in independent sessions and a cell's output is
kept only when both runs agree (`--repeats`). Anything time-, random-, or
path-dependent drops out instead of teaching the model a number that was never
reproducible. That is the validation gate the corpus has lacked for outputs.

Pair families (all task types uncapped by DEFAULT_TYPE_CAP; declared in
config.TYPE_CAPS v4):

    notebook_output      given the session so far + this cell → its real output
    notebook_cell        given the teaching prose + session so far → the cell
                         AND its real output
    notebook_qa          questions grounded in notebook content: what a
                         notebook teaches, what a section explains, which
                         notebook covers a topic
    notebook_authoring   the `.repl` JSON shape itself — emit a well-formed
                         cell / document with real captured outputs

Usage:
    python3 32_notebook_pairs.py --dry-run          # execute, count, save nothing
    python3 32_notebook_pairs.py                    # save (replaces NB32 rows)
    python3 32_notebook_pairs.py --notebook 27      # one notebook (substring match)
    python3 32_notebook_pairs.py --repeats 1        # skip the reproducibility gate
    python3 32_notebook_pairs.py --aro-check        # audit: `aro check` the emitted ARO
    python3 32_notebook_pairs.py --dump out.jsonl   # write pairs to a file too
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
for _cfg in ('release', 'debug'):
    _bin = _REPO / '.build' / _cfg
    if (_bin / 'aro').exists():
        os.environ['PATH'] = f"{_bin}:{os.environ.get('PATH', '')}"
        break

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    LEARNING_DIR, DATA_ROOT, FunnelCounter, NearDuplicateIndex,
    save_notebook_pairs, clean_notebook_pairs, aro_check_snippet, auto_wrap_aro,
    _FEATURESET_HEADER_RE,
)
import stage_runner  # noqa: E402

NOTEBOOK_TAG = 'NB32_notebooks'

DATA_OUT = DATA_ROOT / '32_notebooks'

# One session per notebook must fit; the course's slowest notebook (streaming,
# with deliberate sleeps) runs in well under a minute.
SESSION_TIMEOUT = 300

# Cells marked with this run *because* they fail — never train on the failure
# as if it were the expected result of correct code.
EXPECT_ERROR_MARKER = '(* expect-error *)'

# How much prior session to quote back in an instruction. Enough to make the
# bindings a cell depends on visible, short enough to stay a prompt.
CONTEXT_CELLS = 5
CONTEXT_CHARS = 1800

# An output that is one number is not worth a prediction pair — the model
# would learn the notebook, not the language.
MIN_OUTPUT_CHARS = 12


# ════════════════════════════════════════════════════════════════════════════
# Running a notebook
# ════════════════════════════════════════════════════════════════════════════

def _aro_bin() -> str:
    return os.environ.get('ARO_BIN', 'aro')


def run_notebook_session(cells, cwd) -> dict:
    """Execute every code cell of a notebook in one `aro repl --json` session.

    Returns {cell_index: {'status', 'stdout', 'stderr', 'display', 'error'}}
    keyed by the cell's index in `cells`. Mirrors Learning/validate.py — same
    server, same framing, same one-session-per-notebook discipline — but keeps
    the payloads instead of only the status.
    """
    code_cells = [(i, c) for i, c in enumerate(cells) if c.get('kind') == 'code']
    if not code_cells:
        return {}

    requests = [
        json.dumps({'id': n, 'type': 'execute', 'code': c.get('source', '')})
        for n, (_, c) in enumerate(code_cells, start=1)
    ]
    requests.append(json.dumps({'id': len(code_cells) + 1, 'type': 'shutdown'}))

    proc = subprocess.run(
        [_aro_bin(), 'repl', '--json'],
        input='\n'.join(requests) + '\n',
        capture_output=True, text=True, timeout=SESSION_TIMEOUT, cwd=str(cwd),
    )

    streams: dict[int, list] = {}
    results: dict[int, dict] = {}
    for line in proc.stdout.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = message.get('type')
        if kind == 'stream':
            streams.setdefault(message.get('id'), []).append(message)
        elif kind == 'result':
            results[message.get('id')] = message

    runs = {}
    for request_id, (index, _) in enumerate(code_cells, start=1):
        result = results.get(request_id)
        if result is None:
            runs[index] = {'status': 'dead'}
            break                       # everything after a dead session is noise
        out = ''.join(m.get('text', '') for m in streams.get(request_id, [])
                      if m.get('name') != 'stderr')
        err = ''.join(m.get('text', '') for m in streams.get(request_id, [])
                      if m.get('name') == 'stderr')
        runs[index] = {
            'status':  result.get('status'),
            'stdout':  out,
            'stderr':  err,
            'display': result.get('display') or {},
            'error':   result.get('error') or {},
            'durationMs': result.get('durationMs'),
        }
    return runs


def _signature(run: dict) -> tuple:
    """What must match across repeats for an output to count as reproducible.

    Duration is excluded (it is wall clock, never equal); stderr is excluded
    because deferred-failure warnings can race. stdout and the display bundle
    are the things a pair promises.
    """
    return (run.get('status'), run.get('stdout'),
            json.dumps(run.get('display'), sort_keys=True))


def execute_notebook(path: Path, repeats: int) -> tuple[dict, dict]:
    """Run a notebook `repeats` times; keep only cells that agreed every time.

    Returns (runs, stats). A cell present in `runs` has an output we are
    willing to promise: it happened, and it happened the same way twice.
    """
    document = json.loads(path.read_text())
    cells = document.get('cells', [])
    stats = {'code_cells': 0, 'ok': 0, 'nondeterministic': 0, 'failed': 0}
    stats['code_cells'] = sum(1 for c in cells if c.get('kind') == 'code')

    passes = [run_notebook_session(cells, path.parent) for _ in range(repeats)]
    first = passes[0]

    kept = {}
    for index, run in first.items():
        source = cells[index].get('source', '')
        if run.get('status') != 'ok' or EXPECT_ERROR_MARKER in source:
            stats['failed'] += 1
            continue
        if any(_signature(p.get(index, {})) != _signature(run) for p in passes[1:]):
            stats['nondeterministic'] += 1
            continue
        stats['ok'] += 1
        kept[index] = run
    return kept, stats


# ════════════════════════════════════════════════════════════════════════════
# Rendering
# ════════════════════════════════════════════════════════════════════════════

def render_output(run: dict) -> str:
    """The cell's observable output, the way a notebook shows it: the streams
    first, then the auto-displayed value (ARO-0091 §Automatic display)."""
    parts = []
    if run.get('stdout'):
        parts.append(run['stdout'].rstrip('\n'))
    display = run.get('display') or {}
    plain = (display.get('text/plain') or '').rstrip('\n')
    if plain and plain not in (run.get('stdout') or ''):
        parts.append(plain)
    return '\n'.join(p for p in parts if p)


def session_context(cells, upto_index, runs) -> str:
    """The last few executed cells, as a transcript — what the session knows."""
    prior = [i for i, c in enumerate(cells)
             if i < upto_index and c.get('kind') == 'code' and i in runs]
    chunks = []
    for i in prior[-CONTEXT_CELLS:]:
        chunks.append(cells[i].get('source', '').strip())
    text = '\n'.join(chunks)
    if len(text) > CONTEXT_CHARS:
        text = '…\n' + text[-CONTEXT_CHARS:]
    return text


def preceding_prose(cells, index) -> str:
    """The markdown cell(s) immediately above a code cell — the teaching text
    that the cell is the demonstration of."""
    prose = []
    i = index - 1
    while i >= 0 and cells[i].get('kind') == 'markdown':
        prose.insert(0, cells[i].get('source', '').strip())
        i -= 1
        if len(prose) == 2:
            break
    return '\n\n'.join(prose)


# Section headings only — `#` is the notebook's own title, which is never a
# question worth asking ("In ARO: 03 — Compute & Qualifiers?").
_HEADING_RE = re.compile(r'^#{2,3}\s+(.+?)\s*$', re.MULTILINE)

# Structural headings the course uses everywhere; they name a position in the
# notebook, not a topic, so they make neither a listing entry nor a question.
_STRUCTURAL_HEADINGS = {
    'what just happened', 'variants', 'related', 'discussion', 'in this notebook',
}

_REAL_WORLD_RE = re.compile(r'^real-world example:\s*(.+)$', re.IGNORECASE)


def notebook_title(cells) -> str:
    for cell in cells:
        if cell.get('kind') == 'markdown':
            m = re.match(r'^#\s+(.+)', cell.get('source', '').strip())
            if m:
                return m.group(1).strip()
    return ''


def notebook_cell_json(cell, run, execution_count) -> dict:
    """The cell as it is stored in a `.repl` file after a run — the shape
    SOLARO's ReplNotebook encodes and the model must be able to emit."""
    outputs = []
    if run.get('stdout'):
        outputs.append({'kind': 'stream', 'streamName': 'stdout',
                        'text': run['stdout']})
    display = run.get('display') or {}
    plain, as_json = display.get('text/plain'), display.get('application/json')
    if plain or as_json:
        result = {'kind': 'result'}
        if plain:
            result['plainText'] = plain
        if as_json:
            result['jsonValue'] = (as_json if isinstance(as_json, str)
                                   else json.dumps(as_json))
        outputs.append(result)
    stored = {
        'id': cell.get('id'),
        'kind': 'code',
        'source': cell.get('source', ''),
        'outputs': outputs,
        'executionCount': execution_count,
    }
    duration = run.get('durationMs')
    if duration is not None:
        stored['durationMs'] = round(float(duration), 3)
    return stored


# ════════════════════════════════════════════════════════════════════════════
# Pair families
# ════════════════════════════════════════════════════════════════════════════

# A block framed as "here is what NOT to write" must not be checked as if it
# were a training target — the same convention config.lint_pair_output uses.
_NEGATIVE_MARKERS = ('error', 'wrong', 'invalid', 'fails', "doesn't", 'does not',
                     'never', 'not allowed', '❌', 'rejected')


def prose_blocks_ok(body: str) -> bool:
    """`aro check` every ARO block quoted from a markdown cell.

    Executed cells are verified by running them; prose blocks are not run by
    anything — `Learning/validate.py` only executes code cells — so a snippet
    in a markdown cell can rot silently and then be mined as if it were
    ground truth. This is the gate for that half of a notebook. Deliberate
    negative examples are exempt, and cell-only shapes are not the file
    `aro check` reads, so they are exempt too.
    """
    for match in re.finditer(r'```aro\n(.*?)```', body, re.DOTALL):
        code = match.group(1).strip()
        context = (body[max(0, match.start() - 200):match.start()] + code).lower()
        if any(marker in context for marker in _NEGATIVE_MARKERS):
            continue
        if is_repl_only_shape(code):
            continue
        wrapped, _ = auto_wrap_aro(code)
        if wrapped is None:
            continue
        ok, _err = aro_check_snippet(wrapped)
        if ok is False:
            return False
    return True


def pairs_for_notebook(path: Path, runs: dict, funnel_reasons: dict,
                       prose_gate: bool = True) -> list[dict]:
    document = json.loads(path.read_text())
    cells = document.get('cells', [])
    title = notebook_title(cells)
    name = path.name
    pairs = []

    execution_count = 0
    for index, cell in enumerate(cells):
        if cell.get('kind') != 'code':
            continue
        if index not in runs:
            continue
        execution_count += 1
        run = runs[index]
        source = cell.get('source', '').strip()
        output = render_output(run)
        context = session_context(cells, index, runs)
        prose = preceding_prose(cells, index)

        # ── notebook_output: predict what a cell prints ─────────────────────
        if len(output) >= MIN_OUTPUT_CHARS:
            preamble = (f'Earlier cells in this session have already run:\n\n'
                        f'```aro\n{context}\n```\n\n') if context else ''
            pairs.append({
                'instruction': (
                    f'This is an ARO notebook session (a `.repl` notebook run '
                    f'through `aro repl --json`). {preamble}'
                    f'What does this cell output?\n\n```aro\n{source}\n```'),
                'output': f'```\n{output}\n```',
                'source': 'learning_notebook',
                'task_type': 'notebook_output',
                'category': f'notebook_output_{path.stem[:2]}',
            })
        else:
            funnel_reasons['output_too_short'] = funnel_reasons.get('output_too_short', 0) + 1

        # ── notebook_cell: write the next cell, and say what it prints ──────
        if prose and len(prose) > 120:
            context_block = (f'The session so far:\n\n```aro\n{context}\n```\n\n'
                             if context else '')
            pairs.append({
                'instruction': (
                    f'You are writing the next code cell of an ARO notebook '
                    f'({name} — "{title}").\n\n{context_block}'
                    f'The prose introducing the next cell says:\n\n{prose}\n\n'
                    f'Write that cell, then show the output it produces.'),
                'output': (f'```aro\n{source}\n```\n\nOutput:\n\n```\n{output}\n```'
                           if output else f'```aro\n{source}\n```'),
                'source': 'learning_notebook',
                'task_type': 'notebook_cell',
                'category': f'notebook_cell_{path.stem[:2]}',
            })

        # ── notebook_authoring: the `.repl` JSON shape, with real outputs ───
        if output and len(source) < 400:
            stored = notebook_cell_json(cell, run, execution_count)
            pairs.append({
                'instruction': (
                    f'Write the `.repl` notebook JSON (ARO-0091 notebook '
                    f'format, version 1) for this code cell as it is stored '
                    f'after running — including the outputs it captures. It '
                    f'has id `{cell.get("id")}` and was the '
                    f'{execution_count}{"st" if execution_count == 1 else "nd" if execution_count == 2 else "rd" if execution_count == 3 else "th"} '
                    f'cell executed in the session.\n\n```aro\n{source}\n```'),
                'output': ('```json\n'
                           + json.dumps(stored, indent=2, ensure_ascii=False)
                           + '\n```'),
                'source': 'learning_notebook',
                'task_type': 'notebook_authoring',
                'category': 'repl_cell_json',
            })

    # ── notebook_qa: what does this notebook teach? ─────────────────────────
    headings = []
    for cell in cells:
        if cell.get('kind') != 'markdown':
            continue
        headings.extend(h for h in _HEADING_RE.findall(cell.get('source', ''))
                        if h.strip().lower() not in _STRUCTURAL_HEADINGS)
    if title and headings:
        pairs.append({
            'instruction': (f'What does the ARO Learning notebook `{name}` '
                            f'teach, and what does it cover?'),
            'output': (f'`Learning/{name}` is "{title}" in the ARO notebook '
                       f'course. It covers:\n\n'
                       + '\n'.join(f'- {h}' for h in headings[:12])
                       + '\n\nIt is a `.repl` notebook: markdown prose between '
                         'live ARO code cells, executed against a real REPL '
                         'session (ARO-0091). Open it in SOLARO, or in '
                         'JupyterLab / VS Code / DataSpell after '
                         '`aro kernel install`.'),
            'source': 'learning_notebook',
            'task_type': 'notebook_qa',
            'category': 'notebook_overview',
        })

    # ── notebook_qa: a section, its explanation, and its verified example ───
    for index, cell in enumerate(cells):
        if cell.get('kind') != 'markdown':
            continue
        body = cell.get('source', '').strip()
        heads = _HEADING_RE.findall(body)
        if not heads or len(body) < 200:
            continue
        heading = heads[0].strip()
        if heading.lower() in _STRUCTURAL_HEADINGS:
            continue
        if prose_gate and not prose_blocks_ok(body):
            funnel_reasons['prose_block_failed_aro_check'] = \
                funnel_reasons.get('prose_block_failed_aro_check', 0) + 1
            continue

        # The code cell this section introduces, if it ran.
        demo_index = next((j for j in range(index + 1, min(index + 3, len(cells)))
                           if cells[j].get('kind') == 'code'), None)
        answer = _HEADING_RE.sub('', body).strip()
        if demo_index is not None and demo_index in runs:
            demo = cells[demo_index].get('source', '').strip()
            demo_out = render_output(runs[demo_index])
            answer += f'\n\n```aro\n{demo}\n```'
            if demo_out:
                answer += f'\n\nOutput:\n\n```\n{demo_out}\n```'

        # "Real-world example: the reorder run" is already a request in
        # disguise; everything else is asked about where it is taught, so the
        # answer stays honestly attributable to the notebook it came from.
        real_world = _REAL_WORLD_RE.match(heading)
        if real_world:
            question = (f'Show a real-world ARO example: {real_world.group(1)}.')
        else:
            question = (f'In the ARO course notebook "{title}", what does the '
                        f'section "{heading}" explain?')
        pairs.append({
            'instruction': question,
            'output': answer,
            'source': 'learning_notebook',
            'task_type': 'notebook_qa',
            'category': 'notebook_section',
        })

    return pairs


_README_ROW = re.compile(
    r'^\|\s*(\d+)\s*\|\s*\[([^\]]+)\]\(([^)]+\.repl)\)\s*\|\s*([^|]+?)\s*\|',
    re.MULTILINE)


def course_index_pairs(readme: Path) -> list[dict]:
    """Catalogue Q&A from the course README table: which notebook covers what.

    The README is the map of the course; without it the model can quote a
    notebook but not find one.
    """
    if not readme.exists():
        return []
    rows = [m.groups() for m in _README_ROW.finditer(readme.read_text())]
    if not rows:
        return []

    listing = '\n'.join(f'- {n} — [{t}](Learning/{f}): {teaches}'
                        for n, t, f, teaches in rows)
    pairs = [{
        'instruction': 'What is in the ARO Learning notebook course?',
        'output': ('`Learning/` is the ARO course as runnable `.repl` '
                   'notebooks — markdown prose between live code cells, run '
                   'against a real REPL session (ARO-0091):\n\n' + listing
                   + '\n\nOpen them in SOLARO (a `.repl` file opens as a '
                     'notebook) or in JupyterLab / VS Code / DataSpell after '
                     '`aro kernel install`. '
                     '`python3 Learning/validate.py` executes every code cell '
                     'of every notebook and fails when one stops working.'),
        'source': 'learning_notebook',
        'task_type': 'notebook_qa',
        'category': 'course_index',
    }]
    for number, title, filename, teaches in rows:
        pairs.append({
            'instruction': f'Which ARO notebook covers {teaches[0].lower() + teaches[1:]}?',
            'output': (f'Notebook {number} — "{title}" '
                       f'(`Learning/{filename}`). It teaches {teaches}.'),
            'source': 'learning_notebook',
            'task_type': 'notebook_qa',
            'category': 'course_index',
        })
    return pairs


def format_pairs() -> list[dict]:
    """The `.repl` format itself, described once, authoritatively.

    Hand-written rather than mined: the file shape lives in Swift
    (`Sources/SOLARO/ReplNotebook.swift`) and in ARO-0091, not in any prose the
    miner reads. Kept in sync by test_notebook_pairs.py, which decodes the
    example this pair emits.
    """
    document = {
        'version': 1,
        'cells': [
            {'id': 'nb-c01', 'kind': 'markdown',
             'source': '# Pricing an order\n\nOne espresso, one latte.',
             'outputs': []},
            {'id': 'nb-c02', 'kind': 'code',
             'source': 'Create the <prices> with [2.4, 3.6].\n'
                       'Compute the <total: sum> from <prices>.\n'
                       'Log <total> to the <console>.',
             'outputs': [{'kind': 'stream', 'streamName': 'stdout',
                          'text': '6.00\n'}],
             'executionCount': 1,
             'durationMs': 4.2},
        ],
    }
    shape = ('```json\n' + json.dumps(document, indent=2) + '\n```')
    return [
        {
            'instruction': 'What is a `.repl` notebook in ARO, and what does the file look like?',
            'output': (
                'A `.repl` file is an ARO notebook: markdown prose cells and '
                'ARO code cells with their captured outputs, executed against '
                'the same `aro repl --json` server the Jupyter kernel drives '
                '(ARO-0091). It is JSON — a small cousin of `.ipynb`, but with '
                'the display bundle kept as first-class fields instead of a '
                'MIME dictionary, so the file stays readable in a diff.\n\n'
                + shape +
                '\n\n- `version` is `1`; a decoder refuses versions it does not know.\n'
                '- A cell has an `id` (unique, stable across edits), a `kind` '
                '(`markdown` or `code`), a `source`, and `outputs`.\n'
                '- `executionCount` is the session-order counter — the `[1]` '
                'badge next to a cell — and is absent for a cell that has never run.\n'
                '- `durationMs` is the server-reported execution time of the last run.\n'
                '- Markdown cells carry an empty `outputs` list.'),
            'source': 'aro_0091',
            'task_type': 'notebook_authoring',
            'category': 'repl_format',
        },
        {
            'instruction': 'What shapes can the `outputs` of an ARO `.repl` notebook cell take?',
            'output': (
                'Three, in arrival order — `stream` entries interleave exactly '
                'as the server emitted them, and a cell ends with at most one '
                '`result` or one `error` (every `execute` request gets exactly '
                'one result message):\n\n'
                '```json\n'
                '{"kind": "stream", "streamName": "stdout", "text": "6.00\\n"}\n'
                '{"kind": "result", "plainText": "6.00", "jsonValue": "6.0"}\n'
                '{"kind": "error", "errorName": "AROError", '
                '"errorValue": "Variable \'total\' is already bound", '
                '"traceback": ["…"]}\n'
                '```\n\n'
                '- **stream** is console output as it happens: `Log` writes, '
                'stray runtime prints, warnings on `stderr`.\n'
                '- **result** is the display bundle: `plainText` is '
                '`text/plain` and is always present on a displayed value; '
                '`jsonValue` is `application/json` re-serialized as a string, '
                'present when the value encodes. A cell displays its last '
                'statement\'s value automatically when that statement\'s action '
                'role is `own` or `request` — showing something after `Log`, '
                '`Store`, or `Publish` would invent a result the statement '
                'never had.\n'
                '- **error** carries ARO\'s own error text (ARO-0006) split in '
                'two: the first line as `errorValue`, the whole block as '
                '`traceback`.\n\n'
                'Ordering is guaranteed: every stream for a cell precedes that '
                'cell\'s result, so a client never has to guess when output is done.'),
            'source': 'aro_0091',
            'task_type': 'notebook_authoring',
            'category': 'repl_format',
        },
    ]


# ════════════════════════════════════════════════════════════════════════════
# Driver
# ════════════════════════════════════════════════════════════════════════════

def is_repl_only_shape(code: str) -> bool:
    """True when a block is legal in a cell but not as a file.

    A cell may define a feature set *and* then call it at top level —
    `(PriceOrder: Action) { … }` followed by
    `Application.PriceOrder the <p> from { … }.` — which is exactly what a
    notebook is for and exactly what a `.aro` file may not contain. Such
    blocks are excluded from the `aro check` audit rather than counted as
    failures: they already passed the stronger gate (they ran).
    """
    depth = 0
    has_featureset = False
    top_level_statement = False
    for line in code.split('\n'):
        stripped = line.strip()
        if depth == 0 and stripped and not stripped.startswith('(*'):
            if _FEATURESET_HEADER_RE.match(stripped):
                has_featureset = True
            elif stripped != '}' and not stripped.startswith('}'):
                top_level_statement = True
        depth += line.count('{') - line.count('}')
    return has_featureset and top_level_statement


def aro_check_audit(pairs: list[dict]) -> dict:
    """Cross-check: how much of the emitted ARO passes `aro check`?

    Execution through the REPL is the real gate here — a notebook cell is
    bare statements against accumulated session state, and `aro check` reads
    files, not sessions. This audit puts a number on the corpus anyway: each
    block is auto-wrapped into a feature set the way NB15 does, blocks that
    already define feature sets are checked as they stand, and cell-only
    shapes (definition + top-level call) are counted apart.
    """
    stats = {'checked': 0, 'passed': 0, 'repl_only': 0, 'skipped': 0,
             'failures': []}
    for pair in pairs:
        for block in re.findall(r'```aro\n(.*?)```', pair['output'], re.DOTALL):
            code = block.strip()
            if is_repl_only_shape(code):
                stats['repl_only'] += 1
                continue
            wrapped, _ = auto_wrap_aro(code)
            if wrapped is None:        # meta/template block — not checkable
                stats['skipped'] += 1
                continue
            stats['checked'] += 1
            ok, err = aro_check_snippet(wrapped)
            if ok:
                stats['passed'] += 1
            elif len(stats['failures']) < 10:
                stats['failures'].append({'code': code[:200], 'error': err[:200]})
    return stats


def main():
    ap = argparse.ArgumentParser()
    stage_runner.add_stage_arguments(ap)   # --dry-run / --limit (GitLab #803)
    ap.add_argument('--notebook', help='substring match — mine only these notebooks')
    ap.add_argument('--repeats', type=int, default=2,
                    help='executions per notebook; >1 enables the '
                         'reproducibility gate (default 2)')
    ap.add_argument('--aro-check', action='store_true',
                    help='audit the emitted ARO with `aro check` and report the rate')
    ap.add_argument('--no-prose-gate', action='store_true',
                    help='keep Q&A whose quoted markdown ARO fails `aro check` '
                         '(the gate is on by default)')
    ap.add_argument('--dump', help='also write the pairs to this .jsonl file')
    args = ap.parse_args()

    probe = subprocess.run([_aro_bin(), '--version'], capture_output=True)
    if probe.returncode != 0:
        sys.exit('no working `aro` on PATH — refusing to emit unverified '
                 'notebook outputs (set ARO_BIN or build the CLI)')

    notebooks = sorted(LEARNING_DIR.glob('*.repl'))
    if args.notebook:
        notebooks = [n for n in notebooks if args.notebook in n.name]
    if not notebooks:
        sys.exit(f'no .repl notebooks found under {LEARNING_DIR}')
    # --limit caps the notebooks EXECUTED, not the pairs kept: executing
    # them is the expensive half, and a smoke test wants the data path
    # exercised end to end on one notebook (GitLab #803).
    opts = stage_runner.StageOptions.from_args(args)
    notebooks = opts.apply(notebooks)

    funnel = FunnelCounter('notebook_pairs')
    coverage = {}
    reasons: dict = {}
    raw_pairs = []
    totals = {'code_cells': 0, 'ok': 0, 'nondeterministic': 0, 'failed': 0}

    for path in notebooks:
        runs, stats = execute_notebook(path, max(1, args.repeats))
        pairs = pairs_for_notebook(path, runs, reasons,
                                   prose_gate=not args.no_prose_gate)
        for key in totals:
            totals[key] += stats[key]
        coverage[path.name] = {**stats, 'pairs': len(pairs)}
        raw_pairs.extend(pairs)
        print(f'  {path.name:<44} cells={stats["code_cells"]:3d} '
              f'verified={stats["ok"]:3d} '
              f'nondet={stats["nondeterministic"]:2d} '
              f'failed={stats["failed"]:2d} → {len(pairs):3d} pairs')

    raw_pairs.extend(course_index_pairs(LEARNING_DIR / 'README.md'))
    raw_pairs.extend(format_pairs())

    funnel.record_stage('cell execution', before=totals['code_cells'],
                        after=totals['ok'],
                        reasons={'nondeterministic': totals['nondeterministic'],
                                 'failed_or_expected_error': totals['failed']})

    # Dedup — the course repeats itself on purpose (each notebook re-teaches
    # what it builds on); training data must not.
    dedup = NearDuplicateIndex(threshold=0.9)
    pairs, dropped = [], 0
    for pair in raw_pairs:
        if dedup.check_and_add(pair['instruction']):
            dropped += 1
            continue
        pairs.append(pair)
    funnel.record_stage('dedup', before=len(raw_pairs), after=len(pairs),
                        reasons={'near_duplicate_instruction': dropped, **reasons})

    by_type: dict = {}
    for pair in pairs:
        by_type[pair['task_type']] = by_type.get(pair['task_type'], 0) + 1

    print()
    print(funnel.render_markdown())
    print()
    print(f'notebooks: {len(notebooks)} | code cells: {totals["code_cells"]} | '
          f'verified outputs: {totals["ok"]} | pairs: {len(pairs)}')
    for task_type, n in sorted(by_type.items()):
        print(f'  {task_type:<20} {n:5d}')

    check_stats = None
    if args.aro_check:
        check_stats = aro_check_audit(pairs)
        checked, passed = check_stats['checked'], check_stats['passed']
        check_stats['rate'] = 100 * passed / checked if checked else 0.0
        print(f'\naro check audit: {passed}/{checked} blocks valid '
              f'({check_stats["rate"]:.1f}%) | '
              f'{check_stats["repl_only"]} cell-only shapes and '
              f'{check_stats["skipped"]} meta blocks excluded')
        for failure in check_stats['failures']:
            diagnostic = next((line.strip() for line in failure['error'].splitlines()
                               if 'error:' in line), failure['error'][:110])
            print(f'  ✗ {diagnostic[:110]}')
            print(f'      {failure["code"].splitlines()[0][:100]}')

    DATA_OUT.mkdir(parents=True, exist_ok=True)
    report = {
        'notebooks': coverage,
        'totals': totals,
        'pairs_by_type': by_type,
        'funnel': funnel.to_dict(),
        'aro_check': check_stats,
        'repeats': args.repeats,
    }
    (DATA_OUT / 'coverage.json').write_text(json.dumps(report, indent=2))
    print(f'wrote {DATA_OUT / "coverage.json"}')

    if args.dump:
        with open(args.dump, 'w') as f:
            for pair in pairs:
                f.write(json.dumps(pair) + '\n')
        print(f'wrote {args.dump}')

    if args.dry_run:
        print('dry run — nothing saved to the corpus')
        return 0

    removed = clean_notebook_pairs(NOTEBOOK_TAG)
    if removed:
        print(f'replaced {removed} previous pairs')
    written = save_notebook_pairs(NOTEBOOK_TAG, pairs)
    print(f'saved {written} pairs as {NOTEBOOK_TAG}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
