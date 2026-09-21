# NOTES — train::data-quality (#779-784, #789, #798, #799, #809; tracking #840)

Worktree: `/Users/kris/Projects/ARO/ARO-Lang/.claude/worktrees/agent-a3b5423f58da06e42`
Branch: `train/data-quality` (from `main` @ 0f5625de)

## Ground rules for this task
- Stay inside `Train/` (+ `.gitignore`/`.gitlab-ci.yml` if CI is added). No `Sources/`, `Examples/`, `Book/`, `Proposals/`, `CLAUDE.md`.
- One commit per issue, 10 commits, `(#NNN)` in the subject. Two required trailers.
- One MR into `main`, `Closes` all ten plus #840.

## Read so far
- All ten issues + tracking #840 read via `glab issue view`.
- `Train/` layout: `script/` holds notebooks 00-27 plus standalone `.py` stages
  (28_diagnostic_repairs, 29_multimodel_doc_qa, 30_fim_pairs, 31_failure_dpo,
  32_notebook_pairs) and shared `config.py`, `train_utils.py`, catalogs.
- **`Train/.gitignore` excludes `data/`, `models/`, `release/` and several
  generated `script/*.jsonl`** — so the corpus the issues quote is NOT in the
  repo. It lives only in the main checkout at
  `/Users/kris/Projects/ARO/ARO-Lang/Train/data/`. Analysis reads from there;
  fixes must land in committed code (scripts/tests/CI), not in the ignored data.

## Branch name deviation
A **stale local branch `train/data-quality` already existed** (tip 35d991fa,
2026-07-14, "Train NB16: semantic near-dedup…", 8 commits, never pushed to
origin, not merged into main). I did not touch it. My work is on
**`train/data-quality-840`**, branched from `main` @ 0f5625de.

## #779 — stale catalogs (VERIFIED, numbers corrected)

Measured `Train/script/aro_action_catalog.json` against `aro actions list
--format json` (installed binary 0.12.0):

| | committed | runtime |
|---|---|---|
| actions | 70 | 71 |
| verbs | **128** (issue said 129) | **130** (issue said 131) |

Confirmed every delta the issue lists: `reverse`/`flip` absent; `compare`
missing `from`; `sort` missing `from`; `update` missing `into`; `include` has
an extra `with`; `store` has an extra `in`; `extract` wrongly owns `parse`
(it belongs to ParseDispatch, whose role is `request`, not `own`).

**New finding, not in the issue:** `aro_qualifier_catalog.json` was stale too
— missing `fixed`, which CLAUDE.md documents (33 → 34).

**Also verified by hand:** `Store the <u> in the <r>.` → `aro check` errors
("Expected preposition, but got the keyword 'in'"). So the catalog was
teaching a form the runtime rejects.

**Fix:** new `Train/script/aro_oracle.py` (binary resolution honouring
`ARO_BIN`, `aro_version()`, registry access, `check_block()`); all three
extractors prefer `aro actions --format json` and keep the Swift scan as the
fallback; all three gained `--check`; `config.build_verb_preposition_map()`
now reads the authoritative catalog first instead of prose-mined
knowledge.json. CI job `train:catalogs` (integration stage, `needs:
build:linux`, `ARO_BIN=aro-dist/aro`) runs the three `--check`s.

Commands:
```
python3 Train/script/extract_action_catalog.py    # 70 -> 71 actions
python3 Train/script/extract_action_verbs.py      # 128 -> 130 verbs
python3 Train/script/extract_qualifier_catalog.py # 33 -> 34 qualifiers
python3 Train/script/extract_action_catalog.py --check   # passes
```

## #783 — nothing re-validates the corpus (VERIFIED; the central mechanism)

Confirmed: `_metadata.aro_lang_commit` is stamped at save, `data/04_validated/`
is empty, and the validation notebook only runs inside a full pipeline run.

