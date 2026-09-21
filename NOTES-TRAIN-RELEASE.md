# NOTES-TRAIN-RELEASE

Worktree handoff notes for GitLab #796, #807, #808 (labels `training` + `train::release`).

Branch: `train/release-796` off `origin/main` @ 0f5625de.
(A *local* branch `train/release` already existed at 48de23ba — per instructions it was
neither reused nor deleted; the suffixed name was taken instead.)

## Issues as filed

- **#796** promotion gate too loose: gates on syntax pass >= 40% and quantisation drop <= 10
  points; release v1.1.0 measured 75.5%, so a 40% floor would accept a model half as good.
  `eval_prompts.json` is 105 mostly one-liners. Fix: gate on "no metric worse than previous
  release by more than its CI" against a frozen benchmark, add execution pass (`aro run`) and
  tool-call format rate, store per-prompt results in `version_history.json`.
- **#807** released model records no ARO version; `min_cli_version: "1.0.0"` while CLI is 0.12.0.
  Fix: add `aro_version`, `aro_commit`, catalog hash, corpus hash to manifest + model card;
  `aro ask` warns on catalog-hash mismatch; version the system prompt with the same key.
- **#808** `Train/release/aro_system_prompt.txt` is 14 475 bytes, syntax summary twice,
  `build_system_prompt` truncates at 4000 chars mid-word, thinking rows carry no system prompt,
  prompt teaches pre-#469 `Compare ... against ...`.

## Log

- Read all three issues via `glab issue view`.
- Sibling branches on origin: `train/data-quality-840` (!592), `train/training-eval` (!591),
  `train/infra` (!594). All unmerged; all touch `Train/README.md` and `Train/script/config.py`.

## Verification of the three issues (all three claims hold)

### #796 — gate
`Train/script/27_package.ipynb` cell 10 is the promotion gate. Constants confirmed:
`GATE_REPLY_RATE_MIN=0.50`, `GATE_EMPTY_THINK_MAX=0.20`, `GATE_SYNTAX_PASS_MIN=0.40`,
`GATE_TOOL_LEAK_MAX=0.02`, `GATE_URL_CONTAM_MAX=0.05`, `GATE_QUANT_*_DROP_MAX=0.10`.
`Train/release/version_history.json` (untracked, main checkout) records v1.1.0 at
`syntax_pass_rate = 0.7553191489361702`. So the shipped model beat the floor by 35 points:
the floor cannot fail on any plausible regression. `eval_prompts.json` = 105 prompts.
No execution metric anywhere in the gate; `aro check` only (`_aro_check_snippet`).
`version_history.json` stores only aggregate `gate_metrics` — no per-prompt results, so no
paired comparison is possible today.

### #807 — manifest
`Train/release/model_manifest.json` (built 2026-08-10) is exactly the 9 keys the issue lists,
`min_cli_version: "1.0.0"`. Written by NB27 cell 20 where `'min_cli_version': '1.0.0'` is a
literal. Installed CLI reports `0.12.0`; newest tag in the repo is `0.12.1`. There is no
1.x CLI and there never has been.
EXTRA FINDING (not in the issue): `min_cli_version` is consumed by **nothing** —
`grep -rn 'min_cli_version|minCliVersion' Sources/` is empty. The field is inert metadata
today, so the wrong value misleads readers rather than blocking runs. Recorded in the MR.

### #808 — system prompt
`Train/release/aro_system_prompt.txt` = 14 475 bytes, exactly as filed. Built by NB27 cell 12
from `SYSTEM_PROMPT = build_system_prompt(kb)` (cell 8), i.e. `config.build_system_prompt`.
The duplication is inside the `ARO SYNTAX RULES:` section, which is a raw
`kb['aro_syntax']` dump sliced `[:4000]`: the `(Feature Name: Business Activity)` skeleton and
the whole Application lifecycle block appear twice (once `---`-separated, once fenced), and
the slice ends mid-word at "built-in ope".
The stale `Compare the <first-length> against the <second-length>.` is at line 92 of the
shipped file and comes from that dump — `build_system_prompt`'s own CORE RULES text already
teaches the post-#469 form, so the prompt contradicts itself.
EXTRA FINDING: the prompt advertises 18 tools; the CLI registers those 18 **plus**
`aro_knowledge` (Sources/AROAsk/Tools/KnowledgeTool.swift), which the model is never told about.

## #796 — work done

New `Train/script/release_gate.py`: the gate as a pure decision procedure over a
results file (no model, no GPU), so it is unit-testable and runs in CI.

