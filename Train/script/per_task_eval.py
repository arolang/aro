"""
Per-task validation loss for a LoRA checkpoint (issue #392).

Run as a subprocess from NB05 so the ~15 GB model is released between
checkpoints:

    python per_task_eval.py \
        --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit \
        --adapter-config-dir ../data/adapters/warm_start \
        --ckpt ../data/adapters/warm_start/0000200_adapters.safetensors \
        --data ../data/warm_start_sft/valid_tagged.jsonl \
        --max-per-task 12 --out result.json

`--data` is a JSONL of {"messages": [...], "task_type": "..."} records.
The script loads the base model with the given checkpoint applied (using
the adapter_config.json from --adapter-config-dir), computes the mean
negative log-likelihood of the assistant completion per task type (prompt
tokens masked, mirroring --mask-prompt training), and writes JSON:

    {"per_task": {"code_generation": {"mean_nll": 0.41, "n": 12}, ...},
     "overall": {"mean_nll": ..., "n": ...}}
"""

import argparse
import json
import shutil
import sys
import tempfile
from collections import defaultdict
from pathlib import Path


def _load_records(data_path, max_per_task, seed=0):
    import random
    by_task = defaultdict(list)
    with open(data_path) as f:
        for line in f:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get('messages'):
                by_task[rec.get('task_type', 'unknown')].append(rec)
    rng = random.Random(seed)
    picked = {}
    for task, recs in sorted(by_task.items()):
        picked[task] = (rng.sample(recs, max_per_task)
                        if len(recs) > max_per_task else list(recs))
    return picked


def _sequence_nll(model, tokenizer, messages, max_tokens):
    """Mean NLL over the assistant-completion tokens of a chat sample.
    Returns (nll, n_completion_tokens) or None when the sample is unusable."""
    import mlx.core as mx
    import mlx.nn as nn

    prompt_text = tokenizer.apply_chat_template(
        messages[:-1], tokenize=False, add_generation_prompt=True)
    full_text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=False)

    prompt_ids = tokenizer.encode(prompt_text)
    full_ids = tokenizer.encode(full_text)
    if len(full_ids) > max_tokens:
        full_ids = full_ids[:max_tokens]
    prompt_len = min(len(prompt_ids), len(full_ids))
    if len(full_ids) - prompt_len < 2:
        return None

    toks = mx.array(full_ids)
    inputs = toks[:-1][None]
    targets = toks[1:][None]
    logits = model(inputs)
    ce = nn.losses.cross_entropy(logits, targets)          # (1, L-1)
    # Target position i predicts token i+1 → completion targets start at
    # index prompt_len - 1.
    steps = mx.arange(targets.shape[1])
    mask = (steps >= (prompt_len - 1)).astype(ce.dtype)[None]
    ntoks = mask.sum()
    nll = (ce * mask).astype(mx.float32).sum() / ntoks
    mx.eval(nll)
    return float(nll.item()), int(ntoks.item())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', required=True)
    ap.add_argument('--adapter-config-dir', required=True,
                    help='adapter dir containing adapter_config.json')
    ap.add_argument('--ckpt', default=None,
                    help='specific NNNNNNN_adapters.safetensors checkpoint; '
                         'defaults to adapters.safetensors in the adapter dir')
    ap.add_argument('--data', required=True,
                    help='JSONL with {"messages": [...], "task_type": "..."}')
    ap.add_argument('--max-per-task', type=int, default=12)
    ap.add_argument('--max-tokens', type=int, default=2048)
    ap.add_argument('--out', required=True)
    args = ap.parse_args(argv)

    from mlx_lm import load

    adapter_dir = Path(args.adapter_config_dir)
    config_file = adapter_dir / 'adapter_config.json'
    if not config_file.exists():
        print(f'ERROR: {config_file} not found', file=sys.stderr)
        return 2

    # Assemble a temp adapter dir so we can point mlx-lm at an arbitrary
    # intermediate checkpoint (load() expects adapters.safetensors).
    with tempfile.TemporaryDirectory() as tmp:
        tmp_adapter = Path(tmp) / 'adapter'
        tmp_adapter.mkdir()
        shutil.copy2(config_file, tmp_adapter / 'adapter_config.json')
        weights = Path(args.ckpt) if args.ckpt else adapter_dir / 'adapters.safetensors'
        if not weights.exists():
            print(f'ERROR: weights not found: {weights}', file=sys.stderr)
            return 2
        shutil.copy2(weights, tmp_adapter / 'adapters.safetensors')

        print(f'Loading {args.model} + {weights.name} ...', flush=True)
        model, tokenizer = load(args.model, adapter_path=str(tmp_adapter))

    by_task = _load_records(args.data, args.max_per_task)
    per_task = {}
    total_nll, total_n = 0.0, 0
    for task, recs in by_task.items():
        losses = []
        for rec in recs:
            r = _sequence_nll(model, tokenizer, rec['messages'], args.max_tokens)
            if r is not None:
                losses.append(r[0])
        if losses:
            mean_nll = sum(losses) / len(losses)
            per_task[task] = {'mean_nll': round(mean_nll, 5), 'n': len(losses)}
            total_nll += sum(losses)
            total_n += len(losses)
            print(f'  {task:<20} mean_nll={mean_nll:.4f}  (n={len(losses)})',
                  flush=True)

    result = {
        'checkpoint': args.ckpt or str(adapter_dir / 'adapters.safetensors'),
        'per_task': per_task,
        'overall': {'mean_nll': round(total_nll / total_n, 5) if total_n else None,
                    'n': total_n},
    }
    with open(args.out, 'w') as f:
        json.dump(result, f, indent=2)
    print(f'Wrote {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
