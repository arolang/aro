#!/usr/bin/env python3
"""
Check every ARO snippet in the card set against the real `aro check`.

A card's headline is the thing a reader sees first and the thing most likely
to be copied. A headline that does not parse teaches the wrong syntax to
everyone who sees it, and nothing else in this repository looks at
`facts.yaml` — the generator only renders the string. So this does.

Headlines are not all ARO: some are YAML from `openapi.yaml`, some are shell.
Only the ones that look like an ARO statement are checked, and the rule for
"looks like" is deliberately loose — a trailing period and angle brackets —
so a genuine statement cannot escape the check by being unusual.

Usage: validate-facts.py [facts.yaml ...]
Exit: 0 all good, 1 something does not parse.
"""
import os, re, subprocess, sys, tempfile, pathlib, shutil

# Prefer a binary built from this checkout over whatever is installed.
#
# The installed `aro` lags the tree — at the time of writing it is 0.12.0 while
# HEAD accepts five things it rejects (`Publish as … when`, `subset of`,
# `where … before`, the affix operators, `symmetric-difference`). Validating
# against it would fail cards that are correct, which is worse than not
# validating at all: it teaches the author to write the *older* language.
#
# Same trap `Tests/IntegrationTestsRunner/run-tests.pl` has with ARO_BIN, and
# the same fix — look in the build tree first, and let the caller override.
def _find_aro() -> str:
    here = pathlib.Path(__file__).resolve().parent.parent
    candidates = [os.environ.get("ARO_BIN")] + [
        str(here / ".build" / flavour / "aro") for flavour in ("debug", "release")
    ]
    for candidate in candidates:
        if candidate and pathlib.Path(candidate).is_file():
            return candidate
    found = shutil.which("aro")
    if found:
        print(f"warning: no build in .build/, falling back to {found} — "
              f"a stale binary reports valid cards as broken", file=sys.stderr)
        return found
    return "aro"

ARO = _find_aro()

# Wrapped in a feature set because `aro check` checks applications, not
# fragments. Application-Start is the one every application must have, and a
# trailing Return keeps the "no entry point" and "missing return" diagnostics
# out of the way of the thing being tested.
TEMPLATE = """(Application-Start: CardProbe) {{
{body}
    Return an <OK: status> for the <probe>.
}}
{companions}"""

# A card showing `Application.Doubled the <r> from 21.` is correct ARO; it is
# only "unknown" because a one-statement probe has nowhere to declare the
# action. Declaring a stub for whatever the snippet calls keeps the check
# about syntax rather than about the probe's own incompleteness.
ERROR_LINE = re.compile(r"^\s*\d+:\d+:\s*error:|^\s*\u274c\s*\d+ error")

CALL = re.compile(r"\bApplication\.([A-Za-z][\w-]*)")

def companions_for(headline: str) -> str:
    names = dict.fromkeys(CALL.findall(headline))  # ordered, deduplicated
    # The stub has to match the call's shape. ARO-0081: an action that
    # declares `takes` is called with `from <value>`, one that does not is
    # called with `with { … }`, and the analyser rejects the mismatch. A stub
    # that guessed wrong would fail a card that is written correctly.
    takes = " takes <value>" if re.search(r"Application\.[\w-]+[^.]*\bfrom\b", headline) else ""
    return "".join(
        f"\n({name}: Action{takes}) {{\n    Return an <OK: status> for the <stub>.\n}}\n"
        for name in names
    )

def looks_like_aro(headline: str) -> bool:
    h = headline.strip()
    if "\n" in h:
        return False
    if not h.endswith("."):
        return False
    # A statement names something in angle brackets, or is one of the
    # bracket-free forms in the grammar (`Break.`, `match`, `Publish as`).
    return ("<" in h and ">" in h) or h in ("Break.",) or h.startswith("Publish as ")

def check(headlines):
    """Check each snippet on its own, so one failure cannot mask another."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        app = pathlib.Path(tmp) / "app"
        app.mkdir()
        for ident, headline in headlines:
            (app / "main.aro").write_text(TEMPLATE.format(
                body="    " + headline.strip(),
                companions=companions_for(headline)))
            out = subprocess.run([ARO, "check", str(app)],
                                 capture_output=True, text=True)
            # Warnings are fine and expected — an unused binding is normal in a
            # one-line excerpt. Only errors mean the syntax is wrong.
            #
            # Matched structurally, not by looking for the word anywhere in the
            # output: a headline binding `<errors>` or `<error-count>` is echoed
            # back in the diagnostics and used to fail the check on its own
            # name. `aro check` prints `LINE:COL: error: …` per finding and a
            # `N error(s) found` summary, so those are what to look for.
            diagnostics = [l for l in out.stdout.splitlines()
                           if ERROR_LINE.search(l)]
            if diagnostics or out.returncode != 0:
                failures.append((ident, headline, "\n".join(diagnostics).strip()
                                 or f"aro check exited {out.returncode}"))
    return failures

def main(paths):
    import yaml
    headlines, total, seen_ids = [], 0, {}
    for p in paths:
        data = yaml.safe_load(open(p))
        for n, fact in enumerate(data["facts"], 1):
            total += 1
            # Fragments under facts.d/ carry no ids — those are assigned when
            # the year is assembled — so fall back to file:index, which is
            # what an author needs to find the line anyway.
            ident = fact.get("id") or f"{pathlib.Path(p).name}:{n}"
            if fact.get("id"):
                if ident in seen_ids:
                    print(f"duplicate id {ident} ({p} and {seen_ids[ident]})")
                    return 1
                seen_ids[ident] = p
            for required in ("category", "headline", "explanation"):
                if not str(fact.get(required, "")).strip():
                    print(f"{ident}: missing {required}")
                    return 1
            if looks_like_aro(fact["headline"]):
                headlines.append((ident, fact["headline"]))

    print(f"{total} cards, {len(headlines)} of them ARO snippets to check")
    failures = check(headlines)
    for ident, headline, detail in failures:
        print(f"\n✗ {ident}: {headline}\n{detail}")
    print(f"\n{len(failures)} snippet(s) failed" if failures else "\nall snippets parse")
    return 1 if failures else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["cards/facts.yaml"]))
