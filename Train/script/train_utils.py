"""
Training utilities shared by the fine-tune notebooks (NB05/NB17/NB18/NB20).

Pure-python helpers — no mlx import at module level so the module stays
importable (and testable) on Linux CI where mlx is unavailable.

Covers:
  - LR schedule config for mlx-lm YAML configs        (issue #412)
  - Resume-from-checkpoint discovery                  (issue #423)
  - Convergence detection for the iterative loop      (issue #420)
  - Per-task regression detection across rounds       (issue #421)
  - Min-max per-task checkpoint selection             (issue #392)
"""

import json
import re
from pathlib import Path

# ── LR schedule (issue #412) ─────────────────────────────────────────────────
# mlx-lm's lora trainer accepts an `lr_schedule` block in its YAML config and
# builds the schedule via mlx.optimizers.schedulers (see
# mlx_lm/tuner/utils.py:build_schedule). `arguments` are passed positionally
# to the scheduler; for cosine_decay that is (init_lr, decay_steps, end_lr).


def lr_schedule_config(base_lr, total_iters, kind='cosine_decay',
                       warmup=0, end_factor=0.1, warmup_init_factor=0.1):
    """Return the `lr_schedule` dict for an mlx-lm lora YAML config.

    kind: 'cosine_decay' (default) or any mlx.optimizers.schedulers name
    whose first argument is the initial LR.
    """
    decay_steps = max(1, int(total_iters) - int(warmup))
    cfg = {
        'name': kind,
        'arguments': [float(base_lr), decay_steps, float(base_lr) * end_factor],
    }
    if warmup > 0:
        cfg['warmup'] = int(warmup)
        cfg['warmup_init'] = float(base_lr) * warmup_init_factor
    return cfg


# ── Resume from checkpoint (issue #423) ──────────────────────────────────────

_CKPT_RE = re.compile(r'^(\d+)_adapters\.safetensors$')


def find_resume_checkpoint(adapter_dir):
    """Find the latest intermediate checkpoint in an adapter directory.

    mlx-lm saves intermediate checkpoints as NNNNNNN_adapters.safetensors.
    Returns (checkpoint_path or None, completed_iters). completed_iters is 0
    when no checkpoint exists.
    """
    adapter_dir = Path(adapter_dir)
    if not adapter_dir.exists():
        return None, 0
    best = None
    best_iter = 0
    for p in adapter_dir.iterdir():
        m = _CKPT_RE.match(p.name)
        if m:
            it = int(m.group(1))
            if it > best_iter:
                best_iter = it
                best = p
    return best, best_iter


def resolve_resume(adapter_dir, total_iters, fallback_adapter=None,
                   enabled=True):
    """Decide how an (possibly interrupted) training run should start.

    Returns (resume_file or None, run_iters, decision_str):
      - a previous partial run exists  → resume from its latest checkpoint
        with the remaining iterations
      - previous run already complete  → start fresh full run (checkpoints
        from the finished run are ignored; clear the dir to silence this)
      - nothing to resume              → use `fallback_adapter` (e.g. the
        warm-start adapter) for the full iteration count
    """
    ckpt, done = find_resume_checkpoint(adapter_dir)
    if enabled and ckpt is not None and 0 < done < total_iters:
        remaining = total_iters - done
        return ckpt, remaining, (
            f'RESUME: found checkpoint {ckpt.name} (iter {done}/{total_iters}) '
            f'— resuming with {remaining} remaining iterations')
    if ckpt is not None and done >= total_iters:
        decision = (
            f'NOT resuming: latest checkpoint {ckpt.name} already covers '
            f'{done} >= {total_iters} iters (previous run complete). '
            f'Starting a fresh run; clear {adapter_dir} to remove old checkpoints.')
    elif not enabled:
        decision = 'NOT resuming: RESUME_FROM_CHECKPOINT disabled'
    else:
        decision = 'No previous checkpoint found — starting fresh'
    if fallback_adapter is not None:
        decision += f' (initial weights: {fallback_adapter})'
    return fallback_adapter, total_iters, decision


# ── Convergence detection (issue #420) ───────────────────────────────────────

