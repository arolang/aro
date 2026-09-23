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
  - Disk-safe adapter fusing
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


# ── Resume provenance guard ──────────────────────────────────────────────────
# LoRA A/B tensors have identical shapes across the 4-bit and bf16 checkpoints
# of the same architecture, so `model.load_weights(ckpt, strict=False)` accepts
# an adapter trained on a *different* base without a word of complaint. On
# 2026-08-08 NB18 resumed `round_0/adapter/0000600` — trained 2026-08-04 against
# Qwen3-Coder-30B-A3B-Instruct-4bit — onto the bf16 base that config.py had
# since switched to, and training went NaN at iter 10 (before the first
# optimizer step, so it could not have been the learning rate).
#
# mlx-lm's own adapter_config.json is no help: it is rewritten with the *new*
# model id at the start of every run, so after one bad run it describes weights
# it does not match. We therefore keep our own sidecar, written only once the
# training command is actually launched, and refuse to resume unless it agrees
# with the run we are about to start. A missing sidecar means the checkpoints
# predate this guard — provenance unknown, so do not resume.

PROVENANCE_FILE = 'resume_provenance.json'


def write_resume_provenance(adapter_dir, base_model, lora_parameters=None,
                            num_layers=None):
    """Record what base model / LoRA geometry an adapter dir's checkpoints
    belong to. Call this when a training run starts writing into the dir."""
    adapter_dir = Path(adapter_dir)
    adapter_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        'base_model': base_model,
        'lora_parameters': lora_parameters,
        'num_layers': num_layers,
    }
    (adapter_dir / PROVENANCE_FILE).write_text(json.dumps(payload, indent=2))
    return payload


def read_resume_provenance(adapter_dir):
    """Read the provenance sidecar, or None when absent/unreadable."""
    path = Path(adapter_dir) / PROVENANCE_FILE
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (ValueError, OSError):
        return None


def check_resume_provenance(adapter_dir, base_model, lora_parameters=None,
                            num_layers=None):
    """Return (ok, reason) for resuming `adapter_dir` into the given run.

    `ok` is False when the sidecar is missing or disagrees with the run being
    started — resuming would silently load mismatched weights.
    """
    prov = read_resume_provenance(adapter_dir)
    if prov is None:
        return False, (f'no {PROVENANCE_FILE} — checkpoint provenance unknown '
                       f'(predates the provenance guard)')
    if prov.get('base_model') != base_model:
        return False, (f'checkpoint was trained against {prov.get("base_model")!r}, '
                       f'this run uses {base_model!r}')
    if (lora_parameters is not None and prov.get('lora_parameters') is not None
            and prov['lora_parameters'] != lora_parameters):
        return False, (f'checkpoint LoRA parameters {prov["lora_parameters"]} '
                       f'!= this run\'s {lora_parameters}')
    if (num_layers is not None and prov.get('num_layers') is not None
            and prov['num_layers'] != num_layers):
        return False, (f'checkpoint has {prov["num_layers"]} LoRA layers, '
                       f'this run uses {num_layers}')
    return True, 'provenance matches'


