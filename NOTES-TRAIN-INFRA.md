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
