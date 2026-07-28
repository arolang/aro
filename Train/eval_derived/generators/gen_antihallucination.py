#!/usr/bin/env python3
"""Anti-hallucination training data (issue #436).

For each validated base program, build a variant whose canonical action verb is
replaced by a GENUINELY invalid verb (not in the authoritative ActionRegistry
set, aro_action_verbs.json). Emits:
  * error→fix pairs  — "this uses a non-existent action, fix it" → correct code
  * DPO pairs         — {prompt, chosen=correct, rejected=invalid-verb version}
Both teach the model to use only real ARO verbs. Every `chosen` passes aro check
and uses only authoritative verbs; every `rejected` contains ≥1 invalid verb.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
sys.path.insert(0, str(HERE))
import config  # noqa: E402

AUTH = config.authoritative_action_verbs()
POOL = json.loads((HERE / "base_pool.json").read_text())
OUT_FIX = REPO / "Train" / "eval_derived" / "antihallucination.jsonl"
OUT_DPO = REPO / "Train" / "eval_derived" / "antihallucination_dpo.jsonl"

# canonical verb -> a plausible but NON-EXISTENT verb an LLM might hallucinate
INVALID = {
    "Store": "Stash", "Retrieve": "Grab", "Create": "Spawn", "Send": "Transmit",
    "Log": "Echo", "Update": "Mutate", "Delete": "Purge", "Filter": "Sieve",
    "Extract": "Yank", "Emit": "Broadcast2", "Compute": "Crunch", "Return": "Reply",
    "Read": "Slurp", "Write": "Dump", "Retrieve2": "Lookup", "Publish": "Announce",
}
INVALID = {k: v for k, v in INVALID.items() if v.lower() not in AUTH}  # keep only truly-invalid

INSTR = [
    "This ARO code uses an action that doesn't exist. Fix it to use a real ARO verb:\n```aro\n{bad}\n```",
    "`{verb}` is not a valid ARO action. Correct this feature set:\n```aro\n{bad}\n```",
    "Fix the hallucinated action in this ARO code:\n```aro\n{bad}\n```",
]
PROMPTS = [
    "Write this ARO feature set correctly, using only real ARO actions.",
    "Give me the ARO for this feature set with valid action verbs only.",
]


def verbs_in(code):
    body = re.sub(r"\(\*.*?\*\)", "", code, flags=re.DOTALL)
    return re.findall(r"^\s*([A-Z][a-zA-Z]+)\b", body, re.M)


def main():
    fixes, dpo, seen = [], [], set()
    for item in POOL:
        code = item["code"].strip()
        vs = verbs_in(code)
        # only use bases whose verbs are all authoritative (clean 'chosen')
        if not vs or any(v.lower() not in AUTH for v in vs if v not in ("Given", "Then", "When", "For")):
            continue
        # find a canonical verb we have an invalid synonym for
        target = next((v for v in vs if v in INVALID), None)
        if not target:
            continue
        bad = re.sub(rf"^(\s*){target}(\s)", rf"\g<1>{INVALID[target]}\g<2>", code, count=1, flags=re.M)
        if bad == code:
            continue
        # validate: correct passes aro check; bad has an invalid verb
        ok, _ = config.aro_check_snippet(code, timeout=15)
        if not ok:
            continue
        if not any(v.lower() not in AUTH for v in verbs_in(bad)):
            continue
        key = re.sub(r"\s+", " ", bad)
        if key in seen:
            continue
        seen.add(key)
        tmpl = INSTR[len(fixes) % len(INSTR)]
        fixes.append({
            "instruction": tmpl.format(bad=bad, verb=INVALID[target]),
            "output": f"```aro\n{code}\n```",
            "category": "correction", "task_type": "correction",
            "error_class": f"hallucinated_verb_{INVALID[target]}", "source": "eval_antihallucination",
        })
        dpo.append({
            "prompt": PROMPTS[len(dpo) % len(PROMPTS)] + f"\n\nContext:\n```aro\n{code.splitlines()[0]} ...\n```",
            "chosen": f"```aro\n{code}\n```",
            "rejected": f"```aro\n{bad}\n```",
            "source": "eval_antihallucination_dpo",
        })
    OUT_FIX.write_text("\n".join(json.dumps(x) for x in fixes) + "\n")
    OUT_DPO.write_text("\n".join(json.dumps(x) for x in dpo) + "\n")
    print(f"invalid-verb map (kept): {INVALID}")
    print(f"anti-hallucination error→fix pairs: {len(fixes)} -> {OUT_FIX.name}")
    print(f"anti-hallucination DPO pairs:       {len(dpo)} -> {OUT_DPO.name}")


if __name__ == "__main__":
    main()
