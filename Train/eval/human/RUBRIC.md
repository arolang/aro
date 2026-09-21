# Human evaluation rubric

A hundred answers per release, read by a person. Nothing else in the pipeline
can see the failure the recorded run named as dominant — "valid but wrong" —
because a program that parses, runs, and computes the wrong thing scores
exactly like one that is right.

This is not a replacement for `Train/eval/functional/`. The functional
benchmark answers "did it run and produce what was asked for" on tasks with a
checkable answer; this slice answers "would a person accept it" on the prompts
where there is no single right output.

## Running one

```bash
# 1. Draw a fixed, reproducible slice and write the sheet
python3 Train/script/human_eval.py sample \
    --prompts Train/eval_prompts.json \
    --out Train/eval/human/<version>.csv

# 2. Fill in the four verdict columns and the note. One row per answer.

# 3. Score it
python3 Train/script/human_eval.py score Train/eval/human/<version>.csv
```

The sample is drawn with `eval_stats.EVAL_SEED`, stratified across prompt
categories, so two releases are rated on the same prompts and the comparison
means something. Change the seed and the comparison is gone.

## The four axes

Each is **yes**, **no**, or **n/a** — no five-point scales, because a rater
cannot hold a five-point scale steady over a hundred rows and two people will
not hold the same one.

| Axis | Yes when |
|------|----------|
| **correct** | The answer does what was asked. For code: the program computes the right thing, not merely a thing. For prose: the facts are right. |
| **idiomatic** | It reads like ARO written by someone who knows ARO — feature sets named after their business activity, the right verb for the job, `Compute` qualifiers rather than invented ones, no scaffolding the language does not need. |
| **complete** | Nothing is missing that the prompt asked for. A feature set where an application was asked for is not complete; a program that stops at the happy path when the prompt asked for a guard is not complete. |
| **safe** | It invents nothing. No verbs, qualifiers, system objects or proposal numbers that do not exist; no statistics about its own training; no claim about the language that is not true. |

**n/a** is for an axis the prompt does not exercise — `idiomatic` on a pure
knowledge question, for instance. An n/a is excluded from that axis's
denominator rather than counted as a pass.

## What a verdict is not

- Not a style preference. If two spellings are both idiomatic, both are yes.
- Not a judgement of the prompt. A bad prompt gets an honest verdict on the
  answer it got.
- Not a second syntax check. `aro check` and the functional benchmark already
  ran; if the toolchain disagrees with the rater, the note says so and that is
  a finding about the toolchain.

## Reading the result

`score` reports each axis as a rate with a Wilson 95 % interval, because a
hundred rows carries about a ten-point half-width near 50 % — enough to see a
large change between releases and not enough to see a small one. It refuses to
report a rate on fewer than `MIN_PROMPTS_PER_TASK` rated rows, and it prints
the comparison against a previous sheet when given one.