def resolve_resume(adapter_dir, total_iters, fallback_adapter=None,
                   enabled=True, base_model=None, lora_parameters=None,
                   num_layers=None):
    """Decide how an (possibly interrupted) training run should start.

    Returns (resume_file or None, run_iters, decision_str):
      - a previous partial run exists  → resume from its latest checkpoint
        with the remaining iterations
      - previous run already complete  → start fresh full run (checkpoints
        from the finished run are ignored; clear the dir to silence this)
      - nothing to resume              → use `fallback_adapter` (e.g. the
        warm-start adapter) for the full iteration count

    When `base_model` is given, a partial run is only resumed if the adapter
    dir's provenance sidecar agrees with it (see `check_resume_provenance`);
    otherwise the checkpoints are ignored and the run starts from
    `fallback_adapter`. Pass None to skip the check.
    """
    ckpt, done = find_resume_checkpoint(adapter_dir)
    mismatch = None
    if enabled and ckpt is not None and 0 < done < total_iters and base_model is not None:
        ok, reason = check_resume_provenance(
            adapter_dir, base_model, lora_parameters, num_layers)
        if not ok:
            mismatch = reason
    if mismatch is None and enabled and ckpt is not None and 0 < done < total_iters:
        remaining = total_iters - done
        return ckpt, remaining, (
            f'RESUME: found checkpoint {ckpt.name} (iter {done}/{total_iters}) '
            f'— resuming with {remaining} remaining iterations')
    if mismatch is not None:
        decision = (
            f'NOT resuming: {ckpt.name} exists but {mismatch}. '
            f'Ignoring the stale checkpoints and starting a fresh run — '
            f'clear {adapter_dir} to remove them.')
        if fallback_adapter is not None:
            decision += f' (initial weights: {fallback_adapter})'
        return fallback_adapter, total_iters, decision
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

    SUPERSEDED by `eval_stats.converged_by_overlap` (GitLab #786), which NB21
    now calls. This function compares pass-rate deltas against a fixed
    tolerance, and 0.02 is finer than the instrument it was applied to: on the
    60-prompt code-generation set the smallest non-zero delta expressible is
    1/60 = 0.0167, and on the 12-prompt task sets it is 0.083. The recorded
    2026-08 run stopped with "pass-rate deltas ['0.033', '0.017'] (tol 0.02)"
    — one of those two deltas is a single prompt. Kept for the existing tests
    and for reading old `round_results.json` files; do not use it for new
    stopping decisions.

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


# ── Fusing an adapter into a full model ──────────────────────────────────────
# `mlx_lm fuse` writes a complete copy of the base model — ~57 GB for the 30B
# bf16 Qwen3 — shard by shard, and only writes config.json at the very end. A
# disk that fills mid-write gives
#
#     RuntimeError: [write] Unable to write 402653184 bytes to file.
#
# after the fuse has already spent several minutes, and leaves the half-written
# shards behind: tens of GB that no selector will ever use (they look for
# config.json) and nobody thinks to delete. The next run then starts with even
# less room. `fuse_adapter` below checks the space BEFORE the fuse and removes
# the partial output AFTER a failure, so a too-small disk costs a second, not
# an hour, and never accumulates.

FUSE_HEADROOM = 0.03    # +3% over the measured weight bytes: index/tokenizer
                        # files and filesystem overhead


def _weight_bytes(model_dir):
    """Total bytes of the .safetensors shards in a model directory.

    Returns 0 when the path is not a local directory (a bare HF repo id, say),
    which callers read as "cannot estimate — skip the preflight".
    """
    d = Path(str(model_dir))
    if not d.is_dir():
        return 0
    return sum(f.stat().st_size for f in d.glob('*.safetensors') if f.is_file())


def free_bytes(path):
    """Free bytes on the filesystem holding `path` (nearest existing parent)."""
    import shutil as _shutil
    p = Path(str(path)).resolve()
    while not p.exists() and p.parent != p:
        p = p.parent
    return _shutil.disk_usage(p).free


def fused_model_is_complete(save_path):
    """True when `save_path` holds a fully written model.

    mlx-lm writes the shards first and config.json last, so config.json alone
    is a decent completeness marker — but a shard that failed mid-write can
    still leave the file short, so every shard named in the index must exist
    too.
    """
    d = Path(str(save_path))
    if not (d / 'config.json').exists():
        return False
    index = d / 'model.safetensors.index.json'
    if index.exists():
        try:
            with open(index) as f:
                weight_map = json.load(f).get('weight_map', {})
        except (OSError, ValueError):
            return False
        for shard in set(weight_map.values()):
            f = d / shard
            if not f.exists() or f.stat().st_size == 0:
                return False
        return True
    return any(d.glob('*.safetensors'))


def describe_fuse_space(model_path, save_path):
    """(need_bytes, free_bytes, ok) for fusing `model_path` into `save_path`.

    `need` is 0 when the source size cannot be measured; `ok` is then True —
    an unmeasurable source is not a reason to refuse to try.
    """
    need = int(_weight_bytes(model_path) * (1 + FUSE_HEADROOM))
    free = free_bytes(Path(str(save_path)).parent)
    return need, free, (need == 0 or free >= need)


def fuse_adapter(model_path, adapter_path, save_path, python=None,
                 extra_args=(), log=print, check_space=True):
    """Fuse a LoRA adapter into a full model, safely on a finite disk.

    Removes any existing output first (its bytes count toward the space the
    new copy needs), refuses up front when the filesystem cannot hold the
    result, and deletes a partial output when the fuse fails, so a failure
    leaves the disk as it found it.

    Returns the save path. Raises RuntimeError with the GB numbers on a
    space failure, so the message says what to free rather than which byte
    count could not be written.
    """
    import shutil as _shutil
    import subprocess as _subprocess
    import sys as _sys

    python = python or _sys.executable
    model_path, adapter_path = str(model_path), str(adapter_path)
    save = Path(str(save_path))

    # An existing output — complete or half-written — is about to be replaced.
    # Delete it first: its bytes are space the new copy can use.
    if save.exists():
        freed = sum(f.stat().st_size for f in save.rglob('*') if f.is_file())
        state = 'complete' if fused_model_is_complete(save) else 'PARTIAL'
        log(f'Removing existing {state} output at {save} '
            f'({freed / 1e9:.1f} GB reclaimed)')
        _shutil.rmtree(save, ignore_errors=True)

    need, free, ok = describe_fuse_space(model_path, save)
    if need:
        log(f'Fuse needs ~{need / 1e9:.1f} GB, {free / 1e9:.1f} GB free '
            f'on {save.parent}')
    if check_space and not ok:
        import platform as _platform
        # macOS keeps the blocks of recently deleted files in Time Machine
        # local snapshots, where they count as used rather than free until the
        # snapshot ages out. Deleting a 60 GB model can therefore appear to
        # free nothing; `tmutil listlocalsnapshots /` shows whether that is
        # what is happening.
        snapshot_note = (
            ' On macOS, space freed by deleting large files stays in Time '
            'Machine local snapshots until they expire \u2014 check '
            '`tmutil listlocalsnapshots /`; that space is purgeable and this '
            'check does not count it.'
            if _platform.system() == 'Darwin' else '')
        raise RuntimeError(
            f'Not enough disk space to fuse: need ~{need / 1e9:.1f} GB for '
            f'{save}, only {free / 1e9:.1f} GB free. Free at least '
            f'{(need - free) / 1e9:.1f} GB — old fused models under '
            f'{save.parent.parent} and intermediate *_adapters.safetensors '
            f'checkpoints are the usual candidates — or pass '
            f'check_space=False to try anyway.{snapshot_note}')

    cmd = [python, '-m', 'mlx_lm', 'fuse',
           '--model', model_path,
           '--adapter-path', adapter_path,
           '--save-path', str(save), *extra_args]
    log(' '.join(cmd))
    rc = _subprocess.run(cmd).returncode

    if rc != 0 or not fused_model_is_complete(save):
        partial = 0
        if save.exists():
            partial = sum(f.stat().st_size for f in save.rglob('*') if f.is_file())
            _shutil.rmtree(save, ignore_errors=True)
        now_free = free_bytes(save.parent)
        detail = (f'exit code {rc}' if rc != 0
                  else 'exit code 0 but the output is incomplete')
        hint = ''
        if need and now_free < need:
            hint = (f' The filesystem has {now_free / 1e9:.1f} GB free and the '
                    f'fuse needs ~{need / 1e9:.1f} GB — out of disk.')
        raise RuntimeError(
            f'Fuse failed ({detail}); removed {partial / 1e9:.1f} GB of '
            f'partial output at {save}.{hint}')

    total = sum(f.stat().st_size for f in save.rglob('*') if f.is_file())
    log(f'Fused model saved to {save} ({total / 1e9:.1f} GB)')
    return save


def prune_adapter_checkpoints(adapter_dir, keep=0, log=print):
    """Delete intermediate NNNNNNN_adapters.safetensors checkpoints.

    Call only once the adapter has been fused or the best checkpoint promoted
    to adapters.safetensors — `find_resume_checkpoint` reads these files, so
    pruning them forfeits resume for that run. `keep` retains the N highest
    iteration numbers. Returns the bytes reclaimed.
    """
    d = Path(str(adapter_dir))
    ckpts = []
    for f in d.glob('*_adapters.safetensors'):
        m = _CKPT_RE.match(f.name)
        if m:
            ckpts.append((int(m.group(1)), f))
    ckpts.sort()
    doomed = ckpts[:-keep] if keep else ckpts
    freed = 0
    for _, f in doomed:
        freed += f.stat().st_size
        f.unlink()
    if freed:
        log(f'Pruned {len(doomed)} adapter checkpoint(s) from {d} '
            f'({freed / 1e9:.1f} GB reclaimed)')
    return freed


# ── Training-meta contamination denylist (aro ask self-reference bug) ────────
# The fine-tuned `aro ask` model was observed answering an ARO *usage* question
# ("How do I implement writable stores?") with self-referential training-report
# narration ("the model's fine-tuned syntax pass rate improved from 12% to 72%
# … hallucination rate remained stable at 0.40"). That prose is training-process
# meta-commentary that leaked into the corpus (e.g. via `.context` /
# `.context.repairs.jsonl` user-session logs) and must never be learned as ARO
# content. `is_training_meta` flags such text at ingestion time so contaminated
# samples can be dropped, and at eval time so a model that regurgitates it fails.
#
# Strong phrases are essentially only produced when narrating a training run's
# own results — their bare presence is enough to flag. Soft phrases are training
# vocabulary that is common enough to appear in legitimate contexts, so one alone
# never flags: we require either two distinct soft signals, or one soft signal
# co-occurring with a metric number (a percentage / rate / decimal like 0.40).
# This keeps the filter PRECISE — legitimate ARO Q&A (a "report generator" app,
# ARO code that happens to contain the word "training", "fine-tune the timeout
# config") is not flagged.

_META_STRONG = [
    r'syntax pass rate',
    r'hallucination rate',
    r'held[\s\-]?out',
    r'eval(?:uation)? prompts?',
    r'loss curve',
    r'loss (?:is |was |slowly )?converg',
    r'(?:val(?:idation)?|training)\s+loss',
    r'training round',
    r'training run',
]

_META_SOFT = [
    r'fine[\s\-]?tun(?:e|ed|es|ing)',
    r'base model',
    r'pass[\s\-]?rate',
    r'\bepochs?\b',
    r'\blora\b',
    r'\badapter weights?\b',
    r'dataset size',
    r'\d[\d,\.]*\s+(?:training\s+)?samples\b',
    r'eval(?:uation)?\s+(?:set|prompts?)',
    r'hallucination',
]

_META_STRONG_RE = [re.compile(p, re.IGNORECASE) for p in _META_STRONG]
_META_SOFT_RE = [re.compile(p, re.IGNORECASE) for p in _META_SOFT]
# A metric number: an explicit percentage/rate, the word "percent", or a bare
# two-decimal fraction (e.g. "0.40") of the kind used to report rates.
_METRIC_NUM_RE = re.compile(r'\d+(?:\.\d+)?\s*%|\bpercent\b|\b\d\.\d{2}\b',
                            re.IGNORECASE)


def is_training_meta(text):
    """Return True when `text` reads as training-process/report meta rather than
    ARO content, and should be dropped from (or flagged in) the corpus.

    Intent: catch self-referential training-run narration — syntax pass rates,
    hallucination rates, fine-tune/held-out/eval-prompt/loss-curve commentary —
    of the class that leaked into `aro ask` answers, WITHOUT flagging legitimate
    ARO questions or code. Precision is favoured over recall: a single common
    training word (e.g. "training", "fine-tune") is never enough on its own —
    we require a strong metric phrase, two distinct soft signals, or one soft
    signal alongside a metric number.

    `text` may be any object; non-strings return False.
    """
    if not isinstance(text, str) or not text.strip():
        return False

    for rx in _META_STRONG_RE:
        if rx.search(text):
            return True

    soft_hits = sum(1 for rx in _META_SOFT_RE if rx.search(text))
    if soft_hits >= 2:
        return True
    if soft_hits >= 1 and _METRIC_NUM_RE.search(text):
        return True
    return False


# ── Self-test ────────────────────────────────────────────────────────────────
# Run with:  python3 train_utils.py
# Asserts the known contaminating strings ARE flagged and legitimate ARO
# prompts/code are NOT. Kept in __main__ so importing the module is side-effect
# free on CI.

if __name__ == '__main__':
    _CONTAMINATED = [
        # the verbatim leak that triggered this work
        "the model's fine-tuned syntax pass rate improved from 12% to 72% "
        "while the hallucination rate remained stable at 0.40",
        "hallucination rate remained stable at 0.40",
        "syntax pass rate rose to 72%",
        "In training round 3 the held-out eval prompts showed the loss curve "
        "converging.",
        "The base model was fine-tuned on a dataset size of 12000 samples.",
        "After fine-tuning, the pass rate reached 88%.",
        "evaluation prompts were run against the held-out set",
        "validation loss plateaued around 0.31 by epoch 4",
    ]
    _LEGIT = [
        "How do I implement writable stores in ARO?",
        "Write a complete ARO application that generates a monthly sales report.",
        "Build a report generator that reads a CSV and writes an HTML summary.",
        "Retrieve the <training-data> from the <repository>.",
        "How do I fine-tune the timeout configuration for a slow action?",
        "Compute the <pass-rate: length> from the <students>.",
        "Log \"Starting the model training service\" to the <console>.",
        "How did the model perform in training?",  # question, not a report
        "Write one ARO statement that retrieves the git status.",
        "Emit a <UserCreated: event> with <user>.",
    ]

    failures = []
    for t in _CONTAMINATED:
        if not is_training_meta(t):
            failures.append(f'MISSED (should flag): {t!r}')
    for t in _LEGIT:
        if is_training_meta(t):
            failures.append(f'FALSE POSITIVE (should NOT flag): {t!r}')

    if failures:
        print('is_training_meta self-test FAILED:')
        for f in failures:
            print('  -', f)
        raise SystemExit(1)
    print(f'is_training_meta self-test PASSED — '
          f'{len(_CONTAMINATED)} contaminated flagged, '
          f'{len(_LEGIT)} legitimate passed through.')
