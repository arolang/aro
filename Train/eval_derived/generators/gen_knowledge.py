#!/usr/bin/env python3
"""Curated, accurate ARO knowledge / syntax_qa pairs. Facts are hand-curated
from CLAUDE.md + proposals (not the noisy auto verb map), each rendered in a few
question phrasings. Accuracy matters more than volume here — wrong knowledge
poisons training."""
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "knowledge.jsonl"

ROLES = {
    "REQUEST (External → Internal)": ["Extract", "Parse", "Retrieve", "Fetch", "Probe", "Pull", "Clone"],
    "OWN (Internal → Internal)": ["Compute", "Validate", "Compare", "Create", "Transform", "Stage", "Checkout"],
    "RESPONSE (Internal → External)": ["Return", "Throw"],
    "EXPORT (makes symbols global / exports data)": ["Publish", "Store", "Log", "Send", "Emit", "Commit", "Push", "Tag"],
}

# Canonical prepositions (curated from CLAUDE.md action tables — deliberately
# excludes the auto-map's spurious Log→for).
PREPS = {
    "Log": ["to"], "Retrieve": ["from"], "Store": ["in", "into"], "Emit": ["with"],
    "Commit": ["to", "with"], "Stage": ["to", "for"], "Extract": ["from"],
    "Return": ["with", "for"], "Push": ["to", "with"], "Pull": ["from"],
    "Clone": ["from", "with", "to"], "Checkout": ["from", "to", "with"], "Tag": ["for", "with"],
}

# (question, answer) curated concept facts.
CONCEPTS = [
    ("What is a feature set in ARO?",
     "A feature set is a named block `(Name: Business Activity) { ... }` containing ARO statements. It is triggered by an event that matches its business activity, not called directly."),
    ("How many Application-Start feature sets can an ARO application have?",
     "Exactly one. `Application-Start` is the entry point; zero or more than one is an error."),
    ("What triggers a feature set in ARO?",
     "Events. A feature set runs when an event matches its business activity — an HTTP route (operationId), a custom `{Event} Handler`, a `{repository} Observer`, or a file/socket event."),
    ("Are ARO variables mutable?",
     "No. ARO variables are immutable — you cannot rebind a name. Introduce a new name instead, e.g. via the qualifier-as-name form."),
    ("What is the 'code is the error message' philosophy?",
     "ARO code contains only the happy case. Errors are handled by the runtime, which reports what failed (e.g. 'Can not retrieve the user from the user-repository where id = 530')."),
    ("How does contract-first HTTP work in ARO?",
     "HTTP routes are defined in `openapi.yaml`, and feature sets are named after `operationId` values. Without `openapi.yaml` the HTTP server does not start."),
    ("How do you write a comment in ARO?",
     "With `(* ... *)`."),
    ("What operator does ARO use for string concatenation?",
     "`++`. The `+` operator is arithmetic only; mixing string operands with `+` is an error."),
    ("What does the Keepalive action do?",
     "It blocks execution until a shutdown signal (SIGINT/SIGTERM) is received, letting the event loop process incoming events so servers and watchers stay alive."),
    ("What is a repository observer in ARO?",
     "A feature set whose business activity is `{repository-name} Observer`. It runs automatically when that repository changes (store/update/delete)."),
    ("How are path parameters extracted in ARO?",
     "From `pathParameters`, e.g. `Extract the <id> from the <pathParameters: id>.`"),
    ("How is the request body extracted in an ARO handler?",
     "`Extract the <data> from the <request: body>.`"),
    ("What is lazy execution in ARO?",
     "Actions return an `AROFuture` handle rather than the resolved value; the work is forced the first time something reads the value (a Return, an Emit payload, a When guard, an export, etc.)."),
    ("What is a user-defined action in ARO?",
     "A feature set whose business activity is `Action` becomes callable application-wide as `Application.<Name>` from any other feature set."),
    ("What are the four action roles in ARO?",
     "REQUEST (external→internal), OWN (internal→internal), RESPONSE (internal→external), and EXPORT (makes symbols global or exports data)."),
    ("Does every feature set need a Return or Throw?",
     "Yes. Every feature set must end with a Return or a Throw."),
    ("How do you emit a custom event in ARO?",
     "`Emit a <SomethingCreated: event> with <payload>.` — the event type goes in the result position with a `: event` qualifier and the payload follows `with`."),
    ("How do you keep an application running to process events?",
     "Use the Keepalive action: `Keepalive the <application> for the <events>.`"),
    ("What is a store file in ARO?",
     "A `.store` file that seeds a repository with YAML data; it is read-only unless made writable (chmod o+w)."),
    ("What Compute operations does ARO support?",
     "length/count, uppercase, lowercase, hash, and arithmetic (+, -, *, /, %). Use the qualifier-as-name form for multiple results of the same operation."),
]

