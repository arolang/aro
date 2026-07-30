# 4,000-prompt `aro ask` evaluation — results

Full run, thinking mode on, judged by `aro check` (code) / keyword (knowledge).
Raw per-prompt results: `ask-eval.csv` (repo root, git-ignored — 13 MB, regenerable).

## Overall: 67.0% good (2,679 / 4,000)

| Category | Good |
|----------|-----:|
| knowledge | 83.4% |
| mid (feature sets) | 75.4% |
| mixed | 64.0% |
| full-app | 62.8% |
| one-line | 58.0% |

**The model is much stronger on whole feature sets (75%) than isolated statements (58%)** — it needs the structural scaffolding of a feature set.

## Strong domains (≥90%)
lifecycle, sockets, CLI (100%) · HTTP-client (96%) · websocket, logging (95%) · events (93%) · extract (90%).

## Weak domains (targets)
conditionals/When 0% · error/Throw 2% · publish 3% · config 7% · REST 19% · git 24% · validation 25% · state 33% · collections 46% · response 54%.

## Top failure modes (of 1,321 bad)
1. 408 — no extractable ARO (prose / wrong fences)
2. **218 — "Cannot rebind variable" (immutability violations)**
3. 135 — missing angle brackets · 102 — missing period · 80 — wrong preposition
4. 77 — knowledge missing key facts · 51 — invented/unknown action verbs

## Feedback folded back into training
* **2,679** good answers → training pairs
* **1,160** bad answers fixed (canonical, `aro check`-validated) → `eval_feedback_pairs.jsonl`
* **161** unfixable (marked in the CSV `resolution` column)
* **334** gap-fill examples for the weak domains → `gapfill.jsonl`
* **1,260** reasoning traces → `thinking.jsonl` (see `Train/script/26_thinking_finetune.ipynb`)
