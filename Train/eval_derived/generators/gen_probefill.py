#!/usr/bin/env python3
"""Targeted training pairs for the post-release code probes (issue #441).

The published model passes the NB26 gate at 82% syntax-pass (18/22) — 4 complete
programs still fail `aro check`. This generator provides an `aro check`-validated
reference answer (with a `<think>` reasoning trace) for every code-probe topic,
under paraphrased instructions (not the verbatim probe strings, to teach the
pattern rather than memorise the eval). Each answer is re-validated with
`aro check`; the bare-statement REPL probes are kept as-is (they run via `aro`
stdin but aren't feature sets, so NB26 scores them "NO PROGRAM", not "FAIL").
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "probefill.jsonl"

# (cat, [paraphrased instructions], answer_aro, think, needs_check)
PROBES = [
    ("repl_oneliner",
     ["Write a single ARO line that logs 'Hello, World!' to the console.",
      "Give me one ARO statement that logs \"Hello, World!\" to the console."],
     'Log "Hello, World!" to the <console>.',
     "A single log statement: the Log action writes to the `<console>` sink with the `to` preposition. One line, no feature-set wrapper needed for a REPL one-liner.",
     False),
    ("repl_block",
     ["Write ARO statements that create a list of three numbers and log its length.",
      "Show ARO statements that make a list of 3 numbers and log how many there are."],
     'Create the <numbers> with [1, 2, 3].\nCompute the <count: length> from <numbers>.\nLog <count> to the <console>.',
     "Create binds a list literal to `<numbers>`. Compute with the `length` qualifier counts them into a fresh name `<count>` (immutability — new name per result). Log writes it to the console.",
     False),
    ("application",
     ["Write a minimal ARO application that logs Hello World and exits.",
      "Give me the smallest ARO application that logs Hello World."],
     '(Application-Start: Hello) {\n    Log "Hello, World!" to the <console>.\n    Return an <OK: status> for the <startup>.\n}',
     "A minimal app needs exactly one Application-Start feature set. It logs, then every feature set must end with Return or Throw — `Return an <OK: status> for the <startup>`.",
     True),
    ("application",
     ["Write an ARO Application-Start that starts an HTTP server and keeps running with Keepalive.",
      "Write an ARO entry point that starts the HTTP server and stays alive."],
     '(Application-Start: Server) {\n    Start the <http-server> with <contract>.\n    Keepalive the <application> for the <events>.\n    Return an <OK: status> for the <startup>.\n}',
     "Start the http-server with the contract (from openapi.yaml). Keepalive blocks so the event loop keeps processing until SIGINT/SIGTERM. End with Return.",
     True),
    ("application",
     ["Write an ARO Application-End: Success handler that logs a shutdown message.",
      "Write the ARO graceful-shutdown success handler that logs a message."],
     '(Application-End: Success) {\n    Log "Shutting down..." to the <console>.\n    Return an <OK: status> for the <shutdown>.\n}',
     "Application-End: Success is the optional graceful-shutdown handler. It logs, then returns OK for the shutdown.",
     True),
    ("http_api",
     ["Write an ARO feature set named getUser that retrieves a user by ID from the user-repository and returns it as an OK response.",
      "Write the getUser ARO handler: fetch a user by id from the user-repository and return OK."],
     '(getUser: User API) {\n    Extract the <id> from the <pathParameters: id>.\n    Retrieve the <user> from the <user-repository> where <id> = <id>.\n    Return an <OK: status> with <user>.\n}',
     "The feature-set name matches the openapi operationId `getUser`. Extract the path parameter `id`, then Retrieve where the field is angle-bracketed: `where <id> = <id>` (a bare `where id = ...` fails aro check). Return OK with the user.",
     True),
    ("http_api",
     ["Write an ARO feature set named createOrder that extracts the request body, stores a new order, and returns a Created status.",
      "Write the createOrder ARO handler: read the body, store the order, return Created."],
     '(createOrder: Order API) {\n    Extract the <data> from the <request: body>.\n    Create the <order> with <data>.\n    Store the <order> into the <order-repository>.\n    Return a <Created: status> with <order>.\n}',
     "Extract the body, Create the order from it, Store into the repository with the `into` preposition, and Return a Created status.",
     True),
    ("http_api",
     ["Write an ARO feature set named listProducts that retrieves all products and returns them.",
      "Write the listProducts ARO handler that returns every product."],
     '(listProducts: Product API) {\n    Retrieve the <products> from the <product-repository>.\n    Return an <OK: status> with <products>.\n}',
     "Retrieve all products from the repository (no filter), Return OK with the list.",
     True),
    ("event_handler",
     ["Write an ARO event handler that sends a welcome email when a UserCreated event is received.",
      "Write the ARO UserCreated handler that emails a welcome to the new user."],
     '(SendWelcome: UserCreated Handler) {\n    Extract the <user> from the <event: user>.\n    Send the <welcome-email> to the <user: email>.\n    Return an <OK: status> for the <notification>.\n}',
     "Business activity `UserCreated Handler` triggers on that event. Extract the user from the event payload, Send the email to the user's email, Return OK.",
     True),
    ("event_handler",
     ["Write an ARO feature set that emits an OrderPlaced event with the order data.",
      "Write ARO that emits an OrderPlaced event carrying the order."],
     '(PlaceOrder: Order API) {\n    Extract the <order> from the <request: body>.\n    Emit an <OrderPlaced: event> with <order>.\n    Return an <OK: status> with <order>.\n}',
     "Emit puts the event type in the result position with the `: event` qualifier and the payload after `with`.",
     True),
    ("repository",
     ["Write an ARO feature set that observes the user-repository and logs every change.",
      "Write an ARO observer that logs each change to the user-repository."],
     '(AuditUsers: user-repository Observer) {\n    Extract the <change> from the <event: change>.\n    Log <change> to the <console>.\n    Return an <OK: status> with <change>.\n}',
     "Business activity `{repository} Observer` runs on every store/update/delete. Extract the change from the event and log it.",
     True),
    ("repository",
     ["Write an ARO feature set that stores a new record in the sessions-repository and emits a SessionCreated event.",
      "Write ARO that saves a session record and emits SessionCreated."],
     '(CreateSession: Session API) {\n    Extract the <data> from the <request: body>.\n    Create the <session> with <data>.\n    Store the <session> into the <sessions-repository>.\n    Emit a <SessionCreated: event> with <session>.\n    Return a <Created: status> with <session>.\n}',
     "Create the session from the body, Store into the sessions-repository, Emit SessionCreated with the session, Return Created.",
     True),
    ("iteration",
     ["Write an ARO for-each loop that logs each item in a list of names.",
      "Write ARO that iterates a list of names and logs each one."],
     '(LogNames: Name API) {\n    Retrieve the <names> from the <name-repository>.\n    For each <name> in <names> {\n        Log <name> to the <console>.\n    }\n    Return an <OK: status> with <names>.\n}',
     "Iteration is `For each <item> in <collection> { ... }` (two words, not `For-each`). Log each name inside the loop.",
     True),
    ("conditional",
     ["Write an ARO feature set with a When guard that only returns OK when the user role is \"admin\".",
      "Write ARO that returns OK only when the user's role is admin, using a When guard."],
     '(AdminOnly: User API) {\n    Extract the <user> from the <request: body>.\n    Extract the <role> from the <user: role>.\n    Return an <OK: status> with <user> when <role> == "admin".\n}',
     "A When guard gates a statement: `Return ... when <role> == \"admin\"`. Extract the role first, then guard the Return.",
     True),
    ("computation",
     ["Write an ARO feature set that computes the total price from price and quantity and returns it.",
      "Write ARO that multiplies price by quantity and returns the total."],
     '(ComputeTotal: Order API) {\n    Extract the <price> from the <request: price>.\n    Extract the <quantity> from the <request: quantity>.\n    Compute the <total> from <price> * <quantity>.\n    Return an <OK: status> with <total>.\n}',
     "Arithmetic Compute: `Compute the <total> from <price> * <quantity>`. Extract both operands from the request first.",
     True),
    ("user_action",
     ["Define an ARO user-defined action named DoubleValue that doubles a number.",
      "Write an ARO Application.<Name> action called DoubleValue that doubles its input."],
     '(DoubleValue: Action takes <number>) {\n    Extract the <n> from the <input: number>.\n    Compute the <doubled> from <n> * 2.\n    Return an <OK: status> with { doubled: <doubled> }.\n}',
     "Business activity `Action takes <number>` makes it callable as `Application.DoubleValue`. `takes <number>` extracts a single positional arg as `input.number`. Compute and return the object.",
     True),
    ("debugging",
     ["Fix this ARO code so it passes aro check:\n\n```aro\n(listUsers: User API) {\n    Retrieve the <users> from the <user-repository>.\n    Return an <OK: status> with <users>.\n```",
      "This ARO is missing its closing brace — fix it:\n\n```aro\n(listUsers: User API) {\n    Retrieve the <users> from the <user-repository>.\n    Return an <OK: status> with <users>.\n```"],
     '(listUsers: User API) {\n    Retrieve the <users> from the <user-repository>.\n    Return an <OK: status> with <users>.\n}',
     "The feature set is missing its closing `}`. Add it after the Return so the block is balanced.",
     True),
    ("file",
     ["Write an ARO Application-Start that reads a config file and logs its contents.",
      "Write an ARO entry point that reads config.json and logs it."],
     '(Application-Start: Config) {\n    Read the <config> from the <file: "config.json">.\n    Log <config> to the <console>.\n    Return an <OK: status> for the <startup>.\n}',
     "Read the file into `<config>` with the `from the <file: \"...\">` object, log it, return OK.",
     True),
]


def main():
    rows, seen = [], []
    checked = passed = 0
    aro_missing = False
    for cat, instrs, answer, think, needs_check in PROBES:
        if needs_check:
            checked += 1
            ok, err = config.aro_check_snippet(answer, timeout=15)
            if ok is None:
                aro_missing = True
                continue
            if not ok:
                line = err.splitlines()[1].strip()[:60] if err and len(err.splitlines()) > 1 else str(err)[:60]
                print(f"  DROP {cat}: {line}")
                continue
            passed += 1
        output = f"<think>\n{think}\n</think>\n\n```aro\n{answer}\n```"
        for ins in instrs:
            rows.append({
                "instruction": ins, "output": output,
                "category": "code_generation",
                "task_type": "debugging" if cat == "debugging" else "code_generation",
                "probe_cat": cat, "source": "eval_probefill",
            })
    OUT.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate.")
    print(f"probefill: {checked} checked, {passed} aro-check-passed -> {len(rows)} pairs -> {OUT.name}")


if __name__ == "__main__":
    main()
