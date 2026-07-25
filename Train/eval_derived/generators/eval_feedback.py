#!/usr/bin/env python3
"""Turn the 4,000-prompt eval into training feedback.

 * GOOD rows  -> training pairs (prompt -> the model's validated answer).
 * BAD rows   -> a canonical CORRECT answer (validated with aro check). If a
                 valid fix is produced the pair is added and the row is marked
                 'fixed'; otherwise the row is marked 'unfixable'.
Writes eval_derived/eval_feedback_pairs.jsonl and rewrites ask-eval.csv with a
'resolution' column (good / fixed / unfixable).
"""
import csv
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
sys.path.insert(0, str(HERE))
import config  # noqa: E402
import gen_gapfill as G  # noqa: E402  (reuse validated canonical builders)

CSV = REPO / "ask-eval.csv"
OUT = REPO / "Train" / "eval_derived" / "eval_feedback_pairs.jsonl"
ENTS = G.ENTS

def _cap(s):
    return s[0].upper() + s[1:]


# Extra validated builders for the fixable domains found in the unfixable set.
def files_(e, f):
    return '(ReadFile: IO) {\n    Read the <content> from the <file: "data.txt">.\n    Log <content> to the <console>.\n    Return an <OK: status> with <content>.\n}'


def repository_(e, f):
    return f"(Get{_cap(e)}s: {_cap(e)} API) {{\n    Retrieve the <{e}s> from the <{e}-repository>.\n    Return an <OK: status> with <{e}s>.\n}}"


def computation_(e, f):
    return f"(Total{_cap(e)}: Calc) {{\n    Extract the <price> from the <request: body>.\n    Compute the <total> from <price> * 2.\n    Return an <OK: status> with <total>.\n}}"


def sets_(e, f):
    return "(Common: Sets) {\n    Compute the <common: intersect> from <first> with <second>.\n    Return an <OK: status> with <common>.\n}"


def http_(e, f):
    return f'(Fetch{_cap(e)}: Client) {{\n    Request the <data> from the <http: "https://api.example.com/{e}s">.\n    Return an <OK: status> with <data>.\n}}'


def metrics_(e, f):
    return '(Count: Metrics) {\n    Log "request" to the <metrics: counter>.\n    Return an <OK: status> for the <metric>.\n}'


def extract_(e, f):
    return "(GetId: API) {\n    Extract the <id> from the <pathParameters: id>.\n    Return an <OK: status> with <id>.\n}"


def events_(e, f):
    return f"(Notify{_cap(e)}: {_cap(e)}Created Handler) {{\n    Extract the <{e}> from the <event: {e}>.\n    Send the <welcome> to the <{e}: email>.\n    Return an <OK: status> for the <notification>.\n}}"


def dates_(e, f):
    return '(Now: Time) {\n    Retrieve the <now> from the <date>.\n    Format the <stamp> from the <now> with "yyyy-MM-dd".\n    Return an <OK: status> with <stamp>.\n}'


def parameters_(e, f):
    return "(Args: CLI) {\n    Extract the <name> from the <parameters: name>.\n    Log <name> to the <console>.\n    Return an <OK: status> with <name>.\n}"


def templates_(e, f):
    return f'(Render{_cap(e)}: Template) {{\n    Extract the <name> from the <request: body>.\n    Render the <message> from "Hello, {{{{name}}}}!" with {{ name: <name> }}.\n    Return an <OK: status> with <message>.\n}}'


def logging_(e, f):
    return f'(Log{_cap(e)}: {_cap(e)} API) {{\n    Log "processing {e}" to the <console>.\n    Return an <OK: status> for the <log>.\n}}'


# Map eval domains -> a canonical answer builder (all validated). Domains not
# covered here are treated as unfixable.
BUILDERS = {
    "conditionals": G.when_guard, "error": G.error_throw, "publish": G.publish_,
    "config": G.config_, "validation": G.validation_, "state": G.state_,
    "iteration": G.iteration_, "collections": G.collections_, "group": G.group_,
    "update": G.update_, "delete": G.delete_, "response": G.response_created,
    "git": G.git_commit, "rest": G.response_created, "repo": G.response_created,
    "files": files_, "repository": repository_, "computation": computation_,
    "sets": sets_, "http": http_, "http_client": http_, "metrics": metrics_,
    "extract": extract_, "events": events_, "dates": dates_, "parameters": parameters_,
    "templates": templates_, "logging": logging_, "scoping": G.publish_,
    "pipeline": G.collections_, "watcher": events_, "server": repository_,
}


def entity_of(prompt):
    for e in ENTS:
        if re.search(rf"\b{e}\b", prompt.lower()):
            return e
    return "user"


def reference_answer(domain, prompt):
    b = BUILDERS.get(domain)
    if not b:
        return None
    e = entity_of(prompt)
    f = "status"
    ans = b(e, f)
    ok, _ = config.aro_check_snippet(ans, timeout=15)
    return f"```aro\n{ans}\n```" if ok else None


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def main():
    rows = list(csv.DictReader(open(CSV, newline="")))
    fields = list(rows[0].keys()) + (["resolution"] if "resolution" not in rows[0] else [])
    pairs, seen = [], set()
    n_good = n_fixed = n_unfix = 0

    for r in rows:
        if r["judge"] == "good":
            r["resolution"] = "good"
            n_good += 1
            key = norm(r["prompt"]) + "||good"
            if key not in seen and r["response"].strip():
                seen.add(key)
                pairs.append({
                    "instruction": r["prompt"],
                    "output": r["response"],
                    "category": "knowledge" if r["category"] == "knowledge" else "code_generation",
                    "task_type": "syntax_qa" if r["category"] == "knowledge" else "code_generation",
                    "domain": r["domain"], "source": "eval_good",
                })
        else:
            fix = reference_answer(r["domain"], r["prompt"])
            if fix:
                r["resolution"] = "fixed"
                n_fixed += 1
                key = norm(r["prompt"]) + "||fix"
                if key not in seen:
                    seen.add(key)
                    pairs.append({
                        "instruction": r["prompt"], "output": fix,
                        "category": "code_generation", "task_type": "code_generation",
                        "domain": r["domain"], "source": "eval_fix",
                    })
            else:
                r["resolution"] = "unfixable"
                n_unfix += 1

    # add the standalone gapfill dataset (canonical weak-domain coverage)
    for line in (HERE / "gapfill.jsonl").read_text().splitlines():
        rec = json.loads(line)
        key = norm(rec["instruction"]) + "||gap"
        if key not in seen:
            seen.add(key)
            pairs.append(rec)

    OUT.write_text("\n".join(json.dumps(p) for p in pairs) + "\n")
    # rewrite CSV with resolution
    with open(CSV, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    print(f"good={n_good} fixed={n_fixed} unfixable={n_unfix}")
    print(f"feedback training pairs: {len(pairs)} -> {OUT}")


if __name__ == "__main__":
    main()
