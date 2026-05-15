"""
fix_training_data.py
Generates three JSONL training-pair files from FIXTRAIN.md issue catalogue.

  fix_wrong_explanation.jsonl  — wrong code  →  why it is wrong
  fix_wrong_fix.jsonl          — wrong code  →  corrected code
  fix_explanation_fix.jsonl    — explanation →  corrected code

Call directly (python fix_training_data.py) or import and call generate().
"""

import json
from pathlib import Path
from typing import Optional, Tuple

SCRIPT_DIR = Path(__file__).parent.resolve()

SYSTEM = (
    "You are an expert ARO (Action Result Object) programmer. "
    "ARO is a DSL where every statement is: Verb the <Result> preposition [the] <Object>. "
    "Feature sets follow (Name: Business Activity) { statements }. "
    "Variables are immutable. String concatenation uses ++. "
    "Event publishing uses Emit a <Name: event> with <data>."
)

# ---------------------------------------------------------------------------
# Issue catalogue — (id, wrong, explanation, fix)
# ---------------------------------------------------------------------------
ISSUES = [
    (
        "001",
        "Emit the <user> to the <user-created-event>.",
        "Emit requires the event type in the result position with a `: event` qualifier and the "
        "payload after `with`. This example puts data (`<user>`) in result position, the event "
        "name in object position, and uses the wrong preposition `to`.",
        "Emit a <UserCreated: event> with <user>.",
    ),
    (
        "002",
        "Log the <message> for the <console> with \"Calculator ready\".",
        "Log syntax is `Log <message> to the <console>.` — the preposition is `to`, not `for`. "
        "There is no combined `for` + `with` form. The extra result variable is also incorrect.",
        "Log \"Calculator ready\" to the <console>.",
    ),
    (
        "003",
        "Compute the <label> from \"Order placed: \" + <order-id>.",
        "ARO uses `++` for string concatenation. `+` is reserved for numeric arithmetic only. "
        "Using `+` with string operands is an error.",
        "Compute the <label> from \"Order placed: \" ++ <order-id>.",
    ),
    (
        "004",
        "Compute the <total> from the <quantity> with <price>.",
        "The `Compute … from X with Y` form is only valid for set operations (`intersect`, "
        "`union`, `difference`) where a qualifier is on the result. For arithmetic the entire "
        "expression goes after `from`.",
        "Compute the <total> from <quantity> * <price>.",
    ),
    (
        "005",
        "while <count> <= 3 {\n    Log <count> to the <console>.\n}",
        "No ARO proposal defines a `while` loop. The only iteration construct is `For-each`. "
        "Presenting `while` as canonical ARO syntax is incorrect.",
        "For-each <item> in <items> {\n    Log <item> to the <console>.\n}",
    ),
    (
        "006",
        "Application ExtractDemo {\n    Extract the <age> from the <person>.\n}",
        "ARO feature set declarations must follow `(Feature Name: Business Activity) { ... }`. "
        "The form `Application X {` does not exist. The colon-separated business activity inside "
        "parentheses is mandatory.",
        "(ExtractDemo: My Application) {\n    Extract the <age> from the <person>.\n    Return an <OK: status> with <age>.\n}",
    ),
    (
        "007",
        "Extract the age from the person",
        "All variable identifiers in ARO must be enclosed in angle brackets `<...>`. Bare words "
        "are not valid variable references. Statements also require a trailing period.",
        "Extract the <age> from the <person>.",
    ),
    (
        "008",
        "Execute the <result> from the <console> with \"date +%Y-%m-%d\".",
        "Execute uses `for` to identify the command, not `from`. `from the <console>` incorrectly "
        "implies the console is a data source.",
        "Execute the <result> for \"date +%Y-%m-%d\".",
    ),
    (
        "009",
        "Throw an <Unauthorized: error> for the <admin> to the <console> with <no-access>.",
        "`Throw` accepts only the `for` preposition. The additional clauses `to the <console>` "
        "and `with <no-access>` are not valid for Throw.",
        "Throw an <Unauthorized: error> for the <admin>.",
    ),
    (
        "010",
        "Log <debug> to the <console> for the <application> with <level>.",
        "Once the `to the <console>` target is specified, Log accepts no further clauses.",
        "Log <debug> to the <console>.",
    ),
    (
        "011",
        "emit \"Hello from ARO!\" to the <console> <Output>.",
        "`Emit` is a domain-event publisher, not a console-output action. These forms are "
        "completely fabricated. Console output uses `Log`, not `Emit`.",
        "Log \"Hello from ARO!\" to the <console>.",
    ),
    (
        "012",
        "Publish the <result> as <build>.",
        "Publish syntax is `Publish as <alias> <variable>.` — the alias comes immediately after "
        "`Publish`, then the variable. The shown entry reverses alias and variable and adds an "
        "incorrect `the`.",
        "Publish as <build> <result>.",
    ),
    (
        "013",
        "when true {\n    Log \"active\" to the <console>.\n} else {\n    Log \"inactive\" to the <console>.\n}",
        "In ARO `when` is exclusively a per-statement suffix guard. There are no standalone "
        "`when { } else { }` block constructs. Multiple statements cannot be grouped under a "
        "single `when` block.",
        "Log \"active\" to the <console> when <active>.\nLog \"inactive\" to the <console> when <inactive>.",
    ),
    (
        "014",
        "Compute the <greeting> from \"Hello, \" + \"World\".",
        "ARO uses `++` for string concatenation. `+` is the arithmetic addition operator. "
        "There is no comma operator. The claim that ARO uses `+` for strings is false.",
        "Compute the <greeting> from \"Hello, \" ++ \"World\".",
    ),
    (
        "015",
        "All `.aro` files exist at the top level of the application directory. ARO does not support subdirectories for `.aro` files.",
        "This is factually wrong. ARO automatically discovers `.aro` files in the application "
        "directory AND all subdirectories to any depth. The `sources/` subdirectory convention "
        "is explicitly supported.",
        "All `.aro` files in the directory and subdirectories are automatically discovered. "
        "Files can be in root, `sources/`, or any subdirectory to any depth. No imports are needed.",
    ),
    (
        "016",
        "Compute the <doubled> from <counter> with <counter> * 2.",
        "The `from X with Y` form of Compute is only valid for set operations where a qualifier "
        "(`intersect`, `union`, `difference`) is present on the result. For arithmetic, the "
        "entire expression goes after `from`.",
        "Compute the <doubled> from <counter> * 2.",
    ),
    (
        "017",
        "ARO provides basic set operations: union, difference, and count.",
        "`count` is a built-in computation qualifier (`Compute the <n: count> from <items>.`), "
        "not a set operation. The three set operations are `intersect`, `difference`, and `union`.",
        "ARO provides three set operations: `intersect`, `union`, and `difference`, used as "
        "`Compute the <result: intersect> from <a> with <b>.`",
    ),
    (
        "018",
        "Compute the <missing-items> from the <expected> with the <found>.",
        "Without the `: difference` qualifier on the result, Compute does not know which set "
        "operation to perform.",
        "Compute the <missing-items: difference> from the <expected> with the <found>.",
    ),
    (
        "019",
        "(\"Strip Fragment: \" + <url: \"https://example.com/page#section1\">) {",
        "Feature set headers must follow `(FeatureName: BusinessActivity) {`. A string "
        "concatenation expression is not a valid feature set name.",
        "(StripFragment: URL Normalization) {",
    ),
    (
        "020",
        "(UserSignedUp Handler) {\n    Extract the <user> from the <event: user>.\n}",
        "Feature set headers require both a feature name AND a business activity separated by a "
        "colon: `(FeatureName: BusinessActivity)`. Without the colon and business activity this "
        "is not valid ARO syntax.",
        "(Handle User Signup: UserSignedUp Handler) {\n    Extract the <user> from the <event: user>.\n    Return an <OK: status> for the <signup>.\n}",
    ),
    (
        "021a",
        "Emit the <user-registered> event.",
        "Emit requires the `: event` qualifier (lowercase) on the result and the `with` "
        "preposition for the payload. Bare `event` as a bare word after the variable is not "
        "valid syntax.",
        "Emit a <UserRegistered: event> with <user>.",
    ),
    (
        "021b",
        "Emit a <NormalizeUrl: Event> with { url: <result> }.",
        "The event qualifier must be lowercase `event`, not capitalised `Event`. Also, "
        "object-literal `{ url: <result> }` is not the standard ARO payload form — pass the "
        "variable directly.",
        "Emit a <NormalizeUrl: event> with <result>.",
    ),
    (
        "022",
        "Subscribe to the <user-registered> event.",
        "`Subscribe` is not an ARO action. Event handlers are registered automatically by naming "
        "convention — no explicit subscription call is needed. There is no `Subscribe` verb in "
        "the ARO action vocabulary.",
        "(Handle User Registration: UserRegistered Handler) {\n    Extract the <user> from the <event: user>.\n    Return an <OK: status> for the <registration>.\n}",
    ),
    (
        "023",
        "Set the <user> to { name: \"Bob\", age: 30 }.",
        "ARO variables are unconditionally immutable — no verb bypasses this. There is no `Set` "
        "action in ARO. `Update` modifies fields on an existing repository object, not local "
        "symbol table bindings.",
        "Create the <updated-user> with { name: \"Bob\", age: 30 }.",
    ),
    (
        "024",
        "Accept the <price> from 200.",
        "`Accept` is the state-transition action. Its only valid preposition is `on`. The "
        "`from 200` form is not valid. Accept transitions an entity to a new state, it does not "
        "rebind local variables.",
        "Accept the <order: placed>.",
    ),
    (
        "025",
        "(GET /users) {\n    Return an <OK: status> with <users>.\n}",
        "ARO uses contract-first HTTP via OpenAPI. Feature set names must match the `operationId` "
        "from `openapi.yaml`, not HTTP method+path patterns. `GET /users` is not valid feature "
        "set name syntax.",
        "(listUsers: User API) {\n    Retrieve the <users> from the <user-repository>.\n    Return an <OK: status> with <users>.\n}",
    ),
    (
        "026",
        "Compute the <msg> from \"[AUDIT] user-repository: \" + <changeType> + \" (id: \" + <entityId> + \")\".",
        "ARO uses `++` for string concatenation. `+` is arithmetic addition only.",
        "Compute the <msg> from \"[AUDIT] user-repository: \" ++ <changeType> ++ \" (id: \" ++ <entityId> ++ \")\".",
    ),
    (
        "027",
        "Transform the <title> from <text> using <titlecase>.",
        "`using` is not a valid preposition in ARO. Transform's valid prepositions are `from` "
        "(with optional `with`). The qualifier for the transformation goes on the result variable.",
        "Transform the <title: titlecase> from <text>.",
    ),
    (
        "028",
        "Store the <order> in the <order-repository>.",
        "While the runtime accepts `in`, the canonical documented form throughout all ARO book "
        "examples and AppendixA is `into`. Training data should use canonical form.",
        "Store the <order> into the <order-repository>.",
    ),
    (
        "029",
        "Emit the <event-data> to the <event-bus>.",
        "Emit does not take an explicit destination. The event bus is implicit. The valid "
        "preposition is `with`, not `to`. The result also lacks the required `: event` qualifier.",
        "Emit a <CampaignStarted: event> with <campaign-data>.",
    ),
    (
        "030a",
        "Publish the <result> as <alias>.",
        "The only valid Publish syntax is `Publish as <alias> <variable>.` — `as` comes "
        "immediately after `Publish`, then the alias, then the variable. The shown form inverts "
        "alias and variable and adds an incorrect `the`.",
        "Publish as <alias> <result>.",
    ),
    (
        "030b",
        "Publish the <notification> with the <channel>.",
        "Publish does not accept `with` or `to` prepositions and has no named destination. "
        "The only valid form is `Publish as <alias> <variable>.`",
        "Publish as <notification> <notification>.",
    ),
    (
        "031",
        "Publish broadcasts events to external systems like a message broker or pub/sub system.",
        "Publish is entirely in-process. It registers data in a global registry within the same "
        "application process. The external pub/sub claim is a hallucinated feature that does not "
        "exist in ARO.",
        "Publish makes a value accessible to other feature sets within the same application via "
        "an in-process global registry. It does not connect to external message brokers.",
    ),
    (
        "032",
        "(Emit a UserSignedUp event) when user.email is set.",
        "Feature set headers use `(Name: Business Activity)` format, not parenthesised "
        "statements. `user.email is set` is not valid ARO condition syntax.",
        "(Send Welcome Email: UserSignedUp Handler) {\n    Extract the <user> from the <event: user>.\n    Emit a <WelcomeEmail: event> with <user>.\n    Return an <OK: status> for the <email>.\n}",
    ),
    (
        "033",
        "when <age> >= 18 {\n    Log \"Adult user\" to the <console>.\n    Log <age> to the <console>.\n}",
        "ARO does not have `when <condition> { ... }` block constructs. `when` is only a "
        "trailing guard suffix on individual statements. Multiple statements cannot be grouped "
        "under a single `when` block.",
        "Log \"Adult user\" to the <console> when <age> >= 18.\nLog <age> to the <console> when <age> >= 18.",
    ),
    (
        "034",
        "Accept the <user: email> with { error: \"Invalid email format\" }.",
        "Accept's only valid preposition is `on`. The canonical form is `Accept the <entity: new-state>.` "
        "There is no `with { error: ... }` form — this conflates Accept with Validate/Throw.",
        "Accept the <user: valid>.",
    ),
    (
        "035",
        "Throw an <InvalidUser: error> with { message: \"Invalid user data\" }.",
        "Throw's only valid preposition is `for`. There is no `with` clause for Throw.",
        "Throw an <InvalidUser: error> for the <invalid: user-data>.",
    ),
    (
        "036",
        "Delete the <user> with { id: 42 }.",
        "Delete uses the `from` preposition with an optional `where` clause. There is no `with` "
        "dictionary form.",
        "Delete the <user> from the <user-repository> where id = 42.",
    ),
    (
        "037",
        "{{ <first-name> + \" \" + <last-name> }}",
        "ARO's string concatenation operator is `++`. Using `+` in template expressions is "
        "incorrect.",
        "{{ <first-name> ++ \" \" ++ <last-name> }}",
    ),
    (
        "038",
        "(response: Response) <- (.Body from https://api.example.com/data).",
        "ARO does not have `<-` arrow-assignment syntax, `.Body from` accessor chains, or "
        "type-annotated assignments. These are hallucinated non-ARO constructs.",
        "Request the <response> from \"https://api.example.com/data\".",
    ),
    (
        "039",
        "(Parallel For Each item in items) {\n    Log <item> to the <console>.\n}",
        "Canonical ARO parallel loop syntax is lowercase with angle brackets. The shown form "
        "uses title case, no angle brackets, and wraps in parentheses as if it were a feature "
        "set declaration.",
        "parallel for each <item> in <items> {\n    Log <item> to the <console>.\n}",
    ),
    (
        "040",
        "Render the <greeting> from the <Render Template>.",
        "Render uses `to the <console>`, not `from`. The object `<Render Template>` referencing "
        "a feature set name as a variable is also a fabricated pattern.",
        "Render the <greeting> to the <console>.",
    ),
    (
        "041a",
        "LogLine <- extract the <message> from the <event-log>.",
        "ARO does not have `<-` arrow-assignment syntax. `extract` with a lowercase first letter "
        "is also wrong — ARO verbs are capitalised.",
        "Extract the <message> from the <event-log>.",
    ),
    (
        "041b",
        "Emit <event> to the <event-hub>.",
        "Emit requires the `: event` qualifier on the result, uses `with` not `to`, and does not "
        "accept an explicit destination. The event bus is implicit.",
        "Emit a <DataProcessed: event> with <data>.",
    ),
    (
        "042",
        "Read the <file: streaming> from the <file-path>.",
        "The streaming-mode qualifier goes on the verb, not on the result variable. The canonical "
        "form places the qualifier in angle-bracket verb position.",
        "<Read: streaming> the <data> from <file-path>.",
    ),
    (
        "043",
        "Listen the <input> from the <keyboard>.",
        "Listen syntax is `Listen the <keyboard> to the <stdin>.` — the preposition is `to`, "
        "not `from`, and the keyboard/terminal object is in the result position, not `<input>`.",
        "Listen the <keyboard> to the <stdin>.",
    ),
    (
        "044",
        "Return <sum> from <a> + <b>.",
        "Return syntax is `Return an <OK: status> with <data>.` or "
        "`Return a <Status: status> for the <object>.` Using `from` as the preposition for "
        "Return is not valid.",
        "Compute the <sum> from <a> + <b>.\nReturn an <OK: status> with <sum>.",
    ),
]


