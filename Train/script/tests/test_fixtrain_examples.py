"""The FIXTRAIN audit as a regression suite (GitLab #811).

`Train/FIXTRAIN.md` recorded 83 findings in a corpus that no longer exists, and
the rules that keep those findings out had moved into `config.FIXTRAIN_RULES`
with nothing tying the two together. Each rule now carries the pair the audit
found it with, and this module is what makes that pair mean something:

  * the **wrong** form must trip its own rule — a rule whose pattern stops
    matching is a gate that has quietly opened;
  * the **corrected** form must trip no rule at all, so a rule cannot be
    written in a way that rejects the fix it recommends;
  * the **corrected** form must pass `aro check`, which is the part that keeps
    the recommendation honest about the language that ships.

The `aro check` half needs a binary and skips without one (`ARO_BIN`, then
`.build/release`, then `PATH` — `aro_oracle.aro_bin`), so the suite
stays runnable on a slim CI image. `train:catalogs` runs this file again with
the binary from the same pipeline, which is where that half actually executes.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402
import generate_fixtrain  # noqa: E402

RULES = config.FIXTRAIN_RULES
IDS = [rule["name"] for rule in RULES]


def _binary():
    """The `aro` binary, or None when this host has none."""
    try:
        from aro_oracle import aro_bin
    except ImportError:
        return None
    found = aro_bin()
    return str(found) if found and Path(str(found)).exists() else None


ARO = _binary()


def _program(snippet):
    """Wrap a snippet into the smallest application `aro check` will accept.

    Three shapes occur in the examples: a complete program, a bare feature set
    (the feature-set-header rules), and a run of statements.
    """
    if "Application-Start" in snippet:
        return snippet
    tail = "(Application-Start: Fixtrain Example) {\n    Return an <OK: status> for the <startup>.\n}\n"
    if snippet.lstrip().startswith("("):
        return f"{snippet}\n\n{tail}"
    body = "\n".join(f"    {line}" if line.strip() else line for line in snippet.split("\n"))
    return (
        "(Application-Start: Fixtrain Example) {\n"
        f"{body}\n"
        "    Return an <OK: status> for the <startup>.\n"
        "}\n"
    )


def _aro_check(snippet):
    with tempfile.TemporaryDirectory() as directory:
        Path(directory, "main.aro").write_text(_program(snippet), encoding="utf-8")
        result = subprocess.run(
            [ARO, "check", directory], capture_output=True, text=True, timeout=120
        )
        return result.returncode, (result.stdout + result.stderr).strip()


def _tripped(code):
    return {v["rule"] for v in config.check_fixtrain_issues(code, include_warnings=True)}


@pytest.mark.parametrize("rule", RULES, ids=IDS)
def test_rule_has_an_example_pair(rule):
    assert rule.get("wrong"), f"{rule['name']} has no wrong example"
    assert rule.get("corrected"), f"{rule['name']} has no corrected example"


@pytest.mark.parametrize("rule", RULES, ids=IDS)
def test_wrong_example_trips_its_own_rule(rule):
    tripped = _tripped(rule["wrong"])
    assert rule["name"] in tripped, (
        f"{rule['name']} no longer matches its own wrong example "
        f"{rule['wrong']!r} (tripped: {sorted(tripped) or 'nothing'})"
    )


@pytest.mark.parametrize("rule", RULES, ids=IDS)
def test_corrected_example_trips_nothing(rule):
    tripped = _tripped(rule["corrected"])
    assert not tripped, (
        f"{rule['name']}'s corrected example {rule['corrected']!r} trips {sorted(tripped)}"
    )


@pytest.mark.skipif(ARO is None, reason="no aro binary (set ARO_BIN)")
@pytest.mark.parametrize("rule", RULES, ids=IDS)
def test_corrected_example_passes_aro_check(rule):
    code, output = _aro_check(rule["corrected"])
    assert code == 0, f"{rule['name']}'s corrected example fails aro check:\n{output}"


def test_fixtrain_status_tables_are_current():
    problems = generate_fixtrain.check()
    assert not problems, (
        "FIXTRAIN.md is stale:\n  "
        + "\n  ".join(problems)
        + "\nRegenerate with: python3 Train/script/generate_fixtrain.py"
    )
