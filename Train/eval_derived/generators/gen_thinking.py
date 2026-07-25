#!/usr/bin/env python3
"""Reasoning-augmented ("thinking") training pairs.

For each validated ARO answer, synthesize a <think> trace that models the
reasoning process we want the model to internalise BEFORE it generates code:
  1. understand the user's request
  2. rephrase it in ARO terms (a feature set + business activity)
  3. plan the statements, naming each verb's role
  4. explicitly recall the ARO rules the 4,000-prompt eval showed it breaks
     (immutability -> fresh names; correct preposition per verb; only built-in
     verbs; end with Return/Throw)
Output = "<think>...</think>\n\n```aro\n<answer>\n```". Answers are re-validated
with aro check so a bad trace never ships a bad program.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/Users/kris/Projects/ARO/ARO-Lang/Train/script")
import config  # noqa: E402

OUT = HERE / "thinking.jsonl"
SOURCES = [
    HERE / "gapfill.jsonl",
    Path("/Users/kris/Projects/ARO/ARO-Lang/Train/eval_derived/eval_feedback_pairs.jsonl"),
    HERE / "codegen.jsonl",
    HERE / "errorfix.jsonl",
]

ROLE = {}
for v in ["Extract", "Retrieve", "Read", "Request", "Parse", "Pull", "Clone", "Fetch", "Probe"]:
    ROLE[v] = ("REQUEST", "brings external data in")
for v in ["Compute", "Validate", "Compare", "Create", "Transform", "Accept", "Filter",
          "Group", "Stage", "Checkout", "Update", "Split", "Merge", "Reduce", "Render", "Format"]:
    ROLE[v] = ("OWN", "works on data we already hold")
for v in ["Return", "Throw"]:
    ROLE[v] = ("RESPONSE", "sends a result back out")
for v in ["Log", "Store", "Emit", "Publish", "Send", "Commit", "Push", "Tag", "Broadcast", "Delete"]:
    ROLE[v] = ("EXPORT", "exports data or makes it visible")

PREP = {"Log": "to", "Retrieve": "from", "Store": "into", "Extract": "from",
        "Emit": "with", "Return": "with", "Commit": "with", "Push": "to",
        "Pull": "from", "Read": "from", "Write": "to", "Send": "to",
        "Request": "from", "Publish": "as", "Throw": "with", "Filter": "from",
        "Group": "from", "Accept": "for", "Update": "with", "Configure": "with",
        "Validate": "with", "Render": "from", "Stage": "to", "Delete": "from"}


def parse(code):
    m = re.match(r"\(([^():\n]+):\s*([^()\n]+)\)", code.strip())
    name, activity = (m.group(1).strip(), m.group(2).strip()) if m else ("Handler", "Feature")
    stmts = []
    body = re.sub(r"\(\*.*?\*\)", "", code, flags=re.DOTALL)
    for line in body.split("\n"):
        s = line.strip()
        mm = re.match(r"([A-Z][a-zA-Z.]+)\s+(.*)", s)
        if mm and not s.startswith("("):
            stmts.append((mm.group(1), s))
    return name, activity, stmts


def make_think(instruction, code):
    name, activity, stmts = parse(code)
    verbs = [v for v, _ in stmts]
    lines = []
    lines.append(f"The user is asking: {instruction.rstrip('.')}. Let me work out the ARO.")
    lines.append(f"In ARO this is one feature set. A good header is ({name}: {activity}) — "
                 f"the part after the colon is the business activity that decides what triggers it.")
    lines.append("Now the statements, in order:")
    seen_names = set()
    for v, s in stmts:
        role, desc = ROLE.get(v, ("OWN", "processes data"))
        note = f"  - `{v}` — a {role} action ({desc})."
        if v in PREP:
            note += f" It takes the preposition `{PREP[v]}`."
        # immutability note when a new <result> is bound
        rm = re.search(r"<([a-z][a-zA-Z0-9-]*)", s)
        if rm and v not in ("Return", "Throw", "Log"):
            nm = rm.group(1)
            if nm in seen_names:
                note += f" ⚠ `{nm}` is already bound — ARO variables are immutable, so I must use a new name."
            seen_names.add(nm)
        lines.append(note)
    end = "Throw" if verbs and verbs[-1] == "Throw" else "Return"
    lines.append(f"Every feature set must end with a Return or Throw — here it ends with {end}. Good.")
    lines.append("Rules I'm keeping straight: every variable/object is angle-bracketed; each result "
                 "gets a fresh name (immutability); I only use built-in verbs (no invented actions "
                 "like Save/Get/Set); and every statement ends with a period.")
    return "\n".join(lines)


def main(limit_per_source=2000):
    n, seen = 0, set()
    with open(OUT, "w") as f:
        for src in SOURCES:
            if not src.exists():
                continue
            cnt = 0
            for line in src.read_text().splitlines():
                if cnt >= limit_per_source:
                    break
                if not line.strip():
                    continue
                rec = json.loads(line)
                blocks = config.extract_aro_blocks(rec.get("output", ""))
                if not blocks:
                    continue
                code = blocks[0].strip()
                if "{" not in code or "(" not in code:
                    continue
                key = re.sub(r"\s+", " ", code)
                if key in seen:
                    continue
                # re-validate the answer
                ok, _ = config.aro_check_snippet(code, timeout=15)
                if not ok:
                    continue
                seen.add(key)
                think = make_think(rec["instruction"], code)
                f.write(json.dumps({
                    "instruction": rec["instruction"],
                    "output": f"<think>\n{think}\n</think>\n\n```aro\n{code}\n```",
                    "category": "reasoning",
                    "task_type": "code_generation",
                    "source": "eval_thinking",
                }) + "\n")
                n += 1
                cnt += 1
    print(f"thinking pairs: {n}")


if __name__ == "__main__":
    main()
