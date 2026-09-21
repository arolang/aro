"""
Unit tests for the execution oracle (GitLab #798).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_execution_oracle.py

`aro check` was the only oracle, and it is syntax plus limited semantics: half
the complete programs in the corpus pass it and fail when run. These tests
cover the shape decisions — what can be run, what cannot, and what "not
attempted" must never be confused with — and, where a binary is around, that
running really does catch what checking does not.
"""

import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

PROGRAM = ('(Application-Start: Demo) {\n'
           '    Compute the <n> from 2 + 40.\n'
           '    Log <n> to the <console>.\n'
           '    Return an <OK: status> for the <startup>.\n}\n')

SERVER = ('(Application-Start: Demo) {\n'
          '    Start the <http-server> with <contract>.\n'
          '    Keepalive the <application> for the <events>.\n'
          '    Return an <OK: status> for the <startup>.\n}\n')

WITH_TESTS = PROGRAM + (
    '\n(Addition Works: Calculator Test) {\n'
    '    Given the <a> with 2.\n'
    '    Compute the <sum> from <a> + 40.\n'
    '    Assert the <sum> with 42.\n'
    '    Return an <OK: status> for the <test>.\n}\n')


# ── what can be run at all ───────────────────────────────────────────────────

def test_a_waiting_program_is_recognised():
    """Keepalive, a bound port, a watcher: there is no completion to observe."""
    assert aro_oracle.is_server_program(SERVER) is True
    assert aro_oracle.is_server_program(PROGRAM) is False
    assert aro_oracle.is_server_program(
        '(A: B) {\n    Listen for the <socket>.\n}') is True


def test_colocated_tests_are_recognised():
    assert aro_oracle.has_tests(WITH_TESTS) is True
    assert aro_oracle.has_tests(PROGRAM) is False


@needs_binary
def test_run_returns_none_for_what_it_did_not_ask():
    """`None` is 'not attempted', never 'fine'. Collapsing the two to a score
    of 0.8/0.9 is what made a skipped server and a missing binary look alike."""
    ok, reason = aro_oracle.run_block('Log "hi" to the <console>.')
    assert ok is None and 'entry point' in reason
    ok, reason = aro_oracle.run_block(SERVER)
    assert ok is None and 'server' in reason


@needs_binary
def test_a_complete_program_runs_and_its_stdout_is_the_expected_output():
    ok, output = aro_oracle.run_block(PROGRAM)
    assert ok is True
    assert '42' in output


@needs_binary
def test_grade_block_reports_the_whole_tuple():
    grade = aro_oracle.grade_block(PROGRAM)
    assert grade['check'] is True
    assert grade['run'] is True
    assert '42' in grade['expected_output']
    assert grade['test'] is None, 'no tests in this program'
    assert grade['aro_version'] == aro_oracle.aro_version()


@needs_binary
def test_grade_block_runs_colocated_tests():
    grade = aro_oracle.grade_block(WITH_TESTS)
    assert grade['check'] is True
    assert grade['test'] is True
    assert 'PASS' in grade['test_output'] or 'Passed' in grade['test_output']


@needs_binary
def test_a_failing_test_suite_fails_the_grade():
    wrong = PROGRAM + (
        '\n(Addition Works: Calculator Test) {\n'
        '    Given the <a> with 2.\n'
        '    Compute the <sum> from <a> + 40.\n'
        '    Assert the <sum> with 99.\n'
        '    Return an <OK: status> for the <test>.\n}\n')
    grade = aro_oracle.grade_block(wrong)
    assert grade['check'] is True
    assert grade['test'] is False


@needs_binary
def test_run_is_not_attempted_when_check_already_failed():
    grade = aro_oracle.grade_block('Store the <u> in the <r>.')
    assert grade['check'] is False
    assert grade['run'] is None
    assert 'check failed' in grade['run_output']


@needs_binary
def test_a_program_that_checks_green_and_dies_when_run_is_a_failure():
    """The whole point: `aro check` is syntax plus limited semantics."""
    program = ('(Application-Start: Demo) {\n'
               '    Retrieve the <u> from the <missing-repository>.\n'
               '    Compute the <n: length> from <u>.\n'
               '    Log <n> to the <console>.\n'
               '    Return an <OK: status> for the <startup>.\n}\n')
    check_ok, _ = aro_oracle.check_block(program)
    run_ok, _ = aro_oracle.run_block(program)
    if check_ok and run_ok is False:
        verdict = rc.validate_pair(
            {'instruction': 'x', 'output': f'```aro\n{program}```'},
            *rc.load_catalogs(),
            rc.CheckCache(aro_oracle.aro_bin(), execute=True))
        assert verdict['valid'] is False
        assert 'aro_run' in rc.failure_reasons(verdict)


@needs_binary
def test_the_validator_records_the_expected_output_on_the_pair():
    verbs, vp, known = rc.load_catalogs()
    cache = rc.CheckCache(aro_oracle.aro_bin(), execute=True)
    verdict = rc.validate_pair(
        {'instruction': 'add', 'output': f'```aro\n{PROGRAM}```'},
        verbs, vp, known, cache)
    assert verdict['valid'] is True
    assert verdict['run_attempted'] == 1
    assert verdict['run_passed'] == 1
    assert '42' in verdict['expected_output']


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