Built `Train/script/revalidate_corpus.py` + `Train/script/aro_oracle.py`.
Oracle design notes (probed against 0.12.0 by hand before writing):
- `aro check <dir>` demands an Application-Start → useless for snippets.
- `aro check --syntax -` takes fragments, feature-set bodies and whole
  programs, BUT mis-parses a `(* banner *)` that precedes a feature-set
  header. So: blocks with a feature-set header go through a temp-directory
  check (an `Application-Start` is supplied when absent); bare statements go
  through `--syntax`.
- **`aro check` does NOT catch invented verbs.** `Hash the <digest> from the
  <password>.` exits 0 with only a use-before-definition warning. The catalog
  gate is therefore not redundant with the binary — this is the concrete
  evidence for #798's "check is not enough".
- **`aro check` reports a wrong preposition as a WARNING, exit 0** —
  "Action 'Render' does not accept the preposition 'from'". A corpus graded
  on exit codes never sees these. The validator reads the binary's own
  warnings instead of a regex; the regex fallback is only for `--no-binary`.
- **Bug found in the existing gate:** `as` was in `config.ARO_PREPOSITIONS`,
  so `Compute the <n> as Float from <s>.` (valid, CLAUDE.md) was flagged 17×.
  Removed from both `config.py` and the validator.

### Full-corpus baseline (10 007 pairs, 4 411 with ```aro blocks)
```
pass rate 93.6%   640 failing
reasons: aro_check 484, unknown_verb 172, bad_preposition 65, unknown_qualifier 2
3 730 unique blocks checked in 52 s (10 jobs)
```
By notebook: NB00_git 456/3580 failing (87.3%), NB08 64/3228, NB04 57/1140,
03_material 20/1065, 03_material_runner 17/178, NB00_fix 14/142, NB06 12/194,
NB07 0/480.

`Train/Material/curated.jsonl` (committed): 1069 pairs, 24 failing, 97.8%.

CI: `train:tests` (test stage, python:3.12-slim, pytest) and `train:corpus`
(integration stage, ARO_BIN from build:linux, `--fail-under 97`).
26 new tests; full Train suite 179 passed.

## #780 — ~150 statements with invented verbs (VERIFIED; number corrected upward)

