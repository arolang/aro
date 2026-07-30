#!/usr/bin/env python3
"""Emit Train/script/27_conversation_finetune.ipynb — fine-tunes the ARO model on
multi-turn `aro ask` REPL conversations and measures multi-turn quality
before/after."""
import json
from pathlib import Path

OUT = Path("/Users/kris/Projects/ARO/ARO-Lang/Train/script/27_conversation_finetune.ipynb")
CELLS = []


def md(s):
    CELLS.append({"cell_type": "markdown", "metadata": {}, "source": s.splitlines(keepends=True)})


def code(s):
    CELLS.append({"cell_type": "code", "metadata": {}, "execution_count": None,
                  "outputs": [], "source": s.splitlines(keepends=True)})


md("""# 29 — Conversation / Multi-turn Fine-tune

`aro ask` in REPL mode is an interactive chat: the user asks for an app, the model
emits ARO, the user asks for a change ("add validation", "now emit an event",
"filter it"), and the model must refine the **same** application across turns.
Every other training stage is single-turn, so the model never learns to carry
context or apply an incremental edit.

This notebook fine-tunes on validated multi-turn conversations
(`Train/eval_derived/conversations.jsonl`, built by
`generators/gen_conversations.py`) where each user turn requests a change and each
assistant turn returns the cumulatively-updated, `aro check`-valid feature set. It
measures multi-turn quality **before** and **after** on a held-out slice:
does the final reply (1) stay valid ARO, (2) apply the last requested change, and
(3) keep the feature-set name established earlier in the conversation.
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
DATA_IN      = REPO / "Train" / "eval_derived" / "conversations.jsonl"
WORK         = REPO / "Train" / "data" / "27_conversation"
MLX_DIR      = WORK / "mlx"
ADAPTER_DIR  = WORK / "adapter"
CHART        = REPO / "Train" / "Reports" / "27_conversation_finetune.png"
ITERS        = 300           # keep modest; raise for a full run
LORA_LAYERS  = 16
BATCH_SIZE   = 1
GRAD_ACCUM   = 8
LEARNING_RATE= 1e-5
for d in (MLX_DIR, ADAPTER_DIR, CHART.parent):
    d.mkdir(parents=True, exist_ok=True)
print("repo:", REPO)""")

md("""## 1. Load conversations → split held-out / train / valid

Each record is already `{messages: [system, user, assistant, …]}`. We reserve a
held-out slice to measure multi-turn behaviour, and write the rest as mlx-lm chat
data. `--mask-prompt` (below) trains only the assistant turns.""")

code("""def load_convos():
    rows = []
    if DATA_IN.exists():
        for line in DATA_IN.read_text().splitlines():
            if line.strip():
                r = json.loads(line)
                if r.get("messages") and len(r["messages"]) >= 3:
                    rows.append(r)
    return rows

convos = load_convos()
random.seed(0); random.shuffle(convos)
n_hold = max(4, len(convos) // 5)
holdout = convos[:n_hold]
train_c = convos[n_hold:]
n_val   = max(1, len(train_c) // 10)
valid_c = train_c[:n_val]
train   = train_c[n_val:]
(MLX_DIR/"train.jsonl").write_text("\\n".join(json.dumps({"messages": r["messages"]}) for r in train))
(MLX_DIR/"valid.jsonl").write_text("\\n".join(json.dumps({"messages": r["messages"]}) for r in valid_c))
print(f"convos={len(convos)}  train={len(train)}  valid={len(valid_c)}  holdout={len(holdout)}")
if not convos:
    print("WARNING: no conversations found — run generators/gen_conversations.py first.")""")

md("""## 2. Multi-turn quality metrics

For each held-out conversation we feed every turn **except the final assistant
reply**, generate that reply, and score it:
* **valid_code** — the final ARO passes `aro check`
* **applied_change** — the reply reflects the *last* user request (e.g. a request
  to "emit an event" yields an `Emit`, "filter" yields a `Filter`, "reject/validate"
  a `Throw`, "count/sum" a `Reduce`)
* **name_kept** — the feature-set name established earlier in the conversation is
  preserved (context retention across turns)""")

code('''_FENCE = re.compile(r"```aro\\n(.*?)```", re.DOTALL)
_NAME  = re.compile(r"\\(([A-Za-z][\\w-]*)\\s*:")

# last-request keyword -> ARO verb that should appear in the reply
_CHANGE_VERBS = {
    "emit": "emit", "event": "emit",
    "filter": "filter",
    "reject": "throw", "validate": "throw", "badrequest": "throw", "empty": "throw",
    "count": "reduce", "sum": "reduce", "average": "reduce",
    "extract": "extract", "field": "extract",
    "store": "store", "created": "return",
}

def extract_code(text):
    blocks = _FENCE.findall(text or "")
    return "\\n".join(b.strip() for b in blocks) if blocks else (text or "").strip()

def aro_ok(code):
    ok, _ = config.aro_check_snippet(code, timeout=20)
    return bool(ok)

def expected_verb(last_user):
    lu = (last_user or "").lower()
    for kw, verb in _CHANGE_VERBS.items():
        if kw in lu:
            return verb
    return None

def prior_name(messages):
    # the feature-set name from the FIRST assistant turn, if any
    for m in messages:
        if m["role"] == "assistant":
            mm = _NAME.search(m["content"])
            if mm:
                return mm.group(1)
    return None

def score_reply(convo, reply):
    code = extract_code(reply)
    last_user = convo["messages"][-2]["content"]
    body = re.sub(r"\\(\\*.*?\\*\\)", "", code, flags=re.DOTALL)
    verbs = {v.lower() for v in re.findall(r"^\\s*([A-Z][a-zA-Z]+)\\b", body, re.M)}
    want = expected_verb(last_user)
    name = prior_name(convo["messages"][:-1])
    return {
        "valid_code":     aro_ok(code),
        "applied_change": (want in verbs) if want else True,
        "name_kept":      (name is not None and name in code),
    }''')

