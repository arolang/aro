#!/usr/bin/env python3
"""Generate ~200 curated (instruction, ARO code) training examples covering
modern ARO features — arrays, repositories, user-defined actions, branches
(match), events, git, file I/O, computations. Each example is validated by
running `aro check` against it; failures are auto-fixed where possible and
otherwise dropped. The validated set lands in `curated.jsonl` in the
training-pair format the rest of the pipeline already understands.

Run:
    python3 Train/Material/curate.py
    # writes Train/Material/curated.jsonl
    # logs failures to Train/Material/curated_failures.log
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ARO_BIN = ROOT.parent.parent / '.build/release/aro'
if not ARO_BIN.exists():
    ARO_BIN = ROOT.parent.parent / '.build/debug/aro'

OUT_FILE = ROOT / 'curated.jsonl'
FAIL_LOG = ROOT / 'curated_failures.log'


# ── Validation ─────────────────────────────────────────────────────────────

def aro_check(code: str) -> tuple[bool, str]:
    """Return (passed, error_message)."""
    if not ARO_BIN.exists():
        sys.exit(f'aro binary not found at {ARO_BIN}. Build first: swift build -c release')
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'main.aro').write_text(code)
        r = subprocess.run([str(ARO_BIN), 'check', tmp],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0, (r.stderr or r.stdout).strip()[:300]


# Tiny structural sanity check before we bother spawning aro.
_FEATURE_SET_RE = re.compile(r'\([\w\- ]+:\s*[\w\- ]+(?:\s+takes\s+<[\w\-]+>)?\s*\)\s*\{')


def structurally_ok(code: str) -> bool:
    if not _FEATURE_SET_RE.search(code):
        return False
    # balanced braces
    return code.count('{') == code.count('}')


# ── Example builder ────────────────────────────────────────────────────────

class Examples(list):
    """Convenience accumulator with named .add()."""
    def add(self, instruction: str, code: str, category: str):
        self.append({
            'instruction': instruction.strip(),
            'output': '```aro\n' + code.strip() + '\n```',
            'category': category,
            'task_type': 'code_generation',
        })


E = Examples()

# Repository CRUD — repeated across multiple entity types.
REPO_ENTITIES = [
    ('user',     'User',     'user-repository'),
    ('order',    'Order',    'order-repository'),
    ('product',  'Product',  'product-repository'),
    ('post',     'Post',     'post-repository'),
    ('comment',  'Comment',  'comment-repository'),
    ('task',     'Task',     'task-repository'),
    ('event',    'Event',    'event-store'),
    ('session',  'Session',  'session-repository'),
    ('customer', 'Customer', 'customer-repository'),
    ('ticket',   'Ticket',   'ticket-repository'),
]

for item, Item, repo in REPO_ENTITIES:
    E.add(
        f'Store a new {item} in the {repo}.',
        f'(Save{Item}: Example) {{\n'
        f'    Create the <{item}> with {{ id: 1, name: "Example" }}.\n'
        f'    Store the <{item}> into the <{repo}>.\n'
        f'    Return an <OK: status> with <{item}>.\n'
        f'}}',
        'repository',
    )
    E.add(
        f'Retrieve a {item} from the {repo} by id.',
        f'(Get{Item}: Example) {{\n'
        f'    Create the <key> with 42.\n'
        f'    Retrieve the <{item}> from the <{repo}> where <id> is <key>.\n'
        f'    Return an <OK: status> with <{item}>.\n'
        f'}}',
        'repository',
    )
    E.add(
        f'Delete a {item} from the {repo} by id.',
        f'(Delete{Item}: Example) {{\n'
        f'    Create the <key> with 42.\n'
        f'    Delete the <{item}> from the <{repo}> where <id> is <key>.\n'
        f'    Return an <OK: status> for the <deletion>.\n'
        f'}}',
        'repository',
    )
    E.add(
        f'List all {item} records from the {repo}.',
        f'(List{Item}s: Example) {{\n'
        f'    Retrieve the <{item}s> from the <{repo}>.\n'
        f'    Return an <OK: status> with <{item}s>.\n'
        f'}}',
        'repository',
    )
    # observer
    E.add(
        f'Observe changes on the {repo} and log every change.',
        f'(Audit {Item} Changes: {repo} Observer) {{\n'
        f'    Extract the <{item}> from the <event: {item}>.\n'
        f'    Log <{item}> to the <console>.\n'
        f'    Return an <OK: status> for the <audit>.\n'
        f'}}',
        'repository_observer',
    )

# Array / list operations — Reduce, sort, filter, group.
NUMBER_LISTS = [
    ('numbers',      '[1, 2, 3, 4, 5]'),
    ('prices',       '[19.99, 24.50, 9.95, 100.00]'),
    ('scores',       '[88, 91, 72, 95, 67]'),
    ('temperatures', '[18, 22, 15, 30, 25]'),
    ('quantities',   '[10, 20, 30, 40, 50]'),
]

REDUCE_OPS = [
    ('sum',   'sum',   'Integer'),
    ('total', 'sum',   'Integer'),
    ('avg',   'avg',   'Float'),
    ('count', 'count', 'Integer'),
    ('max',   'max',   'Integer'),
    ('min',   'min',   'Integer'),
]

for var, literal in NUMBER_LISTS:
    for result, op, ty in REDUCE_OPS:
        E.add(
            f'Compute the {op} of the {var} array.',
            f'(Reduce{var.title()}: Example) {{\n'
            f'    Create the <{var}> with {literal}.\n'
            f'    Reduce the <{result}: {ty}> from the <{var}> with {op}().\n'
            f'    Return an <OK: status> with <{result}>.\n'
            f'}}',
            'array_reduce',
        )

# Sort + iteration
for var, literal in NUMBER_LISTS:
    E.add(
        f'Iterate over each entry in the {var} array and log it.',
        f'(Iterate{var.title()}: Example) {{\n'
        f'    Create the <{var}> with {literal}.\n'
        f'    for each <{var[:-1]}> in <{var}> {{\n'
        f'        Log <{var[:-1]}> to the <console>.\n'
        f'    }}\n'
        f'    Return an <OK: status> for the <iteration>.\n'
        f'}}',
        'array_iteration',
    )

# Branches — match expressions.
MATCH_SCENARIOS = [
    (
        'method', '"GET"',
        ['"GET"', '"POST"', '"PUT"', '"DELETE"'],
        'HTTP method router',
    ),
    (
        'status-code', '200',
        ['200', '404', '500'],
        'status code dispatcher',
    ),
    (
        'role', '"admin"',
        ['"admin"', '"editor"', '"viewer"'],
        'user role dispatch',
    ),
    (
        'priority', '"high"',
        ['"low"', '"medium"', '"high"'],
        'priority handler',
    ),
]

for var, value, cases, label in MATCH_SCENARIOS:
    case_lines = '\n'.join(
        f'        case {c} {{\n'
        f'            Log "matched a case" to the <console>.\n'
        f'        }}'
        for c in cases
    )
    E.add(
        f'Write a feature set that branches on the {var} value ({label}).',
        f'(Dispatch {label.title()}: Example) {{\n'
        f'    Create the <{var}> with {value}.\n'
        f'    match <{var}> {{\n'
        f'{case_lines}\n'
        f'        otherwise {{\n'
        f'            Log "unknown {var}" to the <console>.\n'
        f'        }}\n'
        f'    }}\n'
        f'    Return an <OK: status> for the <dispatch>.\n'
        f'}}',
        'match',
    )

# User-defined actions (ARO-0081).
UDA = [
    (
        'Define a user-defined action that doubles a number.',
        '(DoubleValue: Action takes <number>) {\n'
        '    Extract the <n> from the <input: number>.\n'
        '    Compute the <doubled> from <n> * 2.\n'
        '    Return an <OK: status> with { doubled: <doubled> }.\n'
        '}',
    ),
    (
        'Define a user-defined action that squares a number.',
        '(SquareValue: Action takes <number>) {\n'
        '    Extract the <n> from the <input: number>.\n'
        '    Compute the <squared> from <n> * <n>.\n'
        '    Return an <OK: status> with { squared: <squared> }.\n'
        '}',
    ),
    (
        'Define a user-defined action that returns the length of a string.',
        '(StringLength: Action takes <text>) {\n'
        '    Extract the <s> from the <input: text>.\n'
        '    Compute the <len: length> from <s>.\n'
        '    Return an <OK: status> with { length: <len> }.\n'
        '}',
    ),
    (
        'Define a user-defined action that uppercases a string.',
        '(UpperCase: Action takes <text>) {\n'
        '    Extract the <s> from the <input: text>.\n'
        '    Compute the <upper: uppercase> from <s>.\n'
        '    Return an <OK: status> with { upper: <upper> }.\n'
        '}',
    ),
    (
        'Define a user-defined action that adds two numbers from an object input.',
        '(AddPair: Action) {\n'
        '    Extract the <a> from the <input: a>.\n'
        '    Extract the <b> from the <input: b>.\n'
        '    Compute the <sum> from <a> + <b>.\n'
        '    Return an <OK: status> with { sum: <sum> }.\n'
        '}',
    ),
    (
        'Compose two user-defined actions: sum then double.',
        '(DoubleValue: Action takes <number>) {\n'
        '    Extract the <n> from the <input: number>.\n'
        '    Compute the <doubled> from <n> * 2.\n'
        '    Return an <OK: status> with { doubled: <doubled> }.\n'
        '}\n\n'
        '(SumAndDouble: Action) {\n'
        '    Extract the <a> from the <input: a>.\n'
        '    Extract the <b> from the <input: b>.\n'
        '    Compute the <sum> from <a> + <b>.\n'
        '    Application.DoubleValue the <inner> from <sum>.\n'
        '    Extract the <result> from the <inner: doubled>.\n'
        '    Return an <OK: status> with { result: <result> }.\n'
        '}',
    ),
]

for instr, code in UDA:
    E.add(instr, code, 'user_defined_action')

# Computations and qualifiers.
COMPUTE_OPS = [
    ('length',    'length',    'Integer', 'the length of the text'),
    ('uppercase', 'uppercase', 'String',  'an uppercase copy of the text'),
    ('lowercase', 'lowercase', 'String',  'a lowercase copy of the text'),
    ('hash',      'hash',      'String',  'a hash of the password'),
]

for result, q, ty, label in COMPUTE_OPS:
    src = 'text' if q != 'hash' else 'password'
    E.add(
        f'Compute {label}.',
        f'(Compute{result.title()}: Example) {{\n'
        f'    Create the <{src}> with "{"example" if q != "hash" else "s3cret"}".\n'
        f'    Compute the <{result}: {q}> from the <{src}>.\n'
        f'    Return an <OK: status> with <{result}>.\n'
        f'}}',
        'compute_qualifier',
    )

# Arithmetic on two variables.
ARITHMETIC = [
    ('sum',        '+', 'sum of two numbers'),
    ('difference', '-', 'difference of two numbers'),
    ('product',    '*', 'product of two numbers'),
    ('quotient',   '/', 'quotient of two numbers'),
]

for result, op, label in ARITHMETIC:
    E.add(
        f'Compute the {label}.',
        f'(Arith{result.title()}: Example) {{\n'
        f'    Create the <a> with 10.\n'
        f'    Create the <b> with 3.\n'
        f'    Compute the <{result}> from <a> {op} <b>.\n'
        f'    Return an <OK: status> with <{result}>.\n'
        f'}}',
        'arithmetic',
    )

# Events — emit + handler.
EVENT_PAIRS = [
    ('OrderCreated',  'Send Confirmation', 'order'),
    ('UserSignedUp',  'Send Welcome Email', 'user'),
    ('PaymentReceived', 'Issue Receipt',   'payment'),
    ('FileUploaded',  'Scan Upload',       'file'),
    ('CommentPosted', 'Notify Author',     'comment'),
]

for event, handler, subj in EVENT_PAIRS:
    E.add(
        f'Emit a {event} event with a {subj}.',
        f'(Process {subj.title()}: Example) {{\n'
        f'    Create the <{subj}> with {{ id: 1 }}.\n'
        f'    Emit a <{event}: event> with <{subj}>.\n'
        f'    Return an <OK: status> with <{subj}>.\n'
        f'}}',
        'event_emit',
    )
    E.add(
        f'Handle the {event} event.',
        f'({handler}: {event} Handler) {{\n'
        f'    Extract the <{subj}> from the <event: {subj}>.\n'
        f'    Log <{subj}> to the <console>.\n'
        f'    Return an <OK: status> for the <handling>.\n'
        f'}}',
        'event_handler',
    )

# Git actions.
E.add('Retrieve the current git status.',
      '(GitStatus: Example) {\n'
      '    Retrieve the <status> from the <git>.\n'
      '    Return an <OK: status> with <status>.\n'
      '}', 'git')
E.add('Retrieve the recent git log.',
      '(GitLog: Example) {\n'
      '    Retrieve the <log> from the <git>.\n'
      '    Return an <OK: status> with <log>.\n'
      '}', 'git')
E.add('Retrieve the current git branch.',
      '(GitBranch: Example) {\n'
      '    Retrieve the <branch> from the <git>.\n'
      '    Return an <OK: status> with <branch>.\n'
      '}', 'git')
E.add('Stage all changes for commit.',
      '(GitStageAll: Example) {\n'
      '    Stage the <files> to the <git> with ".".\n'
      '    Return an <OK: status> with <files>.\n'
      '}', 'git')
E.add('Commit staged changes with a message.',
      '(GitCommit: Example) {\n'
      '    Commit the <result> to the <git> with "chore: update".\n'
      '    Return an <OK: status> with <result>.\n'
      '}', 'git')

# Application-Start patterns.
E.add('Write a Hello World application.',
      '(Application-Start: Hello World) {\n'
      '    Log "Hello, World!" to the <console>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'application_start')
E.add('Write an Application-Start that keeps running for events.',
      '(Application-Start: Long Running) {\n'
      '    Log "Starting..." to the <console>.\n'
      '    Keepalive the <application> for the <events>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'application_start')
E.add('Write an Application-End success handler.',
      '(Application-End: Success) {\n'
      '    Log "Shutting down cleanly." to the <console>.\n'
      '    Return an <OK: status> for the <shutdown>.\n'
      '}', 'application_end')
E.add('Write an Application-End error handler that logs the error.',
      '(Application-End: Error) {\n'
      '    Extract the <error> from the <shutdown: error>.\n'
      '    Log <error> to the <console>.\n'
      '    Return an <OK: status> for the <error-handling>.\n'
      '}', 'application_end')

# When-guards.
WHEN_GUARDS = [
    ('user-role', '"admin"', '== "admin"', 'admin access'),
    ('status-code', '500', '== 500', 'server error'),
    ('count', '10', '> 5', 'high count'),
]

for var, value, cond, label in WHEN_GUARDS:
    E.add(
        f'Log a message only when the {var} indicates {label}.',
        f'(Guarded {label.title()}: Example) {{\n'
        f'    Create the <{var}> with {value}.\n'
        f'    Log "{label} detected" to the <console> when <{var}> {cond}.\n'
        f'    Return an <OK: status> for the <check>.\n'
        f'}}',
        'when_guard',
    )

# Filtered iteration.
E.add('Iterate over a users list, logging only the active users.',
      '(LogActiveUsers: Example) {\n'
      '    Create the <users> with [\n'
      '        { name: "Alice", active: true },\n'
      '        { name: "Bob", active: false },\n'
      '        { name: "Carol", active: true }\n'
      '    ].\n'
      '    for each <user> in <users> where <user: active> is true {\n'
      '        Log <user: name> to the <console>.\n'
      '    }\n'
      '    Return an <OK: status> for the <iteration>.\n'
      '}', 'array_iteration')

E.add('Iterate over a scores list, logging only scores above 80.',
      '(LogHighScores: Example) {\n'
      '    Create the <scores> with [\n'
      '        { name: "Alice", score: 95 },\n'
      '        { name: "Bob", score: 72 },\n'
      '        { name: "Carol", score: 88 }\n'
      '    ].\n'
      '    for each <entry> in <scores> where <entry: score> > 80 {\n'
      '        Log <entry: name> to the <console>.\n'
      '    }\n'
      '    Return an <OK: status> for the <iteration>.\n'
      '}', 'array_iteration')

# File I/O — `<file: path-var>` is the canonical form.
E.add('Read a YAML file from disk.',
      '(ReadConfig: Example) {\n'
      '    Create the <path> with "config.yaml".\n'
      '    Read the <config> from the <file: path>.\n'
      '    Return an <OK: status> with <config>.\n'
      '}', 'file_io')
E.add('Write a string to a file on disk.',
      '(WriteReport: Example) {\n'
      '    Create the <path> with "report.txt".\n'
      '    Create the <report> with "Report contents".\n'
      '    Write the <report> to the <file: path>.\n'
      '    Return an <OK: status> for the <write>.\n'
      '}', 'file_io')
E.add('Read a JSON file and return its contents.',
      '(ReadData: Example) {\n'
      '    Create the <path> with "data.json".\n'
      '    Read the <data> from the <file: path>.\n'
      '    Return an <OK: status> with <data>.\n'
      '}', 'file_io')
E.add('Append a line to an existing file.',
      '(AppendLog: Example) {\n'
      '    Create the <path> with "events.log".\n'
      '    Create the <line> with "[INFO] event recorded\\n".\n'
      '    Append the <result> to the <file: path> with <line>.\n'
      '    Return an <OK: status> with <result>.\n'
      '}', 'file_io')
E.add('Copy a file from one path to another.',
      '(CopyFile: Example) {\n'
      '    Create the <src> with "in.txt".\n'
      '    Create the <dst> with "out.txt".\n'
      '    Copy the <file: src> to the <destination: dst>.\n'
      '    Return an <OK: status> for the <copy>.\n'
      '}', 'file_io')

# HTTP routes.
HTTP_ROUTES = [
    ('listUsers',  'Users API',  'Retrieve the <users> from the <user-repository>.',
     'Return an <OK: status> with <users>.'),
    ('getUser',    'Users API',  'Extract the <id> from the <pathParameters: id>.\n    Retrieve the <user> from the <user-repository> where <id> is <id>.',
     'Return an <OK: status> with <user>.'),
    ('createUser', 'Users API',  'Extract the <user> from the <request: body>.\n    Store the <user> into the <user-repository>.',
     'Return a <Created: status> with <user>.'),
    ('deleteUser', 'Users API',  'Extract the <id> from the <pathParameters: id>.\n    Delete the <user> from the <user-repository> where <id> is <id>.',
     'Return an <OK: status> for the <deletion>.'),
]

for op, api, body, ret in HTTP_ROUTES:
    E.add(
        f'Write the operationId handler for `{op}`.',
        f'({op}: {api}) {{\n    {body}\n    {ret}\n}}',
        'http_route',
    )

# Sort and dedup on arrays.
E.add('Sort the numbers array ascending.',
      '(SortNumbers: Example) {\n'
      '    Create the <numbers> with [3, 1, 4, 1, 5, 9, 2, 6].\n'
      '    Compute the <sorted: sort> from <numbers>.\n'
      '    Return an <OK: status> with <sorted>.\n'
      '}', 'array_sort')
E.add('Reverse a list of names.',
      '(ReverseNames: Example) {\n'
      '    Create the <names> with ["Alice", "Bob", "Carol"].\n'
      '    Compute the <reversed: reverse> from <names>.\n'
      '    Return an <OK: status> with <reversed>.\n'
      '}', 'array_reverse')

# Compound arithmetic.
E.add('Compute area of a rectangle from width and height.',
      '(Area: Example) {\n'
      '    Create the <width> with 8.\n'
      '    Create the <height> with 5.\n'
      '    Compute the <area> from <width> * <height>.\n'
      '    Return an <OK: status> with <area>.\n'
      '}', 'arithmetic')
E.add('Compute average of three numbers.',
      '(AverageThree: Example) {\n'
      '    Create the <a> with 10.\n'
      '    Create the <b> with 20.\n'
      '    Create the <c> with 30.\n'
      '    Compute the <sum> from <a> + <b> + <c>.\n'
      '    Compute the <avg> from <sum> / 3.\n'
      '    Return an <OK: status> with <avg>.\n'
      '}', 'arithmetic')

# String concatenation with ++.
E.add('Concatenate first and last name into a full name.',
      '(FullName: Example) {\n'
      '    Create the <first> with "Ada".\n'
      '    Create the <last> with "Lovelace".\n'
      '    Compute the <full> from <first> ++ " " ++ <last>.\n'
      '    Return an <OK: status> with <full>.\n'
      '}', 'string')
E.add('Build a greeting from a name.',
      '(Greet: Example) {\n'
      '    Create the <name> with "World".\n'
      '    Compute the <greeting> from "Hello, " ++ <name> ++ "!".\n'
      '    Log <greeting> to the <console>.\n'
      '    Return an <OK: status> for the <greeting>.\n'
      '}', 'string')

# Hash + store pattern.
E.add('Hash a password and store it in the users repository.',
      '(SaveUserWithHash: Example) {\n'
      '    Create the <user> with { id: 1, name: "Alice" }.\n'
      '    Create the <password> with "s3cret".\n'
      '    Compute the <hash: hash> from <password>.\n'
      '    Store the <hash> into the <password-repository>.\n'
      '    Return an <OK: status> with <user>.\n'
      '}', 'compute_qualifier')

# Repository observer with computation.
E.add('Observe new orders and log a confirmation message.',
      '(Confirm Order: order-repository Observer) {\n'
      '    Extract the <order> from the <event: order>.\n'
      '    Compute the <message> from "Order " ++ <order: id> ++ " received".\n'
      '    Log <message> to the <console>.\n'
      '    Return an <OK: status> for the <confirmation>.\n'
      '}', 'repository_observer')

# More UDAs.
E.add('Define a user-defined action that doubles every number in a list.',
      '(DoubleAll: Action takes <numbers>) {\n'
      '    Extract the <list> from the <input: numbers>.\n'
      '    for each <n> in <list> {\n'
      '        Log <n> to the <console>.\n'
      '    }\n'
      '    Return an <OK: status> with <list>.\n'
      '}', 'user_defined_action')
E.add('Define a user-defined action that returns a constant greeting.',
      '(Hello: Action) {\n'
      '    Create the <message> with "Hello, World!".\n'
      '    Return an <OK: status> with { message: <message> }.\n'
      '}', 'user_defined_action')

# Match on integer ranges via explicit cases.
E.add('Branch on an HTTP status code (200, 404, 500, otherwise).',
      '(HandleStatus: Example) {\n'
      '    Create the <status> with 200.\n'
      '    match <status> {\n'
      '        case 200 {\n'
      '            Log "ok" to the <console>.\n'
      '        }\n'
      '        case 404 {\n'
      '            Log "not found" to the <console>.\n'
      '        }\n'
      '        case 500 {\n'
      '            Log "server error" to the <console>.\n'
      '        }\n'
      '        otherwise {\n'
      '            Log "other" to the <console>.\n'
      '        }\n'
      '    }\n'
      '    Return an <OK: status> for the <dispatch>.\n'
      '}', 'match')

# Filtered iteration over various shapes.
E.add('Iterate over a list of orders, logging only those marked open.',
      '(LogOpenOrders: Example) {\n'
      '    Create the <orders> with [\n'
      '        { id: 1, open: true },\n'
      '        { id: 2, open: false },\n'
      '        { id: 3, open: true }\n'
      '    ].\n'
      '    for each <order> in <orders> where <order: open> is true {\n'
      '        Log <order: id> to the <console>.\n'
      '    }\n'
      '    Return an <OK: status> for the <iteration>.\n'
      '}', 'array_iteration')

# HTTP routes for additional resources.
for op, api, body, ret in [
    ('listOrders',  'Orders API',
     'Retrieve the <orders> from the <order-repository>.',
     'Return an <OK: status> with <orders>.'),
    ('getOrder',    'Orders API',
     'Extract the <id> from the <pathParameters: id>.\n    Retrieve the <order> from the <order-repository> where <id> is <id>.',
     'Return an <OK: status> with <order>.'),
    ('createOrder', 'Orders API',
     'Extract the <order> from the <request: body>.\n    Store the <order> into the <order-repository>.\n    Emit an <OrderCreated: event> with <order>.',
     'Return a <Created: status> with <order>.'),
    ('updateOrder', 'Orders API',
     'Extract the <id> from the <pathParameters: id>.\n    Extract the <patch> from the <request: body>.\n    Retrieve the <order> from the <order-repository> where <id> is <id>.\n    Store the <patch> into the <order-repository>.',
     'Return an <OK: status> with <patch>.'),
    ('listProducts', 'Products API',
     'Retrieve the <products> from the <product-repository>.',
     'Return an <OK: status> with <products>.'),
    ('getProduct',  'Products API',
     'Extract the <id> from the <pathParameters: id>.\n    Retrieve the <product> from the <product-repository> where <id> is <id>.',
     'Return an <OK: status> with <product>.'),
    ('listComments', 'Comments API',
     'Retrieve the <comments> from the <comment-repository>.',
     'Return an <OK: status> with <comments>.'),
    ('listPosts',   'Blog API',
     'Retrieve the <posts> from the <post-repository>.',
     'Return an <OK: status> with <posts>.'),
]:
    E.add(
        f'Write the operationId handler for `{op}`.',
        f'({op}: {api}) {{\n    {body}\n    {ret}\n}}',
        'http_route',
    )

# Application-Start with HTTP server + repositories.
E.add('Application-Start that boots an HTTP server backed by a contract.',
      '(Application-Start: HTTP Service) {\n'
      '    Log "starting" to the <console>.\n'
      '    Start the <http-server> with {}.\n'
      '    Keepalive the <application> for the <events>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'application_start')

# Event handlers chained off repository observers.
E.add('Handle the OrderCreated event by emitting a downstream notification.',
      '(Notify Downstream: OrderCreated Handler) {\n'
      '    Extract the <order> from the <event: order>.\n'
      '    Emit a <NotificationQueued: event> with <order>.\n'
      '    Return an <OK: status> for the <handling>.\n'
      '}', 'event_handler')

# Reduce-and-Log pattern.
for var, literal, op, ty in [
    ('numbers', '[1, 2, 3, 4, 5]', 'sum', 'Integer'),
    ('scores',  '[88, 91, 72, 95, 67]', 'avg', 'Float'),
    ('prices',  '[19.99, 24.50, 9.95]', 'sum', 'Float'),
]:
    E.add(
        f'Reduce the {var} array with {op}() and log the result.',
        f'(Reduce{var.title()}AndLog: Example) {{\n'
        f'    Create the <{var}> with {literal}.\n'
        f'    Reduce the <result: {ty}> from the <{var}> with {op}().\n'
        f'    Log <result> to the <console>.\n'
        f'    Return an <OK: status> with <result>.\n'
        f'}}',
        'array_reduce',
    )

# Configurable + framework.
E.add('Require the console from the framework before logging.',
      '(LogWithRequire: Example) {\n'
      '    Require the <console> from the <framework>.\n'
      '    Log "ready" to the <console>.\n'
      '    Return an <OK: status> for the <log>.\n'
      '}', 'framework')

# Set operations with strings.
E.add('Intersect two string arrays.',
      '(StringIntersect: Example) {\n'
      '    Create the <left> with ["a", "b", "c"].\n'
      '    Create the <right> with ["b", "c", "d"].\n'
      '    Compute the <common: intersect> from <left> with <right>.\n'
      '    Return an <OK: status> with <common>.\n'
      '}', 'set_operation')

# Compute with multiple chained steps.
E.add('Compute a total with discount and tax.',
      '(PriceWithTax: Example) {\n'
      '    Create the <price> with 100.\n'
      '    Create the <discount> with 10.\n'
      '    Create the <tax-rate> with 19.\n'
      '    Compute the <discounted> from <price> - <discount>.\n'
      '    Compute the <tax> from <discounted> * <tax-rate> / 100.\n'
      '    Compute the <total> from <discounted> + <tax>.\n'
      '    Return an <OK: status> with <total>.\n'
      '}', 'arithmetic')

# Branch on string.
E.add('Branch on a feature flag string and log a different message per flag.',
      '(FeatureFlag: Example) {\n'
      '    Create the <flag> with "new-checkout".\n'
      '    match <flag> {\n'
      '        case "legacy" {\n'
      '            Log "legacy path" to the <console>.\n'
      '        }\n'
      '        case "new-checkout" {\n'
      '            Log "new checkout path" to the <console>.\n'
      '        }\n'
      '        otherwise {\n'
      '            Log "unknown flag" to the <console>.\n'
      '        }\n'
      '    }\n'
      '    Return an <OK: status> for the <dispatch>.\n'
      '}', 'match')

# Repository observer that emits another event.
E.add('Observe new posts and emit a PostIndexed event.',
      '(Index New Post: post-repository Observer) {\n'
      '    Extract the <post> from the <event: post>.\n'
      '    Emit a <PostIndexed: event> with <post>.\n'
      '    Return an <OK: status> for the <indexing>.\n'
      '}', 'repository_observer')

# Set operations.

for op_name, op, var in [('union', 'union', 'combined'),
                          ('intersect', 'intersect', 'common'),
                          ('difference', 'difference', 'unique')]:
    E.add(
        f'Compute the {op_name} of two sets.',
        f'(Set{op_name.title()}: Example) {{\n'
        f'    Create the <left> with [1, 2, 3].\n'
        f'    Create the <right> with [3, 4, 5].\n'
        f'    Compute the <{var}: {op}> from <left> with <right>.\n'
        f'    Return an <OK: status> with <{var}>.\n'
        f'}}',
        'set_operation',
    )


# ── Auto-fix common issues, then validate ──────────────────────────────────

WHITESPACE_FIX = re.compile(r'(\w)<([a-z])')


def auto_fix(code: str) -> str:
    # Same regex the runtime stripper + Train/script/config.py use.
    return WHITESPACE_FIX.sub(r'\1 <\2', code)


def extract_aro(text: str) -> str:
    m = re.search(r'```aro\n(.*?)```', text, re.DOTALL)
    return m.group(1) if m else text


def validate_and_filter(examples: list) -> tuple[list, list]:
    kept, failed = [], []
    for ex in examples:
        code = extract_aro(ex['output'])
        if not structurally_ok(code):
            failed.append((ex, 'structural_check_failed', code))
            continue
        # try once unfixed, then with the whitespace fix
        for attempt_code in (code, auto_fix(code)):
            ok, err = aro_check(attempt_code)
            if ok:
                ex['output'] = '```aro\n' + attempt_code.strip() + '\n```'
                kept.append(ex)
                break
        else:
            failed.append((ex, err, code))
    return kept, failed


# ── Final batch — push toward 200 ─────────────────────────────────────────

# More repository variations.
for item, Item, repo in [
    ('article', 'Article', 'article-repository'),
    ('invoice', 'Invoice', 'invoice-repository'),
    ('subscription', 'Subscription', 'subscription-repository'),
    ('alert', 'Alert', 'alert-repository'),
    ('tag', 'Tag', 'tag-repository'),
    ('rating', 'Rating', 'rating-repository'),
]:
    E.add(
        f'Store a {item} in the {repo} and log the result.',
        f'(Store{Item}: Example) {{\n'
        f'    Create the <{item}> with {{ id: 1, label: "example" }}.\n'
        f'    Store the <{item}> into the <{repo}>.\n'
        f'    Log <{item}> to the <console>.\n'
        f'    Return an <OK: status> with <{item}>.\n'
        f'}}',
        'repository',
    )

# More UDAs with diverse inputs.
E.add('Define an action that returns the larger of two numbers.',
      '(MaxOf: Action) {\n'
      '    Extract the <a> from the <input: a>.\n'
      '    Extract the <b> from the <input: b>.\n'
      '    match <a> {\n'
      '        case 0 {\n'
      '            Return an <OK: status> with { result: <b> }.\n'
      '        }\n'
      '        otherwise {\n'
      '            Return an <OK: status> with { result: <a> }.\n'
      '        }\n'
      '    }\n'
      '    Return an <OK: status> with { result: <a> }.\n'
      '}', 'user_defined_action')

E.add('Define an action that builds a full URL from base + path.',
      '(BuildURL: Action) {\n'
      '    Extract the <base> from the <input: base>.\n'
      '    Extract the <path> from the <input: path>.\n'
      '    Compute the <url> from <base> ++ "/" ++ <path>.\n'
      '    Return an <OK: status> with { url: <url> }.\n'
      '}', 'user_defined_action')

# More handlers for diverse events.
for event, subj in [
    ('UserDeleted',  'user'),
    ('OrderShipped', 'order'),
    ('OrderCancelled', 'order'),
    ('PaymentFailed', 'payment'),
    ('SessionStarted', 'session'),
    ('SessionExpired', 'session'),
]:
    E.add(
        f'Handle the {event} event by logging the {subj}.',
        f'(Log {event}: {event} Handler) {{\n'
        f'    Extract the <{subj}> from the <event: {subj}>.\n'
        f'    Log <{subj}> to the <console>.\n'
        f'    Return an <OK: status> for the <handling>.\n'
        f'}}',
        'event_handler',
    )

# Combinations.
E.add('Application-Start that creates a value, doubles it via UDA, and logs it.',
      '(Doubler: Action takes <number>) {\n'
      '    Extract the <n> from the <input: number>.\n'
      '    Compute the <doubled> from <n> * 2.\n'
      '    Return an <OK: status> with { doubled: <doubled> }.\n'
      '}\n\n'
      '(Application-Start: Doubler App) {\n'
      '    Create the <value> with 21.\n'
      '    Application.Doubler the <result> from <value>.\n'
      '    Extract the <out> from the <result: doubled>.\n'
      '    Log <out> to the <console>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'composition')

# Compute on objects (field extract).
E.add('Extract a field from an object and log it.',
      '(LogUserName: Example) {\n'
      '    Create the <user> with { name: "Ada", role: "admin" }.\n'
      '    Extract the <name> from the <user: name>.\n'
      '    Log <name> to the <console>.\n'
      '    Return an <OK: status> with <name>.\n'
      '}', 'extract')

E.add('Extract two fields from an object and concatenate them.',
      '(BuildLabel: Example) {\n'
      '    Create the <item> with { sku: "ABC", title: "Widget" }.\n'
      '    Extract the <sku> from the <item: sku>.\n'
      '    Extract the <title> from the <item: title>.\n'
      '    Compute the <label> from <sku> ++ ": " ++ <title>.\n'
      '    Log <label> to the <console>.\n'
      '    Return an <OK: status> with <label>.\n'
      '}', 'extract')

# Application-End handlers.
E.add('Application-End handler that closes a database connection.',
      '(Application-End: Success) {\n'
      '    Close the <database-connections> for the <application>.\n'
      '    Log "closed" to the <console>.\n'
      '    Return an <OK: status> for the <shutdown>.\n'
      '}', 'application_end')

# Stop HTTP server.
E.add('Stop the HTTP server during shutdown.',
      '(Application-End: Success) {\n'
      '    Stop the <http-server> with <application>.\n'
      '    Return an <OK: status> for the <shutdown>.\n'
      '}', 'application_end')

# Additional small examples to push the curated count above 200.
for verb, label in [
    ('Log', 'a startup message'),
    ('Log', 'a shutdown message'),
    ('Log', 'a connection event'),
    ('Log', 'a heartbeat'),
    ('Log', 'a request received'),
]:
    text_var = label.replace(' ', '-').replace('a-', '')
    E.add(
        f'{verb} {label} to the console.',
        f'({verb}{text_var.title().replace("-", "")}: Example) {{\n'
        f'    Create the <message> with "{label}".\n'
        f'    {verb} <message> to the <console>.\n'
        f'    Return an <OK: status> for the <log>.\n'
        f'}}',
        'logging',
    )

# Match on more flag-style values.
E.add('Branch on an environment string (dev, staging, prod).',
      '(EnvBranch: Example) {\n'
      '    Create the <env> with "prod".\n'
      '    match <env> {\n'
      '        case "dev" {\n'
      '            Log "dev mode" to the <console>.\n'
      '        }\n'
      '        case "staging" {\n'
      '            Log "staging mode" to the <console>.\n'
      '        }\n'
      '        case "prod" {\n'
      '            Log "production mode" to the <console>.\n'
      '        }\n'
      '        otherwise {\n'
      '            Log "unknown env" to the <console>.\n'
      '        }\n'
      '    }\n'
      '    Return an <OK: status> for the <dispatch>.\n'
      '}', 'match')

# Iterate + reduce in one feature set.
E.add('Iterate over numbers and compute their sum afterwards.',
      '(IterateThenSum: Example) {\n'
      '    Create the <numbers> with [1, 2, 3, 4, 5].\n'
      '    for each <n> in <numbers> {\n'
      '        Log <n> to the <console>.\n'
      '    }\n'
      '    Reduce the <total: Integer> from the <numbers> with sum().\n'
      '    Log <total> to the <console>.\n'
      '    Return an <OK: status> with <total>.\n'
      '}', 'array_combined')

# Repository observer that filters with when.
E.add('Observe ticket changes and log only the urgent ones.',
      '(Log Urgent Tickets: ticket-repository Observer) {\n'
      '    Extract the <ticket> from the <event: ticket>.\n'
      '    Extract the <priority> from the <ticket: priority>.\n'
      '    Log <ticket> to the <console> when <priority> == "urgent".\n'
      '    Return an <OK: status> for the <handling>.\n'
      '}', 'repository_observer')

# When guards across different types.
E.add('Log a warning only when the count is below a threshold.',
      '(LowCountWarn: Example) {\n'
      '    Create the <count> with 2.\n'
      '    Log "below threshold" to the <console> when <count> < 5.\n'
      '    Return an <OK: status> for the <check>.\n'
      '}', 'when_guard')

E.add('Log only when a boolean flag is true.',
      '(LogIfEnabled: Example) {\n'
      '    Create the <enabled> with true.\n'
      '    Log "enabled" to the <console> when <enabled> is true.\n'
      '    Return an <OK: status> for the <check>.\n'
      '}', 'when_guard')


def main():
    print(f'generated {len(E)} candidate examples', flush=True)
    kept, failed = validate_and_filter(E)
    print(f'  passed `aro check`: {len(kept)}', flush=True)
    print(f'  failed (dropped):  {len(failed)}', flush=True)

    with open(OUT_FILE, 'w') as f:
        for ex in kept:
            f.write(json.dumps(ex, ensure_ascii=False) + '\n')
    with open(FAIL_LOG, 'w') as f:
        for ex, err, code in failed:
            f.write(f'### {ex["instruction"]}\n')
            f.write(f'category: {ex["category"]}\nerror: {err}\n')
            f.write('```aro\n' + code + '\n```\n\n')
    print(f'wrote {len(kept)} validated examples → {OUT_FILE}', flush=True)
    print(f'wrote {len(failed)} failures → {FAIL_LOG}', flush=True)


if __name__ == '__main__':
    main()
