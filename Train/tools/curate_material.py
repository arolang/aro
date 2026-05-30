#!/usr/bin/env python3
"""Generate ~200 curated (instruction, ARO code) training examples covering
modern ARO features — arrays, repositories, user-defined actions, branches
(match), events, git, file I/O, computations. Each example is validated by
running `aro check` against it; failures are auto-fixed where possible and
otherwise dropped. The validated set lands in `curated.jsonl` in the
training-pair format the rest of the pipeline already understands.

Run:
    python3 Train/tools/curate_material.py
    # writes Train/Material/curated.jsonl     (data)
    # writes Train/tools/curated_failures.log (build artefact)
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
MATERIAL_DIR = TOOLS_DIR.parent / 'Material'
ARO_BIN = TOOLS_DIR.parent.parent / '.build/release/aro'
if not ARO_BIN.exists():
    ARO_BIN = TOOLS_DIR.parent.parent / '.build/debug/aro'

# Validated training pairs land in Material/ (data only). The
# failures log is a build artefact and stays alongside the script.
OUT_FILE = MATERIAL_DIR / 'curated.jsonl'
FAIL_LOG = TOOLS_DIR / 'curated_failures.log'


# ── Validation ─────────────────────────────────────────────────────────────

def aro_check(code: str) -> tuple[bool, str]:
    """Return (passed, error_message). Requires a full feature-set program."""
    if not ARO_BIN.exists():
        sys.exit(f'aro binary not found at {ARO_BIN}. Build first: swift build -c release')
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'main.aro').write_text(code)
        r = subprocess.run([str(ARO_BIN), 'check', tmp],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0, (r.stderr or r.stdout).strip()[:300]


def aro_check_syntax(snippet: str) -> tuple[bool, str]:
    """Validate a bare snippet via `aro check --syntax` (no wrapper required).
    Returns (passed, error_message). Used for REPL-style training pairs that
    intentionally aren't wrapped in a feature set."""
    if not ARO_BIN.exists():
        sys.exit(f'aro binary not found at {ARO_BIN}. Build first: swift build -c release')
    r = subprocess.run(
        [str(ARO_BIN), 'check', '--syntax', '-'],
        input=snippet, capture_output=True, text=True, timeout=10,
    )
    return r.returncode == 0, (r.stderr or r.stdout).strip()[:300]


# Tiny structural sanity check before we bother spawning aro. Accepts:
#   (Name: Activity) {                        — basic
#   (Name: Action takes <arg>) {              — user-defined actions
#   (Name: X Handler) when <field> == "x" {   — state guards
#   (Name: Activity)\n{                       — header + body on separate lines
_FEATURE_SET_RE = re.compile(
    r'\([\w\- ]+:\s*[\w\- ]+(?:\s+takes\s+<[\w\-]+>)?\s*\)'
    r'(?:\s+when\s+[^{]+)?\s*\{',
    re.DOTALL,
)


def structurally_ok(code: str) -> bool:
    """Quick pre-check before spawning `aro check`. Accepts either a
    feature-set program (with balanced braces) or a bare REPL block —
    one or more non-comment lines each ending with a period."""
    if _FEATURE_SET_RE.search(code):
        return code.count('{') == code.count('}')
    nontrivial = [
        line.strip() for line in code.split('\n')
        if line.strip() and not line.strip().startswith('(*')
    ]
    return bool(nontrivial) and all(line.endswith('.') for line in nontrivial)


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

        # REPL-style bare-statement pairs use `aro check --syntax`, which
        # validates a snippet without requiring the feature-set wrapper.
        # Same parser as the regular check; just relaxed entry-point rule.
        if ex.get('category') == 'repl_one_liner':
            for attempt_code in (code, auto_fix(code)):
                ok, err = aro_check_syntax(attempt_code)
                if ok:
                    ex['output'] = '```aro\n' + attempt_code.strip() + '\n```'
                    kept.append(ex)
                    break
            else:
                failed.append((ex, err, code))
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

# Bare REPL statements — the model needs to produce these for `aro repl`
# and `echo '...' | aro`. Without explicit examples it over-wraps every
# response in `(Name: Activity) { ... }`, which is wrong for one-liners.
# `aro check` accepts a single statement when it's the whole file.

E.add('Log "Hello" to the console as a one-line ARO statement for the REPL.',
      'Log "Hello" to the <console>.', 'repl_one_liner')
E.add('REPL: create a numeric variable and log it in two lines.',
      'Create the <x> with 42.\nLog <x> to the <console>.', 'repl_one_liner')
E.add('REPL: compute the sum of two literals without wrapping in a feature set.',
      'Create the <a> with 3.\nCreate the <b> with 5.\nCompute the <sum> from <a> + <b>.\n'
      'Log <sum> to the <console>.', 'repl_one_liner')
E.add('Show me a one-line ARO statement (no feature-set wrapper) suitable for `echo ... | aro`.',
      'Log "Hi from a pipe" to the <console>.', 'repl_one_liner')
E.add('REPL: read a file and log its content without wrapping in a feature set.',
      'Create the <path> with "config.yaml".\n'
      'Read the <config> from the <file: path>.\n'
      'Log <config> to the <console>.', 'repl_one_liner')


# Match-pattern reinforcement — round-1 booster smoke-test failed on
# `match X with 200 { ... }` (model invented `match X with N`). Add
# explicit examples that show the correct `match X { case ... }` form.
for var, cases in [
    ('status-code', ['200', '404', '500']),
    ('priority',    ['"low"', '"medium"', '"high"']),
    ('role',        ['"admin"', '"editor"', '"viewer"']),
    ('size',        ['"small"', '"large"']),
]:
    case_block = '\n'.join(
        f'        case {c} {{\n'
        f'            Log "matched a case" to the <console>.\n'
        f'        }}'
        for c in cases
    )
    E.add(
        f'Use a match statement to branch on the {var}. Use `case <value> {{ ... }}` blocks inside the match — do not write `match X with N`.',
        f'(MatchOn{var.title().replace("-", "")}: Example) {{\n'
        f'    Create the <{var}> with {cases[0]}.\n'
        f'    match <{var}> {{\n'
        f'{case_block}\n'
        f'        otherwise {{\n'
        f'            Log "no match" to the <console>.\n'
        f'        }}\n'
        f'    }}\n'
        f'    Return an <OK: status> for the <dispatch>.\n'
        f'}}',
        'match_reinforcement',
    )

E.add('How is the match statement structured in ARO? Show me a correct example.',
      '(MatchStructure: Example) {\n'
      '    Create the <code> with 200.\n'
      '    match <code> {\n'
      '        case 200 {\n'
      '            Log "ok" to the <console>.\n'
      '        }\n'
      '        case 404 {\n'
      '            Log "not found" to the <console>.\n'
      '        }\n'
      '        otherwise {\n'
      '            Log "other" to the <console>.\n'
      '        }\n'
      '    }\n'
      '    Return an <OK: status> for the <match>.\n'
      '}', 'match_reinforcement')

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


