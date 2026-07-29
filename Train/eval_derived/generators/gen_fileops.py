#!/usr/bin/env python3
"""File-operation (Move/Copy/rename) coverage + the `from … to …` fix.

Prompted by a real `aro ask` miss: for "how to move a file" it suggested
`Move the <file> from the <source: "…"> to the <destination: "…">.`, which fails
to parse — `Move` has no `from` preposition (only `to`), and the source path
belongs in the *result* qualifier. The reliable form (verified to actually move
the file: source dir empties, destination gains it) creates file handles first,
then moves/copies between them. This generator teaches that form and an error→fix
pair for the exact mistake. Every code answer is re-validated with `aro check`;
the error→fix pair is gated so the broken form genuinely fails and the fix passes.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "fileops.jsonl"

CASES = [
    ("report", "./in/report.csv", "./archive/report.csv"),
    ("invoice", "./pending/invoice.pdf", "./sent/invoice.pdf"),
    ("photo", "./uploads/photo.jpg", "./gallery/photo.jpg"),
    ("backup", "./data/db.sqlite", "./backups/db.sqlite"),
    ("log", "./tmp/app.log", "./logs/app.log"),
    ("config", "./defaults/config.yaml", "./etc/config.yaml"),
    ("export", "./work/export.json", "./public/export.json"),
    ("draft", "./drafts/post.md", "./published/post.md"),
]


def cap(s):
    return s[0].upper() + s[1:]


def move_prog(name, src, dst):
    return (f"(Move{cap(name)}: File API) {{\n"
            f"    Create the <source-file> with \"{src}\".\n"
            f"    Create the <dest-file> with \"{dst}\".\n"
            f"    Move the <moved: source-file> to the <destination: dest-file>.\n"
            f"    Return an <OK: status> for the <moved>.\n"
            f"}}")


def copy_prog(name, src, dst):
    return (f"(Copy{cap(name)}: File API) {{\n"
            f"    Create the <source-file> with \"{src}\".\n"
            f"    Create the <dest-file> with \"{dst}\".\n"
            f"    Copy the <copied: source-file> to the <destination: dest-file>.\n"
            f"    Return an <OK: status> for the <copied>.\n"
            f"}}")


# The exact aro-ask miss: `from … to …` with inline string paths. Fails to parse.
BROKEN_MOVE = ('(MoveFile: File API) {\n'
               '    Move the <file> from the <source: "./old/path/file.txt"> '
               'to the <destination: "./new/path/file.txt">.\n'
               '    Return an <OK: status> for the <file>.\n'
               '}')
FIXED_MOVE = ('(MoveFile: File API) {\n'
              '    Create the <source-file> with "./old/path/file.txt".\n'
              '    Create the <dest-file> with "./new/path/file.txt".\n'
              '    Move the <moved: source-file> to the <destination: dest-file>.\n'
              '    Return an <OK: status> for the <moved>.\n'
              '}')


def main():
    rows = []
    checked = passed = 0
    aro_missing = False

    def emit_code(instr, prog, verb):
        rows.append({
            "instruction": instr, "output": f"```aro\n{prog}\n```",
            "category": "code_generation", "task_type": "code_generation",
            "verb_domain": verb, "source": "eval_fileops",
        })

    for name, src, dst in CASES:
        for verb, builder, phrasings in [
            ("move", move_prog, [
                f"Write an ARO feature set that moves the {name} file to another folder.",
                f"How do I move a file from one folder to another in ARO?"]),
            ("copy", copy_prog, [
                f"Write an ARO feature set that copies the {name} file to another folder.",
                f"How do I copy a file to another folder in ARO?"]),
        ]:
            prog = builder(name, src, dst)
            checked += 1
            ok, err = config.aro_check_snippet(prog, timeout=15)
            if ok is None:
                aro_missing = True
                continue
            if not ok:
                line = err.splitlines()[1].strip()[:60] if err and len(err.splitlines()) > 1 else str(err)[:60]
                print(f"  SKIP {verb}/{name}: {line}")
                continue
            passed += 1
            for p in phrasings:
                emit_code(p, prog, verb)

    # error→fix: the exact `from … to …` mistake → the handle-based form.
    ok_fixed, _ = config.aro_check_snippet(FIXED_MOVE, timeout=15)
    ok_broken, _ = config.aro_check_snippet(BROKEN_MOVE, timeout=15)
    if ok_fixed and ok_broken is False:
        rows.append({
            "instruction": "Fix this ARO — the Move syntax is wrong:\n"
                           f"```aro\n{BROKEN_MOVE}\n```",
            "output": "`Move` has no `from` preposition (only `to`), and the source path "
                      "goes in the result qualifier — not a separate `<source>` object. "
                      "Create file handles for the source and destination, then move between "
                      "them:\n\n"
                      f"```aro\n{FIXED_MOVE}\n```",
            "category": "correction", "task_type": "correction",
            "error_class": "move_invalid_from_preposition", "verb_domain": "move",
            "source": "eval_fileops",
        })
    else:
        print(f"  WARN move error→fix skipped (fixed_ok={ok_fixed}, broken_ok={ok_broken})")

    OUT.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate.")
    print(f"fileops: checked {checked}, aro-check-passed {passed} -> {len(rows)} pairs -> {OUT.name}")


if __name__ == "__main__":
    main()
