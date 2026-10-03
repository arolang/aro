# The held-out benchmark

**301 prompts that have never been trained on, and a mechanism that keeps it
that way.** GitLab #785.

## Why this exists

Two numbers were being quoted about `aro-coder`. Neither was a measurement.

The release gate's **75.5 % syntax pass** came from `Train/eval_prompts.json`,
whose 105 prompts share templates with the curated material in
`Train/Material/`. The **67 % evaluation** came from a 4,000-prompt `aro ask`
run that was then folded back into training: `Train/eval_derived/README.md`
records 2,679 good answers promoted to `code_generation` pairs and 1,160
repaired bad answers promoted to feedback pairs — 8,536 rows in
`ask_eval_pairs.jsonl`. The post-release probe set has paraphrased answers in
`probefill.jsonl` *by design*; that file says so, and says it is deliberate.

`leakage.py`'s existing check could not see any of this, because it compares a
holdout against the training set **inside one assembled dataset**. A prompt
reserved from `ask_eval_pairs.jsonl` is held out from the split while five
thousand of its siblings — same templates, same entities, paraphrased answers —
stay in train, and the check reports no leakage.

So there was no untouched benchmark, and the project could not tell whether the
model had learned ARO or memorised the prompts it would be graded on. The
"82 % syntax-valid" figure from an earlier session cannot be compared to either
number for the same reason.

## Composition

| stratum | n | what the answer is | graded by |
|---|---:|---|---|
| `nl_application` | 55 | a complete application; 38 of them an `openapi.yaml` **and** the handlers named after its operationIds | `aro check` on the directory; 16 runnable ones also by `aro run` |
| `repl` | 56 | a statement, or a few, with no feature set | `aro check --syntax`, **and** `aro run` after the harness wraps them in an entry point |
| `repair` | 55 | the fix for a broken program, given the diagnostic the toolchain actually printed | `aro check`; 49 of them also by `aro run` |
| `explain` | 55 | prose | a rubric: every `must_include` phrase present, no `must_not_include` phrase |
| `tests` | 45 | the ARO-0015 Given/When/Then test file | `aro test` must pass |
| `plugin` | 35 | 20 ARO call sites, 15 manifests / host-language surfaces | `aro check` and the rubric respectively |

Every prompt also carries a `domain`, and the five weak domains the
4,000-prompt run measured (GitLab #797 — conditionals 0 %, `Throw` 2 %,
`publish` 3 %, configuration 7 %, REST 19 %) are deliberately over-weighted:
28 conditionals, 46 REST, 13 configuration, 9 publish, 6 Throw. The point of a
benchmark is to measure where the model is bad, not where the corpus is thick.

Subject matter is deliberately away from the corpus's users / orders /
products: canal locks, kiln firings, bell towers, silage clamps, seed banks,
ferry berths, glacier stakes. Not for flavour — shared vocabulary is what
drives character-3-gram similarity, and similarity is the gate these prompts
have to clear.

## It is never mined

Mechanically, in four places, because a promise in a README is not a property
of a repository — which is the whole lesson of #785:

1. **A marker file.** This directory contains `.never-mine`.
   `leakage.corpus_files()` — the single enumerator every leakage check and
   every benchmark test goes through — skips any directory containing it.
2. **A naming convention.** `prompts.benchmark.json` carries `.benchmark.` in
   its name, and `corpus_files()` excludes that wherever the file sits, so a
   copy taken *out* of this directory is still excluded.
3. **A raiser.** `leakage.assert_mineable(paths)` raises on a never-mined path,
   for pipeline code that names its inputs by hand and so goes through neither
   of the above.
4. **A test.** `Train/script/tests/test_held_out_benchmark.py` fails if any
   prompt here reaches character-3-gram Jaccard 0.85 against any instruction
   in any corpus file — and it also plants a prompt lifted out of the corpus to
   prove the gate can still refuse.

## Measured leakage

Against **23,931 instructions in 424 corpus files** — every `.jsonl`, `.json`
and `.txt` under `Train/` that could be trained on, the eval-derived set and
the material set included:

```
exact collisions   : 0
near duplicates    : 0   (character 3-gram Jaccard >= 0.85)
highest similarity : 0.5923   [repair-001 vs eval_derived/generators/errorfix.jsonl]
```