def check_convergence(pass_rates, val_losses=None, pass_tol=0.02,
                      loss_tol=0.01, patience=2):
    """Detect a converged iterative loop.

    pass_rates: per-round syntax pass rates (floats, chronological).
    val_losses: per-round best validation losses (may be None / contain None).
    Converged when the last `patience` consecutive round-to-round deltas of
    the pass rate are all within `pass_tol` AND (when val losses are
    available) the val-loss deltas are within `loss_tol`.

    Returns (converged: bool, reason: str).
    """
    if len(pass_rates) < patience + 1:
        return False, (f'not enough rounds ({len(pass_rates)}) for '
                       f'convergence check (need {patience + 1})')

    recent = pass_rates[-(patience + 1):]
    deltas = [abs(recent[i + 1] - recent[i]) for i in range(patience)]
    pass_flat = all(d <= pass_tol for d in deltas)

    loss_flat = True
    loss_msg = 'val loss not available'
    if val_losses is not None:
        recent_vl = [v for v in val_losses[-(patience + 1):] if v is not None]
        if len(recent_vl) >= patience + 1:
            vdeltas = [abs(recent_vl[i + 1] - recent_vl[i]) for i in range(patience)]
            loss_flat = all(d <= loss_tol for d in vdeltas)
            loss_msg = (f'val-loss deltas {["%.4f" % d for d in vdeltas]} '
                        f'(tol {loss_tol})')

    pass_msg = (f'pass-rate deltas {["%.3f" % d for d in deltas]} '
                f'(tol {pass_tol})')
    if pass_flat and loss_flat:
        return True, (f'converged: flat for {patience} consecutive rounds — '
                      f'{pass_msg}; {loss_msg}')
    return False, f'not converged — {pass_msg}; {loss_msg}'


def best_round(round_metrics, key='syntax_pass_rate'):
    """Return the metrics dict of the best training round (round >= 0)."""
    trained = [m for m in round_metrics if m.get('round', -1) >= 0]
    if not trained:
        return None
    return max(trained, key=lambda m: m.get(key, 0.0))


# ── Per-task regression detection (issue #421) ──────────────────────────────

def detect_regressions(per_task_history, threshold=0.10):
    """Compare the latest round's per-task metrics against the best previous
    value for each task.

    per_task_history: list of {task: rate} dicts, chronological (one per round).
    Returns a list of dicts {task, best_previous, current, drop} for every
    task whose current value fell more than `threshold` below its best
    previous value.
    """
    if len(per_task_history) < 2:
        return []
    current = per_task_history[-1]
    regressions = []
    for task, rate in current.items():
        prev_vals = [h[task] for h in per_task_history[:-1] if task in h]
        if not prev_vals:
            continue
        best_prev = max(prev_vals)
        drop = best_prev - rate
        if drop > threshold:
            regressions.append({
                'task': task,
                'best_previous': round(best_prev, 4),
                'current': round(rate, 4),
                'drop': round(drop, 4),
            })
    return sorted(regressions, key=lambda r: -r['drop'])


def per_task_trends(per_task_history):
    """Per-task series across rounds: {task: [rate_round0, rate_round1, ...]}.
    Missing rounds are recorded as None."""
    tasks = set()
    for h in per_task_history:
        tasks.update(h.keys())
    return {t: [h.get(t) for h in per_task_history] for t in sorted(tasks)}


# ── Per-task checkpoint selection (issue #392) ───────────────────────────────

def select_min_max_checkpoint(per_ckpt_task_losses):
    """Pick the checkpoint that minimises the WORST per-task validation loss.

    per_ckpt_task_losses: {ckpt_name: {task: mean_nll}}.
    Ties on max-loss are broken by mean loss. Returns
    (ckpt_name, {'max_loss': .., 'mean_loss': .., 'per_task': {..}}) or
    (None, None) when input is empty.
    """
    best_name, best_stats = None, None
    for name, task_losses in per_ckpt_task_losses.items():
        vals = [v for v in task_losses.values() if v is not None]
        if not vals:
            continue
        stats = {
            'max_loss': max(vals),
            'mean_loss': sum(vals) / len(vals),
            'per_task': dict(task_losses),
        }
        if (best_stats is None
                or (stats['max_loss'], stats['mean_loss'])
                < (best_stats['max_loss'], best_stats['mean_loss'])):
            best_name, best_stats = name, stats
    return best_name, best_stats


def source_to_task_type(source):
    """Map a knowledge_pairs `source` tag to a coarse task type.
    Mirrors NB16's mapping so NB05's per-task validation uses the same
    categories as the dataset assembly."""
    src = (source or '').lower()
    if any(src.startswith(p) for p in ('book_qa:', 'wiki:', 'actions_explain',
                                       'actions_which')):
        return 'syntax_qa'
    if src.startswith('repair'):
        return 'debugging'
    return 'code_generation'


def load_json(path, default=None):
    """Best-effort JSON load — returns `default` when missing/corrupt."""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default
