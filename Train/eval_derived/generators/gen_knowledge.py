#!/usr/bin/env python3
"""Grounded ARO knowledge / syntax_qa pairs (issue #437).

Every answer is grounded in an authoritative source and cites it:
  * per-verb role + preposition Q&A come straight from the runtime
    ActionRegistry catalog (aro_action_catalog.json, via extract_action_catalog.py),
    so they can never drift from the code.
  * per-proposal Q&A read the real title + summary from Proposals/ARO-*.md.
  * curated concept facts (from CLAUDE.md + proposals) carry a source citation.

Each emitted pair also carries a `facts` list (the backtick-delimited spans the
answer asserts) and a `grounding` source, so NB19's fact-checked judge and any
downstream gate can verify the answer reproduces the grounded facts rather than
merely overlapping tokens. Accuracy matters more than volume — wrong knowledge
poisons training."""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
OUT = HERE / "knowledge.jsonl"

# ── authoritative action catalog (role / prepositions / aliases) ────────────
try:
    import extract_action_catalog
    CATALOG = extract_action_catalog.load()
except Exception:
    CATALOG = json.loads((REPO / "Train" / "script" / "aro_action_catalog.json").read_text())

PARAPHRASE = ["{q}", "In ARO, {q_lower}", "Explain: {q_lower}", "Question about ARO: {q}"]


def _facts(answer):
    """The checkable facts an answer asserts: its backtick-delimited spans plus
    any ARO-#### proposal ids. NB19 verifies these appear in the model's reply."""
    spans = [s.strip() for s in re.findall(r"`([^`]+)`", answer) if s.strip()]
    props = re.findall(r"ARO-\d{4}", answer)
    seen, out = set(), []
    for f in spans + props:
        if f.lower() not in seen:
            seen.add(f.lower())
            out.append(f)
    return out


# ── per-proposal grounding: read real titles + summaries ────────────────────
def load_proposals():
    props = {}
    for f in sorted((REPO / "Proposals").glob("ARO-*.md")):
        text = f.read_text(errors="ignore")
        title_m = re.search(r"^#\s+(ARO-\d{4}):\s*(.+)$", text, re.M)
        if not title_m:
            continue
        pid, title = title_m.group(1), title_m.group(2).strip()
        # first prose line after the title/metadata block (skip headings, meta,
        # tables, list markers, and blank lines)
        summary = ""
        for line in text[title_m.end():].splitlines():
            s = line.strip()
            if not s or s.startswith(("#", "|", "-", "*", ">", "`")) or ":" in s[:12] and s.split(":")[0] in (
                    "Status", "Author", "Created", "Type", "Proposal", "Champion"):
                continue
            summary = re.sub(r"\s+", " ", s)
            break
        props[pid] = {"title": title, "summary": summary, "file": f"Proposals/{f.name}"}
    return props


PROPOSALS = load_proposals()

# ── curated concept facts (accurate, from CLAUDE.md + proposals) ────────────
CONCEPTS = [
    ("What is a feature set in ARO?",
     "A feature set is a named block `(Name: Business Activity) { ... }` containing ARO statements. It is triggered by an event that matches its business activity, not called directly."),
    ("How many Application-Start feature sets can an ARO application have?",
     "Exactly one. `Application-Start` is the entry point; zero or more than one is an error."),
    ("What triggers a feature set in ARO?",
     "Events. A feature set runs when an event matches its business activity — an HTTP route (`operationId`), a custom `{Event} Handler`, a `{repository} Observer`, or a file/socket event."),
    ("Are ARO variables mutable?",
     "No. ARO variables are immutable — you cannot rebind a name. Introduce a new name instead, e.g. via the qualifier-as-name form."),
    ("What is the 'code is the error message' philosophy?",
     "ARO code contains only the happy case. Errors are handled by the runtime, which reports what failed (e.g. `Can not retrieve the user from the user-repository where id = 530`)."),
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
    ("What are the action roles in ARO?",
     "REQUEST (external→internal), OWN (internal→internal), RESPONSE (internal→external), EXPORT (makes symbols global or exports data), and SERVER (service lifecycle)."),
    ("Does every feature set need a Return or Throw?",
     "Yes. Every feature set must end with a `Return` or a `Throw`."),
    ("How do you emit a custom event in ARO?",
     "`Emit a <SomethingCreated: event> with <payload>.` — the event type goes in the result position with a `: event` qualifier and the payload follows `with`."),
    ("How do you keep an application running to process events?",
     "Use the Keepalive action: `Keepalive the <application> for the <events>.`"),
    ("What is a store file in ARO?",
     "A `.store` file that seeds a repository with YAML data; it is read-only unless made writable (chmod o+w)."),
    ("What Compute operations does ARO support?",
     "`length`/`count`, `uppercase`, `lowercase`, `hash`, and arithmetic (`+`, `-`, `*`, `/`, `%`). Use the qualifier-as-name form for multiple results of the same operation."),
    ("How do you iterate over a collection in ARO?",
     "With `For-each <item> in <collection> { ... }`. There is no `while` loop; For-each is the iteration construct."),
    ("What is a When guard in ARO?",
     "A conditional that gates a statement, e.g. `Throw a <BadRequest: status> with \"...\" when <value> == \"\".`"),
    ("How do you start an HTTP server in ARO?",
     "In Application-Start: `Start the <http-server> with <contract>.` — the contract comes from `openapi.yaml`."),
    ("What does the Publish action do?",
     "It makes a variable globally accessible to other feature sets: `Publish as <alias> <variable>.`"),
    ("What is the difference between Emit and Publish?",
     "`Emit` fires a domain event that triggers handler feature sets; `Publish` exposes a variable's value globally to other feature sets. Emit is for events, Publish is for shared state."),
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
     "`GitCommit`, `GitPush`, `GitPull`, `GitCheckout`, `GitTag`, and `GitClone`."),
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
    ("How do you configure a runtime timeout?",
     "`Configure the <timeout> with 30.`"),
    ("How are feature sets discovered in an ARO application?",
     "All `.aro` files in the directory and its subdirectories are discovered and parsed automatically; no imports are needed."),
    ("What makes a feature set an HTTP route handler?",
     "Its name matches an `operationId` in `openapi.yaml`."),
    ("How do you stop an HTTP server gracefully?",
     "In an Application-End handler: `Stop the <http-server> with <application>.`"),
]

