#!/usr/bin/env python3
"""
30_fim_pairs.py — fill-in-the-middle pairs from real, validated ARO code.

The dataset assembly has carried a `fim` type cap since v1, but the corpus
contains ZERO fim pairs — the category was planned and never fed. Infilling
is not optional polish here: the model's primary deployment is `aro ask`
inside an editor (SOLARO's co-pilot, `edit_file` workflows, the /fix repair
loop), where the task is literally "produce the missing statement given the
code above and below it". Training only on whole-file generation and then
asking for surgical middles is the mismatch that made repairs retype files.
(Background: "Efficient Training of Language Models to Fill in the Middle",
Bavarian et al. 2022 — infilling capability is nearly free when trained,
absent when not.)

Deterministic, no LLM: take a real .aro file that passes `aro check`, mask
one statement (or one contiguous 2-3 statement run), and the ground truth is
the original text — correct by construction, byte-for-byte idiomatic,
including the spacing quirks (`the<name>`) generation models normalise away.

Sources: Examples/ in this repo, plus ARO-Application when present (the same
corpus roots the rest of the pipeline mines).

Pair shape (chat SFT, PSM expressed in prose because the student is a chat
model, not a base-FIM model):

    user:      Complete the missing statement(s) at <MISSING> in this ARO
               feature set: ...prefix...<MISSING>...suffix...
    assistant: ```aro\n<the original statements>\n```

Gates: the source file must pass `aro check` as found (files that do not are
skipped and counted); masked spans are full statements only, never partial
lines; near-duplicate prompts are dropped.

Usage:
    python3 30_fim_pairs.py --dry-run     # count + validate, save nothing
    python3 30_fim_pairs.py               # save (replaces previous NB30 rows)
    python3 30_fim_pairs.py --per-file 3  # more masks per file (default 2)
"""

import argparse
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
for _cfg in ('release', 'debug'):
    _bin = _REPO / '.build' / _cfg
    if (_bin / 'aro').exists():
        os.environ['PATH'] = f"{_bin}:{os.environ.get('PATH', '')}"
        break

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    save_notebook_pairs, clean_notebook_pairs, NearDuplicateIndex,
    ARO_APPLICATION_ROOT,
)
import stage_runner  # noqa: E402
import sandbox  # noqa: E402

NOTEBOOK_TAG = 'NB30_fim'

# Deterministic masking: same inputs → same pairs, so re-runs replace
# byte-identical data and diffs stay reviewable. Seeded, not Date-based.
RNG = random.Random(30_2026)


def aro_check_dir(files: dict) -> bool:
    """Sandboxed `aro check` over {filename: content} (GitLab #804)."""
    r = sandbox.run_program_dir(['aro', 'check'], extra_files=files, timeout=30)
    return r.returncode == 0


def collect_aro_files() -> list[Path]:
    roots = [_REPO / 'Examples']
    if ARO_APPLICATION_ROOT and Path(ARO_APPLICATION_ROOT).exists():
        roots.append(Path(ARO_APPLICATION_ROOT))
    files = []
    for root in roots:
        files.extend(sorted(root.rglob('*.aro')))
    return files


STATEMENT = re.compile(r'^\s{4,}\S.*\.$')  # indented, ends with a period


def maskable_lines(lines: list[str]) -> list[int]:
    """Indices of complete single-line statements safe to mask."""
    idx = []
    for i, line in enumerate(lines):
        if not STATEMENT.match(line):
            continue
        if line.strip().startswith('(*'):
            continue
        # Skip lines that open or close blocks — masking those breaks nesting.
        if '{' in line or '}' in line:
            continue
        idx.append(i)
    return idx


def build_pairs(per_file: int) -> tuple[list[dict], dict]:
    stats = {'files': 0, 'unchecked': 0, 'no_mask': 0, 'dup': 0}
    dedup = NearDuplicateIndex(threshold=0.9)
    pairs = []

    for path in collect_aro_files():
        text = path.read_text(errors='replace')
        if len(text) > 8000 or text.count('\n') < 8:
            continue
        stats['files'] += 1
        if not aro_check_dir({'main.aro': text}):
            stats['unchecked'] += 1
            continue

        lines = text.split('\n')
        candidates = maskable_lines(lines)
        if not candidates:
            stats['no_mask'] += 1
            continue

        for start in RNG.sample(candidates, min(per_file, len(candidates))):
            # 1–2 statement span when the next line is also maskable.
            span = 2 if (start + 1 in candidates and RNG.random() < 0.3) else 1
            middle = '\n'.join(lines[start:start + span])
            masked = lines[:start] + ['    <MISSING>'] + lines[start + span:]

            instruction = (
                'Complete this ARO code: replace <MISSING> with the missing '
                'statement' + ('s' if span > 1 else '') + '. Match the '
                'surrounding style exactly and output ONLY the missing '
                'line' + ('s' if span > 1 else '') + ' in one ```aro block.'
                '\n\n```aro\n' + '\n'.join(masked) + '\n```'
            )
            if dedup.check_and_add(instruction):
                stats['dup'] += 1
                continue
            pairs.append({
                'instruction': instruction,
                'output': '```aro\n' + middle + '\n```',
                'source': 'example',           # ground truth IS the example
                'task_type': 'fim',
                'category': f'fim_{span}stmt',
            })

    return pairs, stats


def main():
    ap = argparse.ArgumentParser()
    stage_runner.add_stage_arguments(ap)   # --dry-run / --limit (GitLab #803)
    ap.add_argument('--per-file', type=int, default=2)
    args = ap.parse_args()
    opts = stage_runner.StageOptions.from_args(args)

    probe = subprocess.run(['aro', '--version'], capture_output=True)
    if probe.returncode != 0:
        sys.exit('no working `aro` on PATH — refusing to emit unvalidated fim data')

    pairs, stats = build_pairs(args.per_file)
    pairs = opts.apply(pairs)
    print(f"files: {stats['files']} (skipped: {stats['unchecked']} failed "
          f"check, {stats['no_mask']} nothing maskable) | "
          f"dups dropped: {stats['dup']}")
    print(f'fim pairs: {len(pairs)}')

    if args.dry_run:
        print('dry run — nothing saved')
        return 0

    removed = clean_notebook_pairs(NOTEBOOK_TAG)
    if removed:
        print(f'replaced {removed} previous pairs')
    written = save_notebook_pairs(NOTEBOOK_TAG, pairs)
    print(f'saved {written} pairs as {NOTEBOOK_TAG}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
