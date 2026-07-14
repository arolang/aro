"""
Preference-loss LoRA training for NB18 (issue #413).

mlx-lm's `lora` CLI has no DPO/preference trainer, so NB18 used to discard
the rejected side of every (prompt, chosen, rejected) triple and run plain
chosen-only SFT. This module is a small custom MLX training loop that
actually uses the rejected samples:

    loss = CE(chosen completion)                              # stay an SFT
         + beta * max(0, margin - (lp_chosen - lp_rejected))  # ranking term

where lp_* is the length-normalised sequence log-probability of the
completion given the prompt. The cross-entropy anchor keeps the model
producing valid ARO (pure ranking objectives degenerate on small pair
counts); the hinge pushes the chosen answer above the rejected one by at
least `margin` nats/token. Empty-content penalty pairs (rejected == "")
reduce to penalising the model's confidence in immediate EOS — the exact
round-2 collapse mode.

Invoked by NB18 as a subprocess. Output lines intentionally match the
mlx_lm.lora format ("Iter N: Train loss X", "Iter N: Val loss X",
"Adapter saved") so NB18's existing NaN/explosion monitoring keeps working
unchanged. The saved adapter directory (adapter_config.json +
adapters.safetensors + NNNNNNN_adapters.safetensors checkpoints) is
compatible with `mlx_lm.load(..., adapter_path=...)` and `mlx_lm fuse`.

Data format (train.jsonl / valid.jsonl in --data dir), one JSON per line:
    {"prompt":   [{"role": "system", ...}, {"role": "user", ...}],
     "chosen":   [{"role": "assistant", "content": "..."}],
     "rejected": [{"role": "assistant", "content": "..."}]}
"""

import argparse
import json
import random
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))


# ── Data ─────────────────────────────────────────────────────────────────────

def load_pairs(path):
    pairs = []
    with open(path) as f:
        for line in f:
            if not line.strip():
                continue
            p = json.loads(line)
            if p.get('prompt') and p.get('chosen') is not None \
                    and p.get('rejected') is not None:
                pairs.append(p)
    return pairs


def _completion_content(msgs):
    if isinstance(msgs, list) and msgs:
        return msgs[0].get('content', '') or ''
    if isinstance(msgs, str):
        return msgs
    return ''


def tokenize_pair(tokenizer, pair, max_seq_length):
    """Tokenize one preference pair.

    Returns (chosen_ids, rejected_ids, prompt_len) or None when either
    sequence would be truncated (truncated chosen completions are a known
    NaN trigger — skip instead).
    """
    prompt_text = tokenizer.apply_chat_template(
        pair['prompt'], tokenize=False, add_generation_prompt=True)
    prompt_ids = tokenizer.encode(prompt_text)

    eos = tokenizer.eos_token or ''

    def completion_ids(msgs):
        content = _completion_content(msgs)
        return tokenizer.encode(content + eos, add_special_tokens=False)

    chosen = prompt_ids + completion_ids(pair['chosen'])
    rejected = prompt_ids + completion_ids(pair['rejected'])
    if len(chosen) > max_seq_length or len(rejected) > max_seq_length:
        return None
    if len(chosen) - len(prompt_ids) < 1 or len(rejected) - len(prompt_ids) < 1:
        return None
    return chosen, rejected, len(prompt_ids)


# ── Loss ─────────────────────────────────────────────────────────────────────

def _completion_nll(model, token_ids, prompt_len):
    """Mean per-token NLL of the completion (prompt masked).
    token_ids: mx.array of the full prompt+completion sequence."""
    import mlx.core as mx
    import mlx.nn as nn

    inputs = token_ids[:-1][None]
    targets = token_ids[1:][None]
    logits = model(inputs)
    ce = nn.losses.cross_entropy(logits, targets)          # (1, L-1)
    steps = mx.arange(targets.shape[1])
    mask = (steps >= (prompt_len - 1)).astype(mx.float32)[None]
    ntoks = mask.sum()
    return (ce.astype(mx.float32) * mask).sum() / ntoks


def pair_loss(model, chosen_ids, rejected_ids, prompt_len, margin, beta):
    """Preference loss for one pair. Returns (loss, ce_chosen, hinge, pref_ok)."""
    import mlx.core as mx

    ce_chosen = _completion_nll(model, chosen_ids, prompt_len)
    ce_rejected = _completion_nll(model, rejected_ids, prompt_len)
    lp_chosen = -ce_chosen        # mean log-prob per completion token
    lp_rejected = -ce_rejected
    hinge = mx.maximum(0.0, margin - (lp_chosen - lp_rejected))
    loss = ce_chosen + beta * hinge
    pref_ok = (lp_chosen > lp_rejected).astype(mx.float32)
    return loss, ce_chosen, hinge, pref_ok


# ── Adapter save ─────────────────────────────────────────────────────────────

