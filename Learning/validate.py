#!/usr/bin/env python3
"""Validate the Learning notebooks against a real ARO REPL session.

Every code cell of every ``.repl`` file is executed, in order, through
``aro repl --json`` (ARO-0091) — one fresh session per notebook, the
same way a kernel runs it. A cell must answer ``status: ok`` unless its
source carries the marker ``(* expect-error *)``, in which case it must
answer ``status: error`` (used by the immutability notebook to show a
failure without shipping a broken curriculum).

Usage:
    python3 Learning/validate.py [notebook.repl ...]
    ARO_BIN=/path/to/aro python3 Learning/validate.py

With no arguments, validates every ``*.repl`` next to this script.
Exits non-zero when any cell misbehaves.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

EXPECT_ERROR_MARKER = "(* expect-error *)"


def aro_binary() -> str:
    if os.environ.get("ARO_BIN"):
        return os.environ["ARO_BIN"]
    return "aro"


def run_notebook(path: Path) -> list[str]:
    """Return a list of failure descriptions (empty = notebook passes)."""
    document = json.loads(path.read_text())
    if document.get("version") != 1:
        return [f"{path.name}: unsupported version {document.get('version')}"]

    code_cells = [
        (index, cell)
        for index, cell in enumerate(document.get("cells", []), start=1)
        if cell.get("kind") == "code"
    ]
    if not code_cells:
        return []

    requests = []
    for request_id, (_, cell) in enumerate(code_cells, start=1):
        requests.append(json.dumps(
            {"id": request_id, "type": "execute", "code": cell.get("source", "")}))
    requests.append(json.dumps({"id": len(code_cells) + 1, "type": "shutdown"}))

    proc = subprocess.run(
        [aro_binary(), "repl", "--json"],
        input="\n".join(requests) + "\n",
        capture_output=True, text=True, timeout=300,
        cwd=path.parent,
    )

    results: dict[int, dict] = {}
    for line in proc.stdout.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("type") == "result":
            results[message.get("id")] = message

    failures = []
    for request_id, (cell_number, cell) in enumerate(code_cells, start=1):
        result = results.get(request_id)
        source = cell.get("source", "")
        expect_error = EXPECT_ERROR_MARKER in source
        preview = " ".join(source.split())[:70]

        if result is None:
            failures.append(
                f"{path.name} cell {cell_number}: no result (session died?) — {preview}")
            # Everything after a dead session is unattributable.
            break
        status = result.get("status")
        if expect_error and status != "error":
            failures.append(
                f"{path.name} cell {cell_number}: expected an error, got {status} — {preview}")
        elif not expect_error and status != "ok":
            evalue = (result.get("error") or {}).get("evalue", "")
            failures.append(
                f"{path.name} cell {cell_number}: {status} ({evalue[:100]}) — {preview}")
    return failures


def main() -> int:
    root = Path(__file__).resolve().parent
    if len(sys.argv) > 1:
        notebooks = [Path(arg) for arg in sys.argv[1:]]
    else:
        notebooks = sorted(root.glob("*.repl"))

    if not notebooks:
        print("No .repl notebooks found.")
        return 1

    all_failures = []
    for notebook in notebooks:
        failures = run_notebook(notebook)
        marker = "FAIL" if failures else "ok"
        print(f"[{marker}] {notebook.name}")
        all_failures.extend(failures)

    if all_failures:
        print()
        for failure in all_failures:
            print("  " + failure)
        return 1
    print(f"\n{len(notebooks)} notebooks validated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