Scanned every checkable ```aro block on the answer side of all 10 007 rows
against the *corrected* catalog (so `Reverse`/`Flip` no longer count):

```
rows with an unknown statement verb : 172
unknown statement occurrences       : 322  (238 excluding English prose
                                            words fenced as ```aro)
distinct names                      : 121  (108 excluding prose words)
```
Per-verb, matching the issue almost exactly: Hash 20, Grant 18, Encrypt 15,
Process 14, Line 7, Require 7, Greet 6, Farewell 6, Deduct 5, Redirect 5,
Encode 4. So "~150" is really **238**.

Confirmed the cause: only the eval-derived merge stage applied the gate.
`save_notebook_pairs()` ran the FIXTRAIN lint and nothing else.

**Fix:** `config._pair_gate()` runs on every write through
`save_notebook_pair(s)` — the four gates of `revalidate_corpus` — and stamps
`validation` on every kept pair. `ARO_TRAIN_PAIR_GATE=full|static|off`
(default `full`); `static` skips the subprocess for hosts with no binary.
`config.pair_gate_report()` prints the per-source pass-rate table the issue
asked for. 8 new tests.

Applied to the existing corpus, the gate would drop **640 of 10 007 pairs**
(6.4%): aro_check 484, unknown_verb 172, bad_preposition 65,
unknown_qualifier 2 (a pair can fail for more than one reason).

## #798 — `aro check` is the only oracle (VERIFIED; the gap is bigger than filed)

Added `run_block` / `test_block` / `grade_block` to `aro_oracle.py` and `--run`
to the validator. Measured over the whole 10 007-pair corpus:

```
blocks that are complete, non-server programs : 950
ran green                                     : 478
FAILED AT RUNTIME while passing `aro check`   : 472   (~50%)
pairs that gained an expected_output          : 475
blocks carrying colocated tests               : 37  (28 green, 9 failing)
pass rate with the run oracle                 : 89.2%  (93.6% on check alone)
```

`aro test` had never been used by the pipeline at all; 9 failing suites were
invisible. Runtime cost: 52 s for the whole corpus at 10 jobs, so the "budget"
the evaluation stage imposed (n = 6 in the August run) was never necessary.

Design points: `run` returns `None` for "not attempted" (server / no entry
point / no binary) and that is never conflated with success — the old 0.8/0.9
scores made a skipped server and a missing binary indistinguishable.
`ARO_NO_DEFER=1` so two runs of a program agree (ARO-0088 statement overlap).
Servers are detected by shape (Keepalive / Listen / Start the <http-server> …).

## #782 — task_type missing on 48% (VERIFIED exactly)

`4822 / 10007 = 48.2%` — the issue's figure to the decimal.

Fix: `config.infer_task_type()` (the guess moved out of the assembly notebook
into testable code), `config.ensure_task_type()` called by both save paths and
raising `MissingTaskType` (`ARO_TRAIN_REQUIRE_TASK_TYPE=0` to relax),
`config.task_type_census()`, and `Train/script/backfill_task_types.py`.

Backfill result (run on a COPY at /tmp/claude-501/tt/kp.jsonl — see note
below):
```
missing before : 4822 (48.2%)
filled         : 4822   syntax_qa 3679, code_generation 903, correction 119,
                        multi_file_application 102, tool_calling 19
still missing  : 0
re-run         : 0 filled (idempotent)
```
Per type, before → after: syntax_qa 0 → 3679, correction 0 → 119,
tool_calling 0 → 19, **multi_file_application 14 → 116**, code_generation
1005 → 1908. The holdout contained one multi-file application because only 14
of the 116 were labelled — the key mis-labelling was that an answer shaped
`## openapi.yaml` + `## main.aro` was filed as `code_generation`; inference
now reads the answer's shape before the source tag.

**Not written to the shared corpus.** `Train/data/` lives only in the main
checkout and sibling training branches are running against it; rewriting a
10 007-line file while another process appends would lose rows. The backfill
was verified end to end on a copy. `--write` is the operator's one-off step.

Six pre-existing tests in `test_config_infra_helpers.py` saved unlabelled
pairs; they now set `task_type` (that is the point of the change).

## #784 — duplicates (VERIFIED; numbers slightly higher, and one much higher)

Measured on `knowledge_pairs.jsonl` (10 007 rows), normalised (whitespace +
case):

| | issue | measured |
|---|---|---|
| repeated instructions (extra copies) | 276 | **284** (over 131 distinct) |
| byte-identical (instruction, output) | 190 | **199** (over 60 distinct) |
| repeated **outputs** (extra copies) | not counted | **2 710** over 706 distinct |
| most-repeated single answer | — | **379 prompts share one commit message** |

`comment_pairs.jsonl`: 23 057 rows, 1 149 distinct outputs, 6 897 distinct
instructions. So ~20 rows per distinct answer — and **15 701 of the rows are
byte-identical pairs**, which is a bigger problem than the 9× paraphrase.

**Fix:** three caps in `config`, applied at save (`_dedup_gate`, seeded from
the corpus already on disk so a rerun cannot reintroduce anything):
exact (instruction, output) once; `ARO_TRAIN_MAX_PER_INSTRUCTION` (3);
`ARO_TRAIN_MAX_PER_OUTPUT` (3) — the output-side cap that did not exist.
Plus `Train/script/dedup_corpus.py` for corpora that already exist.

Before/after, `dedup_corpus.py` at caps 3/3:
```
knowledge_pairs.jsonl  10 007 -> 8 376 rows (-1 631: output_cap 1 512,
                       exact_pair 114, instruction_cap 5)
                       duplicate pair copies 199 -> 0
                       most-repeated answer  379 -> 3
comment_pairs.jsonl    23 057 -> 3 311 rows (-19 746: exact_pair 12 122,
                       output_cap 7 463, instruction_cap 161)
                       all 1 149 distinct outputs retained
```
Again a report, not a rewrite of the shared corpus (concurrent branches).

## #781 — git-diff pairs (VERIFIED; one claim corrected)

`git_examples_pairs.jsonl` 3 514 rows, `git_applications_pairs.jsonl` 110 —
confirmed. NB00_git is 3 580 of 10 007 rows = **35.8%**. All tagged
`debugging`. No generator in the repository (searched `Train/`).

Validated them for the first time:
```
git_examples_pairs.jsonl      3 514 pairs, 478 failing, 86.4% pass
                              (aro_check 458, unknown_verb 97)
git_applications_pairs.jsonl    110 pairs,  17 failing, 84.6% pass
```

**Claim corrected:** the issue says "the `.aro` suffix rule gives it a high
default quality". It does not — those sources end `.aro@<sha>`, so
`source_quality_score` matched no rule and returned the 0.8 DEFAULT. The
deeper problem is the same one in a different place: every row carried its own
`path@sha`, so `SOURCE_SOFT_CAP_SHARE = 0.30` saw three thousand sources of
one row each and never fired on a source holding 36% of the corpus.

**Fix:** `Train/script/33_git_diff_pairs.py` — the generator, in the
repository. Whole files at both SHAs (`git show <sha>:<path>`), both run
through `aro check`, pair kept only when the NEW side checks green, labelled
`correction` when the old side failed and `code_transformation` otherwise, the
answer being commit subject + body + the unified diff + the old side's actual
diagnostic. Source `git:<repo>/<path>@<sha>`.
Plus `config.source_family()` (`.aro@<sha>` → `git`), `SOURCE_QUALITY_SCORES['git'] = 0.6`,
`SOURCE_CAPS = {'git': 1200}` and `source_cap()`.

Proof run over this repository's last 60 `.aro`-touching commits:
```
60 commits, 98 files, 51 usable -> 102 pairs
4 corrections, 47 transformations, 2 rejected because the new side does
not pass aro check
```
9 new tests (they build throwaway git repos).

## #789 — the thinking booster (VERIFIED; and the template is factually wrong)

`data/26_thinking/mlx/train.jsonl`:
```
rows                                   2 348
with a <think> block                   1 156
without one                            1 192   (issue: 1192 ✓)
templated ("a EXPORT/OWN/REQUEST action", "Let me work out the ARO.")
                                       1 156 of 1 156  (issue said 1024)
mean think length                      1 640 chars  (issue said 807)
rows carrying a system prompt          0        (issue ✓)
```

**New finding:** the template asserts "`Log` — a EXPORT action". The registry
says Log's role is **response**. So the booster taught the wrong role 798
times, and the grammar is wrong too ("a EXPORT", "a OWN").

**Fix:** `config.thinking_trace_is_templated()` / `validate_thinking_row()` —
a gate that checks presence, the template fingerprint and the system prompt,
which a 40-character threshold cannot — and
`Train/script/34_thinking_pairs.py`, which builds traces by breaking a
validated program in one known way, asking the oracle, and writing the think
block from the real diagnostic. Invented verbs are graded against the catalog
rather than `aro check` (which accepts them) and the trace says so.

Before/after, scored by the same gate:
```
data/26_thinking/mlx/train.jsonl   2 348 rows,     0 usable (0.0%)
                                   2 348 no system prompt
                                   1 192 no <think>
                                   1 156 templated
34_thinking_pairs.py over Train/Material/curated.jsonl
                                   1 007 rows, 1 007 usable (100%)
                                   categories: invalid_verb 382,
                                   missing_period 344, unknown_qualifier 162,
                                   wrong_preposition 119
```