# ── Multi-file examples ────────────────────────────────────────────────────
# Material was previously almost all single-file snippets. Real ARO apps
# have main.aro + openapi.yaml + per-feature .aro files; the model needs
# to learn that layout. Each entry below specifies a `files` dict; the
# validator writes them all to a tempdir and runs `aro check` against
# the directory (matching how `aro run ./MyApp/` actually loads the app).
#
# The serialized `output` field uses `## filename` headers so the model
# learns to emit one fenced block per file, in the order it would write
# them. That's the same convention `aro ask --openapi` already follows.

class MultiFileExamples(list):
    def add(self, instruction, files, category='multi_file'):
        self.append({
            'instruction': instruction.strip(),
            'files': files,
            'category': category,
            'task_type': 'multi_file_application',
        })


MF = MultiFileExamples()

# OpenAPI service — users CRUD
MF.add(
    'Build a complete ARO HTTP service for managing users: list, get by id, '
    'create, delete. Include openapi.yaml and main.aro with operationId '
    'handlers.',
    {
        'openapi.yaml':
            'openapi: 3.0.3\n'
            'info:\n  title: User API\n  version: 1.0.0\n'
            'paths:\n'
            '  /users:\n'
            '    get:\n      operationId: listUsers\n'
            '    post:\n      operationId: createUser\n'
            '  /users/{id}:\n'
            '    get:\n      operationId: getUser\n'
            '    delete:\n      operationId: deleteUser\n',
        'main.aro':
            '(Application-Start: User Service) {\n'
            '    Log "Starting User Service" to the <console>.\n'
            '    Start the <http-server> with {}.\n'
            '    Keepalive the <application> for the <events>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}\n'
            '\n'
            '(listUsers: User API) {\n'
            '    Retrieve the <users> from the <user-repository>.\n'
            '    Return an <OK: status> with <users>.\n'
            '}\n'
            '\n'
            '(getUser: User API) {\n'
            '    Extract the <id> from the <pathParameters: id>.\n'
            '    Retrieve the <user> from the <user-repository> where <id> is <id>.\n'
            '    Return an <OK: status> with <user>.\n'
            '}\n'
            '\n'
            '(createUser: User API) {\n'
            '    Extract the <user> from the <request: body>.\n'
            '    Store the <user> into the <user-repository>.\n'
            '    Emit a <UserCreated: event> with <user>.\n'
            '    Return a <Created: status> with <user>.\n'
            '}\n'
            '\n'
            '(deleteUser: User API) {\n'
            '    Extract the <id> from the <pathParameters: id>.\n'
            '    Delete the <user> from the <user-repository> where <id> is <id>.\n'
            '    Return an <OK: status> for the <deletion>.\n'
            '}\n',
    },
)

# Orders service with state machine + event handler
MF.add(
    'Build an order service with create / get / ship routes. The ship route '
    'transitions the order to "shipped" and emits an OrderShipped event. '
    'Include openapi.yaml, main.aro and handlers.aro.',
    {
        'openapi.yaml':
            'openapi: 3.0.3\n'
            'info:\n  title: Orders API\n  version: 1.0.0\n'
            'paths:\n'
            '  /orders:\n'
            '    post: { operationId: createOrder }\n'
            '  /orders/{id}:\n'
            '    get:  { operationId: getOrder }\n'
            '  /orders/{id}/ship:\n'
            '    post: { operationId: shipOrder }\n',
        'main.aro':
            '(Application-Start: Orders) {\n'
            '    Start the <http-server> with {}.\n'
            '    Keepalive the <application> for the <events>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}\n'
            '\n'
            '(createOrder: Orders) {\n'
            '    Extract the <order> from the <request: body>.\n'
            '    Store the <order> into the <order-repository>.\n'
            '    Return a <Created: status> with <order>.\n'
            '}\n'
            '\n'
            '(getOrder: Orders) {\n'
            '    Extract the <id> from the <pathParameters: id>.\n'
            '    Retrieve the <order> from the <order-repository> where <id> is <id>.\n'
            '    Return an <OK: status> with <order>.\n'
            '}\n'
            '\n'
            '(shipOrder: Orders) {\n'
            '    Extract the <id> from the <pathParameters: id>.\n'
            '    Retrieve the <order> from the <order-repository> where <id> is <id>.\n'
            '    Accept the <transition> for the <order> with "shipped".\n'
            '    Emit an <OrderShipped: event> with <order>.\n'
            '    Return an <OK: status> with <order>.\n'
            '}\n',
        'handlers.aro':
            '(Notify Shipment: OrderShipped Handler) {\n'
            '    Extract the <order> from the <event: order>.\n'
            '    Log <order> to the <console>.\n'
            '    Return an <OK: status> for the <notification>.\n'
            '}\n',
    },
)

# File-watcher pipeline (no openapi)
MF.add(
    'Build a file-watcher application that monitors ./inbox for new CSV files '
    'and stores each row into a row-repository. Include main.aro and importer.aro.',
    {
        'main.aro':
            '(Application-Start: CSV Importer) {\n'
            '    Log "Watching ./inbox" to the <console>.\n'
            '    Start the <file-monitor> with { directory: "./inbox" }.\n'
            '    Keepalive the <application> for the <events>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}\n',
        'importer.aro':
            '(Process Upload: File Event Handler) {\n'
            '    Extract the <path> from the <event: path>.\n'
            '    Read the <rows> from the <file: path>.\n'
            '    for each <row> in <rows> {\n'
            '        Store the <row> into the <row-repository>.\n'
            '    }\n'
            '    Return an <OK: status> for the <processing>.\n'
            '}\n',
    },
)

# Event-driven app: order placed → confirmation email + inventory adjust
MF.add(
    'Build an event-driven order app. The createOrder route stores the '
    'order and emits OrderPlaced. Two handlers react: one sends a '
    'confirmation email, one decrements inventory. Include openapi.yaml, '
    'main.aro and handlers.aro.',
    {
        'openapi.yaml':
            'openapi: 3.0.3\n'
            'info:\n  title: Orders\n  version: 1.0.0\n'
            'paths:\n  /orders:\n    post: { operationId: createOrder }\n',
        'main.aro':
            '(Application-Start: Orders) {\n'
            '    Start the <http-server> with {}.\n'
            '    Keepalive the <application> for the <events>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}\n'
            '\n'
            '(createOrder: Orders) {\n'
            '    Extract the <order> from the <request: body>.\n'
            '    Store the <order> into the <order-repository>.\n'
            '    Emit an <OrderPlaced: event> with <order>.\n'
            '    Return a <Created: status> with <order>.\n'
            '}\n',
        'handlers.aro':
            '(Send Confirmation: OrderPlaced Handler) {\n'
            '    Extract the <order> from the <event: order>.\n'
            '    Send the <confirmation> to the <order: email>.\n'
            '    Return an <OK: status> for the <notification>.\n'
            '}\n'
            '\n'
            '(Adjust Inventory: OrderPlaced Handler) {\n'
            '    Extract the <order> from the <event: order>.\n'
            '    Retrieve the <item> from the <inventory-repository> where <id> is <order>.\n'
            '    Store the <item> into the <inventory-repository>.\n'
            '    Return an <OK: status> for the <adjustment>.\n'
            '}\n',
    },
)

