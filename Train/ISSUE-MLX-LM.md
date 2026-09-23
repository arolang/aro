# [BUG] Qwen3 MoE routers missing `mx.stop_gradient` on expert indices — LoRA training crashes on the first backward pass

## Summary

LoRA fine-tuning of **Qwen3 Mixture-of-Experts** models (e.g.
`mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16`) crashes as soon as the
first gradient is taken:

```
ValueError: [gather_axis] Cannot calculate VJP with respect to indices.
            Use stop_gradient on indices to stop gradients from being computed.
```

The forward pass is fine, so **validation runs clean first** (`Iter 1: Val
loss 2.416`) and only the training step dies — which makes it read like a
data or batching problem rather than a model bug.

**Root cause:** `Qwen3MoeSparseMoeBlock` selects its experts with
`argpartition` and reads the gate values back with `take_along_axis`, but
never stops the gradient on the indices. `inds` descends from `gates`, which
descends from a trainable parameter, so MLX traces it as differentiable and
tries to build a VJP for the *indices* of the gather.

Inference is unaffected — nothing differentiates — which is why this only
shows up under `mlx_lm lora --train`.

## Root cause

`mlx_lm/models/qwen3_moe.py` (0.31.3, lines 130-132):

```python
k = self.top_k
inds = mx.argpartition(gates, kth=-k, axis=-1)[..., -k:]
scores = mx.take_along_axis(gates, inds, axis=-1)
```

Compare `mlx_lm/models/qwen2_moe.py:134`, which does it correctly:

```python
inds = mx.stop_gradient(mx.argpartition(-gates, kth=k - 1, axis=-1)[..., :k])
scores = mx.take_along_axis(gates, inds, axis=-1)
```

`SwitchGLU` already calls `mx.stop_gradient(idx)` on its own copy of the
indices (`switch_layers.py:187`), so the expert dispatch survives; it is only
the router's `take_along_axis` that reaches the failing VJP.

Minimal reproduction, no model needed:

```python
import mlx.core as mx

x = mx.random.normal((4, 8))
w = mx.random.normal((8, 6))

def f(w):
    gates = mx.softmax(x @ w, axis=-1)
    inds = mx.argpartition(gates, kth=-2, axis=-1)[..., -2:]   # add stop_gradient -> works
    return mx.take_along_axis(gates, inds, axis=-1).sum()

mx.eval(mx.grad(f)(w))   # ValueError: [gather_axis] Cannot calculate VJP ...
```

## Fix (confirmed working)

Wrap the indices, exactly as the other MoE models do:

```diff
-        inds = mx.argpartition(gates, kth=-k, axis=-1)[..., -k:]
+        inds = mx.stop_gradient(mx.argpartition(gates, kth=-k, axis=-1)[..., -k:])
         scores = mx.take_along_axis(gates, inds, axis=-1)
```

Choosing an expert is a discrete selection, so there is no gradient to lose —
the gradient still flows to `gates` through `scores`.

Verified with `mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16`, 16 LoRA
layers, `--grad-checkpoint`, `--mask-prompt`, batch size 2: 4 iterations
complete, val loss 2.694 -> 2.394, adapter saved, peak memory 78.9 GB.

## Affected files

Same unpatched pattern in mlx-lm 0.31.3:

- `mlx_lm/models/qwen3_moe.py:131` — **confirmed crash** (Qwen3-Coder-30B-A3B)
- `mlx_lm/models/qwen3_next.py:338`
- `mlx_lm/models/lfm2_moe.py:216`
- `mlx_lm/models/bailing_moe.py:192`

## Environment

- **Chip:** Apple M5 Max (128 GB unified memory)
- **macOS:** 26.4 (Tahoe)
- **Python:** 3.12
- **mlx:** 0.32.2
- **mlx-metal:** 0.32.2
- **mlx-lm:** 0.31.3

## Related

- `Train/ISSUE-MLX.md` — the earlier MoE LoRA blocker (missing float32
  `steel_gather_mm_rhs_nax` kernel), fixed upstream in mlx 0.32.

## Workaround in this repo

`Train/training.sh` runs `Train/tools/patch_mlx_lm.py` after every
`pip install`, which re-applies the `stop_gradient` to the installed package.
It is idempotent and becomes a no-op once this is fixed upstream.
