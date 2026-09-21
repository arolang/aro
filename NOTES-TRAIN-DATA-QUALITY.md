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

