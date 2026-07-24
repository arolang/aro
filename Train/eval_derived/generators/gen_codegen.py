#!/usr/bin/env python3
"""code_generation pairs from the validated base pool. Output is a program that
already passes `aro check`; the instruction is derived from the feature-set
business activity + the verbs used. Two instruction phrasings per base."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
POOL = json.loads((HERE / "base_pool.json").read_text())
OUT = HERE / "codegen.jsonl"

VERB_PHRASE = {
    "Extract": "extracts a value", "Retrieve": "retrieves data from a repository",
    "Store": "stores an item in a repository", "Compute": "computes a value",
    "Log": "logs to the console", "Emit": "emits an event", "Create": "creates an object",
    "Filter": "filters a collection", "Render": "renders a template",
    "Commit": "commits to git", "Stage": "stages files", "Push": "pushes to a remote",
    "Pull": "pulls from a remote", "Checkout": "checks out a branch", "Tag": "tags a release",
    "Read": "reads a file", "Write": "writes a file", "Send": "sends a message",
    "Request": "makes an HTTP request", "Accept": "accepts a state transition",
    "Validate": "validates input", "Compare": "compares values", "Group": "groups a collection",
    "Split": "splits a string", "Transform": "transforms data", "Merge": "merges collections",
    "Reduce": "reduces a collection", "List": "lists items", "Configure": "configures the runtime",
    "Publish": "publishes a variable", "Keepalive": "keeps the application alive",
    "Start": "starts a service", "Stop": "stops a service", "Parse": "parses input",
    "Make": "creates a directory", "Broadcast": "broadcasts a message", "Call": "calls a service",
    "Format": "formats a value", "Throw": "throws an error",
}
SKIP = {"Return", "Given", "When", "Then", "For", "Application."}


def header_of(code):
    m = re.match(r"\(([^():\n]+):\s*([^()\n]+)\)", code.strip())
    return (m.group(1).strip(), m.group(2).strip()) if m else ("", "")


def verbs_of(code):
    body = re.sub(r"\(\*.*?\*\)", "", code, flags=re.DOTALL)
    seen = []
    for m in re.finditer(r"^\s*([A-Z][a-zA-Z]+)\s", body, re.M):
        v = m.group(1)
        if v not in SKIP and v not in seen and v in VERB_PHRASE:
            seen.append(v)
    return seen


def instr_from_verbs(verbs):
    ph = [VERB_PHRASE[v] for v in verbs[:4]]
    if not ph:
        return None
    if len(ph) == 1:
        joined = ph[0]
    else:
        joined = ", ".join(ph[:-1]) + " and " + ph[-1]
    return f"Write an ARO feature set that {joined}."


def main():
    n, seen = 0, set()
    with open(OUT, "w") as f:
        for item in POOL:
            code = item["code"]
            name, activity = header_of(code)
            verbs = verbs_of(code)
            instrs = []
            vi = instr_from_verbs(verbs)
            if vi:
                instrs.append(vi)
            if activity and activity not in ("Example", "Demo"):
                instrs.append(f"Write an ARO feature set for {activity.lower()}.")
            phrasings = []
            for ins in instrs:
                phrasings.append(ins)
                phrasings.append("Show me an ARO example: " + ins[0].lower() + ins[1:])
                phrasings.append(ins.replace("Write an ARO feature set", "Give me idiomatic ARO that", 1))
            for ins in phrasings:
                key = ins + "||" + code[:40]
                if key in seen:
                    continue
                seen.add(key)
                f.write(json.dumps({
                    "instruction": ins,
                    "output": f"```aro\n{code}\n```",
                    "category": "code_generation",
                    "task_type": "code_generation",
                    "source": "eval_gen_codegen",
                }) + "\n")
                n += 1
    print(f"code_generation pairs: {n}")


if __name__ == "__main__":
    main()
