#!/usr/bin/env python3
"""The `aro` binary as the training pipeline's oracle.

Every data-quality gate in this pipeline ultimately asks one question: *would
the runtime accept this?* Until now each stage answered it for itself — one
notebook shelling out to `aro check`, another consulting a JSON catalog last
regenerated a month earlier, a third not asking at all. The catalogs drifted
(GitLab #779), invented verbs walked past the gate that only ran at one stage
(GitLab #780), and nothing re-asked the question when the language changed
(GitLab #783).

This module is the single place that talks to the binary:

* `aro_bin()` / `aro_version()`  — which binary, which version.
* `action_catalog()` / `action_verbs()` — the registry, straight from
  `aro actions list --format json`.
* `check_block()` — `aro check` on one ```aro block, in the mode that matches
  what the block actually is.

It deliberately has no dependency on `config.py`, so the catalog extractors,
the standalone validator and the notebooks can all import it.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


# ── Which binary ─────────────────────────────────────────────────────────────

def aro_bin() -> str | None:
    """Path to the `aro` binary, or None when there is none.

    `ARO_BIN` wins (CI sets it to the build artefact), then a local build,
    then whatever is on PATH. A stale installed binary silently answering for
    a worktree build is the same trap `aro build` has with libARORuntime.a, so
    the resolution order puts the worktree's own build first.
    """
    env = os.environ.get('ARO_BIN')
    if env and Path(env).exists():
        return env
    for rel in ('.build/release/aro', '.build/debug/aro'):
        p = REPO / rel
        if p.exists():
            return str(p)
    return shutil.which('aro')


@lru_cache(maxsize=1)
def aro_version() -> str:
    """`aro --version`, or 'unavailable' when there is no binary."""
    binary = aro_bin()
    if not binary:
        return 'unavailable'
    try:
        r = subprocess.run([binary, '--version'], capture_output=True,
                           text=True, timeout=20)
        return (r.stdout or r.stderr).strip().splitlines()[0].strip()
    except (OSError, subprocess.SubprocessError, IndexError):
        return 'unavailable'


def require_aro_bin() -> str:
    binary = aro_bin()
    if not binary:
        raise RuntimeError(
            'no `aro` binary found. Set ARO_BIN, build with '
            '`swift build -c release`, or install the CLI.')
    return binary


# ── The action registry, from the binary ─────────────────────────────────────

ROLE_LABEL = {
    'request': 'REQUEST (External → Internal)',
    'own': 'OWN (Internal → Internal)',
    'response': 'RESPONSE (Internal → External)',
    'export': 'EXPORT (makes symbols global / exports data)',
    'server': 'SERVER (service lifecycle operations)',
}


def canonical_verb(name: str, verbs: list[str]) -> str:
    """The catalog key for an action: the verb that stands for its name.

    `aro actions` reports an action's Swift type name (`GitCommit`,
    `ParseDispatch`, `WaitForEvents`) and its verb set. The catalog has always
    been keyed by verb, so the key is the verb the name is built around —
    `commit`, `parse`, `wait` — and only failing that the alphabetically first
    verb.
    """
    lowered = name.lower()
    verbs = [v.lower() for v in verbs]
    if lowered in verbs:
        return lowered
    contained = [v for v in verbs if v in lowered]
    if contained:
        return max(contained, key=len)
    return sorted(verbs)[0]


def registry_json(directory: str | None = None) -> dict:
    """Raw `aro actions list --format json` output."""
    binary = require_aro_bin()
    cmd = [binary, 'actions', 'list', '--format', 'json']
    if directory:
        cmd += ['--directory', directory]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f'`aro actions` failed: {(r.stderr or r.stdout)[:300]}')
    return json.loads(r.stdout)


def action_catalog(include_plugins: bool = False) -> dict:
    """{canonical_verb: {role, role_label, prepositions, aliases, name}}.

    Built from the binary's own registry, so aliases that several Swift
    structs contribute to one registered action (Clear/Delete) and dispatchers
    that take a verb away from the struct that declares it (`parse` belongs to
    ParseDispatch, not ExtractAction) come out the way the runtime sees them.
    """
    data = registry_json()
    actions = list(data.get('builtin', []))
    if include_plugins:
        actions += list(data.get('plugin', []))
    catalog = {}
    for a in actions:
        verbs = sorted(v.lower() for v in a.get('verbs', []))
        if not verbs:
            continue
        role = (a.get('role') or '').lower()
        key = canonical_verb(a.get('name', verbs[0]), verbs)
        catalog[key] = {
            'role': role,
            'role_label': ROLE_LABEL.get(role, role),
            'prepositions': sorted(p.lower() for p in a.get('prepositions', [])),
            'aliases': verbs,
            'name': a.get('name'),
        }
    return dict(sorted(catalog.items()))


def action_verbs(include_plugins: bool = False) -> list[str]:
    """Every verb the registry answers to, lowercased and sorted."""
    verbs: set[str] = set()
    for meta in action_catalog(include_plugins).values():
        verbs.update(meta['aliases'])
    return sorted(verbs)


# ── `aro check` on a code block ──────────────────────────────────────────────

# A feature-set header: `(Name: Activity) {`, with the `takes <arg>` and
# `when <guard>` forms the language allows between the header and the brace.
FEATURE_SET_RE = re.compile(
    r'\([^()\n:]+:\s*[^()\n]+\)(?:\s+when\s+[^{\n]+)?\s*\{')

_ENTRY_POINT = ('(Application-Start: Corpus Validation) {\n'
                '    Return an <OK: status> for the <startup>.\n}\n')

# `aro check --syntax` reads its input as a run of statements and stumbles
# over a `(* banner *)` that precedes a feature-set header — the very shape
# documentation habitually uses. Blocks that declare a feature set therefore
# go through a directory check, which is also how `aro run` will see them.


def check_block(code: str, timeout: int = 20, binary: str | None = None,
                extra_files: dict | None = None) -> tuple[bool | None, str]:
    """Run `aro check` over one ```aro block.

    Returns `(passed, error)`. `passed is None` means no binary was available
    and the caller must decide whether that is fatal — never that the block is
    fine.

    A block carrying a feature-set header is checked as an application
    directory (an `Application-Start` is supplied when the block has none, so
    a single handler can be checked on its own); a bare run of statements goes
    to `aro check --syntax`, which is what REPL-shaped pairs are.
    """
    binary = binary or aro_bin()
    if not binary:
        return None, 'aro_not_found'
    code = code.strip()
    if not code:
        return False, 'empty block'
    try:
        if FEATURE_SET_RE.search(code):
            with tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / 'main.aro').write_text(code)
                if 'Application-Start' not in code:
                    (Path(tmp) / '_entry_point.aro').write_text(_ENTRY_POINT)
                for name, content in (extra_files or {}).items():
                    (Path(tmp) / name).write_text(content)
                r = subprocess.run([binary, 'check', tmp], capture_output=True,
                                   text=True, timeout=timeout)
        else:
            r = subprocess.run([binary, 'check', '--syntax', '-'], input=code,
                               capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, 'timeout'
    except OSError as exc:
        return None, f'aro_not_runnable: {exc}'
    # Warnings matter as much as the exit code here — `aro check` reports a
    # preposition an action does not take as a warning and still exits 0 — so
    # keep enough of the output to read them, not just the first error.
    return r.returncode == 0, (r.stderr or r.stdout).strip()[:4000]


ARO_FENCE_RE = re.compile(r'```aro\b[^\n]*\n(.*?)```', re.DOTALL)


def aro_blocks(text: str) -> list[str]:
    """Every ```aro fenced block in `text`."""
    return [m.group(1) for m in ARO_FENCE_RE.finditer(text or '')]


if __name__ == '__main__':
    print(f'aro binary : {aro_bin()}')
    print(f'aro version: {aro_version()}')
    cat = action_catalog()
    print(f'actions    : {len(cat)}')
    print(f'verbs      : {len(action_verbs())}')
