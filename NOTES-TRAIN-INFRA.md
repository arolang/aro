# NOTES — train::infra (#792, #793, #795, #803, #804, #812)

Worktree: `/Users/kris/Projects/ARO/ARO-Lang/.claude/worktrees/agent-a5aed95394b2d82cb`
Branch: `train/infra` (from `main` @ d15b1250)

## Setup

- A stale local branch `train/infra` already existed, tip `f3b42f6f` ("Train docs: fix
  numbering drift…", 2026-07-14, never pushed to origin, not merged into main, not
  checked out in any worktree). Renamed it to `train/infra-legacy-202607` to free the
  name; nothing lost, fully reversible.

## Issues as read from GitLab (verbatim summaries)

- **#792** last full run not reproducible: `Train/data/04_validated`, `05_dataset`,
  `Train/models` empty; `knowledge_pairs` missing rows from several stages;
  `requirements.txt` pins nothing; `config.PIPELINE_VERSION` still `2026.07`.
  Fix: pin mlx/mlx-lm/transformers with a lock file; versioned `Train/runs/<release>/`;
  init stage must refuse to wipe later-stage outputs without `--fresh`; bump version.
- **#793** patched mlx build nothing installs/checks. Fix: pin mlx, add one-iteration
  LoRA smoke test to init + `training.sh`, record mlx version.
- **#795** hyper-parameters scattered over 8 notebooks, contradictory. Fix: `HPARAMS[stage]`
  in `config.py`; log every run incl. sweeps; wire per-task eval; select by pass rate.
- **#803** notebooks non-resumable/untestable. Fix: extract to `train/stages/NN_*.py`,
  `--dry-run`/`--limit`, per-stage CI smoke test.
- **#804** generated programs write into the repo. Fix: `cwd=tmpdir`, sandboxed HOME,
  networking off; .gitignore the stray names.
- **#812** only four stages log to `experiments.db`, untracked binary. Fix: log every
  stage under one session id; export a committed CSV summary into `Train/runs/`.

## Log

### Verification pass (before any edit)

Checked against the *main* checkout (`/Users/kris/Projects/ARO/ARO-Lang/Train`), since
this worktree has no gitignored pipeline outputs.

- #792 **confirmed**: `data/04_validated`, `data/05_dataset`, `models/` all exist and are
  empty. `knowledge_pairs.jsonl` = 10 008 rows from only NB00_git (3580), NB08 (3228),
  NB04 (1140), 03_material (1065), NB07 (480), NB06 (194), 03_material_runner (178),
  NB00_fix (142) — nothing from the synthetic/function-calling/external-repo/validation
  stages. `requirements.txt` pins nothing. `config.PIPELINE_VERSION == '2026.07'`.
- #812 **confirmed**: `experiments.db` (45 KB, untracked) holds 22 rows from exactly four
  notebooks — NB17 (2), NB18 (2), NB19 (2), NB20 (16).
- #804 **confirmed**: `eval_metrics.run_aro_program()` runs `subprocess.run(['aro','run',str(d)])`
  with **no `cwd=` and no `env=`**; same for `aro_check_dir()`, `config.aro_check_snippet()`,
  `30_fim_pairs.py`, `28_diagnostic_repairs.py`, `tools/run_prompts.py`.
  Stray files present in the main checkout's `Train/script/`: `app.log` (34 B,
  "Log started"), `test.txt` ("Hello, ARO!"), `decoded.txt` + `encoded.txt` (0 B),
  `events.jsonl` (1083 B).
  **Correction to #804**: `32_notebook_pairs.py` ALREADY passes `cwd=str(cwd)` to
  `aro repl --json`, so "this also removes the path-dependent cell drop-outs in the
  notebook-pairs stage" is stale — that stage is the one call site that was already right.
- #795 **mostly confirmed, one correction**: hyper-parameters found in
  07/11/18/19/21/22/23/24/25. **`07_warmstart_finetune` sets no LoRA rank at all** — it
  passes `--num-layers 16` and nothing else, so it inherits mlx-lm's default rank. Its
  chart title nevertheless prints "rank 16 / 16 layers", which is where the issue's
  "warm start | rank 16" came from. The real rank disagreement is therefore between the
  *printed claim* and the *actual* default; the layer count (8 vs 16) is the parameter
  that genuinely differs across stages.
- #803 **confirmed**: `00_META_PIPELINE` has `TIMEOUT = 0   # no timeout by default`;
  `timeout=0` becomes nbconvert `-1` and `subprocess` `None`, so a hung stage blocks
  forever. 27 notebooks + 5 `.py` stages (28–32). `script/tests/` has 8 test modules, all
  for pure helpers.
- No `Train` job exists in `.gitlab-ci.yml` at all — the pipeline's Python is untested in CI.
### #792 — done (commit 1)

