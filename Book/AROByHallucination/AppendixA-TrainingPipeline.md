\newpage

# Appendix A: The Training Pipeline

> "The pipeline is twenty-four notebooks, a config file, and a great deal of patience."

---

This appendix is for people who want to run the training pipeline themselves, extend it, or understand what each step does at a technical level. If you only want to use `aro ask`, you do not need any of this. Chapter 2 covers what the model learned and why; this appendix covers *how*.

## A.1 Prerequisites

The pipeline runs on Apple Silicon (M1 or later) with at least 16 GB of unified memory. It uses MLX for local inference and fine-tuning. You will need:

- Python 3.12+ with `mlx-lm`, `matplotlib`, `transformers`
- The `aro` binary on your PATH (for `aro check` and `aro run` validation)
- A HuggingFace account and `huggingface-cli login` (for model upload)

The pipeline lives in `ARO-Train/Train/script/`. All notebooks share a common configuration through `config.py`.

## A.2 The Notebooks

### Data Collection (NB00-NB02)

**NB00 (init)** sets up the directory structure and configuration.

**NB01 (corpus collection)** indexes every source of truth: the 65 Examples, the Language Guide, the Book, the Proposals, the Wiki, and the runtime's Swift source code for action metadata. Output: a manifest of ~400 items.

**NB02 (knowledge extraction)** parses the manifest into structured knowledge: 54 actions with their verbs and prepositions, 115 examples with their source code, 61 proposals with Q&A seeds. Output: `knowledge.json`.

### Training Pair Generation (NB03-NB13)

**NB03 (LLM knowledge extraction)** is the first notebook that calls the model. For each real example, book chapter, and proposal, it generates instruction/response pairs. It validates every generated code block with `aro check`, and when validation fails, feeds the error back to the model for up to two repair attempts. Bare code snippets from proposals are auto-wrapped in feature sets before checking. Output: ~700 pairs.

**NB04 (warm-start fine-tune)** trains the base model on all pairs collected so far. This gives the model enough ARO knowledge to generate useful code in later notebooks. The adapter is saved and loaded by every subsequent notebook. Training runs for two full epochs with batch size 4.

**NB05 (actions training)** generates pairs for every ARO action: usage examples, alias mappings, explanations, "which action" questions, and in-context feature sets. Also includes 16 static error-pattern pairs covering common mistakes (++ vs +, reserved prefixes, wrong prepositions). Output: ~350 pairs across 59 verbs.

**NB06 (execution-grounded pairs)** generates code that must actually *run*, not just parse. Four strategies: mutation of existing examples, recombination of two examples into one, spec-to-code from proposals, and readme-to-code from example descriptions. Every pair is validated with both `aro check` and `aro run`. Output: ~300 pairs.

**NB07 (book Q&A)** extracts question/answer pairs from the Language Guide chapters.

**NB08 (wiki training)** mines the project wiki for training pairs.

**NB09 (git training)** mines real fix and refactor commits from the git history of ARO applications. A sanitisation step removes old-style `<Verb>` syntax and validates all code blocks with `aro check`.

**NB10 (synthetic data generation)** is the largest notebook. It generates 3,500+ samples across seven task types: code generation, debugging, correction, full application, fill-in-the-middle, syntax Q&A, and code explanation. It also generates multi-feature-set "architecture" applications. A self-repair loop with targeted error hints fixes common syntax mistakes.

**NB11 (function calling)** teaches the model to invoke `aro ask` tools correctly. Training pairs cover direct tool calls (with correct JSON arguments), the `/fix` workflow chain (read → check → edit → verify), and tool selection for common tasks.

**NB12-NB13 (application prompts, external repos)** generate additional training pairs from application plan files and external ARO repositories.

### Validation & Assembly (NB14-NB17)

**NB14-NB15 (comment extraction, validation)** extract comments from existing code and validate all collected pairs.

**NB16 (dataset assembly)** combines all pairs into a single training dataset with train/validation/test splits.

**NB17 (fine-tune)** runs the full LoRA fine-tune on the assembled dataset.

### Optimisation & Evaluation (NB18-NB20)

**NB18 (DPO)** runs Direct Preference Optimisation using chosen/rejected pairs built from `aro check` validation.

**NB19 (evaluation)** evaluates the model against a fixed set of probe prompts and reports syntax pass rates.

**NB20 (iterative loop)** uses the current model to generate new training data, validates it, adds passing samples to the training set and failing samples to the DPO negatives, then retrains. Multiple rounds.

### Distillation & Release (NB21-NB24)

**NB21 (distillation)** distils the 30B teacher model into an 8B student. The teacher generates 5,000 validated outputs; the student is fine-tuned on the merged dataset.

**NB22 (package)** quantises the best model to 4-bit, generates a README, smoke-tests the output, and uploads both the distilled student (`ARO-Lang/aro-coder-4bit`) and the teacher (`ARO-Lang/aro-teacher-30b-4bit`) to HuggingFace.

**NB23 (chat)** is a live test environment for the packaged model.

## A.3 The Model Lifecycle

The lifecycle flows top-to-bottom:

1. **Base model** (Qwen 30B or previous teacher from HF)
2. **Warm-start** (NB04: LoRA on ~4,000 pairs)
3. **Full fine-tune** (NB17: LoRA on full dataset)
4. **DPO** (NB18: preference optimisation)
5. **Iterative loop** (NB20: generate, validate, retrain)
6. **Upload teacher** to `ARO-Lang/aro-teacher-30b-4bit`
7. **Distil** 30B teacher into 8B student (NB21)
8. **Upload student** to `ARO-Lang/aro-coder-4bit`
9. **End user** downloads `aro-coder-4bit` via `aro ask`

## A.4 Iterative Improvement

After the first complete pipeline run, set `TRAIN_ON_BASE = False` in `config.py`. On the next run, the pipeline will download the teacher model from HuggingFace instead of starting from vanilla Qwen. Each cycle builds on the previous one.

The teacher model (`ARO-Lang/aro-teacher-30b-4bit`) is the full 30B model after all fine-tuning and DPO. The student model (`ARO-Lang/aro-coder-4bit`) is the distilled 8B version for everyday inference. Both are uploaded after each training cycle.

## A.5 Key Configuration

`TRAIN_ON_BASE`
:   `True` for fresh start, `False` to resume from the HF teacher.

`MODEL_ID`
:   Resolved at import time. Used by all notebooks.

`TEACHER_MODEL_ID`
:   `ARO-Lang/aro-teacher-30b-4bit`

`PREFERRED_MODEL_ID`
:   `ARO-Lang/aro-coder-4bit` (distilled student)

`STUDENT_MODEL_ID`
:   `mlx-community/Qwen3-8B-4bit`

`BASE_MODEL_ID`
:   Vanilla Qwen 30B MoE (fallback)

All configuration lives in `Train/script/config.py`.