PARAPHRASE = ["{q}", "In ARO, {q_lower}", "Explain: {q_lower}", "Question about ARO: {q}"]

# Proposal one-line topics (from CLAUDE.md proposal index).
PROPOSALS = {
    "ARO-0001": "Language fundamentals — core syntax, literals, expressions, scoping",
    "ARO-0002": "Control flow — When guards, match expressions, iteration",
    "ARO-0003": "Type system — types, OpenAPI integration, schemas",
    "ARO-0004": "Actions — action roles, built-in actions, extensions",
    "ARO-0005": "Application architecture — app structure, lifecycle, concurrency",
    "ARO-0006": "Error philosophy — 'code is the error message'",
    "ARO-0007": "Events & reactive — events, state, repositories",
    "ARO-0008": "I/O services — HTTP, files, sockets, system objects",
    "ARO-0009": "Native compilation — LLVM, aro build, plugins in binaries",
    "ARO-0010": "Advanced features — regex, dates, exec",
    "ARO-0011": "HTML/XML parsing — the Parse action for HTML/XML documents",
    "ARO-0015": "Testing framework — colocated tests, Given/When/Then",
    "ARO-0018": "Data pipelines — filter, transform, aggregate, group collections",
    "ARO-0022": "State guards — event handler filtering with field:value syntax",
    "ARO-0036": "Extended file operations — Exists, Stat, Make, Copy, Move actions",
    "ARO-0037": "Regex split — the Split action with regex delimiters",
    "ARO-0040": "Format-aware I/O — auto format detection for JSON, YAML, CSV",
    "ARO-0041": "Date/time ranges — date arithmetic, ranges, recurrence patterns",
    "ARO-0042": "Set operations — intersect, difference, union on collections",
    "ARO-0043": "Sink syntax — expressions in result position",
    "ARO-0044": "Runtime metrics — execution counts, timing, Prometheus format",
    "ARO-0047": "Command-line parameters — CLI argument parsing, Parameters action",
    "ARO-0048": "WebSocket — WebSocket server support, real-time messaging",
    "ARO-0050": "Template engine — Mustache-style templates, Render action",
    "ARO-0051": "Streaming execution — lazy evaluation, Stream Tee, aggregation fusion",
    "ARO-0073": "Store files — file-backed repositories, YAML seed data",
    "ARO-0080": "Git actions — native Git via libgit2: status, stage, commit, push, pull",
    "ARO-0081": "User-defined actions — feature sets callable as Application.<Name>",
}

