#!/usr/bin/env python3
"""
28_diagnostic_repairs.py — training pairs for fixing `aro check` diagnostics.

Why this exists: `aro ask /fix` failed on a real project (Crawler) in every
way a repair can fail — it appended handlers that already existed in sibling
files, could not delete a single unused-variable line without retyping the
whole file, and never once checked whether a warning was true before acting
on it. The repair *mechanics* are now deterministic in AROAsk, but the model
still writes the handlers and judges the reports, so it must be trained on:

  1. append a handler for a genuinely unhandled event (and nothing else),
  2. recognise a handler in a SIBLING file and change nothing,
  3. delete exactly the binding line of an unused variable,
  4. delete the enclosing `case` block when the binding is its only statement,
  5. refuse to delete a variable that is read later (stale/wrong report),
  6. remove a duplicated handler (the damage this class of bug causes),
  plus one syntax_qa pair per aro_knowledge entry so the `aro_knowledge`
  tool's answers and the model's instincts agree.

Every pair is VALIDATED against the real `aro check` before it is saved:
"before" must produce the diagnostic the instruction claims, "after" must be
clean. A pair that does not validate is dropped loudly, never written.

Binary: $ARO_BIN if set, else the repo's own .build/{release,debug}/aro,
else `aro` on PATH. The repo build is preferred because the installed binary
may predate checker fixes this data depends on (per-file orphan events,
range-loop reads).

Usage:
    python3 Train/script/28_diagnostic_repairs.py            # generate+save
    python3 Train/script/28_diagnostic_repairs.py --dry-run  # validate only

Idempotent: re-running replaces this script's pairs (clean_notebook_pairs).
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import (  # noqa: E402
    save_notebook_pairs, clean_notebook_pairs,
)

NOTEBOOK_TAG = 'NB28_repairs'

SYSTEM = (
    'You are an expert ARO (Action Result Object) programmer. ARO is a DSL '
    'where every statement is: Verb the <Result> preposition [the] <Object>. '
    'Feature sets follow (Name: Business Activity) { statements }. Variables '
    'are immutable. An ARO application is a directory: ALL .aro files are '
    'compiled together with no imports, so a handler may live in any file.'
)


# ── aro binary ───────────────────────────────────────────────────────────────

def resolve_aro() -> str:
    env = os.environ.get('ARO_BIN')
    if env and os.access(env, os.X_OK):
        return env
    repo = Path(__file__).resolve().parents[2]
    for cfg in ('release', 'debug'):
        candidate = repo / '.build' / cfg / 'aro'
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return 'aro'


ARO = resolve_aro()


def aro_check(files: dict) -> tuple[int, str]:
    """`aro check` over a dict of {filename: content} as one application."""
    with tempfile.TemporaryDirectory() as tmp:
        for name, content in files.items():
            (Path(tmp) / name).write_text(content)
        r = subprocess.run([ARO, 'check', tmp],
                           capture_output=True, text=True, timeout=30)
        return r.returncode, (r.stdout + r.stderr)


# ── case templates ───────────────────────────────────────────────────────────
# Each variation gets distinct event/variable names so the model learns the
# shape, not the tokens.

EVENTS = [
    ('OrderPlaced',   [('order-id', 'order-id'), ('total', 'total')]),
    ('FileUploaded',  [('path', 'path'), ('size', 'size')]),
    ('UserRegistered', [('email', 'email')]),
    ('ReportReady',   [('url', 'url'), ('format', 'format')]),
]

UNUSED_VARS = ['retry-count', 'temp-result', 'old-name', 'debug-flag']


def emitter_file(event: str, fields: list) -> str:
    payload = ', '.join(f'{f}: <{v}>' for f, v in fields)
    binds = '\n'.join(
        f'    Extract the <{v}> from the <request: {v}>.' for _, v in fields)
    return f"""(Process Request: processRequest) {{
{binds}
    Emit a <{event}: event> with {{ {payload} }}.
    Return an <OK: status> for the <processing>.
}}
"""


def handler_file(event: str, fields: list) -> str:
    extracts = '\n'.join(
        f'    Extract the <{f}> from the <event: {f}>.' for f, _ in fields)
    return f"""(Handle {event}: {event} Handler) {{
{extracts}
    Return an <OK: status> for the <handled>.
}}
"""


def build_pairs() -> list[dict]:
    pairs, failures = [], []

    def validated(pair, before_files, after_files, expect_before, case):
        """Save only what the toolchain agrees with."""
        _, before_out = aro_check(before_files)
        if expect_before and expect_before not in before_out:
            failures.append(f'{case}: before missing "{expect_before}"')
            return
        code, after_out = aro_check(after_files)
        if code != 0 or 'warning:' in after_out:
            failures.append(f'{case}: after not clean: {after_out[:120]}')
            return
        pairs.append(pair)

    # 1. Genuinely unhandled event → append a handler, touch nothing else.
    for event, fields in EVENTS:
        before = emitter_file(event, fields)
        handler = handler_file(event, fields)
        after = before + '\n' + handler
        validated({
            'instruction':
                f'`aro check` reports:\n```\nmain.aro:\n  warning: Event '
                f"'{event}' is emitted but no handler exists\n```\n\n"
                f'The application has one file.\n\n## main.aro\n```aro\n'
                f'{before}```\n\nFix the warning.',
            'output':
                f'No feature set anywhere in the application has business '
                f'activity `{event} Handler`, so the warning is real. The fix '
                f'is to APPEND a handler that extracts the fields the Emit '
                f'passes — existing lines stay byte-for-byte unchanged:\n\n'
                f'```aro\n{handler}```',
            'source': 'repair', 'task_type': 'correction',
            'category': 'repair_append_handler',
        }, {'main.aro': before}, {'main.aro': after},
            'no handler exists', f'append-{event}')

    # 2. Handler exists in a sibling file → change nothing.
    for event, fields in EVENTS[:3]:
        emitter = emitter_file(event, fields)
        handler = handler_file(event, fields)
        files = {'main.aro': emitter, 'handlers.aro': handler}
        validated({
            'instruction':
                f'A code checker claims event `{event}` is emitted but no '
                f'handler exists. The application:\n\n## main.aro\n```aro\n'
                f'{emitter}```\n\n## handlers.aro\n```aro\n{handler}```\n\n'
                f'Fix the problem.',
            'output':
                f'There is nothing to fix. ARO applications have no imports — '
                f'every feature set in every file is globally visible — and '
                f'`handlers.aro` already declares `({event} Handler)`. One '
                f'handler serves every Emit of that event. The report is '
                f'stale or was produced per-file; adding a second handler '
                f'would be a defect, not a fix.',
            'source': 'repair', 'task_type': 'debugging',
            'category': 'repair_already_handled',
        }, files, files, None, f'sibling-{event}')

    # 3. Unused variable at statement level → delete exactly that line.
    for var in UNUSED_VARS:
        before = f"""(Application-Start: Demo) {{
    Log "starting" to the <console>.
    Compute the <{var}> from 5 * 2.
    Return an <OK: status> for the <startup>.
}}
"""
        after = before.replace(f'    Compute the <{var}> from 5 * 2.\n', '')
        validated({
            'instruction':
                f'`aro check` reports:\n```\n  3:5: warning: Variable '
                f"'{var}' is defined but never used\n```\n\n```aro\n{before}"
                f'```\n\nFix the warning.',
            'output':
                f'`<{var}>` is bound on line 3 and read nowhere — not in a '
                f'loop bound, a `when` guard, or a `${{...}}` interpolation. '
                f'Delete exactly that one statement; every other line stays '
                f'byte-for-byte identical:\n\n```aro\n{after}```',
            'source': 'repair', 'task_type': 'correction',
            'category': 'repair_delete_unused',
        }, {'main.aro': before}, {'main.aro': after},
            'is defined but never used', f'unused-{var}')

    # 4. Binding is the only statement in a case block → the block goes too.
    before_case = """(Application-Start: Config) {
    Extract the <raw> from the <env: LIMIT>.
    match <raw> {
        case /^[1-9][0-9]*$/ {
            Transform the <limit: int> from the <raw>.
        }
        case /^$/ {
            Create the <fallback> with 1000.
        }
    }
    Log <limit> to the <console>.
    Return an <OK: status> for the <startup>.
}
"""
    after_case = """(Application-Start: Config) {
    Extract the <raw> from the <env: LIMIT>.
    match <raw> {
        case /^[1-9][0-9]*$/ {
            Transform the <limit: int> from the <raw>.
        }
    }
    Log <limit> to the <console>.
    Return an <OK: status> for the <startup>.
}
"""
    validated({
        'instruction':
            '`aro check` reports:\n```\n  8:13: warning: Variable '
            "'fallback' is defined but never used\n```\n\n```aro\n"
            + before_case + '```\n\nFix the warning.',
        'output':
            '`<fallback>` is never read, but its binding is the ONLY '
            'statement in the `case /^$/` block — deleting the line alone '
            'would leave an empty block, which does not parse. Remove the '
            'whole case:\n\n```aro\n' + after_case + '```',
        'source': 'repair', 'task_type': 'correction',
        'category': 'repair_delete_case_block',
    }, {'main.aro': before_case}, {'main.aro': after_case},
        'is defined but never used', 'case-block')

    # 5. The report is wrong: the variable IS read. Refuse to delete.
    used_var = """(Application-Start: Drain) {
    Extract the <raw> from the <env: MAX>.
    Transform the <max-iters: int> from the <raw>.
    for <pass> from 0 to <max-iters> {
        Log <pass> to the <console>.
    }
    Return an <OK: status> for the <startup>.
}
"""
    validated({
        'instruction':
            'A checker report claims:\n```\n  3:5: warning: Variable '
            "'max-iters' is defined but never used\n```\n\n```aro\n"
            + used_var + '```\n\nFix the warning.',
        'output':
            'Do not change the code. `<max-iters>` IS read — it is the upper '
            'bound of the range loop on line 4 (`for <pass> from 0 to '
            '<max-iters>`). Loop bounds, `when` guards and `${...}` '
            'interpolations are all reads. The report is stale or produced '
            'by an analyzer that misses loop bounds; deleting the binding '
            'would break the loop. The correct action is to change nothing '
            'and say why.',
        'source': 'repair', 'task_type': 'debugging',
        'category': 'repair_refuse_false_warning',
    }, {'main.aro': used_var}, {'main.aro': used_var}, None, 'false-warning')

    # 6. A duplicated handler — the damage this bug class causes — gets removed.
    event, fields = EVENTS[0]
    emitter = emitter_file(event, fields)
    handler = handler_file(event, fields)
    dup = handler.replace(f'(Handle {event}:', f'(Handle {event} Again:')
    before_dup = {'main.aro': emitter, 'handlers.aro': handler + '\n' + dup}
    after_dup = {'main.aro': emitter, 'handlers.aro': handler}
    validated({
        'instruction':
            f'A repair tool appended a second handler for `{event}` that '
            f'already had one. Clean this up.\n\n## handlers.aro\n```aro\n'
            f'{handler}\n{dup}```',
        'output':
            f'Both feature sets have business activity `{event} Handler`, so '
            f'both run on every `{event}` event — the work happens twice. '
            f'Keep the original, remove the duplicate:\n\n```aro\n{handler}```',
        'source': 'repair', 'task_type': 'correction',
        'category': 'repair_remove_duplicate',
    }, before_dup, after_dup, None, 'duplicate')

    # 7. Knowledge Q/A — the aro_knowledge entries as trainable pairs, so the
    #    tool's answers and the model's instincts agree. Kept in sync by hand
    #    with Sources/AROAsk/KnowledgeBase.swift; the shared test fixture is
    #    the check output formats above.
    knowledge_qa = [
        ('How do I fix "Event X is emitted but no handler exists"?',
         'First search EVERY .aro file in the application for a feature set '
         'with business activity `X Handler` — ARO has no imports, all files '
         'are compiled together, and handlers often live in their own file. '
         'If one exists anywhere, change nothing: the warning is stale. Only '
         'if none exists, append `(Handle X: X Handler) { Extract the '
         '<field> from the <event: field>. ... Return an <OK: status> for '
         'the <handled>. }` extracting exactly the fields the Emit passes. '
         'Never add a second handler for the same event.'),
        ('How do I fix "Variable v is defined but never used"?',
         'Verify it first: loop bounds (`for <i> from 0 to <v>`), `when` '
         'guards, `${<v>}` interpolations and qualifier bases are all reads. '
         'If <v> is read anywhere, the report is wrong — change nothing. If '
         'it is genuinely unread, delete only the binding statement; if that '
         'statement is the sole content of a `case` or loop block, remove '
         'the enclosing block with it, because an empty block does not parse.'),
        ('Can I invent a Compute qualifier if none fits?',
         'No. The qualifier namespace is closed: built-ins, plugin '
         'qualifiers (handle.name), chains (a|b), or date offsets (-7d). An '
         'unknown name is a compile error. Sorting and reversing are actions '
         '(`Sort the <s> for the <x>.`), element access is an Extract '
         '(`Extract the <f: first> from the <x>.`), and a result type uses '
         '`as` (`Compute the <n> as Float from <s>.`).'),
        ('Is spacing like `the<name>` or `<a>< <b>` a syntax error in ARO?',
         'No. Spacing inside statements is not significant: `the<name>` '
         'equals `the <name>`, and `<a>< <b>` is the comparison `<a> < <b>` '
         'written tightly. When repairing a file, copy such lines '
         'byte-for-byte — "tidying" them is how repairs introduce errors.'),
    ]
    for q, a in knowledge_qa:
        pairs.append({
            'instruction': q, 'output': a,
            'source': 'repair', 'task_type': 'syntax_qa',
            'category': 'repair_knowledge',
        })

    return pairs, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true',
                    help='validate and report; save nothing')
    args = ap.parse_args()

    print(f'aro binary: {ARO}')
    pairs, failures = build_pairs()

    for f in failures:
        print(f'  DROPPED  {f}')
    print(f'validated pairs: {len(pairs)}  (dropped: {len(failures)})')

    if failures:
        # A dropped pair means the toolchain disagrees with the template —
        # that is a bug in this script or a checker change, and silently
        # training on the survivors would hide it.
        print('FAILING: every template must validate. Fix the template or '
              'the expectation before saving.')
        return 1

    if args.dry_run:
        print('dry run — nothing saved')
        return 0

    removed = clean_notebook_pairs(NOTEBOOK_TAG)
    if removed:
        print(f'replaced {removed} previous pairs')
    written = save_notebook_pairs(NOTEBOOK_TAG, pairs)
    print(f'saved {written} pairs as {NOTEBOOK_TAG}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
