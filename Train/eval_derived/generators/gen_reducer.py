#!/usr/bin/env python3
"""Reduce-action coverage: qualifier-as-name reducers + the `with sum()` fix.

Prompted by a real `aro ask` miss — it suggested
`Reduce the <sum> from the <numbers> with sum.`, which fails aro check (a bare
`with sum` needs `sum()`; the concise form is the qualifier-as-name reducer
`Reduce the <total: sum> from the <numbers>.`). This generator teaches both the
qualifier-as-name reducers (sum/avg/min/max/count — each verified to *run*, not
just parse) and an error→fix pair for the exact mistake. Every code answer is
re-validated with `aro check`; the error→fix pair is gated so the broken form
genuinely fails and the fix passes.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "reducer.jsonl"

ENTS = ["order", "invoice", "payment", "product", "account", "ticket", "review",
        "shipment", "task", "score", "reading", "transaction", "sample", "metric"]


def cap(s):
    return s[0].upper() + s[1:]


# qualifier-as-name reducer: `Reduce the <name: reducer> from the <collection>.`
def qual_reducer(e, red, resultname):
    return (f"(Reduce{cap(e)}{red.capitalize()}: {cap(e)} API) {{\n"
            f"    Retrieve the <{e}-values> from the <{e}-repository>.\n"
            f"    Reduce the <{resultname}: {red}> from the <{e}-values>.\n"
            f"    Return an <OK: status> with <{resultname}>.\n"
            f"}}")


def count_call(e):
    # the call form with `with count()`
    return (f"(Count{cap(e)}s: {cap(e)} API) {{\n"
            f"    Retrieve the <{e}s> from the <{e}-repository>.\n"
            f"    Reduce the <total: Integer> from the <{e}s> with count().\n"
            f"    Return an <OK: status> with <total>.\n"
            f"}}")


# reducer key → (result name, instruction phrasings)
REDUCERS = {
    "sum": ("total", ["Write an ARO feature set that sums the {e} values with Reduce.",
                      "How do I sum a list of {e} values in ARO?"]),
    "avg": ("average", ["Write an ARO feature set that averages the {e} values with Reduce.",
                        "How do I compute the average of {e} values in ARO?"]),
    "min": ("smallest", ["Write an ARO feature set that finds the smallest {e} value with Reduce.",
                        "How do I get the minimum {e} value in ARO?"]),
    "max": ("largest", ["Write an ARO feature set that finds the largest {e} value with Reduce.",
                       "How do I get the maximum {e} value in ARO?"]),
}

# Self-contained "sum a variable amount of numbers" — the exact aro-ask miss.
# Verified to run → 15.
SUM_FIXED = ("(SumNumbers: Demo) {\n"
             "    Create the <numbers> with [1, 2, 3, 4, 5].\n"
             "    Reduce the <sum: sum> from the <numbers>.\n"
             "    Return an <OK: status> with <sum>.\n"
             "}")
SUM_BROKEN = SUM_FIXED.replace("Reduce the <sum: sum> from the <numbers>.",
                               "Reduce the <sum> from the <numbers> with sum.")


def main():
    rows, seen = [], set()
    checked = passed = 0
    aro_missing = False

    def emit_code(instr, answer, key):
        nonlocal passed
        rows.append({
            "instruction": instr, "output": f"```aro\n{answer}\n```",
            "category": "code_generation", "task_type": "code_generation",
            "verb_domain": f"reduce_{key}", "source": "eval_reducer",
        })

    for red, (resultname, phrasings) in REDUCERS.items():
        for i, e in enumerate(ENTS):
            answer = qual_reducer(e, red, resultname)
            checked += 1
            ok, err = config.aro_check_snippet(answer, timeout=15)
            if ok is None:
                aro_missing = True
                continue
            if not ok:
                line = err.splitlines()[1].strip()[:60] if err and len(err.splitlines()) > 1 else str(err)[:60]
                print(f"  SKIP reduce_{red}/{e}: {line}")
                continue
            passed += 1
            for tmpl in phrasings:
                ins = tmpl.replace("{e}", e)
                if ins in seen:
                    continue
                seen.add(ins)
                emit_code(ins, answer, red)

    # count() call form
    for e in ENTS:
        answer = count_call(e)
        checked += 1
        ok, _ = config.aro_check_snippet(answer, timeout=15)
        if ok:
            passed += 1
            ins = f"How do I count a collection of {e}s in ARO with Reduce?"
            if ins not in seen:
                seen.add(ins)
                emit_code(ins, answer, "count")

    # "sum a variable amount of numbers" + the error→fix pair
    _ok_fixed, _ = config.aro_check_snippet(SUM_FIXED, timeout=15)
    _ok_broken, _ = config.aro_check_snippet(SUM_BROKEN, timeout=15)
    if _ok_fixed and _ok_broken is False:
        for ins in ["How do I sum a variable amount of numbers in ARO?",
                    "How do I add up a list of numbers in ARO?",
                    "Sum a list of numbers in ARO and return the total."]:
            emit_code(ins, SUM_FIXED, "sum")
        rows.append({
            "instruction": "Fix this ARO — the reducer syntax is wrong:\n"
                           f"```aro\n{SUM_BROKEN}\n```",
            "output": "The reducer can't be a bare `with sum`. Use the concise "
                      "qualifier-as-name form `Reduce the <sum: sum> from the <numbers>.` "
                      "(or the call form `with sum()`).\n\n"
                      f"```aro\n{SUM_FIXED}\n```",
            "category": "correction", "task_type": "correction",
            "error_class": "reducer_missing_parens", "verb_domain": "reduce_sum",
            "source": "eval_reducer",
        })
    else:
        print(f"  WARN reducer extras skipped (fixed_ok={_ok_fixed}, broken_ok={_ok_broken})")

    OUT.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate.")
    print(f"reducer: checked {checked}, aro-check-passed {passed} -> {len(rows)} pairs -> {OUT.name}")


if __name__ == "__main__":
    main()
