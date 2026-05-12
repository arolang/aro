# [BUG] `steel_gather_mm_rhs_nax` missing float32 kernel instantiation — LoRA training crashes on MoE models

## Summary

LoRA fine-tuning crashes on **Mixture-of-Experts** models (e.g. `Qwen3-Coder-30B-A3B-Instruct-4bit`) with:

```
RuntimeError: [metal::Device] Unable to load function steel_gather_mm_rhs_nax_nt_float32_float32_bm64_bn128_bk128_wm2_wn4
```

**Root cause:** In `steel_gemm_gather_nax.metal`, the `rhs_nax` gather kernels are only instantiated for `float16` and `bfloat16` — the `float32` variant is missing. When LoRA training computes loss with float32 accumulation through MoE expert routing, it requests the float32 kernel and crashes.

Dense models work fine because they never call `gather_mm`.

**The same code and model works on M1** — likely because M1's default dtype handling or LoRA's compute path stays in float16/bfloat16 on that architecture, never requesting the missing float32 variant.

Could someone from the team clarify why the float32 instantiation was omitted? Was it intentional (e.g. performance reasons) or an oversight? Understanding this would help us know whether the fix below is the right approach, or whether the training pipeline should cast to a different dtype instead.

## Root cause

In [`mlx/backend/metal/kernels/steel/gemm/kernels/steel_gemm_gather_nax.metal`](https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/steel/gemm/kernels/steel_gemm_gather_nax.metal) (lines 36-37):

```metal
instantiate_gather_mm_shapes_helper(float16, half, float16, half);
instantiate_gather_mm_shapes_helper(bfloat16, bfloat, bfloat16, bfloat);
// float32 variant is MISSING
```

Meanwhile, the C++ dispatch in `matmul.cpp` generates the kernel name from the tensor dtype — when LoRA training feeds float32 tensors through MoE layers, it requests `steel_gather_mm_rhs_nax_nt_float32_float32_...` which was never compiled into the metallib.

Verification: `strings mlx.metallib | grep steel_gather_mm_rhs_nax` shows only `float16` and `bfloat16` variants — no `float32`.

## Fix (confirmed working)

Add one line to `steel_gemm_gather_nax.metal`:

```diff
 instantiate_gather_mm_shapes_helper(float16, half, float16, half);
 instantiate_gather_mm_shapes_helper(bfloat16, bfloat, bfloat16, bfloat);
+instantiate_gather_mm_shapes_helper(float32, float, float32, float);
```

Building mlx from source with this fix resolves the issue completely. Tested with `Qwen3-Coder-30B-A3B-Instruct-4bit` — 3 LoRA iterations completed successfully, val loss 3.455 -> 2.477, adapter saved, peak memory 22.6 GB.

## Environment

- **Chip:** Apple M5 Max (128 GB unified memory)
- **GPU architecture:** `applegpu_g17s`
- **macOS:** 26.4 (Tahoe), Build 25E246
- **Python:** 3.12
- **mlx:** 0.31.1
- **mlx-metal:** 0.31.1
- **mlx-lm:** 0.31.1

## Full traceback

```
Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File ".venv/lib/python3.12/site-packages/mlx_lm/__main__.py", line 6, in <module>
    cli.main()
  File ".venv/lib/python3.12/site-packages/mlx_lm/cli.py", line 40, in main
    submodule.main()
  File ".venv/lib/python3.12/site-packages/mlx_lm/lora.py", line 362, in main
    run(types.SimpleNamespace(**args))
  File ".venv/lib/python3.12/site-packages/mlx_lm/lora.py", line 334, in run
    train_model(args, model, train_set, valid_set, training_callback)
  File ".venv/lib/python3.12/site-packages/mlx_lm/lora.py", line 288, in train_model
    train(
  File ".venv/lib/python3.12/site-packages/mlx_lm/tuner/trainer.py", line 276, in train
    val_loss = evaluate(
               ^^^^^^^^^
  File ".venv/lib/python3.12/site-packages/mlx_lm/tuner/trainer.py", line 196, in evaluate
    mx.eval(all_losses, ntokens)
RuntimeError: [metal::Device] Unable to load function steel_gather_mm_rhs_nax_nt_float32_float32_bm64_bn128_bk128_wm2_wn4
Function steel_gather_mm_rhs_nax_nt_float32_float32_bm64_bn128_bk128_wm2_wn4 was not found in the library
```

## Steps to reproduce

### 1. CLI reproducer

```bash
# Create minimal training data
mkdir -p /tmp/mlx_moe_test
echo '{"messages":[{"role":"user","content":"Hello"},{"role":"assistant","content":"World"}]}' > /tmp/mlx_moe_test/train.jsonl
echo '{"messages":[{"role":"user","content":"Test"},{"role":"assistant","content":"Response"}]}' > /tmp/mlx_moe_test/valid.jsonl

# This crashes (MoE model):
python -m mlx_lm lora \
  --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit \
  --data /tmp/mlx_moe_test \
  --train \
  --num-layers 4 \
  --iters 1 \
  --batch-size 1 \
  --adapter-path /tmp/mlx_moe_test/adapter \
  --val-batches 1

# This works fine (dense model, same machine):
python -m mlx_lm lora \
  --model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit \
  --data /tmp/mlx_moe_test \
  --train \
  --num-layers 4 \
  --iters 1 \
  --batch-size 1 \
  --adapter-path /tmp/mlx_moe_test/adapter_dense \
  --val-batches 1
```

### 2. Minimal Python reproducer

```python
"""
Reproduces the missing steel_gather_mm_rhs_nax float32 kernel.
Load a MoE model, run a forward pass with float32 — crashes on mx.eval().
"""
import mlx.core as mx
from mlx_lm import load

print(f"Device: {mx.default_device()}")
print(f"Device info: {mx.device_info()}")

model, tokenizer = load("mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")

prompt = tokenizer.encode("Hello world", return_tensors=None)
input_ids = mx.array([prompt])

logits = model(input_ids)     # triggers gather_mm inside MoE layers
mx.eval(logits)               # CRASHES: missing float32 rhs_nax kernel
print("OK")
```

## Workaround

Build mlx from source with the one-line fix:

```bash
git clone --depth 1 https://github.com/ml-explore/mlx.git
cd mlx

# Add float32 kernel instantiation
echo 'instantiate_gather_mm_shapes_helper(float32, float, float32, float);' >> \
  mlx/backend/metal/kernels/steel/gemm/kernels/steel_gemm_gather_nax.metal

# Requires Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
pip install --no-build-isolation .
```

## Affected models

- `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (MoE, 30B total / 3B active) — **confirmed crash**
- Likely all MoE models that route through `gather_mm` with float32 tensors

## Working models (same hardware)

- `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` (dense, 7B) — trains successfully
- `mlx-community/Qwen3.5-9B-MLX-4bit` (dense, 9B) — trains successfully

## Related issues

- ml-explore/mlx-examples#1357 — similar `steel_*` kernel missing (different kernel: `steel_attention_*`)
- ollama/ollama#13896 — M5 MLX kernel load failures
- ollama/ollama#14118 — MLX Metal errors on M5
