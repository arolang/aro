#!/usr/bin/env python3
"""Authored base programs for verbs/domains missing from the harvested pool
(git, set-ops, Throw, Configure, Parameters, Publish, Group, Compare, dates).
Each is validated with `aro check`; only passers are used. Run directly to see
which candidates pass/fail so failures can be corrected."""
import sys
from pathlib import Path
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

CANDIDATES = {
"git_status": """(Show Status: Repo) {
    Retrieve the <status> from the <git>.
    Log <status> to the <console>.
    Return an <OK: status> with <status>.
}""",
"git_commit": """(Commit Work: Repo) {
    Stage the <files> to the <git> with ".".
    Commit the <result> to the <git> with "feat: update feature".
    Return an <OK: status> with <result>.
}""",
"git_push": """(Upload Work: Repo) {
    Push the <result> to the <git>.
    Return an <OK: status> with <result>.
}""",
"git_pull": """(Sync Work: Repo) {
    Pull the <updates> from the <git>.
    Return an <OK: status> with <updates>.
}""",
"git_checkout": """(Branch Work: Repo) {
    Checkout the <branch> from the <git> with "feature/new".
    Return an <OK: status> with <branch>.
}""",
"git_tag": """(Tag Release: Repo) {
    Tag the <release> for the <git> with "v1.0.0".
    Return an <OK: status> with <release>.
}""",
"git_clone": """(Clone Repo: Repo) {
    Clone the <repo> from the <git> with { url: "https://example.com/x.git", path: "./x" }.
    Return an <OK: status> with <repo>.
}""",
"set_intersect": """(Common Items: Sets) {
    Compute the <common: intersect> from <first-set> with <second-set>.
    Return an <OK: status> with <common>.
}""",
"set_union": """(All Items: Sets) {
    Compute the <all: union> from <first-set> with <second-set>.
    Return an <OK: status> with <all>.
}""",
"set_difference": """(Only First: Sets) {
    Compute the <only-first: difference> from <first-set> with <second-set>.
    Return an <OK: status> with <only-first>.
}""",
"throw_guard": """(Reject Invalid: Validation) {
    Extract the <value> from the <request: body>.
    Throw a <BadRequest: status> with "value is required" when <value> == "".
    Return an <OK: status> with <value>.
}""",
"configure": """(Set Timeout: Config) {
    Configure the <timeout> with 30.
    Return an <OK: status> with <timeout>.
}""",
"parameters": """(Read Args: CLI) {
    Extract the <name> from the <parameters: name>.
    Log <name> to the <console>.
    Return an <OK: status> with <name>.
}""",
"publish": """(Share Config: Setup) {
    Compute the <port> from 8080.
    Publish as <server-port> <port>.
    Return an <OK: status> with <port>.
}""",
"group": """(Group Orders: Pipeline) {
    Group the <grouped> from the <orders> by <status>.
    Return an <OK: status> with <grouped>.
}""",
"compare": """(Check Sizes: Compare) {
    Compare the <first> against the <second>.
    Return an <OK: status> with <first>.
}""",
"validate": """(Validate Input: Check) {
    Validate the <data> with <schema>.
    Return an <OK: status> with <data>.
}""",
"filter": """(Active Users: Pipeline) {
    Retrieve the <users> from the <user-repository>.
    Filter the <active> from the <users> where <status> = "active".
    Return an <OK: status> with <active>.
}""",
"date_now": """(Timestamp: Time) {
    Retrieve the <now> from the <date>.
    Format the <stamp> from the <now> with "yyyy-MM-dd".
    Return an <OK: status> with <stamp>.
}""",
"render_console": """(Greeting: Template) {
    Extract the <name> from the <request: body>.
    Render the <message> from "Hello, {{name}}!" with { name: <name> }.
    Log <message> to the <console>.
    Return an <OK: status> with <message>.
}""",
"render_html": """(Page: Template) {
    Extract the <title> from the <request: body>.
    Render the <html> from "<h1>{{title}}</h1>" with { title: <title> }.
    Return an <OK: status> with <html>.
}""",
}

if __name__ == "__main__":
    passed, failed = {}, {}
    for name, code in CANDIDATES.items():
        ok, err = config.aro_check_snippet(code, timeout=15)
        if ok:
            passed[name] = code
        else:
            failed[name] = err.replace("\n", " ")[:120]
    print(f"PASS {len(passed)}/{len(CANDIDATES)}: {', '.join(passed)}")
    print("FAIL:")
    for n, e in failed.items():
        print(f"  {n}: {e}")