# concept → authoritative source citation (keyword-routed; all are in CLAUDE.md).
_SRC_KEYWORDS = [
    (("operationId", "openapi", "http route", "route handler", "contract-first"), "ARO-0005 / CLAUDE.md · Contract-First HTTP"),
    (("arofuture", "lazy"), "CLAUDE.md · Lazy Execution"),
    (("keepalive",), "CLAUDE.md · Long-Running Applications"),
    (("git", "gitcommit", "stage the"), "ARO-0080 · Git Actions"),
    (("application.<name>", "user-defined action"), "ARO-0081 · User-Defined Actions"),
    (("happy case", "error message", "code contains only"), "ARO-0006 · Error Philosophy"),
    (("observer", "repository changes"), "ARO-0007 · Events & Reactive"),
    (("for-each", "when guard", "match"), "ARO-0002 · Control Flow"),
    (("intersect", "union", "difference"), "ARO-0042 · Set Operations"),
    (("render", "{{", "template"), "ARO-0050 · Template Engine"),
    (("store file", ".store"), "ARO-0073 · Store Files"),
    (("websocket",), "ARO-0048 · WebSocket"),
    (("parameters:", "command-line"), "ARO-0047 · Command-Line Parameters"),
    (("configure the",), "ARO-0035 · Configurable Runtime"),
    (("immutable", "qualifier-as-name", "compute", "length", "hash", "concatenation", "++"), "ARO-0001 · Language Fundamentals"),
    (("action role", "roles in aro", "return or", "publish"), "ARO-0004 · Actions"),
]


def concept_source(answer):
    low = answer.lower()
    for kws, src in _SRC_KEYWORDS:
        if any(k in low for k in kws):
            return src
    return "CLAUDE.md"


def emit(f, q, a, cat="syntax_qa", grounding=None):
    grounding = grounding or concept_source(a)
    facts = _facts(a)
    seen = set()
    n = 0
    for p in PARAPHRASE:
        ql = q[0].lower() + q[1:]
        inst = p.format(q=q, q_lower=ql)
        if inst in seen:
            continue
        seen.add(inst)
        f.write(json.dumps({
            "instruction": inst, "output": a,
            "category": cat, "task_type": cat, "source": "eval_gen_knowledge",
            "grounding": grounding, "facts": facts,
        }) + "\n")
        n += 1
    return n


def main():
    facts_written = 0
    with open(OUT, "w") as f:
        # per-verb role + preposition Q&A — authoritative, from the catalog
        for verb, meta in CATALOG.items():
            V = verb.capitalize()
            src = f"ActionRegistry ({meta['source']})"
            role_label = meta["role_label"]
            aliases = ", ".join(f"`{a}`" for a in meta["aliases"])
            emit(f, f"What is the action role of the {V} action in ARO?",
                 f"`{V}` has the {meta['role'].upper()} role — {role_label}. "
                 f"Aliases: {aliases}. (Source: {src}.)", grounding=src)
            preps = ", ".join(f"`{p}`" for p in meta["prepositions"]) or "(none)"
            emit(f, f"Which prepositions does the {V} action use in ARO?",
                 f"`{V}` accepts the prepositions {preps}. (Source: {src}.)", grounding=src)
            facts_written += 2
        # curated concept facts
        for q, a in CONCEPTS:
            emit(f, q, a)
            facts_written += 1
        # per-proposal Q&A grounded in the actual proposal file
        for pid, meta in PROPOSALS.items():
            ans = f"{pid} — *{meta['title']}*."
            if meta["summary"]:
                ans += f" {meta['summary']}"
            ans += f" (Source: {meta['file']}.)"
            emit(f, f"What does {pid} cover in ARO?", ans,
                 cat="knowledge", grounding=meta["file"])
            facts_written += 1
    total = sum(1 for _ in open(OUT))
    print(f"knowledge: {facts_written} grounded facts "
          f"({len(CATALOG)} actions×2 + {len(CONCEPTS)} concepts + {len(PROPOSALS)} proposals) "
          f"-> {total} pairs (with paraphrases)")


if __name__ == "__main__":
    main()
