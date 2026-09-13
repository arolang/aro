\newpage

# Appendix A: The Training Pipeline

> "The pipeline is twenty-eight notebooks, a config file, and a great deal of patience."

---

This appendix is for people who want to run the training pipeline themselves, extend it, or understand what each step does at a technical level. If you only want to use `aro ask`, you do not need any of this. Chapter 2 covers what the model learned and why; this appendix covers *how*.

## A.1 Prerequisites

The pipeline runs on Apple Silicon (M1 or later) with at least 16 GB of unified memory. It uses MLX for local inference and fine-tuning. You will need:

- Python 3.12+ with `mlx-lm`, `matplotlib`, `transformers`
- The `aro` binary on your PATH (for `aro check` and `aro run` validation)
- A HuggingFace account and `huggingface-cli login` (for model upload)

The pipeline lives in the ARO repository itself, at `Train/script/`. All notebooks share a common configuration through `config.py`.

## A.2 The Notebooks

The notebooks are numbered by filename, and `00_META_PIPELINE.ipynb` runs `01` through `27` in order, each in its own isolated kernel. One warning before you read further: the markdown heading *inside* several notebooks still carries an older number from before the files were renumbered, so `18_finetune.ipynb` opens with "# 17 — Full Fine-Tune". Trust the filename; that is what the meta notebook orders by.

Counts below (actions, examples, proposals) are what the corpus held when this appendix was written. They are not constants — the pipeline re-derives them from the repository on every run, which is the point.

### Setup and corpus (01–04)

**01 (init)** wipes pipeline artifacts and sets up the directory structure for a clean run.

**02 (action reference)** builds the comprehensive reference for every ARO action, organised by semantic role.

**03 (corpus collection)** walks the repository and indexes every source of truth: the Examples directory (109 applications at the time of writing), the Book, the Proposals (67), the wiki, and the runtime's Swift source for action metadata.

**04 (knowledge extraction)** turns the raw corpus into `knowledge.json` — the canonical action/syntax reference that every later system prompt is built from.

### Training pair generation (05–14)

**05 (material seeding)** reads `Train/Material/curated.jsonl`, the hand-curated and `aro check`-validated pairs, into the knowledge stream. Hand-written data goes in first so everything generated later has something correct to imitate.

**06 (LLM knowledge extraction)** is the first notebook that calls the model. For each real example, book chapter, and proposal, it generates instruction/response pairs, validates every generated code block with `aro check`, and feeds failures back for up to two repair attempts. Bare snippets from proposals are auto-wrapped in feature sets before checking.

**07 (warm-start fine-tune)** trains the base model on everything collected so far, so the later generation steps already speak the DSL. The adapter is saved to `data/adapters/warm_start/` and loaded by every subsequent notebook.

**08 (actions training)** generates pairs for every ARO action: usage examples, alias mappings, explanations, "which action" questions, and in-context feature sets. It also includes static error-pattern pairs covering common mistakes (`++` versus `+`, reserved prefixes, wrong prepositions).

**09 (REPL execution training)** generates code that must actually *run*, not merely parse. Every pair is validated with `aro run` as well as `aro check`.

**10 (book Q&A)** extracts question/answer pairs from the Book, so the model can explain as well as write.

**11 (synthetic data generation)** is the largest notebook: thousands of samples across code generation, debugging, correction, full applications, fill-in-the-middle, syntax Q&A, and code explanation, with a self-repair loop driven by targeted error hints.

**12 (function calling)** teaches the model to invoke the eighteen `aro ask` tools correctly — direct calls with valid JSON arguments, the `/fix` chain (read → check → edit → verify), and tool selection.

**13 (external repo training)** clones external ARO repositories — plugins, applications, bundles — and extracts pairs from them.

**14 (comment extraction)** mines every `(* … *)` comment from `.aro` files, pairing intent with implementation.

### Validation and assembly (15–17)

**15 (validation)** runs `aro check` over every collected pair. Code that looks plausible and fails to check is worse than no data, because it teaches the model to write it.

**16 (eval-derived merge)** folds the evaluation feedback, gap-fill and reasoning traces back into the curated stream.

