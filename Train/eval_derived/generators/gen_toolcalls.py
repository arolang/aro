#!/usr/bin/env python3
"""tool_calling pairs teaching the correct JSON tool-call protocol (directly
counters the disguised-bash-block failure). Output is the assistant emitting a
`<tool_call>{...}</tool_call>` — never a shell command or code fence."""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "toolcalls.jsonl"

# (user request template, tool name, arguments dict)
CASES = [
    ("Check the syntax of the ARO app at {p}.", "aro_check", {"path": "{p}"}),
    ("Run `aro check` on {p}.", "aro_check", {"path": "{p}"}),
    ("Validate the ARO code in {p}.", "aro_check", {"path": "{p}"}),
    ("Read the file {p}.", "read_file", {"path": "{p}"}),
    ("Show me the contents of {p}.", "read_file", {"path": "{p}"}),
    ("Open {p} and show it to me.", "read_file", {"path": "{p}"}),
    ("Run the ARO application at {p}.", "aro_run", {"path": "{p}"}),
    ("Execute the app in {p}.", "aro_run", {"path": "{p}"}),
    ("List the files in {p}.", "list_dir", {"path": "{p}"}),
    ("What files are in {p}?", "list_dir", {"path": "{p}"}),
    ("Search for 'Retrieve' across {p}.", "grep", {"pattern": "Retrieve", "path": "{p}"}),
    ("Find every 'Emit' statement in {p}.", "grep", {"pattern": "Emit", "path": "{p}"}),
    ("Build a native binary from {p}.", "aro_build", {"path": "{p}"}),
    ("Compile {p} to a binary.", "aro_build", {"path": "{p}"}),
    ("Run the tests in {p}.", "aro_test", {"path": "{p}"}),
    ("Parse the AST of {p}.", "parse_aro", {"path": "{p}"}),
    ("Generate docs for {p}.", "generate_docs", {"path": "{p}"}),
    ("List all built-in and plugin actions.", "list_actions", {}),
    ("List the ARO language proposals.", "list_proposals", {}),
]

PATHS = ["./MyApp", "main.aro", "./UserService", "sources/users.aro", "./OrderService",
         "./HTTPServer", "app/main.aro", "./Calculator", "./FileWatcher", "./GitDemo",
         "./Chat", "orders.aro", "./Inventory", "sources/api/users.aro", "./Metrics"]


def main():
    n, seen = 0, set()
    with open(OUT, "w") as f:
        for i, (utmpl, tool, args) in enumerate(CASES):
            for p in PATHS:
                user = utmpl.format(p=p)
                filled = {k: (v.format(p=p) if isinstance(v, str) else v) for k, v in args.items()}
                call = json.dumps({"name": tool, "arguments": filled})
                out = f"<tool_call>{call}</tool_call>"
                key = user
                if key in seen:
                    continue
                seen.add(key)
                f.write(json.dumps({
                    "instruction": user,
                    "output": out,
                    "category": "tool_calling",
                    "task_type": "tool_calling",
                    "source": "eval_gen_toolcalls",
                }) + "\n")
                n += 1
                if "{p}" not in utmpl:  # no-arg case: only once
                    break
    print(f"tool_calling pairs: {n}")


if __name__ == "__main__":
    main()