md("## 3. Generation over a conversation prefix (base, then adapter)")

code('''from mlx_lm import load as mlx_load, generate as mlx_generate

def make_gen(adapter=None):
    model, tok = mlx_load(BASE_MODEL, adapter_path=str(adapter) if adapter else None)
    def gen(prefix_messages):
        prompt = tok.apply_chat_template(prefix_messages, add_generation_prompt=True, tokenize=False)
        return mlx_generate(model, tok, prompt=prompt, max_tokens=512, verbose=False)
    return gen

def evaluate(gen_fn):
    agg = {"valid_code": 0, "applied_change": 0, "name_kept": 0}
    n = 0
    for convo in holdout:
        prefix = convo["messages"][:-1]            # everything but the final assistant reply
        reply = gen_fn(prefix)
        s = score_reply(convo, reply)
        for k in agg:
            agg[k] += int(s[k])
        n += 1
    return {k: (100 * v / n if n else 0.0) for k, v in agg.items()}

print("Evaluating BASE model on held-out conversations ...")
before = evaluate(make_gen(None))
print("before:", before)''')

md("## 4. LoRA fine-tune on the multi-turn conversations (mask the prompt)")

code('''cmd = [sys.executable, "-m", "mlx_lm", "lora", "--train",
       "--model", BASE_MODEL,
       "--data", str(MLX_DIR),
       "--adapter-path", str(ADAPTER_DIR),
       "--iters", str(ITERS),
       "--num-layers", str(LORA_LAYERS),
       "--batch-size", str(BATCH_SIZE),
       "--grad-accumulation-steps", str(GRAD_ACCUM),
       "--learning-rate", str(LEARNING_RATE),
       "--mask-prompt"]        # train only the assistant turns
print(" ".join(cmd))
subprocess.run(cmd, check=True)''')

code('''print("Evaluating FINE-TUNED model on held-out conversations ...")
after = evaluate(make_gen(ADAPTER_DIR))
print("after:", after)''')

md("## 5. Chart — multi-turn quality before vs after")

code('''metrics = ["valid_code", "applied_change", "name_kept"]
labels  = ["% valid ARO", "% applied the\\nrequested change", "% kept the\\nfeature-set name"]
b = [before[m] for m in metrics]; a = [after[m] for m in metrics]
x = range(len(metrics)); w = 0.38
fig, ax = plt.subplots(figsize=(9, 5))
ax.bar([i-w/2 for i in x], b, w, label="base", color="#bbbbbb")
ax.bar([i+w/2 for i in x], a, w, label="conversation fine-tune", color="#2ca02c")
for i in x:
    ax.text(i-w/2, b[i]+1, f"{b[i]:.0f}%", ha="center", fontsize=9)
    ax.text(i+w/2, a[i]+1, f"{a[i]:.0f}%", ha="center", fontsize=9)
ax.set_xticks(list(x)); ax.set_xticklabels(labels)
ax.set_ylim(0, 115); ax.set_ylabel("%"); ax.legend()
ax.set_title("ARO Conversation Fine-tune — multi-turn quality on held-out chats")
fig.tight_layout(); fig.savefig(CHART, dpi=120)
print("wrote", CHART)
print("summary:", {"before": before, "after": after})''')

md("""## Conclusion

`applied_change` and `name_kept` should rise: the model learns to carry the
conversation's context and apply each incremental edit to the same feature set,
while `valid_code` stays high. The chart is saved to
`Train/Reports/27_conversation_finetune.png` for the post-training PDF report.

To grow coverage, add more arcs to `generators/gen_conversations.py` (each new arc
is a sequence of `(user_request, updated_aro)` turns; every assistant turn is
re-validated with `aro check`). The conversations are multi-turn `messages`
records, so they can also be routed into the main dataset (NB16 already ingests
`messages`-format samples for tool-calling) to reach the shipped teacher/student.
""")

nb = {"cells": CELLS,
      "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
                   "language_info": {"name": "python", "version": "3.12"}},
      "nbformat": 4, "nbformat_minor": 5}
OUT.write_text(json.dumps(nb, indent=1, ensure_ascii=False) + "\n")
print("wrote", OUT, "cells:", len(CELLS))