**17 (dataset assembly)** merges every source into one balanced dataset with train/validation/test splits, and writes `stats.json` and a dataset report.

### Fine-tuning and evaluation (18–21)

**18 (fine-tune)** runs the full LoRA fine-tune on the assembled dataset, resuming from the warm-start adapter.

**19 (preference SFT)** makes a second pass over preference pairs — chosen/rejected built from `aro check` outcomes — so the model learns which of two plausible answers a human would want.

**20 (evaluation)** measures the model across several dimensions, syntax pass rate against `aro check` first among them.

**21 (iterative loop)** uses the current model to generate new training data, adds what passes to the training set and what fails to the preference negatives, then retrains. Multiple rounds.

### Distillation and release (22–27)

**22 (distillation)** transfers the 30B MoE teacher's ARO expertise into an 8B dense student.

**23 (material fine-tune)** trains a focused LoRA adapter on the curated `Train/Material/` set as a final booster.

**24 (thinking fine-tune)** teaches the model to reason before it answers — understand the request, restate it, then write.

**25 (conversation fine-tune)** trains multi-turn behaviour, which is what the `aro ask` REPL actually is.

**26 (post-release validation)** downloads the *published* model from Hugging Face and validates it the way a user consumes it, rather than trusting the local artifact.

**27 (package)** quantises the best model to 4-bit, generates a README, smoke-tests it, and uploads the distilled student (`ARO-Lang/aro-coder-6bit`) and the teacher (`ARO-Lang/aro-teacher-30b-bf16`) to Hugging Face. The `6bit` in the student's repository name is historical; the quantisation is 4-bit.

## A.3 The Model Lifecycle

The lifecycle flows top-to-bottom:

1. **Base model** (`mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16`, or the previous teacher from Hugging Face)
2. **Warm-start** (07: LoRA on the action/syntax reference)
3. **Full fine-tune** (18: LoRA on the assembled dataset)
4. **Preference SFT** (19: chosen/rejected pairs from `aro check`)
5. **Iterative loop** (21: generate, validate, retrain)
6. **Distil** 30B teacher into 8B student (22)
7. **Boosters** (23 material, 24 thinking, 25 conversation)
8. **Upload** teacher to `ARO-Lang/aro-teacher-30b-bf16` and student to `ARO-Lang/aro-coder-6bit` (27)
9. **Validate the published artifact** the way a user gets it (26)
10. **End user** downloads `aro-coder-6bit` via `aro ask`

## A.4 Iterative Improvement

After the first complete pipeline run, set `TRAIN_ON_BASE = False` in `config.py`. On the next run, the pipeline will download the teacher model from HuggingFace instead of starting from vanilla Qwen. Each cycle builds on the previous one.

The teacher model (`ARO-Lang/aro-teacher-30b-bf16`) is the full 30B model after all fine-tuning. The student model (`ARO-Lang/aro-coder-6bit`) is the distilled 8B version for everyday inference. Both are uploaded after each training cycle.

## A.5 Key Configuration

`TRAIN_ON_BASE`
:   `True` always uses `BASE_MODEL_ID` (fresh training, or a new base model). `False` resumes from `TEACHER_MODEL_ID` if it exists on Hugging Face, falling back to the base otherwise.

`MODEL_ID`
:   Resolved once at import time by `resolve_model_id()`. Used by all notebooks.

`BASE_MODEL_ID`
:   `mlx-community/Qwen3-Coder-30B-A3B-Instruct-bf16`

`TEACHER_MODEL_ID`
:   `ARO-Lang/aro-teacher-30b-bf16`

`STUDENT_MODEL_ID`
:   `mlx-community/Qwen3-8B-bf16` — the base the distilled student is trained from

`PREFERRED_MODEL_ID`
:   `ARO-Lang/aro-coder-6bit` — the published, 4-bit-quantised student

`CLEAN_ON_RESTART`
:   `True` by default. Every notebook tags the rows it writes to `knowledge_pairs.jsonl` with its own number, and re-running a notebook removes its previous rows first, so reruns replace rather than duplicate.

All configuration lives in `Train/script/config.py`, with unit tests for the pure-Python helpers in `Train/script/tests/`.
