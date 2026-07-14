"""
Unit tests for the pure-python data-quality helpers in Train/script/config.py.

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_config_helpers.py

No model, no aro binary, and no knowledge.json required — everything tested
here is pure python. Known-bad snippets are taken verbatim from
Train/FIXTRAIN.md (the training-data issue catalogue).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import config  # noqa: E402
from config import (  # noqa: E402
    check_fixtrain_issues,
    lint_pair_output,
    validate_syntax_reference,
    hallucinated_verbs_in_code,
    check_verb_prepositions,
    check_openapi_contract,
    near_duplicate_filter,
    source_quality_score,
    word_overlap_ratio,
    auto_wrap_aro,
    is_complete_program,
    derive_source_quality_from_validation,
)


def _rules(code):
    return {v['rule'] for v in check_fixtrain_issues(code, include_warnings=True)}


def _error_rules(code):
    return {v['rule'] for v in check_fixtrain_issues(code)}


# ── FIXTRAIN lint: known-bad snippets from FIXTRAIN.md must be flagged ───────

def test_string_concat_plus():
    assert 'string-concat-plus' in _rules('Compute the <label> from "Order placed: " + <order-id>.')
    assert 'string-concat-plus' in _rules('Create the <ir-output> with "Hello, World" + "\\n".')
    assert 'string-concat-plus' in _rules('{{ <first-name> + " " + <last-name> }}')
    # `++` is correct and must NOT be flagged
    assert 'string-concat-plus' not in _rules('Compute the <greeting> from "Hello, " ++ <name>.')
    # numeric addition must NOT be flagged
    assert 'string-concat-plus' not in _rules('Compute the <total> from <price> + <qty>.')


def test_emit_wrong_forms():
    # ISSUE-001: data/event swapped + wrong preposition
    assert {'emit-with-destination', 'emit-missing-event-qualifier'} <= _rules(
        'Emit the <user> to the <user-created-event>.')
    # ISSUE-029: explicit destination
    assert 'emit-with-destination' in _rules('Emit the <event-data> to the <event-bus>.')
    # ISSUE-011: lowercase emit to console
    assert 'emit-with-destination' in _rules('emit "Hello from ARO!" to the <console> <Output>.')
    # ISSUE-021: missing `: event` qualifier / capitalised `Event`
    assert 'emit-missing-event-qualifier' in _rules('Emit the <user-registered> event.')
    assert 'emit-missing-event-qualifier' in _rules('Emit an <EventX> with <result>.')
    assert 'emit-missing-event-qualifier' in _rules('Emit a <NormalizeUrl: Event> with <result>.')
    # Correct Emit must pass
    assert not _error_rules('Emit a <UserCreated: event> with <user>.')


def test_log_wrong_forms():
    # ISSUE-002
    assert 'log-for-console' in _rules('Log the <message> for the <console> with "Calculator ready".')
    # ISSUE-010: extra clauses after `to the <console>`
    assert 'log-extra-clauses' in _rules('Log <debug> to the <console> for the <application> with <level>.')
    # Correct Log — including a `when` guard — must pass
    assert not _error_rules('Log "Calculator ready" to the <console>.')
    assert not _error_rules('Log <error> to the <console> when <failed>.')


def test_publish_wrong_forms():
    # ISSUE-012/030: inverted / non-`as` forms
    assert 'publish-not-as-form' in _rules('Publish the <result> as <build>.')
    assert 'publish-not-as-form' in _rules('Publish the <notification> with the <channel>.')
    assert 'publish-not-as-form' in _rules('Publish the <shared-value> to the <registry>.')
    # Canonical form must pass
    assert not _error_rules('Publish as <alias> <result>.')


def test_when_and_while_blocks():
    # ISSUE-013/033: standalone when-blocks
    assert 'when-block' in _rules('when <age> >= 18 {\n    Log "Adult user" to the <console>.\n}')
    assert 'when-block' in _rules('when true {\n    Log "active" to the <console>.\n}')
    assert 'else-block' in _rules(
        'when true {\n    Log "a" to the <console>.\n} else {\n    Log "b" to the <console>.\n}')
    # ISSUE-005: while loops
    assert 'while-loop' in _rules('while <count> <= 3 {\n    Log <count> to the <console>.\n}')
    # Statement-suffix `when` guard is the valid form — must pass
    assert not _error_rules('Return an <OK: status> with <user> when <active>.')
    # Feature-set declaration guards must pass
    assert not _error_rules(
        '(Handle Payment: OrderPlaced Handler) when <status> = "paid" {\n'
        '    Extract the <order> from the <event: order>.\n'
        '    Return an <OK: status> for the <payment>.\n}')


def test_hallucinated_actions():
    assert 'hallucinated-subscribe' in _rules('Subscribe to the <user-registered> event.')
    assert 'hallucinated-set' in _rules('Set the <user> to { name: "Bob", age: 30 }.')
    assert 'hallucinated-build' in _rules('Build the <result> with <options> from the <source>.')


def test_missing_angle_brackets():
    # ISSUE-007
    assert 'missing-angle-brackets' in _rules('Extract the age from the person')
    # Correct bracketed form must pass
    assert not _error_rules('Extract the <age> from the <person>.')


def test_feature_set_declarations():
    # ISSUE-006: keyword headers
    assert 'feature-set-keyword-header' in _rules('Application ExtractDemo {\n    Extract the <age> from the <person>.\n}')
    assert 'feature-set-keyword-header' in _rules('Feature Set: Execute Action Examples {\n}')
    # ISSUE-020/025: parenthesised header without business activity
    assert 'feature-set-missing-activity' in _rules('(UserSignedUp Handler) {\n    Extract the <user> from the <event: user>.\n}')
    assert 'feature-set-missing-activity' in _rules('(GET /users) {\n    Return an <OK: status> with <users>.\n}')
    # Valid headers must pass
    assert not _error_rules(
        '(listUsers: User API) {\n'
        '    Retrieve the <users> from the <user-repository>.\n'
        '    Return an <OK: status> with <users>.\n}')
    assert not _error_rules(
        '(Application-Start: My App) {\n'
        '    Log "Starting..." to the <console>.\n'
        '    Return an <OK: status> for the <startup>.\n}')


def test_compute_from_with_arithmetic():
    # ISSUE-004/016
    assert 'compute-from-with-arithmetic' in _rules('Compute the <total> from the <quantity> with <price>.')
    assert 'compute-from-with-arithmetic' in _rules('Compute the <discount> from <amount> with <rate>.')
    # Set operations WITH a qualifier are the valid `from … with` form
    assert not _error_rules('Compute the <missing-items: difference> from the <expected> with the <found>.')
    assert not _error_rules('Compute the <common: intersect> from <a> with <b>.')
    # Plain arithmetic must pass
    assert not _error_rules('Compute the <total> from <quantity> * <price>.')


def test_wrong_prepositions():
    # ISSUE-009/035: Throw
    assert 'throw-wrong-preposition' in _rules(
        'Throw an <Unauthorized: error> for the <admin> to the <console> with <no-access>.')
    assert 'throw-wrong-preposition' in _rules('Throw an <InvalidUser: error> with { message: "bad" }.')
    assert not _error_rules('Throw an <Unauthorized: error> for the <admin>.')
    # ISSUE-027: Transform using
    assert 'transform-using' in _rules('Transform the <title> from <text> using <titlecase>.')
    assert not _error_rules('Transform the <title: titlecase> from <text>.')
    # ISSUE-036: Delete with dict
    assert 'delete-with-dict' in _rules('Delete the <user> with { id: 42 }.')
    assert not _error_rules('Delete the <user> from the <user-repository> where id = 42.')
    # ISSUE-008: Execute from
    assert 'execute-from' in _rules('Execute the <result> from the <console> with "date +%Y-%m-%d".')
    # ISSUE-043: Listen from
    assert 'listen-from' in _rules('Listen the <input> from the <keyboard>.')
    assert not _error_rules('Listen the <keyboard> to the <stdin>.')
    # ISSUE-044: Return from
    assert 'return-from' in _rules('Return <sum> from <a> + <b>.')
    assert not _error_rules('Return an <OK: status> with <sum>.')
    # ISSUE-024/034: Accept from/with
    assert 'accept-wrong-preposition' in _rules('Accept the <price> from 200.')
    assert 'accept-wrong-preposition' in _rules('Accept the <user: email> with { error: "Invalid email format" }.')
    assert not _error_rules('Accept the <order: placed>.')


def test_arrow_assignment():
    # ISSUE-038/041
    assert 'arrow-assignment' in _rules('(response: Response) <- (.Body from https://api.example.com/data).')
    assert 'arrow-assignment' in _rules('LogLine <- extract the <message> from the <event-log>.')
    assert 'arrow-assignment' in _rules('processedAt: DateTime <- now.')
    # Ordinary hyphenated variables must pass
    assert not _error_rules('Extract the <user-id> from the <request: body>.')


def test_warn_rules_do_not_drop():
    # ISSUE-028: `Store … in the` is a warn, not an error
    code = 'Store the <order> in the <order-repository>.'
    assert 'store-in-preposition' in _rules(code)
    assert 'store-in-preposition' not in _error_rules(code)
    assert not _error_rules('Store the <order> into the <order-repository>.')


def test_comments_are_stripped_before_linting():
    assert not _error_rules(
        '(* This shows why while loops and + concatenation are wrong in ARO *)\n'
        'Log "ok" to the <console>.')


def test_canonical_examples_are_clean():
    # The CLAUDE.md flagship examples must produce zero error violations.
    code = """(createUser: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
}"""
    assert not _error_rules(code)
    code2 = """(Application-Start: File Watcher) {
    Log "Starting..." to the <console>.
    Start the <file-monitor> with ".".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}"""
    assert not _error_rules(code2)
    code3 = """For each <item> in <items> {
    Compute the <name: uppercase> from the <item: name>.
    Log <name> to the <console>.
}"""
    assert not _error_rules(code3)


def test_lint_pair_output_gate():
    bad_pair = {
        'instruction': 'Show me event emission',
        'output': '```aro\nEmit the <user> to the <user-created-event>.\n```',
    }
    assert lint_pair_output(bad_pair)

    good_pair = {
        'instruction': 'Show me event emission',
        'output': '```aro\nEmit a <UserCreated: event> with <user>.\n```',
    }
    assert not lint_pair_output(good_pair)

    # Blocks framed as deliberate negative examples are skipped
    negative_example_pair = {
        'instruction': 'Explain a common mistake',
        'output': ('This is WRONG because Emit takes no destination:\n'
                   '```aro\nEmit the <x> to the <event-bus>.\n```'),
    }
    assert not lint_pair_output(negative_example_pair)

    # messages-format pairs are linted via the assistant turn
    bad_messages_pair = {
        'messages': [
            {'role': 'system', 'content': 'sys'},
            {'role': 'user', 'content': 'Write a loop'},
            {'role': 'assistant', 'content': '```aro\nwhile <count> <= 3 {\n    Log <count> to the <console>.\n}\n```'},
        ],
    }
    assert lint_pair_output(bad_messages_pair)

    # Prose-only pairs pass through
    assert not lint_pair_output({'instruction': 'q', 'output': 'Plain prose answer.'})


# ── Syntax reference guard (#377) ────────────────────────────────────────────

def test_validate_syntax_reference_accepts_good_reference():
    good = (
        '## Core Syntax Examples\n(Name: Activity) { ... }\n\n'
        '## Key Rules\n- rules here\n\n'
        '## Action Semantic Roles\n- REQUEST/OWN/RESPONSE/EXPORT\n'
    ) + 'x' * 2000
    assert validate_syntax_reference(good) is True


def test_validate_syntax_reference_rejects_bad_references():
    for bad in (
        '',                                             # empty
        'short',                                        # too short
        'error: unknown subcommand "syntax"' + 'x' * 2000,  # the historic failure
        ('## Core Syntax Examples\n' + 'x' * 2000),     # missing sections
    ):
        try:
            validate_syntax_reference(bad)
        except ValueError:
            continue
        raise AssertionError(f'validate_syntax_reference accepted bad input: {bad[:60]!r}')


# ── Verb validation (#386) ───────────────────────────────────────────────────

def test_hallucinated_verbs_in_code():
    valid = {'extract', 'compute', 'return', 'log', 'emit', 'for', 'when'}
    assert hallucinated_verbs_in_code('Tail the <file> from the <path>.', valid) == {'Tail'}
    assert hallucinated_verbs_in_code('Extract the <a> from the <b>.\nCompute the <c> from <a> * 2.', valid) == set()
    # Prose inside comments must not be flagged
    assert hallucinated_verbs_in_code('(* Demonstrates Extract usage *)\nExtract the <a> from the <b>.', valid) == set()


# ── Verb + preposition signatures (#402) ─────────────────────────────────────

def test_check_verb_prepositions():
    vp_map = {'log': {'to'}, 'retrieve': {'from'}, 'store': {'into'}}
    assert check_verb_prepositions('Log <msg> to the <console>.', vp_map) == []
    bad = check_verb_prepositions('Retrieve the <user> with the <user-repository>.', vp_map)
    assert len(bad) == 1 and 'with' in bad[0]
    # `when` guards and `where` queries are always allowed
    assert check_verb_prepositions('Retrieve the <user> from the <repo> where id = 1.', vp_map) == []
    # Verbs without documented prepositions are skipped (no verdict)
    assert check_verb_prepositions('Frobnicate the <x> via the <y>.', vp_map) == []


# ── OpenAPI contract cross-check (#402) ──────────────────────────────────────

_YAML = """openapi: 3.0.3
info:
  title: User API