# Posts API with comments observer
MF.add(
    'Build a blog posts API with create and list routes. Add a repository '
    'observer that audits every new post by logging it. Include '
    'openapi.yaml, main.aro and observer.aro.',
    {
        'openapi.yaml':
            'openapi: 3.0.3\n'
            'info:\n  title: Blog\n  version: 1.0.0\n'
            'paths:\n'
            '  /posts:\n'
            '    get:  { operationId: listPosts }\n'
            '    post: { operationId: createPost }\n',
        'main.aro':
            '(Application-Start: Blog) {\n'
            '    Start the <http-server> with {}.\n'
            '    Keepalive the <application> for the <events>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}\n'
            '\n'
            '(listPosts: Blog) {\n'
            '    Retrieve the <posts> from the <post-repository>.\n'
            '    Return an <OK: status> with <posts>.\n'
            '}\n'
            '\n'
            '(createPost: Blog) {\n'
            '    Extract the <post> from the <request: body>.\n'
            '    Store the <post> into the <post-repository>.\n'
            '    Return a <Created: status> with <post>.\n'
            '}\n',
        'observer.aro':
            '(Audit Post: post-repository Observer) {\n'
            '    Extract the <post> from the <event: post>.\n'
            '    Log <post> to the <console>.\n'
            '    Return an <OK: status> for the <audit>.\n'
            '}\n',
    },
)


# Validation for multi-file: write files to a tempdir, run `aro check`
# against the directory. Output gets serialized as `## filename` blocks.

def _serialize_multi_file(files):
    parts = []
    for fname, content in files.items():
        lang = 'yaml' if fname.endswith('.yaml') or fname.endswith('.yml') else 'aro'
        parts.append(f'## {fname}\n```{lang}\n{content.strip()}\n```')
    return '\n\n'.join(parts)


def validate_multi_file(examples):
    kept, failed = [], []
    for ex in examples:
        files = ex['files']
        with tempfile.TemporaryDirectory() as tmp:
            for fname, content in files.items():
                (Path(tmp) / fname).write_text(content)
            try:
                r = subprocess.run(
                    [str(ARO_BIN), 'check', tmp],
                    capture_output=True, text=True, timeout=15,
                )
                ok = r.returncode == 0
                err = (r.stderr or r.stdout).strip()[:500]
            except Exception as exc:
                ok, err = False, str(exc)[:300]
        if ok:
            kept.append({
                'instruction': ex['instruction'],
                'output': _serialize_multi_file(files),
                'category': ex['category'],
                'task_type': ex['task_type'],
            })
        else:
            failed.append((ex, err))
    return kept, failed


# ── Gap-coverage examples for features Material previously missed ──────────
# These cover: typed event extraction (ARO-0046), state guards (ARO-0022),
# template engine details, store files, metrics, sink syntax (ARO-0043),
# plugin qualifier calls, configurable runtime, parameters, websocket
# handler (uses the openapi-driven websocket pattern), context-aware
# formatting.

# Typed event extraction (ARO-0046)
E.add('Use typed event extraction to pull a strongly-typed field out of an event payload.',
      '(Process Order: OrderCreated Handler) {\n'
      '    Extract the <total: Integer> from the <event: total>.\n'
      '    Log <total> to the <console>.\n'
      '    Return an <OK: status> with <total>.\n'
      '}', 'typed_event')

E.add('Extract a string field out of an event with a type hint.',
      '(Greet User: UserSignedUp Handler) {\n'
      '    Extract the <name: String> from the <event: name>.\n'
      '    Log <name> to the <console>.\n'
      '    Return an <OK: status> with <name>.\n'
      '}', 'typed_event')

E.add('Extract a typed sub-object out of an event.',
      '(Audit Payment: PaymentReceived Handler) {\n'
      '    Extract the <amount: Integer> from the <event: amount>.\n'
      '    Extract the <currency: String> from the <event: currency>.\n'
      '    Log <amount> to the <console>.\n'
      '    Log <currency> to the <console>.\n'
      '    Return an <OK: status> for the <audit>.\n'
      '}', 'typed_event')

# State guards (ARO-0022) — guard a handler on a field value
E.add('Guard a handler so it only fires when the event status field equals "paid".',
      '(Ship Paid Order: OrderUpdated Handler) when <status> == "paid" {\n'
      '    Extract the <order> from the <event: order>.\n'
      '    Log <order> to the <console>.\n'
      '    Return an <OK: status> with <order>.\n'
      '}', 'state_guard')

E.add('Use a state guard so a handler only runs for events where priority equals "urgent".',
      '(Page Oncall: TicketCreated Handler) when <priority> == "urgent" {\n'
      '    Extract the <ticket> from the <event: ticket>.\n'
      '    Send the <page> to the <oncall: phone>.\n'
      '    Return an <OK: status> for the <page>.\n'
      '}', 'state_guard')

E.add('Two handlers for the same event, dispatched by state guard.',
      '(Trial Welcome: UserSignedUp Handler) when <plan> == "trial" {\n'
      '    Extract the <user> from the <event: user>.\n'
      '    Send the <trial-email> to the <user: email>.\n'
      '    Return an <OK: status> for the <notification>.\n'
      '}\n\n'
      '(Pro Welcome: UserSignedUp Handler) when <plan> == "pro" {\n'
      '    Extract the <user> from the <event: user>.\n'
      '    Send the <pro-email> to the <user: email>.\n'
      '    Return an <OK: status> for the <notification>.\n'
      '}', 'state_guard')

# Template engine (ARO-0050)
E.add('Render a Mustache-style template with a single placeholder.',
      '(RenderGreeting: Example) {\n'
      '    Create the <template> with "Hello, {{name}}!".\n'
      '    Create the <data> with { name: "Ada" }.\n'
      '    Render the <html> from the <template> with <data>.\n'
      '    Return an <OK: status> with <html>.\n'
      '}', 'template')

E.add('Render an HTML invoice from a template and an order object.',
      '(RenderInvoice: Example) {\n'
      '    Create the <template> with "<h1>Invoice #{{id}}</h1><p>Total: {{total}}</p>".\n'
      '    Create the <data> with { id: 42, total: 199 }.\n'
      '    Render the <html> from the <template> with <data>.\n'
      '    Return an <OK: status> with <html>.\n'
      '}', 'template')

E.add('Render a template that loops over a list of items.',
      '(RenderItems: Example) {\n'
      '    Create the <template> with "{{#items}}- {{name}}\\n{{/items}}".\n'
      '    Create the <data> with { items: [\n'
      '        { name: "Widget" },\n'
      '        { name: "Gadget" }\n'
      '    ] }.\n'
      '    Render the <text> from the <template> with <data>.\n'
      '    Return an <OK: status> with <text>.\n'
      '}', 'template')

# Sink syntax (ARO-0043)
E.add('Use sink syntax to put a computed expression in the result position.',
      '(SinkDemo: Example) {\n'
      '    Create the <a> with 3.\n'
      '    Create the <b> with 4.\n'
      '    Return an <OK: status> with <a> + <b>.\n'
      '}', 'sink_syntax')