Reused from the sibling branches rather than reinvented:
- `eval_stats.wilson_interval` (GitLab #786, `train/training-eval` !591) — imported when
  present, with a byte-identical local fallback so this branch stands alone before !591
  merges. `test_release_gate.py::test_matches_eval_stats_when_that_module_is_present`
  asserts the two agree; run with the sibling module on PYTHONPATH it passes (30 passed).
- `functional_eval.grade` + `Train/eval/functional/tasks.json` (GitLab #813, !591) — the
  source of the per-prompt `exec_pass` flag.
- `aro_oracle` (GitLab #840, `train/data-quality-840` !592) — the `aro run` oracle, used
  as the execution backend when functional_eval is absent.
- `experiment_db` (`train/infra` !594) — the gate report is recorded as a stage record.

Gate rules now: paired non-regression against the previous release (exact McNemar on the
discordant pairs, alpha 0.05), unpaired Wilson-interval comparison when only aggregates
were stored, plus refusals for a dropped metric, benchmark drift (<90% prompt overlap)
and a shrunken benchmark. Fixed floors kept but demoted to a collapse net.

`python3 Train/script/release_gate.py --demo` replays the real v1.1.0 numbers
(75.5% syntax pass, 105 prompts, 94 with code) against a 45% candidate:
  pre-#796 gate:  PASSED — 45.0% clears the 40% floor
  post-#796 gate: REFUSED — syntax_pass_rate regressed 75.5% -> 44.7%; 29 prompts got
                  worse and 0 got better (exact McNemar p=0.0000 < 0.05)
Exit 0 iff the demonstration holds (old accepts, new refuses).

## #807 — work done

New `Train/script/release_metadata.py` + `tests/test_release_metadata.py`.
NB27 now computes the provenance once (cell 12, after SYSTEM_PROMPT exists) and writes it
into the manifest (cell 20), the model card and version_history (cell 16), and ships a copy
of the manifest inside QUANT_DIR so the HF cache carries it too.

**How min_cli_version was established** — mechanically, not by picking a number.
`derive_min_cli_version` takes the later of two repository facts:
 1. earliest semver tag containing the commit that introduced each `aro ask` tool
    (`git log -S 'name: "<tool>"' -- Sources/AROAsk`, then `git tag --contains`):
    all 18 tools land in d7695769 → first tag **0.10.0**;
 2. earliest tag containing the commit that made `ARO-Lang/aro-coder-6bit` the default
    model id (4964867178, "rename(model): aro-coder-4bit → aro-coder-6bit") → **0.11.3**.
Answer: **0.11.3**. Verified live: `python3 Train/script/release_metadata.py` prints
  aro_version 0.12.1-15-g…, catalog_hash 3187f658c9e07e65, min_cli_version 0.11.3,
  basis {tool_vocabulary: 0.10.0, tools_checked: 18, tools_located: 18,
         default_model_id: 0.11.3}
Installed CLI is 0.12.0; newest tag 0.12.1. There is no 1.x, so the shipped "1.0.0" named
a release that does not exist.

NOT DONE (needs Sources/, outside this MR's remit): having `aro ask` warn on a catalog-hash
mismatch. `release_metadata.catalog_drift()` returns the exact sentence to print; the CLI
side is a one-line comparison. Also note `min_cli_version` is read by nothing in Sources/
today, so it is currently documentation rather than a check.

## #808 — work done

`config.build_system_prompt` rewritten (delimited block, `# ── System prompt builder ──`
through `training_system_prompt`). The raw `kb['aro_syntax']` dump is gone; the action
reference and the closed qualifier set are generated from `aro_action_catalog.json` /
`aro_qualifier_catalog.json`, everything else stated once.

Measured (`scratchpad/compare_prompt.py`, `scratchpad/tokcount.py` with the tokenizer from
Train/release/aro-coder-6bit):
  shipped file            14 475 bytes / 3 549 tokens
  old builder, today's kb 15 867 bytes
  new builder              7 518 bytes / 2 106 tokens   (-48% vs shipped, -53% like-for-like,
                                                          -1 443 tokens per request)
Issue said "roughly 4000 tokens"; measured 3 549. Corrected.

Contradictions / defects removed:
 1. pre-#469 `Compare the <first-length> against the <second-length>.` (line 92 of the
    shipped file) while the same prompt's CORE RULES taught the #469 form. Gone.
 2. mid-word truncation "built-in ope" at the 4000-char slice. Gone (no slice).
 3. the feature-set skeleton and the whole Application-End block printed twice, once as
    prose and once fenced. Gone (test asserts no repeated paragraph *or* line > 40 chars).
 4. `aro_knowledge` — registered by the CLI (Sources/AROAsk/Tools/KnowledgeTool.swift),
    never mentioned in the prompt, so the model could not use it. Added.
 5. the hardcoded partial qualifier list ("length, uppercase, trim, sum, … ") replaced by
    the full closed set from the catalogue, which is what makes "never invent one" checkable.

Training/serving disagreement: only NB24 (thinking) was affected — it built rows with no
system turn, and its before/after eval also omitted one. NB25 (conversation) was NOT
affected: gen_conversations.py already calls build_system_prompt (issue is stale on that
point). NB24 patched in both places; test asserts `"role": "system"` appears twice there.

Tests: Train/script/tests/test_system_prompt.py (25 tests). Whole Train/script/tests suite:
225 passed, 1 skipped.

### #808 latency, measured

Ran Train/release/aro-coder-6bit locally (mlx_lm, 3 prompts, max_tokens=200, temp 0.2,
same loaded model for both arms):
  old prompt  3 549 tokens  times 10.79 / 4.27 / 8.75 s   median 8.75 s
  new prompt  2 037 tokens  times  5.64 / 3.16 / 5.73 s   median 5.64 s
-> -1 512 tokens, -36% median latency. (Earlier 2 106 figure was before the final trim
pass; 2 037 is the shipped number.)

## Merge request

!595 https://git.ausdertechnik.de/arolang/aro/-/merge_requests/595
Commits: 0f7fc42c (#796), 8d915e5d (#807), 032cb54f (#808).
Closes #796, #807, #808.
