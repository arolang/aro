# Eval-derived training data

`ask_eval_pairs.jsonl` — **8,024** validated instruction/output training pairs
generated to fix weaknesses surfaced by a 4,000-prompt `aro ask` evaluation and
the 2026-07 training-run charts (`Train/script/run/`). Every ARO code output
passes `aro check`; every error→fix "broken" input genuinely fails it (no
`trivial_fix_no_diff`).

## Composition

| task_type | count | notes |
|-----------|------:|-------|
| correction (error→fix) | 5,440 | 14 injected error classes incl. hallucinated actions (the model's #1 weakness), missing period/brackets/activity, `+` vs `++`, wrong Emit shape, unclosed braces, uncapitalized verbs |
| code_generation | 1,695 | derived from 678 validated base programs (harvested + entity-varied), full verb/domain coverage |
| full_application (OpenAPI) | 180 | contract-first: `openapi.yaml` object schema + ARO feature sets per operationId, full CRUD |
| syntax_qa + knowledge | 452 | curated, accurate — action roles, prepositions, concepts, proposal topics |
| tool_calling | 257 | correct `<tool_call>` JSON protocol (counters the disguised-bash-block bug) |

Weighted deliberately toward error→fix / OpenAPI / tool_calling — the gaps the
run charts exposed (debugging was 87% `trivial_fix_no_diff`; hallucination_rate
≈ 0.40; tool_calling ≈ 24 samples).

## Reproduce

```bash
python3 generators/run_all.py   # rebuild pool → expand → generate → assemble
```

The base pool is harvested from `Examples/**/*.aro` + `Train/Material/canonical.json`
and validated with `aro check`; `supplement.py` adds authored git/set-op/template
programs. `inject.py` holds the error-injection transforms.

## Pipeline placement

Injected upstream (before `16_dataset_assembly`) into the curated pairs stream so
it flows into the 30B teacher (NB17) and, via distillation (NB21) + booster (NB23),
into the shipped student — not a post-packaging patch. `TYPE_CAPS` bumped to
`v3-2026-07-24` in `config.py` to keep the distinct new examples.