The 0.59 is the *exhaustive* figure: every benchmark prompt against every
corpus instruction with no filtering. The fast path used by CI is a prefix
filter that is exact at the threshold and misses nothing at or above it.

Three prompts were rewritten during authoring because the audit showed them
asking a question the corpus already answers, even though none of the three
breached the threshold — 0.708, 0.617 and 0.524. A threshold is a floor, not a
definition of novelty.

## Does it ship reference answers?

Yes, and the argument against is real: a correct answer sitting in the
repository is exactly what got mined last time.

It ships them anyway because a benchmark whose own references do not pass is
measuring the benchmark rather than the model, and `--reference` is the only
way to find a task whose expected output was wrong when it was written. All
301 pass. Scoring never reads them — `aro check`, `aro run` and `aro test` are
the judges — so they are documentation of satisfiability, not a scoring key,
and the exclusion that protects the prompts protects them identically.

A contract-first task's `openapi.yaml` lives under `reference_files`, which
only `--reference` reads, rather than under `files`, which the grader puts in
the directory. Producing the contract is the task; handing it over would be
handing over half the answer.

## Running it

```bash
# the freeze, the structure, and the leakage gate — no binary needed
python3 Train/script/held_out_benchmark.py --verify

# prove the reporting with no model and no binary
python3 Train/script/held_out_benchmark.py --stub

# grade the checked-in references — verifies the benchmark itself
ARO_BIN=.build/debug/aro python3 Train/script/held_out_benchmark.py --reference

# grade a model: one JSONL row per sample, {"id": …, "output": …}
python3 Train/script/held_out_benchmark.py --generations runs/candidate.jsonl \
        --samples 5 --json report.json --rows rows.jsonl

# leakage on its own, and the slow exhaustive audit
python3 Train/script/leakage.py --list-corpus
python3 Train/script/leakage.py --exhaustive --verbose
```

The harness takes generated answers as a **file** rather than calling a model,
so it scores whatever produced them — a notebook, a different model, a human —
and so the arithmetic can be proved with no model at all.

## What it reports

Per stratum, per domain and overall:

* **`aro check` pass@1 and pass@5** — the axis the 75.5 % measured, kept so the
  two are comparable. pass@5 is reported as `-`, not as a smaller number, when
  fewer than five samples were generated: pass@5 off a greedy decode is not a
  pass@5.
* **execution pass by `aro run`** — the program ran and printed what was asked.
  This is the axis that catches "parses, runs, computes the wrong thing", the
  dominant failure in the run this replaces and one `aro check` cannot see.
* **`aro test` pass** — Given/When/Then assertions over values rather than
  printing. The strongest grade here.
* **the rubric** for the prose answers.

A generation nothing could judge — no binary — is counted as `unreachable` and
kept out of both the numerator and the denominator. NB21 counted a missing
binary as a pass; that is the shape of mistake this issue is about.

## Changing it

Don't, casually. `MANIFEST.json` records the sha256 of `prompts.benchmark.json`
and `held_out_benchmark.verify_frozen()` compares it, so an edit without a
version bump fails a test rather than silently moving the ruler mid-measurement
— which is how 75.5 % and 67 % came to be quoted side by side.

`authoring/` holds the six stratum modules and `build.py`, which reassembles
the JSON. The repair prompts carry diagnostics captured from the binary, so a
rebuild against a different `aro` can change them; `build.py` refuses to write
a different digest unless you pass `--version <next>`, and `MANIFEST.json`
records which binary built the prompts.

## Known limits

* **The `tests` stratum is inverted.** The answer is the test file and the
  application is checked in, rather than the other way round. ARO-0015 §2.2's
  `When the <result> from the <feature-set>.` does not execute in this runtime
  ("Cannot when the … from the …"), and an `Application.<Name>` call inside a
  test feature set binds the argument rather than the call's result — so a
  checked-in test cannot reach a generated application's code. Both measured
  against the binary this was frozen on.
* **Contract-first rows are parse-graded only.** A server has no completion to
  observe, so there is no execution axis for them without standing up a client.
* **The rubric is lexical.** It catches the confident wrong answer and it will
  occasionally mark down an unusual phrasing. It needs no judge model and it is
  reproducible, which is the trade that was taken.
* **`aro check --syntax` accepts an unterminated statement.** `Grab the <x>
  from the <nowhere>` passes; the same line with a period is correctly
  rejected as an invented verb. That is one reason the repl stratum is graded
  on execution as well as on parsing.