Written:
- `Train/requirements.txt` rewritten: HF stack pinned `==`, mlx floored `>=0.32.2`
  (floor not pin — see #793 note below), notebook/plot stack floored, pytest added.
- `Train/requirements.lock.darwin-py312.txt` — full transitive freeze taken from the
  venv that produced the last release (`Train/.venv`, macOS 26 arm64, CPython 3.12).
  **Finding**: `01_init` ran `%pip install matplot` — a typo for matplotlib. `matplot`
  is a real unrelated package; it pulls `pyloco`, which pulls the PyPI `typing`
  backport that shadows the stdlib `typing` module on Python 3. Those five lines are
  commented out in the lock and the typo is fixed in the notebook.
- `config.PIPELINE_VERSION` 2026.07 → 2026.09 with a changelog comment.
- `config.RUN_ARCHIVE_ROOT` / `run_archive_dir()`; `NotAFreshRun`, `fresh_requested()`,
  `assert_fresh_allowed()`.
- `Train/script/run_archive.py` (+ `--check`, `--dry-run`) and `Train/runs/README.md`.
- `01_init` cell 4 now calls `assert_fresh_allowed(STAGE_DIRS)` before the rmtree.
- README: "Reproducing a run" section listing the executable sequence.
- `Train/script/tests/test_run_archive.py` — 10 tests.

Commands run: `pytest Train/script/tests/test_run_archive.py -q` → 10 passed;
`pytest Train/script/tests -q` → 163 passed;
`python3 Train/script/run_archive.py --dry-run` → reports both required artifacts
missing in this worktree (expected — data/ is gitignored and absent here).

### #793 — done (commit 2)

**Correction to the issue**: the patched-mlx dependency is stale. Verified by
`strings`-scanning the metallibs of both mlx installs on this machine:
- `Train/.venv` mlx **0.32.2** → gather kernels for bfloat16, float16, **float32**
- system python mlx **0.31.2** → same three
So the float32 instantiation is upstream from 0.31.2 on (report was against 0.31.1).
requirements.txt therefore floors `mlx>=0.32.2` rather than pinning a private build.

Written: `Train/script/mlx_preflight.py` (metallib kernel scan; `--lora` one-iteration
smoke test; `--json`; exit 0/1/2), `tests/test_mlx_preflight.py` (12 tests, synthetic
metallibs — no GPU needed), training.sh preflight gate (exit 3 on failure,
`ARO_TRAIN_SKIP_MLX_PREFLIGHT=1` overrides), an 01_init preflight cell, ISSUE-MLX.md
status header, README env-var rows.

Bug found while writing the tests: `_parse_version('1.0.0rc1')` returned (1,0,1).

Commands: `python3 Train/script/mlx_preflight.py --no-record` → OK with a
below-floor warning (system mlx 0.31.2); `Train/.venv/bin/python … --json` → ok true;
`bash -n Train/training.sh` → clean; `pytest Train/script/tests -q` → 175 passed.

### #795 — done (commit 3)

`config.HPARAMS` (8 stage rows, `HPARAMS_VERSION = v1-2026-09-21`), `hparams()`,
`hparams_record()`; all 8 training notebooks rewritten to read `HP[...]` including
their mlx-lm command lines; `check_hparams.py` (+ `--list`) enforces it;
`tests/test_hparams.py` (17 tests) incl. a test asserting the shipped notebooks pass.
NB18 sweep now logs each variant to experiments.db as `NB17-sweep`.

Picks where notebooks disagreed (full reasoning in the commit message):
- `lora_rank` = 8 everywhere (sweep-measured; 07 and 22 never set one and were
  already getting mlx-lm's default 8 — the "rank 16" was only a chart label)
- iterative `learning_rate` 1e-5 → 8e-6; `grad_accum` 4 → 16 (match SFT, the
  measured stage; the NaN rationale for 4 does not hold up)
- material `learning_rate` 1e-4 → 2e-5 (match the student's own rate)
- `lora_layers` left per stage with reasons recorded (16 teacher/student, 8
  preference/material); warm_start `grad_accum` left at 1 and marked unmeasured
- `max_seq_len` 4096 shared, 2048 warm_start, 5120 conversation — recorded exceptions

Commands: `check_hparams.py` → 8 notebooks clean; `--list` prints the table;
per-cell `compile()` over all 9 edited notebooks → 0 syntax errors;
`pytest Train/script/tests -q` → 189 passed.

### #803 — done (commit 4)

`Train/script/stage_runner.py`: `StageOptions` (`--dry-run`/`--limit`, plus
`from_env()` for notebooks via `ARO_TRAIN_DRY_RUN`/`ARO_TRAIN_LIMIT`), and
`run_notebook()` with a **stall watchdog** — kills a stage that has written nothing
for `ARO_TRAIN_STALL_TIMEOUT` (default 1800s) rather than capping wall clock, so a
6h fine-tune that prints loss lines is never killed. `MAX_RUNTIME_OVERRIDES` kept
for hard caps, empty by default.
Meta notebook's executor cell now delegates to it; `TIMEOUT_OVERRIDES`/`DEFAULT_TIMEOUT`
(all zeros) removed; run loop reports `stalled` distinctly.
Stages 28/30/31/32 take the shared options; 32 limits notebooks executed (the
expensive half). 29 keeps its own older `--limit` (documents) — noted in README.
CI: new `train-tests` job in the `test` stage (python:3.12-slim) running pytest,
`check_hparams.py`, a `run_archive --dry-run`, and asserting `mlx_preflight` exits 2
off Apple Silicon.

Commands: `pytest Train/script/tests/test_stage_runner.py -q` → 14 passed;
full suite → 203 passed; `py_compile` on all 9 scripts → OK; per-cell compile of the
meta notebook → 0 syntax errors; `python3 Train/script/28_diagnostic_repairs.py
--dry-run --limit 3` → capped at 3 pairs as intended.

### #804 — done (commit 5)

`Train/script/sandbox.py`: `sandbox_env()` (env allowlist + private HOME/TMPDIR +
dead-proxy offline vars), `prepare_workdir()`, `sandboxed_run()`, `program_dir()`,
`mirrored_dir()`, `run_program_dir()`. All generated-code call sites routed through
it: `config.aro_check_snippet`, `eval_metrics.run_aro_program` / `aro_check_dir`,
`28_diagnostic_repairs.aro_check`, `30_fim_pairs.aro_check_dir`,
`32_notebook_pairs.run_notebook_session` (+ per-pass `mirrored_dir`),
`tools/run_prompts.run_aro_check`, `tools/curate_material.aro_check` and its bulk check.
`.gitignore`: the five stray names.

**Reproduced the bug and the fix against real aro 0.12.0**:
`Write "Hello, ARO!" to the <file: "test.txt">.` — old call shape → `test.txt` in the
caller's cwd; `sandbox.run_program_dir` → `test.txt` in the throwaway dir, cwd clean.
(`Log … to the <file: …>` is not valid syntax in 0.12.0; `Write` is the sink that
produced the strays.) That proof is now `TestAgainstTheRealRuntime` in
`tests/test_sandbox.py`, skipped when no `aro` is on PATH.

**Stale in the issue**: 32_notebook_pairs already passed `cwd=`; its real problem was
that the cwd was `Learning/<notebook dir>` inside the repo, which is also why cells
dropped out as non-reproducible between the two passes.

**Could not verify / brief was stale**: there is no `AROWorkingDirectory` anywhere in
`Sources/` on main (d15b1250). Relative paths resolve against
`FileManager.default.currentDirectoryPath`, so `cwd=` on the subprocess is the lever.

Commands: `pytest Train/script/tests/test_sandbox.py -q` → 17 passed;
full suite → 219 passed (before the new file) / see next run.

### #812 — done (commit 6)

`experiment_db.py` extended: schema migrated with ALTER TABLE (session_id,
pipeline_version, hparams_version, aro_version, rows_in, rows_out, drop_reasons);
`record_data_stage()`, `record_funnel()`, `export_csv()`, a CLI
(`--export --release X`, `--list --stage NB17`), `ARO_TRAIN_DB` override.
`config.save_notebook_pairs()` now records every data stage automatically (the one
funnel they all use). Recording cells appended to 07, 22, 23, 24, 25, 27.
`Train/.gitignore`: `experiments.db` (+ journal/wal).
`Train/script/tests/conftest.py` points the suite at a temp DB.

**What replaced experiments.db**: nothing — it stays as the working store and stays
gitignored. The *record* is `Train/runs/<release>/experiments.csv`, exported from it.
`Train/runs/2026.09/experiments.csv` is committed here: the real 22 rows of the
September run, exported from a copy of the main checkout's database (the original
was not modified).

Commands: `experiment_db.py --export --release 2026.09 --db <copy of sept.db>`
→ "wrote 22 run(s)"; `pytest Train/script/tests -q` → 228 passed;
`check_hparams.py` → clean; per-cell compile of all edited notebooks → 0 errors.

## Done

MR: https://git.ausdertechnik.de/arolang/aro/-/merge_requests/594
Branch `train/infra` pushed to `origin` (never to `public`).

Commits:
- cc85e501  train: make a pipeline run reproducible from the repository (#792)
- 6aad95b9  train: check mlx can train a MoE model before spending GPU time on it (#793)
- 89973364  train: one hyper-parameter table, and a reason on every line (#795)
- f0b91e70  train: a stage that stops writing is killed; a stage that runs long is not (#803)
- 7daf9c1e  train: generated programs run in a sandbox, not in the repository (#804)
- 2066fd0a  train: every stage records, and the record is a CSV you can read (#812)

Scope: only `Train/`, `.gitlab-ci.yml` and this file. Nothing in Sources/, Examples/,
Book/, Proposals/, CLAUDE.md.