# Extra curated concepts (accurate, from CLAUDE.md + proposals).
CONCEPTS2 = [
    ("How do you iterate over a collection in ARO?",
     "With `For-each <item> in <collection> { ... }`. There is no `while` loop; For-each is the iteration construct."),
    ("What is a When guard in ARO?",
     "A conditional that gates a statement, e.g. `Throw a <BadRequest: status> with \"...\" when <value> == \"\".`"),
    ("How do you start an HTTP server in ARO?",
     "In Application-Start: `Start the <http-server> with <contract>.` — the contract comes from openapi.yaml."),
    ("What does the Publish action do?",
     "It makes a variable globally accessible to other feature sets: `Publish as <alias> <variable>.`"),
    ("What is the difference between Emit and Publish?",
     "Emit fires a domain event that triggers handler feature sets; Publish exposes a variable's value globally to other feature sets. Emit is for events, Publish is for shared state."),
    ("How do you read a file in ARO?",
     "`Read the <content> from the <file: \"path.txt\">.`"),
    ("How do you write a file in ARO?",
     "`Write the <content> to the <file: \"path.txt\">.`"),
    ("How do you compute the length of a string in ARO?",
     "`Compute the <len: length> from <text>.` — use the qualifier-as-name form when you need multiple lengths."),
    ("How do you hash a value in ARO?",
     "`Compute the <digest: hash> from <password>.`"),
    ("How do you commit changes with the git system object?",
     "`Stage the <files> to the <git> with \".\".` then `Commit the <result> to the <git> with \"message\".`"),
    ("What events do git actions emit?",
     "GitCommit, GitPush, GitPull, GitCheckout, GitTag, and GitClone."),
    ("How do you compute the intersection of two sets in ARO?",
     "`Compute the <common: intersect> from <set-a> with <set-b>.` Union and difference use the same shape with `union`/`difference`."),
    ("How do you render a template in ARO?",
     "`Render the <output> from \"Hello, {{name}}!\" with { name: <name> }.` — Mustache-style placeholders."),
    ("How do you throw an error in ARO?",
     "`Throw a <BadRequest: status> with \"message\".` optionally guarded with `when <cond>`."),
    ("How do you return a Created status with a value?",
     "`Return a <Created: status> with <value>.`"),
    ("How do you group a collection by a field in ARO?",
     "`Group the <groups> from the <items> by \"field\".`"),
    ("How do you filter a collection in ARO?",
     "`Filter the <matches> from the <items> where <field> = \"value\".`"),
    ("What is the qualifier-as-name syntax?",
     "It separates the variable name from the operation using a colon, e.g. `Compute the <first-length: length> from <a>.` so you can have multiple results of the same operation."),
    ("How do you call a user-defined action?",
     "`Application.<Name> the <result> from <input>.` — same call shape as a plugin action."),
    ("How do you observe repository changes?",
     "Name a feature set `(Audit: <repository-name> Observer)`; it runs on store/update/delete of that repository."),
    ("How do you read a command-line parameter in ARO?",
     "`Extract the <name> from the <parameters: name>.`"),
    ("How do you send a message over a websocket?",
     "`Send the <message> to the <websocket>.`"),
    ("How do you expose Prometheus metrics in ARO?",
     "Log to a metrics counter; the runtime exposes counts/timing in Prometheus format (ARO-0044)."),
    ("How do you configure a runtime timeout?",
     "`Configure the <timeout> with 30.` (ARO-0035)."),
    ("What is the happy-case rule for production code?",
     "ARO's happy-case model is intentionally insecure for production — it omits error handling because the runtime reports failures. Do not use it for production as-is."),
    ("How are feature sets discovered in an ARO application?",
     "All `.aro` files in the directory and its subdirectories are discovered and parsed automatically; no imports are needed."),
    ("What makes a feature set an HTTP route handler?",
     "Its name matches an `operationId` in openapi.yaml."),
    ("How do you stop an HTTP server gracefully?",
     "In an Application-End handler: `Stop the <http-server> with <application>.`"),
]


def emit(f, q, a, cat="syntax_qa"):
    seen = set()
    for p in PARAPHRASE:
        ql = q[0].lower() + q[1:]
        inst = p.format(q=q, q_lower=ql)
        if inst in seen:
            continue
        seen.add(inst)
        f.write(json.dumps({
            "instruction": inst, "output": a,
            "category": cat, "task_type": cat, "source": "eval_gen_knowledge",
        }) + "\n")


def main():
    n = 0
    with open(OUT, "w") as f:
        # role Q&A
        for role, verbs in ROLES.items():
            rname = role.split(" ")[0]
            for v in verbs:
                emit(f, f"What is the action role of the {v} action in ARO?",
                     f"`{v}` is a {rname}-role action — {role.split('(')[1].rstrip(') ')}.")
                n += 1
        # preposition Q&A
        for v, ps in PREPS.items():
            emit(f, f"Which prepositions does the {v} action use in ARO?",
                 f"`{v}` uses: {', '.join('`'+p+'`' for p in ps)}.")
            n += 1
        # concepts
        for q, a in CONCEPTS + CONCEPTS2:
            emit(f, q, a)
            n += 1
        # proposals
        for pid, topic in PROPOSALS.items():
            emit(f, f"What does {pid} cover in ARO?", f"{pid} covers {topic}.", cat="knowledge")
            n += 1
    total = sum(1 for _ in open(OUT))
    print(f"knowledge concepts/roles/preps: {n} facts -> {total} pairs (with paraphrases)")


if __name__ == "__main__":
    main()
