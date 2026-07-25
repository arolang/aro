#!/usr/bin/env python3
"""Gap-fill generator: heavily-validated training examples for the exact domains
the 4,000-prompt eval showed the model fails (conditionals 0%, error 2%, publish
3%, config 7%, rest 19%, git 24%, validation 25%, state 33%, collections 46%,
response 54%). Canonical templates (verified with aro check) × entities ×
instruction phrasings; every emitted answer is re-validated with aro check."""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/Users/kris/Projects/ARO/ARO-Lang/Train/script")
import config  # noqa: E402

OUT = HERE / "gapfill.jsonl"
ENTS = ["user", "order", "product", "invoice", "customer", "payment", "ticket",
        "account", "booking", "device", "review", "shipment", "task", "project"]
FIELDS = ["status", "email", "name", "amount", "total", "role", "level", "state"]


def cap(s):
    return s[0].upper() + s[1:]


# domain -> (instruction templates, answer builder(e, f))
def when_guard(e, f):
    return f"""(Filter{cap(e)}: {cap(e)} API) {{
    Retrieve the <{e}> from the <{e}-repository>.
    Return an <OK: status> with <{e}> when <active>.
}}"""


def error_throw(e, f):
    return f"""(Validate{cap(e)}: {cap(e)} API) {{
    Extract the <data> from the <request: body>.
    Throw a <BadRequest: status> with "{f} is required" when <{f}> == "".
    Return an <OK: status> with <data>.
}}"""


def publish_(e, f):
    return f"""(Share{cap(e)}: Setup) {{
    Compute the <{e}-count: count> from the <{e}s>.
    Publish as <{e}-total> <{e}-count>.
    Return an <OK: status> with <{e}-count>.
}}"""


def config_(e, f):
    return f"""(Configure{cap(e)}: Setup) {{
    Configure the <timeout> with 30.
    Return an <OK: status> with <timeout>.
}}"""


def validation_(e, f):
    # Immutability: each binding gets a fresh name (extract->input, validate->validated).
    return f"""(Check{cap(e)}: {cap(e)} API) {{
    Extract the <input> from the <request: body>.
    Validate the <validated> with <input>.
    Throw a <BadRequest: status> with "invalid" when <input> == "".
    Return an <OK: status> with <validated>.
}}"""


def state_(e, f):
    return f"""(Advance{cap(e)}: {cap(e)}Placed Handler) {{
    Extract the <{e}> from the <event: {e}>.
    Accept the <transition> for the <{e}> with "shipped".
    Return an <OK: status> with <{e}>.
}}"""


def iteration_(e, f):
    return f"""(Process{cap(e)}s: {cap(e)} API) {{
    Retrieve the <{e}s> from the <{e}-repository>.
    For each <{e}> in <{e}s> {{
        Log <{e}> to the <console>.
    }}
    Return an <OK: status> with <{e}s>.
}}"""


def collections_(e, f):
    return f"""(Active{cap(e)}s: {cap(e)} API) {{
    Retrieve the <{e}s> from the <{e}-repository>.
    Filter the <active> from the <{e}s> where <{f}> = "active".
    Return an <OK: status> with <active>.
}}"""


def group_(e, f):
    return f"""(Group{cap(e)}s: {cap(e)} API) {{
    Retrieve the <{e}s> from the <{e}-repository>.
    Group the <groups> from the <{e}s> by "{f}".
    Return an <OK: status> with <groups>.
}}"""


def update_(e, f):
    return f"""(Update{cap(e)}: {cap(e)} API) {{
    Extract the <key> from the <pathParameters: id>.
    Extract the <data> from the <request: body>.
    Retrieve the <{e}> from the <{e}-repository> where <id> is <key>.
    Update the <{e}> with <data>.
    Return an <OK: status> with <{e}>.
}}"""


