# NOTES — train::training-eval (#786 #787 #791 #801 #806 #813, tracking #839)

Worktree: `/Users/kris/Projects/ARO/ARO-Lang/.claude/worktrees/agent-a6ccdaca8c129ba73`
Branch: `train/training-eval` off `origin/main` (0f5625de).

## Setup notes

- A **stale local branch** named `train/training-eval` already existed (tip `cc13bac1`,
  dated 2026-07-14, 6 commits about notebooks NB05/NB16-NB20, never pushed to origin,
  not checked out in any worktree, merge-base `b369d7e0`). Its commits were reachable
  from no other ref. Renamed it to `train/training-eval-2026-07-stale` (non-destructive,
  nothing lost) and created the fresh branch off `origin/main`.
- `glab` needs `GITLAB_HOST=git.ausdertechnik.de` and `--repo arolang/aro`.

## Issues (read 2026-09-21)

- **#839 tracking** — the model cannot be measured. Headline figures (75.5% gate, 67% eval)
  measured on prompts folded back into training. Ordering: #785/#786 first (benchmark),
  then gates (#796 #801 #813), then training decisions (#787 #788 #791 #806 #794).
- **#786** — eval sets too small: quick eval 60 prompts, debugging/translation 12 each;
  execution checks n=6 (Aug) / 21 (Jul); translation n=1; `check_convergence` tol 0.02
  vs ±17pt noise. Fix: >=100 prompts/task, fixed seed, 3 samples (pass@k), `aro run`
  with 10s timeout, Wilson CIs, convergence by interval overlap.
- **#787** — iterative loop degrades; `best_round: 0`. Fix: don't fuse between rounds,
  filter by `aro run` + novelty, cap rounds / drop the stage.
- **#791** — 3 LoRA adapters fused in sequence, no gate; material stage lr 1e-4 (10x);
  thinking stage silently falls back to 30B base.
- **#801** — hallucination = fraction of verbs absent from KB; ROUGE-L vs single reference.
  Fix: fact-checked judge on the authoritative catalog; "refuses to invent statistics";
  flag tasks scoring below base.
- **#806** — curriculum inverted: prose first, programs last; correction cap 4000 vs
  code_generation 3000; eval-derived adds 5440 correction pairs.
- **#813** — "good" == `aro check` passed (3495/4000), 494 keyword. Fix: 100-item human
  slice per release under `Train/eval/human/`, plus functional tests.

## Environment verified

- `aro` on PATH: `/opt/homebrew/bin/aro`, version `0.12.0`.
- `python3` 3.12.10, `pytest` 9.0.3.
- `Train/script/tests/` already exists: 8 test modules, pure-python, run with
  `python3 -m pytest Train/script/tests/` or `python3 -m unittest discover`.
- `.gitlab-ci.yml` has small `stage: test` jobs (`proposals`, `action-reference`,
  `grammar-appendix`, `harness:unit`) each a slim image + one script line.
  No Train job exists yet — that is the shape to follow.

## Plan (one commit per issue)

1. #786 — sample-size machinery: Wilson intervals, pass@k with fixed seed,
   convergence by interval overlap, required-n calculator; enlarge eval sets.
2. #787 — reproduce the "best round is 0" claim from checked-in artefacts first;
   then no-fuse-between-rounds policy + execution/novelty filter + round cap.
3. #791 — per-stage promotion gate before each fuse; no silent base fallback.
4. #801 — grounded fact-checker replacing the keyword hallucination metric;
   below-base regression flag.
5. #806 — curriculum ordering by stage, 2x weight on execution-verified pairs,
   correction cap <= code_generation.
6. #813 — functional benchmark ("it ran and produced what was asked for") +
   human-rated slice under Train/eval/human/.

## Evidence found (local, gitignored artefacts in the MAIN checkout — not in the worktree)

`/Users/kris/Projects/ARO/ARO-Lang/Train/data/rounds/round_results.json` and
`/Users/kris/Projects/ARO/ARO-Lang/Train/data/07_eval/report.json` exist locally
(both under gitignored `Train/data/`). They confirm the audit claims exactly.

### #787 — the loop's own record

code_generation pass rate, rounds 0..7:
`0.700 0.467 0.617 0.333 0.283 0.500 0.533 0.517`; `"best_round": 0`;
`"promotion_pass_rate": 0.667`; round 7 was the one carried forward.
Regressions recorded in the file itself: debugging 0.50 -> 0.25,
code_generation 0.70 -> 0.5167.

Derived: round-to-round absolute deltas (points) 23.3, 15.0, 28.3, 5.0, 21.7,
3.3, 1.7 — mean 14.0, max 28.3. Population stdev of the series 12.8 points,
range 41.7 points. **The claim reproduces.**

### #786 — exact sample sizes, back-derived from the recorded rates

Every rate is an exact integer fraction: code_generation n = 60
(0.70 = 42/60, 0.2833 = 17/60), debugging n = 12, translation n = 12.
So one prompt is worth 1.67 points on code_generation and 8.3 on the other two
— the issue's figures are correct and unchanged.

Main evaluation (`data/07_eval/report.json`): `_meta.n_samples = 200` but
`sample_composition` is code_generation 65, syntax_qa 65, full_application 37,
function_calling 15, debugging 2, and **n = 1** for each of alias, architecture,
code_explanation, correction, error_pattern, knowledge, multi_file_application,
tool_calling, translation, usage, which_action. `_meta.exec_checks_used = 6`.
Confirms "execution checks on 6 samples" and "translation had n = 1".

`check_convergence` tol 0.02 vs a 60-prompt set: the smallest non-zero delta
expressible is 1/60 = 0.0167, so the test is finer than the instrument.

### #801 — both consequences are in the artefact

- `code_explanation`: ft_rouge_l **0.021** vs base_rouge_l **0.149**, and
  ft_fact_f1 0.000 vs base 0.333. Nothing in the report flags it.
- `_meta.training_meta_probe.failed = true`, flagged response begins
  "The model achieved a 95% syntax pass rate on the training data ... The
  training data included 1000 examples" — the confabulated statistics.
- `ft_hallucination_rate` is 0.000 for debugging, context_llm, context_static,
  function_calling, multi_file_application and syntax_qa — the keyword metric
  sees nothing anywhere.

### Mechanics read directly

- `train_utils.check_convergence(pass_rates, val_losses, pass_tol=0.02,
  loss_tol=0.01, patience=2)` — flat-delta test only, no interval notion.
  `train_utils.best_round()` — plain `max()` over rounds, no interval.
- `eval_metrics.py` already has `run_aro_program(code, openapi, timeout=10)`
  and `is_safely_runnable()`; the evaluation simply almost never calls them
  (6 executions out of 200 samples).
- `config.hallucinated_verbs_in_code()` (config.py:1586) is the whole
  hallucination metric: statement-leading verbs not in `canonical_verb_set()`.
  A program whose verbs are all real but whose *qualifier*, *system object* or
  *field* is invented scores 0.0 — clean. Prose that invents a statistic
  contains no ARO verbs at all, so it also scores 0.0. That is the
  demonstration for #801.
- `aro run` verified working in this worktree on a scratch program:
  `[Application-Start] Hello, ARO.` / `[Application-Start] 5` / `[OK] startup`,
  exit 0. Stdout is stable and prefixed per feature set.

## Code map (verified by reading the notebooks)

### #787 — one claim in the issue is STALE
`21_iterative_loop.ipynb` cell 15 lines 51-61 anchors
`TRAINING_BASE_MODEL = BASE_MODEL` and resumes from the previous round's
*adapter*; `fuse_model()` (cell 10 lines 411-423) still runs every round but
only for downstream consumers (NB22 distillation, NB27 packaging). So the
issue's "then fuses the adapter to become the next round's base — compounding
LoRA fuses" **no longer describes the code**; that part was already fixed.
What remains true: `NUM_ROUNDS = 8`, acceptance is `aro check` only (plus a
comment-heaviness and a length/token filter), `best_round()` is a plain argmax
over `syntax_pass_rate` (= the code_generation rate) on 60 prompts, and the
promotion gate at cell 15 lines 326-341 only *warns* when the held-out gap
exceeds 0.15 — it never blocks.

Also found: `aro_check()` in cell 6 returns `(None, 'aro_not_found')` when the
binary is missing, and `generate_with_repair` accepts `passed is None` — with no
`aro` on PATH every generated sample is accepted unchecked.

### #791 — confirmed, all of it
- NB23 material: `LR = 1e-4`, `ITERS = max(200, min(1200, len(train_pairs)*4))`
  over 1069 curated rows -> the 1200 cap, i.e. ~4.5 epochs. Ten times NB24/NB25's
  `1e-5`. Fuse (cell 11) is unconditional; the smoke test runs *after* it.
- NB24 thinking: computes `before`/`after` held-out metrics (cells 7 and 10),
  charts them, and then fuses (cell 14) regardless. `subprocess.run(_fuse, check=True)`.
- NB25 conversation: the only pre-fuse check is `_adapters_finite()` (NaN/Inf),
  not a quality gate. Trains on `eval_derived/conversations.jsonl` — **24 rows**,
  of which ~17 reach training.
- Silent base fallback, NB24 cell 1: falls through `material/fused` ->
  `distill/student/fused` -> `config.BASE_MODEL_ID` (the 30B MoE), announced by
  a `print`. NB25 has the same 3-deep chain.

### #806 — confirmed, with a corrected figure
- `config.py:135-153`, `TYPE_CAPS_VERSION = 'v4-2026-09-07'`:
  `correction: 4000`, `code_generation: 3000`, `syntax_qa: 2500`, rest uncapped.
- The cap is applied **first-N-wins in insertion order** (NB17 cell 12), not a
  sample, so which 4000 corrections survive is decided by append order.
- `eval_derived/` really does supply 5440 correction pairs from
  `ask_eval_pairs.jsonl`, but the **merged total is 6084** (5440 + 642 from
  `antihallucination.jsonl` + 1 + 1) — the issue's 5440 is the biggest file,
  not the total. ~2084 are dropped by insertion order.
- NB17 cell 19 `random.seed(42); random.shuffle(final)` — the dataset is
  shuffled twice and ordered by nothing.
- `s['weight']` (from `SOURCE_QUALITY_SCORES`) is stripped at cell 21 before the
  mlx files are written: **no weight ever reaches training**. Execution-verified
  sources (NB09 REPL pairs, NB32 notebook cells, `reducer.jsonl`) are not in
  `SOURCE_QUALITY_SCORES` at all and take `DEFAULT_SOURCE_QUALITY = 0.8` —
  below unverified `proposal`/`comment` prose at 0.95.

### Stale / corrected figures found so far

| Issue | Claim | Status |
|---|---|---|
| #787 | "fuses the adapter to become the next round's base" | **STALE** — NB21 anchors `TRAINING_BASE_MODEL = BASE_MODEL` and chains adapters; fusing is downstream-only |
| #786 | "main evaluation ran execution checks on 6 samples" | true of the recorded run; the *cap* is now `MAX_EXEC_CHECKS = 40`. The 6 is caused by the gate, not the cap: `is_safely_runnable` rejects anything containing `Start the`, `Request the`, `Keepalive`, … so almost nothing qualifies |
| #786 | quick eval 60 prompts, 12 per task | **current** — NB21 `quick_eval(n=60)`, `N_PER_TASK_EVAL = 12` |
| #786 | `check_convergence` tol 0.02 | **current** — train_utils.py:195 |
| #806 | "eval-derived set contributes 5440 correction pairs" | 5440 is `ask_eval_pairs.jsonl` alone; the merged total is **6084** |
| #806 | caps `correction` 4000, `code_generation` 3000 | **current** — config.py:137-153, `TYPE_CAPS_VERSION = 'v4-2026-09-07'` |
| #813 | judged by `aro check` | **current**, and worse than stated: `eval_prompts.json` already carries one entry with `"grade_by": "execution_output"`, `fixtures` and `expected_output` (added for GitLab #486) and **nothing in the repo implements it** — a grep for `grade_by` outside that data file returns nothing |
| #791 | material LR 1e-4, 1200 iters, unconditional fuse, 30B fallback | **all current** |

## Work log

### Commit 1 — #786 (eval sample sizes)

Added `Train/script/eval_stats.py`: Wilson intervals, `proportion()` (rate +
interval + resolution + underpowered flag), `compare()` with an
`indistinguishable` verdict, `required_n` / `detectable_effect` /
`sufficiency_report`, unbiased `pass_at_k`, `converged_by_overlap` (replaces
the 0.02 flat-delta test) and `best_round_by_interval` (reports the tie set).
Constants: `MIN_PROMPTS_PER_TASK = 100`, `SAMPLES_PER_PROMPT = 3`,
`EVAL_SEED = 20260921`, `EXEC_TIMEOUT_SECONDS = 10`. Stdlib only (Acklam's
normal quantile, so no scipy on the slim CI image).

44 tests in `Train/script/tests/test_eval_stats.py`, including the recorded
2026-08 series as a fixture.

NB21 wired: `N_PER_TASK_EVAL` 12 -> 100, `n_code` 60 -> 100, every rate now
recorded with `per_task_n` / `eval_n`, convergence by interval overlap,
per-task intervals and an UNDERPOWERED line printed each round, `sufficiency`
written into round_results.json. `train_utils.check_convergence` marked
superseded (kept for old records and its tests).

CI: new `train:unit` job, `python:3.12-slim` + pytest over
`Train/script/tests` (197 tests before this branch, all passing; nothing in
that directory needs mlx or the aro binary).

CLI run against the real 2026-08 record:

```
8 rounds, n=60 prompts each
round    rate        95% interval   vs round 0
    0   0.700  [0.575, 0.801]   -
    1   0.467  [0.346, 0.591]   indistinguishable
    2   0.617  [0.490, 0.729]   indistinguishable
    3   0.333  [0.227, 0.459]   worse
    4   0.283  [0.185, 0.408]   worse
    5   0.500  [0.377, 0.623]   indistinguishable
    6   0.533  [0.409, 0.654]   indistinguishable
    7   0.517  [0.393, 0.638]   indistinguishable
highest rate: round 0
rounds indistinguishable from it: [0, 1, 2, 5, 6, 7]
smallest change this set can resolve at p=0.5: 24.6%
prompts needed to call the 0.700 to 0.517 this run shipped on: 111
```

