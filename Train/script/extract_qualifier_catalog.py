#!/usr/bin/env python3
"""Extract the authoritative Compute-qualifier catalog from the runtime.

The sibling of `extract_action_catalog.py`, and the missing half of the same
idea (GitLab #486). Actions have had a generated catalog and a validation gate
for a while; qualifiers never did, so nothing in the pipeline could answer "is
`<total: lines>` a thing the runtime implements?" — and the answer was no for
202 distinct names across 2,652 samples, every one of which passed `aro check`,
ran green, and printed the wrong value.

Two sources, in order of preference:

1. `aro actions --qualifiers --format json`, when an `aro` binary is around.
   That is the runtime telling you what it registered, including any plugin
   qualifiers in the project.
2. `Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift`, parsed directly.
   The built-in table lives in one place — `builtInQualifiers` — so this is a
   faithful fallback on a training host with no toolchain.

Regenerate after adding or changing a qualifier:

    python3 Train/script/extract_qualifier_catalog.py

Output: aro_qualifier_catalog.json
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
COMPUTE_SRC = (REPO / "Sources" / "ARORuntime" / "Actions" / "BuiltIn"
               / "ComputeAction.swift")
OUT = Path(__file__).resolve().parent / "aro_qualifier_catalog.json"

# `.init(name: "lines", inputTypes: [...], acceptsParameters: false,`
_NAME_RE = re.compile(r'\.init\(name:\s*"([\w.-]+)"')
_TABLE_RE = re.compile(
    r"static let builtInQualifiers:\s*\[BuiltInQualifier\]\s*=\s*\[(.*?)\n    \]",
    re.DOTALL)

# A qualifier that is legal without appearing in the catalog.
#   plugin form   handle.qualifier
#   chain         a|b  (each element resolved separately)
#   date offset   -7d, +2w, +24h
_NAMESPACED_RE = re.compile(r"^[\w-]+\.[\w-]+$")
_DATE_OFFSET_RE = re.compile(r"^[+-]\d+[smhdwMy]$")


def _from_cli():
    """Ask the runtime. Returns None when no usable `aro` is on PATH."""
    aro = shutil.which("aro") or str(REPO / ".build" / "debug" / "aro")
    if not Path(aro).exists() and not shutil.which("aro"):
        return None
    try:
        proc = subprocess.run(
            [aro, "actions", "--qualifiers", "--format", "json"],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    entries = payload.get("qualifiers")
    if not entries:
        # Pre-#486 binaries drop the qualifier section silently — the
        # exact blocker this catalog was blocked on. Fall back rather
        # than emit an empty catalog, which would make the gate a no-op.
        return None
    return {
        entry["name"]: {
            "namespace": entry.get("namespace", "_builtin"),
            "builtin": bool(entry.get("builtin")),
            "input_types": entry.get("inputTypes", []),
            "accepts_parameters": bool(entry.get("acceptsParameters")),
            "description": entry.get("description", ""),
            "source": "aro actions --qualifiers --format json",
        }
        for entry in entries
    }


def _from_source():
    """Parse the built-in table out of ComputeAction.swift."""
    if not COMPUTE_SRC.exists():
        return {}
    text = COMPUTE_SRC.read_text(errors="ignore")
    table = _TABLE_RE.search(text)
    if not table:
        return {}
    return {
        name: {
            "namespace": "_builtin",
            "builtin": True,
            "input_types": [],
            "accepts_parameters": False,
            "description": "",
            "source": str(COMPUTE_SRC.relative_to(REPO)),
        }
        for name in _NAME_RE.findall(table.group(1))
    }


def extract():
    return dict(sorted((_from_cli() or _from_source()).items()))


def load():
    """The catalog, preferring the committed JSON so training hosts without
    a checkout of Sources/ still get one."""
    if OUT.exists():
        return json.loads(OUT.read_text())
    return extract()


def is_known(name, catalog=None):
    """Is `name` something the runtime can actually resolve?

    Handles the three forms that are legal without being catalog entries:
    plugin-namespaced qualifiers, chains, and date offsets. Those three
    exemptions are what keep the false-positive rate at zero.
    """
    catalog = catalog if catalog is not None else load()
    name = (name or "").strip()
    if not name:
        return False
    if "|" in name:
        return all(is_known(part, catalog) for part in name.split("|"))
    if _DATE_OFFSET_RE.match(name):
        return True
    if name.lower() in catalog:
        return True
    # Plugin form: any `handle.qualifier`. The handle belongs to a plugin
    # that may not be installed where the gate runs, so the shape is as
    # much as can be checked without the project in hand.
    return bool(_NAMESPACED_RE.match(name))


if __name__ == "__main__":
    catalog = extract()
    OUT.write_text(json.dumps(catalog, indent=1) + "\n")
    builtins = sum(1 for v in catalog.values() if v["builtin"])
    source = next(iter(catalog.values()), {}).get("source", "(none)")
    print(f"wrote {len(catalog)} qualifiers ({builtins} built-in) -> {OUT}")
    print(f"source: {source}")
