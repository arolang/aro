"""Fail when a training notebook declares a hyper-parameter of its own.

GitLab #795. Hyper-parameters used to be declared in eight notebooks, which
then disagreed — gradient accumulation was 16 in one stage "to smooth
heterogeneous-task gradient noise" and 4 in another "for NaN robustness", on
the same model — and nothing made the disagreement visible. config.HPARAMS is
now the one table; this check is what keeps it the one table.

Two things are checked per training notebook:

  * every constant the stage uses is read from `HP[...]`, not written as a
    literal;
  * the mlx-lm command line passes no quoted numeric literal for a flag that
    HPARAMS covers — `'--learning-rate', '1e-5'` bypasses the table just as
    effectively as an assignment does, and is easier to miss.

    python3 Train/script/check_hparams.py          # exit 1 on any finding
    python3 Train/script/check_hparams.py --list   # print the table instead
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import config  # noqa: E402

SCRIPT_DIR = Path(__file__).resolve().parent

# notebook -> (stage, {notebook constant name: HPARAMS key})
NOTEBOOK_STAGES = {
    '07_warmstart_finetune.ipynb': ('warm_start', {
        'batch_size': 'batch_size',
    }),
    '18_finetune.ipynb': ('sft', {
        'BATCH_SIZE': 'batch_size', 'GRAD_ACCUM': 'grad_accum',
        'LORA_LAYERS': 'lora_layers', 'LORA_RANK': 'lora_rank',
        'LEARNING_RATE': 'learning_rate', 'WEIGHT_DECAY': 'weight_decay',
        'ITERS': 'iters', 'MAX_SEQ_LEN': 'max_seq_len',
        'STEPS_PER_EVAL': 'steps_per_eval', 'VAL_BATCHES': 'val_batches',
        'LR_WARMUP': 'lr_warmup',
    }),
    '19_preference_sft.ipynb': ('preference', {
        'MAX_SEQ_LEN': 'max_seq_len', 'BATCH_SIZE': 'batch_size',
        'GRAD_ACCUM': 'grad_accum', 'LORA_LAYERS': 'lora_layers',
        'LORA_RANK': 'lora_rank', 'LEARNING_RATE': 'learning_rate',
        'DPO_ITERS': 'iters', 'PREF_BETA': 'beta',
    }),
    '21_iterative_loop.ipynb': ('iterative', {
        'ITERS_PER_ROUND': 'iters_per_round', 'BATCH_SIZE': 'batch_size',
        'GRAD_ACCUM': 'grad_accum', 'LORA_RANK': 'lora_rank',
        'LORA_LAYERS': 'lora_layers', 'LEARNING_RATE': 'learning_rate',
        'MAX_SEQ_LEN': 'max_seq_len', 'STEPS_PER_EVAL': 'steps_per_eval',
        'WEIGHT_DECAY': 'weight_decay',
    }),
    '22_distillation.ipynb': ('student', {
        'STUDENT_LR': 'learning_rate', 'STUDENT_MAX_SEQ_LEN': 'max_seq_len',
    }),
    '23_material_finetune.ipynb': ('material', {
        'LR': 'learning_rate', 'BATCH': 'batch_size', 'RANK': 'lora_rank',
        'LAYERS': 'lora_layers', 'MAX_SEQ': 'max_seq_len',
    }),
    '24_thinking_finetune.ipynb': ('thinking', {
        'ITERS': 'iters', 'LORA_LAYERS': 'lora_layers',
        'BATCH_SIZE': 'batch_size', 'LEARNING_RATE': 'learning_rate',
    }),
    '25_conversation_finetune.ipynb': ('conversation', {
        'ITERS': 'iters', 'LORA_LAYERS': 'lora_layers',
        'BATCH_SIZE': 'batch_size', 'GRAD_ACCUM': 'grad_accum',
        'LEARNING_RATE': 'learning_rate', 'MAX_SEQ': 'max_seq_len',
    }),
}

# mlx-lm flags HPARAMS covers. A quoted numeric literal after one of these
# bypasses the table.
COVERED_FLAGS = (
    '--learning-rate', '--num-layers', '--batch-size',
    '--grad-accumulation-steps', '--iters', '--max-seq-length',
)

_LITERAL_ASSIGN = re.compile(
    r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([-+0-9][-+0-9eE._]*)\s*(#.*)?$')
_LITERAL_FLAG = re.compile(
    r"""(--[a-z-]+)['"]\s*,\s*['"]([0-9][0-9eE.+-]*)['"]""")


def code_lines(nb_path: Path):
    """(cell index, line index, text) for every code line in a notebook."""
    nb = json.loads(nb_path.read_text())
    for ci, cell in enumerate(nb.get('cells', [])):
        if cell.get('cell_type') != 'code':
            continue
        for li, line in enumerate(cell.get('source', [])):
            yield ci, li, line.rstrip('\n')


def check_notebook(nb_path: Path, stage: str, mapping: dict):
    """Findings for one notebook, as human-readable strings."""
    findings = []
    lines = list(code_lines(nb_path))
    text = '\n'.join(line for _, _, line in lines)

    if 'hparams(' not in text:
        findings.append(f'{nb_path.name}: never calls hparams({stage!r}) — '
                        'its settings are not coming from config.HPARAMS')

    for ci, li, line in lines:
        m = _LITERAL_ASSIGN.match(line)
        if m and m.group(1) in mapping:
            findings.append(
                f'{nb_path.name}: cell {ci} line {li}: '
                f'{m.group(1)} = {m.group(2)} is a literal — '
                f"use HP[{mapping[m.group(1)]!r}] (config.HPARAMS[{stage!r}])")

        for flag, value in _LITERAL_FLAG.findall(line):
            if flag in COVERED_FLAGS:
                findings.append(
                    f'{nb_path.name}: cell {ci} line {li}: '
                    f"{flag} is passed the literal '{value}' — "
                    f'HPARAMS[{stage!r}] is meant to decide that')

    return findings


def check_all(script_dir: Path = SCRIPT_DIR, stages=None):
    stages = stages if stages is not None else NOTEBOOK_STAGES
    findings = []
    for name, (stage, mapping) in sorted(stages.items()):
        path = script_dir / name
        if not path.is_file():
            findings.append(f'{name}: notebook missing — '
                            'update NOTEBOOK_STAGES in check_hparams.py')
            continue
        findings.extend(check_notebook(path, stage, mapping))
    return findings


def print_table():
    print(f'config.HPARAMS  ({config.HPARAMS_VERSION})\n')
    keys = sorted({k for row in config.HPARAMS.values() for k in row})
    width = max(len(s) for s in config.HPARAMS)
    print(' ' * (width + 2) + '  '.join(f'{k:>14}' for k in keys))
    for stage, row in config.HPARAMS.items():
        cells = '  '.join(f'{str(row.get(k, "—")):>14}' for k in keys)
        print(f'{stage:<{width}}  {cells}')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--list', action='store_true',
                    help='print the HPARAMS table instead of checking')
    args = ap.parse_args(argv)

    if args.list:
        print_table()
        return 0

    findings = check_all()
    if findings:
        print('Hyper-parameters escaping config.HPARAMS (GitLab #795):\n')
        for f in findings:
            print(f'  - {f}')
        print(f'\n{len(findings)} finding(s).')
        return 1
    print(f'All {len(NOTEBOOK_STAGES)} training notebooks read config.HPARAMS '
          f'({config.HPARAMS_VERSION}).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