# Configure runtime (ARO-0035)
E.add('Configure the HTTP client timeout before issuing a request.',
      '(SlowRequest: Example) {\n'
      '    Configure the <http-client> with { timeout: 60 }.\n'
      '    Create the <api-url> with "https://example.com".\n'
      '    Request the <response> from the <api-url>.\n'
      '    Return an <OK: status> with <response>.\n'
      '}', 'configure')

E.add('Configure the file monitor with a specific directory and start it.',
      '(Application-Start: Watcher) {\n'
      '    Configure the <monitor-config> with { directory: "./inbox" }.\n'
      '    Start the <file-monitor> with <monitor-config>.\n'
      '    Keepalive the <application> for the <events>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'configure')

# Metrics (ARO-0044)
E.add('Increment a Prometheus counter on every request.',
      '(handleRequest: API) {\n'
      '    Log 1 to the <metric: requests-total>.\n'
      '    Return an <OK: status> for the <request>.\n'
      '}', 'metrics')

E.add('Record a request duration to a histogram metric.',
      '(handleSearch: API) {\n'
      '    Extract the <query> from the <queryParameters: q>.\n'
      '    Retrieve the <results> from the <search-repository>.\n'
      '    Log <results> to the <metric: search-results>.\n'
      '    Return an <OK: status> with <results>.\n'
      '}', 'metrics')

# Parameters (ARO-0047)
E.add('Read command-line parameters at startup.',
      '(Application-Start: CLI Tool) {\n'
      '    Parameters the <args> for the <application>.\n'
      '    Log <args> to the <console>.\n'
      '    Return an <OK: status> for the <startup>.\n'
      '}', 'parameters')

# Plugin qualifier call (handle.qualifier form)
E.add('Use a Collections plugin qualifier to pick a random list element.',
      '(PickRandom: Example) {\n'
      '    Create the <items> with ["a", "b", "c"].\n'
      '    Compute the <pick: Collections.pick-random> from <items>.\n'
      '    Return an <OK: status> with <pick>.\n'
      '}', 'plugin_qualifier')

E.add('Use a stats plugin qualifier to sort numbers.',
      '(SortViaPlugin: Example) {\n'
      '    Create the <nums> with [3, 1, 2].\n'
      '    Compute the <sorted: stats.sort> from <nums>.\n'
      '    Return an <OK: status> with <sorted>.\n'
      '}', 'plugin_qualifier')

# Plugin action call (Handle.Verb form)
E.add('Call a plugin action that renders Markdown to HTML.',
      '(RenderMD: Example) {\n'
      '    Create the <md> with "# Title".\n'
      '    Markdown.ToHTML the <html> from <md>.\n'
      '    Return an <OK: status> with <html>.\n'
      '}', 'plugin_action')

# Context-aware formatting (ARO-0031)
E.add('Use context-aware formatting so the same result renders differently for console vs HTTP.',
      '(handleStatus: API) {\n'
      '    Retrieve the <status> from the <system-status>.\n'
      '    Return an <OK: status> with <status>.\n'
      '}', 'context_aware')

# ── Round-3 gap booster: categories that scored 0% in the 100-prompt eval ──
# (user_defined_action, state_guard, plugin_qualifier, template, typed_event,
#  multi_file/openapi, application_end). These reinforce categories the
#  100-prompt sweep proved are under-represented.

# --- User-defined actions: 40 more diverse callers/callees -----------------
MORE_UDA = [
    ('Define a user-defined action that triples a number.',
     '(TripleValue: Action takes <number>) {\n'
     '    Extract the <n> from the <input: number>.\n'
     '    Compute the <tripled> from <n> * 3.\n'
     '    Return an <OK: status> with { tripled: <tripled> }.\n'
     '}'),
    ('Define a user-defined action that returns the negation of a number.',
     '(Negate: Action takes <number>) {\n'
     '    Extract the <n> from the <input: number>.\n'
     '    Compute the <neg> from 0 - <n>.\n'
     '    Return an <OK: status> with { neg: <neg> }.\n'
     '}'),
    ('Define a user-defined action that returns the absolute value of an integer.',
     '(AbsValue: Action takes <number>) {\n'
     '    Extract the <n> from the <input: number>.\n'
     '    Compute the <neg> from 0 - <n>.\n'
     '    Return an <OK: status> with { abs: <neg> } when <n> < 0.\n'
     '    Return an <OK: status> with { abs: <n> }.\n'
     '}'),
    ('Define a user-defined action that builds a greeting from a name.',
     '(BuildGreeting: Action takes <name>) {\n'
     '    Extract the <n> from the <input: name>.\n'
     '    Compute the <greeting> from "Hello, " ++ <n> ++ "!".\n'
     '    Return an <OK: status> with { greeting: <greeting> }.\n'
     '}'),
    ('Define a user-defined action that lowercases a string.',
     '(LowerCase: Action takes <text>) {\n'
     '    Extract the <s> from the <input: text>.\n'
     '    Compute the <lower: lowercase> from <s>.\n'
     '    Return an <OK: status> with { lower: <lower> }.\n'
     '}'),
    ('Define a user-defined action that hashes a password.',
     '(HashPassword: Action takes <password>) {\n'
     '    Extract the <p> from the <input: password>.\n'
     '    Compute the <h: hash> from <p>.\n'
     '    Return an <OK: status> with { hash: <h> }.\n'
     '}'),
    ('Define a user-defined action that validates an email address by length.',
     '(ValidateEmail: Action takes <email>) {\n'
     '    Extract the <e> from the <input: email>.\n'
     '    Compute the <len: length> from <e>.\n'
     '    Return an <Error: status> with { valid: false } when <len> == 0.\n'
     '    Return an <OK: status> with { valid: true }.\n'
     '}'),
    ('Define a user-defined action that counts the words in a string.',
     '(CountWords: Action takes <text>) {\n'
     '    Extract the <s> from the <input: text>.\n'
     '    Split the <words> from <s> with " ".\n'
     '    Compute the <count: length> from <words>.\n'
     '    Return an <OK: status> with { count: <count> }.\n'
     '}'),
    ('Define a user-defined action that capitalises the first letter of a string.',
     '(Capitalise: Action takes <text>) {\n'
     '    Extract the <s> from the <input: text>.\n'
     '    Compute the <upper: uppercase> from <s>.\n'
     '    Return an <OK: status> with { cap: <upper> }.\n'
     '}'),
    ('Define a user-defined action that computes a percentage of an integer total.',
     '(PercentOf: Action) {\n'
     '    Extract the <part> from the <input: part>.\n'
     '    Extract the <total> from the <input: total>.\n'
     '    Compute the <pct> from <part> * 100 / <total>.\n'
     '    Return an <OK: status> with { percent: <pct> }.\n'
     '}'),
    ('Define a user-defined action that adds VAT to a price at 19%.',
     '(AddVAT: Action takes <price>) {\n'
     '    Extract the <p> from the <input: price>.\n'
     '    Compute the <vat> from <p> * 19 / 100.\n'
     '    Compute the <gross> from <p> + <vat>.\n'
     '    Return an <OK: status> with { gross: <gross>, vat: <vat> }.\n'
     '}'),
    ('Define a user-defined action that picks the larger of two numbers using suffix when.',
     '(MaxOf: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Return an <OK: status> with { max: <a> } when <a> > <b>.\n'
     '    Return an <OK: status> with { max: <b> }.\n'
     '}'),
    ('Define a user-defined action that picks the smaller of two numbers using suffix when.',
     '(MinOf: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Return an <OK: status> with { min: <a> } when <a> < <b>.\n'
     '    Return an <OK: status> with { min: <b> }.\n'
     '}'),
    ('Define a user-defined action that checks if a number is even using suffix when.',
     '(IsEven: Action takes <number>) {\n'
     '    Extract the <n> from the <input: number>.\n'
     '    Compute the <r> from <n> % 2.\n'
     '    Return an <OK: status> with { even: true } when <r> == 0.\n'
     '    Return an <OK: status> with { even: false }.\n'
     '}'),
    ('Define a user-defined action that clamps a value to non-negative.',
     '(ClampLow: Action takes <value>) {\n'
     '    Extract the <v> from the <input: value>.\n'
     '    Return an <OK: status> with { clamped: 0 } when <v> < 0.\n'
     '    Return an <OK: status> with { clamped: <v> }.\n'
     '}'),
    ('Define a user-defined action that returns the head of a list.',
     '(Head: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <h: first> from <items>.\n'
     '    Return an <OK: status> with { head: <h> }.\n'
     '}'),
    ('Define a user-defined action that returns the last element of a list.',
     '(Last: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <t: last> from <items>.\n'
     '    Return an <OK: status> with { last: <t> }.\n'
     '}'),
    ('Define a user-defined action that reverses a list.',
     '(ReverseList: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <r: reverse> from <items>.\n'
     '    Return an <OK: status> with { reversed: <r> }.\n'
     '}'),
    ('Define a user-defined action that sums a list of integers via Reduce.',
     '(SumList: Action takes <list>) {\n'
     '    Extract the <items: List> from the <input: list>.\n'
     '    Reduce the <total: Integer> from the <items> with sum().\n'
     '    Return an <OK: status> with { sum: <total> }.\n'
     '}'),
    ('Define a user-defined action that returns the length of a list.',
     '(ListSize: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <n: length> from <items>.\n'
     '    Return an <OK: status> with { size: <n> }.\n'
     '}'),
    ('Define a user-defined action that calls another user-defined action.',
     '(Square: Action takes <number>) {\n'
     '    Extract the <n> from the <input: number>.\n'
     '    Compute the <sq> from <n> * <n>.\n'
     '    Return an <OK: status> with { sq: <sq> }.\n'
     '}\n\n'
     '(SquareOfSum: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Compute the <sum> from <a> + <b>.\n'
     '    Application.Square the <inner> from <sum>.\n'
     '    Extract the <result> from the <inner: sq>.\n'
     '    Return an <OK: status> with { result: <result> }.\n'
     '}'),
    ('Define a user-defined action that converts Celsius to Fahrenheit.',
     '(CtoF: Action takes <celsius>) {\n'
     '    Extract the <c> from the <input: celsius>.\n'
     '    Compute the <f> from <c> * 9 / 5 + 32.\n'
     '    Return an <OK: status> with { fahrenheit: <f> }.\n'
     '}'),
    ('Define a user-defined action that converts a price in cents to dollars and cents.',
     '(FormatPrice: Action takes <cents>) {\n'
     '    Extract the <c> from the <input: cents>.\n'
     '    Compute the <dollars> from <c> / 100.\n'
     '    Compute the <rem> from <c> % 100.\n'
     '    Return an <OK: status> with { dollars: <dollars>, cents: <rem> }.\n'
     '}'),
    ('Define a user-defined action that returns "yes" or "no" for a boolean input.',
     '(YesNo: Action takes <flag>) {\n'
     '    Extract the <b> from the <input: flag>.\n'
     '    Return an <OK: status> with { label: "yes" } when <b> == true.\n'
     '    Return an <OK: status> with { label: "no" }.\n'
     '}'),
    ('Define a user-defined action that concatenates first and last name with a space.',
     '(FullName: Action) {\n'
     '    Extract the <first> from the <input: first>.\n'
     '    Extract the <last> from the <input: last>.\n'
     '    Compute the <full> from <first> ++ " " ++ <last>.\n'
     '    Return an <OK: status> with { full: <full> }.\n'
     '}'),
    ('Define a user-defined action that returns a slug from a title (lowercased).',
     '(Slugify: Action takes <title>) {\n'
     '    Extract the <t> from the <input: title>.\n'
     '    Compute the <slug: lowercase> from <t>.\n'
     '    Return an <OK: status> with { slug: <slug> }.\n'
     '}'),
    ('Define a user-defined action that returns the discount price.',
     '(Discount: Action) {\n'
     '    Extract the <price> from the <input: price>.\n'
     '    Extract the <pct> from the <input: percent>.\n'
     '    Compute the <off> from <price> * <pct> / 100.\n'
     '    Compute the <final> from <price> - <off>.\n'
     '    Return an <OK: status> with { price: <final>, saved: <off> }.\n'
     '}'),
    ('Define a user-defined action that returns the count of unique items in a list.',
     '(UniqueCount: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <u: unique> from <items>.\n'
     '    Compute the <n: length> from <u>.\n'
     '    Return an <OK: status> with { unique: <n> }.\n'
     '}'),
    ('Define a user-defined action that doubles every number in a list.',
     '(DoubleEach: Action takes <list>) {\n'
     '    Extract the <items: List> from the <input: list>.\n'
     '    for each <item> in <items> {\n'
     '        Compute the <d> from <item> * 2.\n'
     '        Log <d> to the <console>.\n'
     '    }\n'
     '    Return an <OK: status> with { items: <items> }.\n'
     '}'),
    ('Define a user-defined action that returns true if a list is empty.',
     '(IsEmpty: Action takes <list>) {\n'
     '    Extract the <items> from the <input: list>.\n'
     '    Compute the <n: length> from <items>.\n'
     '    Return an <OK: status> with { result: "empty" } when <n> == 0.\n'
     '    Return an <OK: status> with { result: "non-empty" }.\n'
     '}'),
    ('Define a user-defined action that builds a key-value JSON object from two fields.',
     '(BuildPair: Action) {\n'
     '    Extract the <key> from the <input: key>.\n'
     '    Extract the <value> from the <input: value>.\n'
     '    Return an <OK: status> with { key: <key>, value: <value> }.\n'
     '}'),
    ('Define a user-defined action that picks the first non-empty string of two inputs.',
     '(Coalesce: Action) {\n'
     '    Extract the <a> from the <input: a>.\n'
     '    Extract the <b> from the <input: b>.\n'
     '    Compute the <la: length> from <a>.\n'
     '    Return an <OK: status> with { value: <a> } when <la> > 0.\n'
     '    Return an <OK: status> with { value: <b> }.\n'
     '}'),
    ('Define a user-defined action used inside an HTTP route handler.',
     '(NormalizeName: Action takes <name>) {\n'
     '    Extract the <n> from the <input: name>.\n'
     '    Compute the <lower: lowercase> from <n>.\n'
     '    Return an <OK: status> with { name: <lower> }.\n'
     '}\n\n'
     '(createUser: User API) {\n'
     '    Extract the <body> from the <request: body>.\n'
     '    Extract the <raw-name> from the <body: name>.\n'
     '    Application.NormalizeName the <res> from { name: <raw-name> }.\n'
     '    Extract the <name> from the <res: name>.\n'
     '    Create the <user> with { name: <name> }.\n'
     '    Store the <user> into the <user-repository>.\n'
     '    Return a <Created: status> with <user>.\n'
     '}'),
    ('Define a user-defined action that returns a default value when input is missing.',
     '(WithDefault: Action) {\n'
     '    Extract the <value> from the <input: value>.\n'
     '    Extract the <default> from the <input: default>.\n'
     '    Compute the <len: length> from <value>.\n'
     '    Return an <OK: status> with { result: <default> } when <len> == 0.\n'
     '    Return an <OK: status> with { result: <value> }.\n'
     '}'),
    ('Define a user-defined action that returns the area of a rectangle.',
     '(RectArea: Action) {\n'
     '    Extract the <w> from the <input: width>.\n'
     '    Extract the <h> from the <input: height>.\n'
     '    Compute the <a> from <w> * <h>.\n'
     '    Return an <OK: status> with { area: <a> }.\n'
     '}'),
    ('Define a user-defined action that returns the perimeter of a rectangle.',
     '(RectPerimeter: Action) {\n'
     '    Extract the <w> from the <input: width>.\n'
     '    Extract the <h> from the <input: height>.\n'
     '    Compute the <p> from <w> * 2 + <h> * 2.\n'
     '    Return an <OK: status> with { perimeter: <p> }.\n'
     '}'),
    ('Define a user-defined action that adds an item to an existing list.',
     '(AppendItem: Action) {\n'
     '    Extract the <items> from the <input: items>.\n'
     '    Extract the <item> from the <input: item>.\n'
     '    Compute the <combined> from <items> + [<item>].\n'
     '    Return an <OK: status> with { items: <combined> }.\n'
     '}'),
    ('Define a user-defined action that returns the kind label of a status code.',
     '(StatusKind: Action takes <code>) {\n'
     '    Extract the <c> from the <input: code>.\n'
     '    Return an <OK: status> with { kind: "success" } when <c> < 300.\n'
     '    Return an <OK: status> with { kind: "redirect" } when <c> < 400.\n'
     '    Return an <OK: status> with { kind: "client-error" } when <c> < 500.\n'
     '    Return an <OK: status> with { kind: "server-error" }.\n'
     '}'),
    ('Define a user-defined action that builds an HTTP problem-detail body.',
     '(Problem: Action) {\n'
     '    Extract the <title> from the <input: title>.\n'
     '    Extract the <status> from the <input: status>.\n'
     '    Return an <OK: status> with { title: <title>, status: <status>, kind: "about:blank" }.\n'
     '}'),
    ('Define a user-defined action used from an Application-Start.',
     '(Banner: Action takes <name>) {\n'
     '    Extract the <n> from the <input: name>.\n'
     '    Compute the <line> from "*** " ++ <n> ++ " ***".\n'
     '    Return an <OK: status> with { banner: <line> }.\n'
     '}\n\n'
     '(Application-Start: BannerApp) {\n'
     '    Application.Banner the <b> from { name: "Hello" }.\n'
     '    Extract the <banner> from the <b: banner>.\n'
     '    Log <banner> to the <console>.\n'
     '    Return an <OK: status> for the <startup>.\n'
     '}'),
]
for instr, code in MORE_UDA:
    E.add(instr, code, 'user_defined_action')

# --- State guards: 10 more ------------------------------------------------
MORE_STATE_GUARDS = [
    ('Guard an OrderUpdated handler so it only runs when status equals "shipped".',
     '(NotifyShipped: OrderUpdated Handler) when <status> == "shipped" {\n'
     '    Extract the <order> from the <event: order>.\n'
     '    Send the <shipping-email> to the <order: email>.\n'
     '    Return an <OK: status> for the <notification>.\n'
     '}'),
    ('Guard a UserUpdated handler so it only runs when role equals "admin".',
     '(AuditAdmin: UserUpdated Handler) when <role> == "admin" {\n'
     '    Extract the <user> from the <event: user>.\n'
     '    Log <user> to the <audit-log>.\n'
     '    Return an <OK: status> for the <audit>.\n'
     '}'),
    ('Guard a PaymentReceived handler so it only runs when currency equals "EUR".',
     '(EUOnly: PaymentReceived Handler) when <currency> == "EUR" {\n'
     '    Extract the <amount> from the <event: amount>.\n'
     '    Log <amount> to the <console>.\n'
     '    Return an <OK: status> for the <amount>.\n'
     '}'),
    ('Guard a TaskUpdated handler so it only runs when priority equals "high".',
     '(EscalateHigh: TaskUpdated Handler) when <priority> == "high" {\n'
     '    Extract the <task> from the <event: task>.\n'
     '    Send the <page> to the <oncall: phone>.\n'
     '    Return an <OK: status> for the <page>.\n'
     '}'),
    ('Guard a JobFinished handler so it only runs when result equals "failure".',
     '(AlertFailure: JobFinished Handler) when <result> == "failure" {\n'
     '    Extract the <job> from the <event: job>.\n'
     '    Send the <alert> to the <oncall: phone>.\n'
     '    Return an <OK: status> for the <alert>.\n'
     '}'),
    ('Guard a SubscriptionChanged handler so it only runs when plan equals "pro".',
     '(WelcomePro: SubscriptionChanged Handler) when <plan> == "pro" {\n'
     '    Extract the <user> from the <event: user>.\n'
     '    Send the <welcome> to the <user: email>.\n'
     '    Return an <OK: status> for the <notification>.\n'
     '}'),
    ('Guard a LoginAttempt handler so it only runs when success equals false.',
     '(LogFailedLogin: LoginAttempt Handler) when <success> == false {\n'
     '    Extract the <ip> from the <event: ip>.\n'
     '    Log <ip> to the <audit-log>.\n'
     '    Return an <OK: status> for the <log>.\n'
     '}'),
    ('Guard a FileChanged handler so it only runs for events where kind equals "modified".',
     '(ReloadConfig: FileChanged Handler) when <kind> == "modified" {\n'
     '    Extract the <path> from the <event: path>.\n'
     '    Log <path> to the <console>.\n'
     '    Return an <OK: status> for the <reload>.\n'
     '}'),
    ('Guard an OrderUpdated handler so it only runs when total exceeds 1000.',
     '(BigOrderAlert: OrderUpdated Handler) when <total> > 1000 {\n'
     '    Extract the <order> from the <event: order>.\n'
     '    Send the <alert> to the <oncall: phone>.\n'
     '    Return an <OK: status> for the <alert>.\n'
     '}'),
    ('Pair two handlers on the same event split by region state guard.',
     '(EUDispatch: OrderPlaced Handler) when <region> == "EU" {\n'
     '    Extract the <order> from the <event: order>.\n'
     '    Send the <order> to the <eu-warehouse>.\n'
     '    Return an <OK: status> for the <dispatch>.\n'
     '}\n\n'
     '(USDispatch: OrderPlaced Handler) when <region> == "US" {\n'
     '    Extract the <order> from the <event: order>.\n'
     '    Send the <order> to the <us-warehouse>.\n'
     '    Return an <OK: status> for the <dispatch>.\n'
     '}'),
]
for instr, code in MORE_STATE_GUARDS:
    E.add(instr, code, 'state_guard')

# --- Plugin qualifiers (handle.qualifier) — 10 more -----------------------
MORE_PLUGIN_QUAL = [
    ('Use a Collections plugin qualifier to shuffle a list.',
     '(ShufflePlay: Example) {\n'
     '    Create the <songs> with ["a", "b", "c"].\n'
     '    Compute the <order: Collections.shuffle> from <songs>.\n'
     '    Return an <OK: status> with <order>.\n'
     '}'),
    ('Use a Collections plugin qualifier to reverse a list.',
     '(ReverseList: Example) {\n'
     '    Create the <items> with [1, 2, 3].\n'
     '    Compute the <r: Collections.reverse> from <items>.\n'
     '    Return an <OK: status> with <r>.\n'
     '}'),
    ('Use a stats plugin qualifier to compute the average of a list.',
     '(Average: Example) {\n'
     '    Create the <nums> with [10, 20, 30].\n'
     '    Compute the <avg: stats.avg> from <nums>.\n'
     '    Return an <OK: status> with <avg>.\n'
     '}'),
    ('Use a stats plugin qualifier to compute the sum of a list.',
     '(Sum: Example) {\n'
     '    Create the <nums> with [1, 2, 3, 4].\n'
     '    Compute the <s: stats.sum> from <nums>.\n'
     '    Return an <OK: status> with <s>.\n'
     '}'),
    ('Use a stats plugin qualifier to find the minimum of a list.',
     '(MinValue: Example) {\n'
     '    Create the <nums> with [5, 1, 4].\n'
     '    Compute the <m: stats.min> from <nums>.\n'
     '    Return an <OK: status> with <m>.\n'
     '}'),
    ('Use a stats plugin qualifier to find the maximum of a list.',
     '(MaxValue: Example) {\n'
     '    Create the <nums> with [5, 1, 4].\n'
     '    Compute the <m: stats.max> from <nums>.\n'
     '    Return an <OK: status> with <m>.\n'
     '}'),
    ('Use a stats plugin qualifier to deduplicate a list.',
     '(Unique: Example) {\n'
     '    Create the <items> with [1, 1, 2, 3, 3].\n'
     '    Compute the <u: stats.unique> from <items>.\n'
     '    Return an <OK: status> with <u>.\n'
     '}'),
    ('Use a Collections plugin qualifier to pick the first element.',
     '(PickFirst: Example) {\n'
     '    Create the <items> with ["x", "y", "z"].\n'
     '    Compute the <f: Collections.first> from <items>.\n'
     '    Return an <OK: status> with <f>.\n'
     '}'),
    ('Use a Collections plugin qualifier to pick the last element.',
     '(PickLast: Example) {\n'
     '    Create the <items> with ["x", "y", "z"].\n'
     '    Compute the <l: Collections.last> from <items>.\n'
     '    Return an <OK: status> with <l>.\n'
     '}'),
    ('Use a Collections plugin qualifier inside a handler.',
     '(PickWinner: ContestEnded Handler) {\n'
     '    Extract the <entries> from the <event: entries>.\n'
     '    Compute the <winner: Collections.pick-random> from <entries>.\n'
     '    Send the <prize> to the <winner: email>.\n'
     '    Return an <OK: status> for the <notification>.\n'
     '}'),
]
for instr, code in MORE_PLUGIN_QUAL:
    E.add(instr, code, 'plugin_qualifier')

# --- Template / Render: 10 more ------------------------------------------
MORE_TEMPLATE = [
    ('Render a template that uses a single placeholder for the user name.',
     '(Welcome: Example) {\n'
     '    Create the <template> with "Welcome, {{name}}.".\n'
     '    Create the <data> with { name: "Pat" }.\n'
     '    Render the <message> from the <template> with <data>.\n'
     '    Return an <OK: status> with <message>.\n'
     '}'),
    ('Render an email body from a template using fields name and amount.',
     '(EmailBody: Example) {\n'
     '    Create the <template> with "Hi {{name}}, your bill is {{amount}}.".\n'
     '    Create the <data> with { name: "Sam", amount: 42 }.\n'
     '    Render the <body> from the <template> with <data>.\n'
     '    Return an <OK: status> with <body>.\n'
     '}'),
    ('Render a SMS notification from a template.',
     '(SMSText: Example) {\n'
     '    Create the <template> with "Code: {{code}}".\n'
     '    Create the <data> with { code: 1234 }.\n'
     '    Render the <sms> from the <template> with <data>.\n'
     '    Return an <OK: status> with <sms>.\n'
     '}'),
    ('Render an HTML page with a title and a paragraph.',
     '(HTMLPage: Example) {\n'
     '    Create the <template> with "<html><h1>{{title}}</h1><p>{{body}}</p></html>".\n'
     '    Create the <data> with { title: "Hi", body: "World" }.\n'
     '    Render the <html> from the <template> with <data>.\n'
     '    Return an <OK: status> with <html>.\n'
     '}'),
    ('Render a template that iterates over a list of users.',
     '(UserList: Example) {\n'
     '    Create the <template> with "{{#users}}- {{name}}\\n{{/users}}".\n'
     '    Create the <data> with { users: [\n'
     '        { name: "Ada" },\n'
     '        { name: "Lin" }\n'
     '    ] }.\n'
     '    Render the <list> from the <template> with <data>.\n'
     '    Return an <OK: status> with <list>.\n'
     '}'),
    ('Render a confirmation message from an event payload.',
     '(ConfirmOrder: OrderCreated Handler) {\n'
     '    Extract the <order> from the <event: order>.\n'
     '    Create the <template> with "Thanks for order #{{id}}.".\n'
     '    Render the <message> from the <template> with <order>.\n'
     '    Send the <message> to the <order: email>.\n'
     '    Return an <OK: status> for the <notification>.\n'
     '}'),
    ('Render a multi-line markdown summary from a template.',
     '(Summary: Example) {\n'
     '    Create the <template> with "# {{title}}\\n\\n{{body}}".\n'
     '    Create the <data> with { title: "Report", body: "All good." }.\n'
     '    Render the <md> from the <template> with <data>.\n'
     '    Return an <OK: status> with <md>.\n'
     '}'),
    ('Render an OG-style social card from a template.',
     '(SocialCard: Example) {\n'
     '    Create the <template> with "{{title}} — {{subtitle}}".\n'
     '    Create the <data> with { title: "ARO", subtitle: "Action-Result-Object" }.\n'
     '    Render the <card> from the <template> with <data>.\n'
     '    Return an <OK: status> with <card>.\n'
     '}'),
    ('Render a price tag from a template.',
     '(PriceTag: Example) {\n'
     '    Create the <template> with "{{name}}: €{{price}}".\n'
     '    Create the <data> with { name: "Widget", price: 9 }.\n'
     '    Render the <tag> from the <template> with <data>.\n'
     '    Return an <OK: status> with <tag>.\n'
     '}'),
    ('Render a template inline inside an HTTP route handler.',
     '(getCard: API) {\n'
     '    Extract the <id> from the <pathParameters: id>.\n'
     '    Retrieve the <user> from the <user-repository>.\n'
     '    Create the <template> with "Hello, {{name}}!".\n'
     '    Render the <body> from the <template> with <user>.\n'
     '    Return an <OK: status> with <body>.\n'
     '}'),
]
for instr, code in MORE_TEMPLATE:
    E.add(instr, code, 'template')

# --- Typed event extraction: 10 more --------------------------------------
MORE_TYPED_EVENTS = [
    ('Extract a typed Integer field from an event.',
     '(Track: ScoreUpdated Handler) {\n'
     '    Extract the <points: Integer> from the <event: points>.\n'
     '    Log <points> to the <console>.\n'
     '    Return an <OK: status> with <points>.\n'
     '}'),
    ('Extract a typed Float field from an event.',
     '(Measure: SensorRead Handler) {\n'
     '    Extract the <temp: Float> from the <event: temperature>.\n'
     '    Log <temp> to the <console>.\n'
     '    Return an <OK: status> with <temp>.\n'
     '}'),
    ('Extract a typed Boolean field from an event.',
     '(ToggleHandler: ToggleChanged Handler) {\n'
     '    Extract the <enabled: Boolean> from the <event: enabled>.\n'
     '    Log <enabled> to the <console>.\n'
     '    Return an <OK: status> with <enabled>.\n'
     '}'),
    ('Extract a typed String email from an event and send a welcome message.',
     '(Welcome: UserSignedUp Handler) {\n'
     '    Extract the <email: String> from the <event: email>.\n'
     '    Send the <welcome-email> to the <email>.\n'
     '    Return an <OK: status> for the <notification>.\n'
     '}'),
    ('Extract two typed fields from an event.',
     '(Audit: PaymentReceived Handler) {\n'
     '    Extract the <amount: Integer> from the <event: amount>.\n'
     '    Extract the <currency: String> from the <event: currency>.\n'
     '    Log <amount> to the <audit-log>.\n'
     '    Log <currency> to the <audit-log>.\n'
     '    Return an <OK: status> for the <audit>.\n'
     '}'),
    ('Extract a typed nested object field from an event.',
     '(LogUser: UserCreated Handler) {\n'
     '    Extract the <user-id: Integer> from the <event: user-id>.\n'
     '    Extract the <user-name: String> from the <event: user-name>.\n'
     '    Log <user-id> to the <console>.\n'
     '    Log <user-name> to the <console>.\n'
     '    Return an <OK: status> for the <log>.\n'
     '}'),
    ('Extract a typed Integer field then use it in a computation.',
     '(Score: GameEnded Handler) {\n'
     '    Extract the <points: Integer> from the <event: points>.\n'
     '    Compute the <bonus> from <points> * 2.\n'
     '    Log <bonus> to the <console>.\n'
     '    Return an <OK: status> with <bonus>.\n'
     '}'),
    ('Extract a typed field combined with a state guard.',
     '(BigOrder: OrderCreated Handler) when <region> == "EU" {\n'
     '    Extract the <total: Integer> from the <event: total>.\n'
     '    Log <total> to the <audit-log>.\n'
     '    Return an <OK: status> with <total>.\n'
     '}'),
    ('Extract a typed list field from an event.',
     '(TagSummary: PostPublished Handler) {\n'
     '    Extract the <tags: List> from the <event: tags>.\n'
     '    Compute the <n: length> from <tags>.\n'
     '    Log <n> to the <console>.\n'
     '    Return an <OK: status> with <n>.\n'
     '}'),
    ('Extract a typed timestamp from an event.',
     '(TouchIndex: FileChanged Handler) {\n'
     '    Extract the <ts: String> from the <event: timestamp>.\n'
     '    Log <ts> to the <audit-log>.\n'
     '    Return an <OK: status> with <ts>.\n'
     '}'),
]
for instr, code in MORE_TYPED_EVENTS:
    E.add(instr, code, 'typed_event')

# --- Application-End handlers: 6 more -------------------------------------
MORE_APP_END = [
    ('Write an Application-End: Success handler that stops the HTTP server.',
     '(Application-End: Success) {\n'
     '    Stop the <http-server> with <application>.\n'
     '    Return an <OK: status> for the <shutdown>.\n'
     '}'),
    ('Write an Application-End: Error handler that logs the error.',
     '(Application-End: Error) {\n'
     '    Extract the <error> from the <shutdown: error>.\n'
     '    Log <error> to the <console>.\n'
     '    Return an <OK: status> for the <error-handling>.\n'
     '}'),
    ('Write an Application-End: Success that flushes the audit log.',
     '(Application-End: Success) {\n'
     '    Log "shutting down" to the <audit-log>.\n'
     '    Return an <OK: status> for the <shutdown>.\n'
     '}'),
    ('Pair an Application-Start and Application-End: Success in one file.',
     '(Application-Start: Server) {\n'
     '    Log "starting" to the <console>.\n'
     '    Keepalive the <application> for the <events>.\n'
     '    Return an <OK: status> for the <startup>.\n'
     '}\n\n'
     '(Application-End: Success) {\n'
     '    Log "stopping" to the <console>.\n'
     '    Return an <OK: status> for the <shutdown>.\n'
     '}'),
    ('Write an Application-End: Error that pages oncall and exits.',
     '(Application-End: Error) {\n'
     '    Extract the <error> from the <shutdown: error>.\n'
     '    Send the <error> to the <oncall: phone>.\n'
     '    Return an <OK: status> for the <error-handling>.\n'
     '}'),
    ('Write an Application-End: Success that closes a database connection.',
     '(Application-End: Success) {\n'
     '    Stop the <database> with <application>.\n'
     '    Return an <OK: status> for the <shutdown>.\n'
     '}'),
]
for instr, code in MORE_APP_END:
    E.add(instr, code, 'application_end')


def main():
    print(f'generated {len(E)} single-file + {len(MF)} multi-file candidates', flush=True)
    kept, failed = validate_and_filter(E)
    mf_kept, mf_failed = validate_multi_file(MF)
    print(f'  single-file passed: {len(kept)}', flush=True)
    print(f'  multi-file passed:  {len(mf_kept)}', flush=True)
    print(f'  failed (dropped):   {len(failed) + len(mf_failed)}', flush=True)
    kept.extend(mf_kept)

    # Fall through to the original write logic, but accept the merged list.
    _run_main_write(kept, failed + [(ex, err, '\n\n'.join(ex['files'].values()))
                                     for ex, err in mf_failed])


def _run_main_write(kept, failed):
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