def save_adapter(model, adapter_dir, iteration=None):
    import mlx.core as mx
    from mlx.utils import tree_flatten

    adapter_dir = Path(adapter_dir)
    adapter_dir.mkdir(parents=True, exist_ok=True)
    weights = dict(tree_flatten(model.trainable_parameters()))
    final = adapter_dir / 'adapters.safetensors'
    mx.save_safetensors(str(final), weights)
    if iteration is not None:
        mx.save_safetensors(
            str(adapter_dir / f'{iteration:07d}_adapters.safetensors'), weights)
    print(f'Iter {iteration if iteration is not None else "final"}: '
          f'Adapter saved to {final}', flush=True)


# ── Training loop ────────────────────────────────────────────────────────────

def train_preference(args):
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    from mlx.utils import tree_map
    from mlx_lm import load
    from mlx_lm.tuner.utils import (build_schedule, linear_to_lora_layers,
                                    print_trainable_parameters)
    from mlx_lm.utils import save_config

    from config import patch_qwen3_chat_template
    from train_utils import lr_schedule_config

    mx.random.seed(args.seed)
    random.seed(args.seed)
    if mx.metal.is_available():
        mx.set_wired_limit(mx.device_info()['max_recommended_working_set_size'])

    data_dir = Path(args.data)
    train_pairs = load_pairs(data_dir / 'train.jsonl')
    valid_pairs = load_pairs(data_dir / 'valid.jsonl')
    print(f'Loaded {len(train_pairs)} train / {len(valid_pairs)} valid '
          f'preference pairs', flush=True)
    if len(train_pairs) < 4:
        print('ERROR: too few training pairs (<4)', file=sys.stderr)
        return 1

    print(f'Loading model {args.model} ...', flush=True)
    model, tokenizer = load(args.model)
    patch_qwen3_chat_template(tokenizer)

    # Tokenize up front; skip pairs that would truncate.
    def tokenize_all(pairs, label):
        out = []
        skipped = 0
        for p in pairs:
            t = tokenize_pair(tokenizer, p, args.max_seq_length)
            if t is None:
                skipped += 1
            else:
                out.append(t)
        if skipped:
            print(f'  {label}: skipped {skipped} pairs > {args.max_seq_length} '
                  f'tokens (or empty completions)', flush=True)
        return out

    train_tok = tokenize_all(train_pairs, 'train')
    valid_tok = tokenize_all(valid_pairs, 'valid')
    if len(train_tok) < 4:
        print('ERROR: too few usable pairs after tokenization', file=sys.stderr)
        return 1

    # ── LoRA surgery ────────────────────────────────────────────────────────
    model.freeze()
    lora_parameters = {
        'rank': args.lora_rank,
        'dropout': args.lora_dropout,
        'scale': args.lora_scale,
    }
    linear_to_lora_layers(model, args.num_layers, lora_parameters)
    if args.resume_adapter_file:
        print(f'Loading fine-tuned weights from {args.resume_adapter_file}',
              flush=True)
        model.load_weights(args.resume_adapter_file, strict=False)
    print_trainable_parameters(model)

    adapter_dir = Path(args.adapter_path)
    adapter_dir.mkdir(parents=True, exist_ok=True)
    # adapter_config.json compatible with mlx_lm.tuner.utils.load_adapters
    # (and therefore `mlx_lm.load(adapter_path=...)` and `mlx_lm fuse`).
    save_config({
        'fine_tune_type': 'lora',
        'num_layers': args.num_layers,
        'lora_parameters': lora_parameters,
        'trainer': 'preference_loss.py',
        'margin': args.margin,
        'beta': args.beta,
        'learning_rate': args.learning_rate,
        'weight_decay': args.weight_decay,
        'iters': args.iters,
    }, adapter_dir / 'adapter_config.json')

    # ── Optimizer + schedule ───────────────────────────────────────────────
    if args.lr_schedule == 'cosine':
        lr = build_schedule(lr_schedule_config(
            args.learning_rate, args.iters,
            warmup=min(args.lr_warmup, max(0, args.iters // 10))))
    else:
        lr = args.learning_rate
    optimizer = optim.AdamW(learning_rate=lr, weight_decay=args.weight_decay)

    def loss_fn(model, chosen_ids, rejected_ids, prompt_len):
        return pair_loss(model, chosen_ids, rejected_ids, prompt_len,
                         args.margin, args.beta)

    loss_and_grad = nn.value_and_grad(model, loss_fn)

    def evaluate(n_pairs):
        model.eval()
        subset = valid_tok[:n_pairs] if n_pairs else valid_tok
        tot, tot_ce, tot_hinge, tot_pref = 0.0, 0.0, 0.0, 0.0
        for chosen, rejected, plen in subset:
            loss, ce, hinge, pref = loss_fn(
                model, mx.array(chosen), mx.array(rejected), plen)
            mx.eval(loss, ce, hinge, pref)
            tot += loss.item()
            tot_ce += ce.item()
            tot_hinge += hinge.item()
            tot_pref += pref.item()
        model.train()
        n = max(1, len(subset))
        return tot / n, tot_ce / n, tot_hinge / n, tot_pref / n

    # ── Loop ────────────────────────────────────────────────────────────────
    model.train()
    order = list(range(len(train_tok)))
    random.shuffle(order)
    cursor = 0
    acc_grads = None
    running_loss, running_ce, running_hinge, running_n = 0.0, 0.0, 0.0, 0
    t0 = time.perf_counter()

    for it in range(1, args.iters + 1):
        if valid_tok and (it == 1 or it % args.steps_per_eval == 0
                          or it == args.iters):
            v_loss, v_ce, v_hinge, v_pref = evaluate(args.val_pairs)
            print(f'Iter {it}: Val loss {v_loss:.3f}, '
                  f'Val CE {v_ce:.3f}, Val hinge {v_hinge:.3f}, '
                  f'Pref acc {v_pref:.2f}', flush=True)

        # one micro-batch = one pair (batch_size kept for CLI compatibility)
        for _ in range(max(1, args.batch_size)):
            if cursor >= len(order):
                random.shuffle(order)
                cursor = 0
            chosen, rejected, plen = train_tok[order[cursor]]
            cursor += 1

            (loss, ce, hinge, _pref), grads = loss_and_grad(
                model, mx.array(chosen), mx.array(rejected), plen)
            acc_grads = grads if acc_grads is None else tree_map(
                lambda a, b: a + b, acc_grads, grads)
            mx.eval(loss, acc_grads)
            running_loss += loss.item()
            running_ce += ce.item()
            running_hinge += hinge.item()
            running_n += 1

        if it % args.grad_accumulation_steps == 0:
            n_micro = args.grad_accumulation_steps * max(1, args.batch_size)
            acc_grads = tree_map(lambda g: g / n_micro, acc_grads)
            acc_grads, _norm = optim.clip_grad_norm(acc_grads, args.max_grad_norm)
            optimizer.update(model, acc_grads)
            mx.eval(model.parameters(), optimizer.state)
            acc_grads = None

        if it % args.steps_per_report == 0 or it == args.iters:
            n = max(1, running_n)
            elapsed = time.perf_counter() - t0
            cur_lr = optimizer.learning_rate
            mx.eval(cur_lr)
            print(f'Iter {it}: Train loss {running_loss / n:.3f}, '
                  f'CE {running_ce / n:.3f}, Hinge {running_hinge / n:.3f}, '
                  f'Learning Rate {float(cur_lr.item()):.3e}, '
                  f'It/sec {args.steps_per_report / max(elapsed, 1e-6):.3f}, '
                  f'Peak mem {mx.get_peak_memory() / 1e9:.3f} GB', flush=True)
            running_loss = running_ce = running_hinge = 0.0
            running_n = 0
            t0 = time.perf_counter()

        if it % args.save_every == 0:
            save_adapter(model, adapter_dir, iteration=it)

    save_adapter(model, adapter_dir, iteration=args.iters)
    print('Training complete.', flush=True)
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', required=True)
    ap.add_argument('--data', required=True,
                    help='dir containing preference train.jsonl / valid.jsonl')
    ap.add_argument('--adapter-path', required=True)
    ap.add_argument('--iters', type=int, default=200)
    ap.add_argument('--batch-size', type=int, default=1,
                    help='pairs per micro-step (keep 1 on 30B models)')
    ap.add_argument('--grad-accumulation-steps', type=int, default=8)
    ap.add_argument('--num-layers', type=int, default=8)
    ap.add_argument('--lora-rank', type=int, default=8)
    ap.add_argument('--lora-dropout', type=float, default=0.0)
    ap.add_argument('--lora-scale', type=float, default=20.0)
    ap.add_argument('--learning-rate', type=float, default=5e-6)
    ap.add_argument('--weight-decay', type=float, default=0.01)
    ap.add_argument('--lr-schedule', choices=['constant', 'cosine'],
                    default='cosine')
    ap.add_argument('--lr-warmup', type=int, default=20)
    ap.add_argument('--margin', type=float, default=0.5,
                    help='required log-prob/token gap between chosen and rejected')
    ap.add_argument('--beta', type=float, default=0.3,
                    help='weight of the ranking hinge term')
    ap.add_argument('--max-grad-norm', type=float, default=1.0)
    ap.add_argument('--max-seq-length', type=int, default=4096)
    ap.add_argument('--steps-per-report', type=int, default=5)
    ap.add_argument('--steps-per-eval', type=int, default=25)
    ap.add_argument('--val-pairs', type=int, default=16,
                    help='validation pairs per eval (0 = all)')
    ap.add_argument('--save-every', type=int, default=50)
    ap.add_argument('--resume-adapter-file', default=None)
    ap.add_argument('--seed', type=int, default=0)
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    return train_preference(args)


if __name__ == '__main__':
    sys.exit(main())