def delete_(e, f):
    return f"""(Delete{cap(e)}: {cap(e)} API) {{
    Extract the <key> from the <pathParameters: id>.
    Delete the <{e}> from the <{e}-repository> where <id> is <key>.
    Return an <OK: status> with <{e}>.
}}"""


def response_created(e, f):
    return f"""(Create{cap(e)}: {cap(e)} API) {{
    Extract the <data> from the <request: body>.
    Create the <{e}> with <data>.
    Store the <{e}> into the <{e}-repository>.
    Return a <Created: status> with <{e}>.
}}"""


def git_commit(e, f):
    return """(CommitWork: Repo) {
    Stage the <files> to the <git> with ".".
    Commit the <result> to the <git> with "feat: update".
    Return an <OK: status> with <result>.
}"""


DOMAINS = {
    "conditionals": (["Write an ARO feature set that returns a {e} only when it is active (use a when guard).",
                      "Show me an ARO when guard on a {e} handler.",
                      "How do I add a when guard in ARO for {e}s?"], when_guard),
    "error": (["Write an ARO feature set that throws BadRequest when the {f} of a {e} is empty.",
               "Add error handling (Throw) to a {e} handler in ARO.",
               "How do I throw an error in ARO when {f} is missing?"], error_throw),
    "publish": (["Write an ARO feature set that publishes the {e} count for other feature sets.",
                 "How do I publish a variable across feature sets in ARO for {e}s?"], publish_),
    "config": (["Write an ARO feature set that configures a runtime timeout.",
                "How do I configure a runtime setting in ARO?"], config_),
    "validation": (["Write an ARO feature set that validates {e} input and rejects it when empty.",
                    "How do I validate input data in ARO for a {e}?"], validation_),
    "state": (["Write an ARO state-machine handler that accepts a shipped transition for a {e}.",
               "How do I accept a state transition in ARO for a {e}?"], state_),
    "iteration": (["Write an ARO feature set that iterates over {e}s and logs each one.",
                   "How do I loop over a list of {e}s in ARO?"], iteration_),
    "collections": (["Write an ARO feature set that filters {e}s by {f}.",
                     "How do I filter a list of {e}s in ARO?"], collections_),
    "group": (["Write an ARO feature set that groups {e}s by {f}.",
               "How do I group a collection of {e}s by {f} in ARO?"], group_),
    "update": (["Write an ARO handler that updates a {e} by id from the request body.",
                "How do I update a {e} in a repository in ARO?"], update_),
    "delete": (["Write an ARO handler that deletes a {e} by id.",
                "How do I delete a {e} from a repository in ARO?"], delete_),
    "response": (["Write an ARO handler that creates a {e} and returns Created.",
                  "How do I return a Created status with a {e} in ARO?"], response_created),
    "git": (["Write an ARO feature set that stages and commits changes to git.",
             "How do I commit changes via the git system object in ARO?"], git_commit),
}


def main():
    n, seen = 0, set()
    with open(OUT, "w") as f:
        for domain, (instrs, builder) in DOMAINS.items():
            for i, e in enumerate(ENTS):
                fld = FIELDS[i % len(FIELDS)]
                answer = builder(e, fld)
                ok, err = config.aro_check_snippet(answer, timeout=15)
                if not ok:
                    print(f"SKIP {domain}/{e}: {err.splitlines()[1].strip()[:50] if err else ''}")
                    continue
                for tmpl in instrs:
                    ins = tmpl.replace("{e}", e).replace("{f}", fld)
                    key = ins
                    if key in seen:
                        continue
                    seen.add(key)
                    f.write(json.dumps({
                        "instruction": ins,
                        "output": f"```aro\n{answer}\n```",
                        "category": "code_generation" if "Write" in tmpl or "How" in tmpl else "syntax_qa",
                        "task_type": "code_generation",
                        "domain": domain,
                        "source": "eval_gapfill",
                    }) + "\n")
                    n += 1
    print(f"gapfill pairs: {n}")


if __name__ == "__main__":
    main()