paths:
  /users:
    get:
      operationId: listUsers
  /users/{id}:
    get:
      operationId: getUser
"""


def test_check_openapi_contract_matches():
    code = """(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}"""
    assert check_openapi_contract(code, _YAML) == []


def test_check_openapi_contract_mismatches():
    code = """(Get User: User API) {
    Extract the <userId> from the <pathParameters: userId>.
    Return an <OK: status> with <user>.
}"""
    violations = check_openapi_contract(code, _YAML)
    assert any('listUsers' in v for v in violations)
    assert any('getUser' in v for v in violations)
    assert any('userId' in v for v in violations)


# ── Near-duplicate detection (#404) ──────────────────────────────────────────

def test_near_duplicate_filter_token_fallback():
    samples = [
        {'text': 'Show me how to use the Extract action in ARO with a request body', 'score': 0.9},
        {'text': 'Show me how to use the Extract action in ARO with the request body', 'score': 1.0},
        {'text': 'Write a TCP socket server that echoes every incoming message back', 'score': 1.0},
    ]
    kept, dropped = near_duplicate_filter(
        samples, get_text=lambda s: s['text'], get_score=lambda s: s['score'],
        use_embeddings=False, jaccard_threshold=0.65)
    assert dropped == 1
    assert len(kept) == 2
    # The higher-scored representative of the duplicate cluster survives
    assert any(s['score'] == 1.0 and 'Extract' in s['text'] for s in kept)
    assert any('socket' in s['text'] for s in kept)


def test_near_duplicate_filter_keeps_distinct():
    samples = [
        {'text': 'Build an HTTP server that lists users from a repository'},
        {'text': 'Watch a directory for file changes and log every event'},
        {'text': 'Parse a CSV file and compute the average of the price column'},
        {'text': 'Emit a domain event when an order transitions to the shipped state'},
        {'text': 'Render a mustache template with customer data to the console'},
    ]
    kept, dropped = near_duplicate_filter(
        samples, get_text=lambda s: s['text'], use_embeddings=False)
    assert dropped == 0 and len(kept) == 5


# ── Source quality scores (#407) ─────────────────────────────────────────────

def test_source_quality_score():
    assert source_quality_score('example:HelloWorld') == 1.0
    assert source_quality_score('book_qa:TheLanguageGuide:Chapter08') == 0.8
    assert source_quality_score('/Users/kris/Projects/ARO/Examples/main.aro') == 0.95
    assert source_quality_score('unknown_new_source') == config.DEFAULT_SOURCE_QUALITY
    assert 0 < source_quality_score(None) <= 1.0


def test_derive_source_quality_from_validation():
    validated = (
        [{'source': 'mutation:1', 'valid': True}] * 15
        + [{'source': 'mutation:2', 'valid': False}] * 5
        + [{'source': 'example:x', 'valid': True}] * 3   # below min_count → excluded
    )
    rates = derive_source_quality_from_validation(validated, min_count=20)
    assert rates == {'mutation': 0.75}


# ── Misc helpers ─────────────────────────────────────────────────────────────

def test_word_overlap_ratio():
    assert word_overlap_ratio('Compute the total price of an order', 'compute total price order') > 0.5
    assert word_overlap_ratio('Compute the total price of an order', 'delete everything now') < 0.25
    assert word_overlap_ratio('a an the of', 'unrelated') == 1.0  # no long words → vacuous pass


def test_auto_wrap_aro():
    wrapped, was = auto_wrap_aro('Extract the <a> from the <b>.\nCompute the <c> from <a> * 2.')
    assert was and wrapped.startswith('(Application-Start: Example) {')
    assert 'Return an <OK: status>' in wrapped
    # Already-wrapped code untouched
    code = '(Name: Activity) {\n    Log "x" to the <console>.\n}'
    same, was = auto_wrap_aro(code)
    assert not was and same == code
    # Template/meta content rejected
    assert auto_wrap_aro('(Name: Activity) with <statements>') == (None, False)
    # The wrapped snippet is a complete program (pass as a raw block)
    assert is_complete_program([wrapped])


# Allow running without pytest: `python3 test_config_helpers.py`
if __name__ == '__main__':
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith('test_') and callable(fn):
            try:
                fn()
                print(f'  PASS {name}')
            except AssertionError as e:
                failures += 1
                print(f'  FAIL {name}: {e}')
    if failures:
        sys.exit(f'{failures} test(s) failed')
    print('All tests passed.')
