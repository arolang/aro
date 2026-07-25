#!/usr/bin/env python3
"""Emit Train/script/28_thinking_finetune.ipynb — a self-contained notebook that
fine-tunes the ARO model to REASON before answering and measures reasoning
quality before/after with a chart."""
import json
from pathlib import Path

OUT = Path("/Users/kris/Projects/ARO/ARO-Lang/Train/script/28_thinking_finetune.ipynb")

CELLS = []


def md(s):
    CELLS.append({"cell_type": "markdown", "metadata": {}, "source": s.splitlines(keepends=True)})


def code(s):
    CELLS.append({"cell_type": "code", "metadata": {}, "execution_count": None,
                  "outputs": [], "source": s.splitlines(keepends=True)})


md("""# 28 — Thinking / Reasoning Fine-tune

Teach the ARO model to **reason before it answers**: understand the request,
rephrase it in ARO terms, plan the feature-set structure, and explicitly recall
the rules the 4,000-prompt eval showed it breaks (immutability, prepositions,
built-in verbs, Return/Throw) — *then* generate code.

Training data: `Train/eval_derived/thinking.jsonl` (reasoning traces) +
`eval_feedback_pairs.jsonl`. The notebook evaluates reasoning quality on a
held-out slice **before** and **after** the fine-tune and writes a chart.
""")

code("""import json, subprocess, sys, tempfile, random, re
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

REPO = Path.cwd().parents[1] if (Path.cwd().name == "script") else Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config

BASE_MODEL   = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
DATA_IN      = REPO / "Train" / "eval_derived"
WORK         = REPO / "Train" / "data" / "28_thinking"
MLX_DIR      = WORK / "mlx"
ADAPTER_DIR  = WORK / "adapter"
CHART        = REPO / "Train" / "Reports" / "thinking_finetune.png"
ITERS        = 400          # keep modest; raise for a full run
LORA_LAYERS  = 16
BATCH_SIZE   = 2
LEARNING_RATE= 1e-5
for d in (MLX_DIR, ADAPTER_DIR, CHART.parent):
    d.mkdir(parents=True, exist_ok=True)
print("repo:", REPO)""")

md("## 1. Load reasoning data → chat messages, split train/valid/held-out")

code("""def load_pairs():
    pairs = []
    for name in ("thinking.jsonl", "eval_feedback_pairs.jsonl"):
        p = DATA_IN / name
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                if r.get("instruction") and r.get("output"):
                    pairs.append(r)
    return pairs

pairs = load_pairs()
random.seed(0); random.shuffle(pairs)
holdout = pairs[:120]                 # measure before/after on these
train_p = pairs[120:]
def to_msg(r):
    return {"messages": [
        {"role": "user", "content": r["instruction"]},
        {"role": "assistant", "content": r["output"]},
    ]}
n_val = max(1, len(train_p)//20)
valid = [to_msg(r) for r in train_p[:n_val]]
train = [to_msg(r) for r in train_p[n_val:]]
(MLX_DIR/"train.jsonl").write_text("\\n".join(json.dumps(m) for m in train))
(MLX_DIR/"valid.jsonl").write_text("\\n".join(json.dumps(m) for m in valid))
print(f"pairs={len(pairs)} train={len(train)} valid={len(valid)} holdout={len(holdout)}")""")

md("""## 2. Reasoning-quality metrics

For each held-out prompt we score the model's answer on:
* **reasons** — did it emit a non-empty `<think>` block before the code?
* **valid_code** — does the extracted ARO pass `aro check`?
""")

code("""def has_reasoning(text):
    m = re.search(r"<think>(.*?)</think>", text, re.DOTALL)
    return bool(m and len(m.group(1).strip()) > 40)

def code_valid(text):
    blocks = config.extract_aro_blocks(text)
    if not blocks:
        return False
    wrapped, _ = config.auto_wrap_aro(blocks[0])
    ok, _ = config.aro_check_snippet(wrapped or blocks[0], timeout=20)
    return bool(ok)

def evaluate(gen_fn):
    reasons = valid = 0
    for r in holdout:
        out = gen_fn(r["instruction"])
        reasons += has_reasoning(out)
        valid   += code_valid(out)
    n = len(holdout)
    return {"reasons": 100*reasons/n, "valid_code": 100*valid/n}""")

md("## 3. Generation (base model, then adapter). Requires `mlx_lm` + the model.")

code("""from mlx_lm import load as mlx_load, generate as mlx_generate
from mlx_lm.sample_utils import make_sampler

def make_gen(adapter=None):
    model, tok = mlx_load(BASE_MODEL, adapter_path=str(adapter) if adapter else None)
    def gen(instruction):
        msgs = [{"role": "user", "content": instruction}]
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)
        return mlx_generate(model, tok, prompt=prompt, max_tokens=512, verbose=False)
    return gen

print("Evaluating BASE model on held-out ...")
before = evaluate(make_gen(None))
print("before:", before)""")

md("## 4. LoRA fine-tune on the reasoning data (mlx-lm, same pattern as NB17)")

code("""cmd = [sys.executable, "-m", "mlx_lm", "lora", "--train",
       "--model", BASE_MODEL,
       "--data", str(MLX_DIR),
       "--adapter-path", str(ADAPTER_DIR),
       "--iters", str(ITERS),
       "--num-layers", str(LORA_LAYERS),
       "--batch-size", str(BATCH_SIZE),
       "--learning-rate", str(LEARNING_RATE)]
print(" ".join(cmd))
subprocess.run(cmd, check=True)""")

code("""print("Evaluating FINE-TUNED model on held-out ...")
after = evaluate(make_gen(ADAPTER_DIR))
print("after:", after)""")

md("## 5. Chart — reasoning quality before vs after")

code("""metrics = ["reasons", "valid_code"]
labels  = ["% with reasoning", "% valid ARO code"]
b = [before[m] for m in metrics]; a = [after[m] for m in metrics]
x = range(len(metrics)); w = 0.38
fig, ax = plt.subplots(figsize=(8, 5))
ax.bar([i-w/2 for i in x], b, w, label="base", color="#bbbbbb")
ax.bar([i+w/2 for i in x], a, w, label="thinking fine-tune", color="#2ca02c")
for i in x:
    ax.text(i-w/2, b[i]+1, f"{b[i]:.0f}%", ha="center", fontsize=9)
    ax.text(i+w/2, a[i]+1, f"{a[i]:.0f}%", ha="center", fontsize=9)
    ax.text(i, max(b[i],a[i])+6, f"+{a[i]-b[i]:.0f} pts", ha="center", fontsize=9, color="#2ca02c", fontweight="bold")
ax.set_xticks(list(x)); ax.set_xticklabels(labels)
ax.set_ylim(0, 110); ax.set_ylabel("%"); ax.legend()
ax.set_title("ARO Thinking Fine-tune — reasoning quality on held-out prompts")
fig.tight_layout(); fig.savefig(CHART, dpi=120)
print("wrote", CHART)
print("summary:", {"before": before, "after": after})""")

md("""## Conclusion

`reasons` should rise toward ~100% (the model now emits a planning `<think>`
block) and `valid_code` should climb as the reasoning forces it to respect
immutability, prepositions and the built-in verb set before generating. The
chart is saved to `Train/Reports/thinking_finetune.png` and can be embedded in
the post-training PDF report.
""")

nb = {"cells": CELLS, "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
      "language_info": {"name": "python", "version": "3.12"}}, "nbformat": 4, "nbformat_minor": 5}
OUT.write_text(json.dumps(nb, indent=1))
print("wrote", OUT, "cells:", len(CELLS))
