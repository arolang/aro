#!/usr/bin/env python3
"""Long-tail action-verb coverage (issue #439).

The 2026-07-28 report showed 87 verbs over 50,679 uses with a steep tail:
Return/Create/Log/Extract/Compute dominate while Split/Merge/Render/Transform/
Reduce, the git verbs, set-ops, Accept/Configure/Parameters/Compare/Parse sit in
the hundreds — a robustness risk. This generator emits diverse, `aro check`-
validated feature sets exercising each thin-domain verb, across many entities, so
the base corpus carries real variety before NB16's per-verb floor up-samples the
remainder. Every emitted answer is re-validated with `aro check`.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "verbfill.jsonl"

ENTS = ["user", "order", "product", "invoice", "customer", "payment", "ticket",
        "account", "booking", "device", "review", "shipment", "task", "project",
        "message", "event", "alert", "job", "record", "session"]
FIELDS = ["status", "email", "name", "amount", "total", "role", "level", "state"]


def cap(s):
    return s[0].upper() + s[1:]


# ── tail-verb template families (verb → builder(e, f) → full feature set) ─────
def split_(e, f):
    return f"""(Parse{cap(e)}Line: {cap(e)} API) {{
    Retrieve the <csv-line> from the <{e}-repository>.
    Split the <segments> from the <csv-line> by /,/.
    Return an <OK: status> with <segments>.
}}"""


def merge_(e, f):
    return f"""(Merge{cap(e)}s: {cap(e)} API) {{
    Retrieve the <primary> from the <{e}-repository>.
    Retrieve the <secondary> from the <{e}-archive>.
    Merge the <combined: {e}s> with <secondary>.
    Return an <OK: status> with <combined>.
}}"""


def render_(e, f):
    return f"""(Render{cap(e)}: {cap(e)} API) {{
    Retrieve the <{e}> from the <{e}-repository>.
    Render the <output> from "Hello, {{{{name}}}}!" with {{ name: <{e}> }}.
    Return an <OK: status> with <output>.
}}"""


def transform_(e, f):
    return f"""(Upcase{cap(e)}: {cap(e)} API) {{
    Extract the <{f}> from the <request: {f}>.
    Transform the <upper: uppercase> from the <{f}>.
    Return an <OK: status> with <upper>.
}}"""


def reduce_(e, f):
    return f"""(Count{cap(e)}s: {cap(e)} API) {{
    Retrieve the <{e}s> from the <{e}-repository>.
    Reduce the <total: Integer> from the <{e}s> with count().
    Return an <OK: status> with <total>.
}}"""


def setops_(e, f):
    return f"""(Common{cap(e)}s: {cap(e)} API) {{
    Retrieve the <list-a> from the <{e}-repository>.
    Retrieve the <list-b> from the <{e}-archive>.
    Compute the <common: intersect> from <list-a> with <list-b>.
    Return an <OK: status> with <common>.
}}"""


def accept_(e, f):
    return f"""(Advance{cap(e)}: {cap(e)}Placed Handler) {{
    Extract the <{e}> from the <event: {e}>.
    Accept the <transition: placed_to_paid> on <{e}: status>.
    Return an <OK: status> with <{e}>.
}}"""


def configure_(e, f):
    return f"""(Configure{cap(e)}: Setup) {{
    Configure the <{e}-repository: ttl> with 60.
    Return an <OK: status> with <{e}-repository>.
}}"""


def parameters_(e, f):
    return f"""(Read{cap(e)}Param: CLI) {{
    Extract the <{f}> from the <parameter: {f}>.
    Log <{f}> to the <console>.
    Return an <OK: status> with <{f}>.
}}"""


def compare_(e, f):
    return f"""(Verify{cap(e)}: {cap(e)} API) {{
    Extract the <supplied> from the <request: {f}>.
    Retrieve the <expected> from the <{e}-repository>.
    Compare the <match> against the <expected>.
    Return an <OK: status> with <match>.
}}"""


def parse_(e, f):
    return f"""(Parse{cap(e)}Doc: {cap(e)} API) {{
    Read the <html-content> from the <file: "{e}.html">.
    Parse the <document> from the <html-content>.
    Return an <OK: status> with <document>.
}}"""


def validate_(e, f):
    return f"""(Validate{cap(e)}: {cap(e)} API) {{
    Extract the <input> from the <request: body>.
    Validate the <validated> with <input>.
    Return an <OK: status> with <validated>.
}}"""


# git families vary their string literals / result names by entity so entity
# fan-out yields distinct valid programs (not 2 carriers up-sampled 75×).
def git_status(e, f):
    return f"""(Repo{cap(e)}Status: Repo) {{
    Retrieve the <{e}-status> from the <git>.
    Log <{e}-status> to the <console>.
    Return an <OK: status> with <{e}-status>.
}}"""


def git_push(e, f):
    return f"""(Push{cap(e)}: Repo) {{
    Stage the <files> to the <git> with ".".
    Commit the <saved> to the <git> with "chore: sync {e}".
    Push the <result> to the <git>.
    Return an <OK: status> with <result>.
}}"""


def git_pull(e, f):
    return f"""(Pull{cap(e)}: Repo) {{
    Pull the <{e}-updates> from the <git>.
    Return an <OK: status> with <{e}-updates>.
}}"""


def git_checkout(e, f):
    return f"""(Checkout{cap(e)}: Repo) {{
    Checkout the <branch> from the <git> with "feature/{e}".
    Return an <OK: status> with <branch>.
}}"""


def git_tag(e, f):
    return f"""(Tag{cap(e)}: Repo) {{
    Tag the <release> for the <git> with "release-{e}".
    Return an <OK: status> with <release>.
}}"""


def git_clone(e, f):
    return f"""(Clone{cap(e)}: Repo) {{
    Clone the <repo> from the <git> with {{ url: "https://example.com/{e}.git", path: "./{e}" }}.
    Return an <OK: status> with <repo>.
}}"""


# verb-key → (instruction phrasings, builder). The key names the primary verb.
FAMILIES = {
    "split":      (["Write an ARO feature set that splits a {e} CSV line into segments.",
                    "How do I split a string by comma in ARO for a {e}?"], split_),
    "merge":      (["Write an ARO feature set that merges two {e} collections.",
                    "How do I merge two lists in ARO for {e}s?"], merge_),
    "render":     (["Write an ARO feature set that renders a template for a {e}.",
                    "How do I render a Mustache template in ARO for a {e}?"], render_),
    "transform":  (["Write an ARO feature set that uppercases the {f} of a {e}.",
                    "How do I transform a value to uppercase in ARO for a {e}?"], transform_),
    "reduce":     (["Write an ARO feature set that counts {e}s with Reduce.",
                    "How do I reduce a collection to a count in ARO for {e}s?"], reduce_),
    "setops":     (["Write an ARO feature set that intersects two {e} lists.",
                    "How do I compute the intersection of two sets in ARO for {e}s?"], setops_),
    "accept":     (["Write an ARO state handler that accepts a paid transition for a {e}.",
                    "How do I accept a state transition in ARO for a {e}?"], accept_),
    "configure":  (["Write an ARO feature set that configures the {e} repository TTL.",
                    "How do I configure a repository setting in ARO for {e}s?"], configure_),
    "parameters": (["Write an ARO feature set that reads the {f} command-line parameter.",
                    "How do I read a CLI parameter in ARO?"], parameters_),
    "compare":    (["Write an ARO feature set that compares a supplied {f} against the stored one for a {e}.",
                    "How do I compare two values in ARO for a {e}?"], compare_),
    "parse":      (["Write an ARO feature set that parses an HTML document for a {e}.",
                    "How do I parse HTML in ARO for a {e}?"], parse_),
    "validate":   (["Write an ARO feature set that validates {e} input.",
                    "How do I validate input in ARO for a {e}?"], validate_),
    "git_status": (["Write an ARO feature set that logs the git status for the {e} repo.",
                    "How do I get the git status in ARO?"], git_status),
    "git_push":   (["Write an ARO feature set that stages, commits and pushes the {e} changes to git.",
                    "How do I push commits to git in ARO?"], git_push),
    "git_pull":   (["Write an ARO feature set that pulls the latest {e} updates from git.",
                    "How do I pull from git in ARO?"], git_pull),
    "git_checkout": (["Write an ARO feature set that checks out the {e} feature branch.",
                      "How do I switch git branches in ARO?"], git_checkout),
    "git_tag":    (["Write an ARO feature set that tags the {e} release.",
                    "How do I tag a release in ARO?"], git_tag),
    "git_clone":  (["Write an ARO feature set that clones the {e} git repository.",
                    "How do I clone a repository in ARO?"], git_clone),
}

# git families now vary by entity, but their instruction phrasings don't mention
# the entity — cap their fan-out to 8 so the git verbs get healthy carrier counts
# without dominating.
_GIT_FAMILIES = {"git_status", "git_push", "git_pull", "git_checkout",
                 "git_tag", "git_clone"}


def main():
    n, seen = 0, set()
    checked = passed = 0
    aro_missing = False
    with open(OUT, "w") as f:
        for verb, (instrs, builder) in FAMILIES.items():
            ents = ENTS[:8] if verb in _GIT_FAMILIES else ENTS
            for i, e in enumerate(ents):
                fld = FIELDS[i % len(FIELDS)]
                answer = builder(e, fld)
                checked += 1
                ok, err = config.aro_check_snippet(answer, timeout=15)
                if ok is None:
                    aro_missing = True
                    continue
                if not ok:
                    line = err.splitlines()[1].strip()[:60] if err and len(err.splitlines()) > 1 else err[:60]
                    print(f"  SKIP {verb}/{e}: {line}")
                    continue
                passed += 1
                for tmpl in instrs:
                    ins = tmpl.replace("{e}", e).replace("{f}", fld)
                    if ins in seen:
                        continue
                    seen.add(ins)
                    f.write(json.dumps({
                        "instruction": ins,
                        "output": f"```aro\n{answer}\n```",
                        "category": "code_generation",
                        "task_type": "code_generation",
                        "verb_domain": verb,
                        "source": "eval_verbfill",
                    }) + "\n")
                    n += 1
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate.")
    print(f"verbfill: checked {checked}, aro-check-passed {passed} -> {n} pairs -> {OUT.name}")


if __name__ == "__main__":
    main()