def _pair(user: str, assistant: str, task_type: str) -> dict:
    return {
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user",   "content": user},
            {"role": "assistant", "content": assistant},
        ],
        "task_type": task_type,
    }


def generate(out_dir: Optional[Path] = None) -> Tuple[Path, Path, Path]:
    """
    Write the three JSONL files.  Returns (path1, path2, path3).
    """
    out_dir = out_dir or SCRIPT_DIR
    out_dir = Path(out_dir)

    p1 = out_dir / "fix_wrong_explanation.jsonl"
    p2 = out_dir / "fix_wrong_fix.jsonl"
    p3 = out_dir / "fix_explanation_fix.jsonl"

    with p1.open("w") as f1, p2.open("w") as f2, p3.open("w") as f3:
        for (issue_id, wrong, explanation, fix) in ISSUES:
            # List 1 — wrong code → why it is wrong
            pair1 = _pair(
                f"What is wrong with this ARO code?\n\n```aro\n{wrong}\n```",
                explanation,
                "debugging",
            )

            # List 2 — wrong code → corrected code
            pair2 = _pair(
                f"Fix this ARO code:\n\n```aro\n{wrong}\n```",
                f"```aro\n{fix}\n```",
                "debugging",
            )

            # List 3 — explanation → corrected code
            pair3 = _pair(
                f"Show me the correct ARO syntax for this scenario: {explanation}",
                f"```aro\n{fix}\n```",
                "code_generation",
            )

            f1.write(json.dumps(pair1) + "\n")
            f2.write(json.dumps(pair2) + "\n")
            f3.write(json.dumps(pair3) + "\n")

    print(f"fix_wrong_explanation.jsonl  — {len(ISSUES)} pairs → {p1}")
    print(f"fix_wrong_fix.jsonl          — {len(ISSUES)} pairs → {p2}")
    print(f"fix_explanation_fix.jsonl    — {len(ISSUES)} pairs → {p3}")
    return p1, p2, p3


if __name__ == "__main__":
    generate()
