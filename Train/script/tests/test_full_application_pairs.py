"""36_full_application_pairs — prompt framing, grading gates, and the keep
decision, with a fake model and the real toolchain as the judge."""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'full_app', SCRIPT_DIR / '36_full_application_pairs.py')
fa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fa)

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

# A program that parses, runs, and finishes on its own — the shape a kept
# pair must have.
GOOD_PROGRAM = (
    '(Application-Start: Min) {\n'
    '    Create the <threshold> with 3.\n'
    '    Compute the <total: length> from "abc".\n'
    '    Log <total> to the <console>.\n'
    '}')
GOOD_CONTRACT = (
    'openapi: 3.0.0\n'
    'info: {title: Contracts, version: 1.0.0}\n'
    'paths:\n'
    '  /contracts:\n'
    '    get:\n'
    '      operationId: listContracts\n'
    '      responses:\n'
    '        200: {description: ok}')
GOOD_CONTRACT_APP = (
    '(listContracts: Contracts) {\n'
    '    Return the <OK: status> for the <request>.\n'
    '}\n'
    '\n'
    '(Application-Start: Contracts Service) {\n'
    '    Start the <http-server> with <contract>.\n'
    '    Keepalive the <application> for the <events>.\n'
    '}')

BAD_PROGRAM = ('(Application-Start: B) {\n'
               '    Frobnicate the <widget> with the <gizmo>.\n'
               '}')
RUNTIME_ERROR_PROGRAM = (
    '(Application-Start: R) {\n'
    '    Log <never-defined-name> to the <console>.\n'
    '}')


def fake_chat(first_turn, repair_turn):
    """A chat function with one script for the first ask and one for every
    repair turn — the repair turn is recognisable by the checker's complaint
    the pipeline always feeds back."""
    def chat(messages, **_kw):
        last = messages[-1]['content']
        if 'aro check' in last and '```' in last:
            return repair_turn
        for needle, answer in first_turn:
            if needle in last:
                return answer
        return 'I have nothing for that.'
    chat.system_prompt = 'You are an expert ARO programmer.'
    return chat


GOOD_ANSWER = f'```aro\n{GOOD_PROGRAM}\n```'
GOOD_CONTRACT_ANSWER = (
    f'```yaml\n{GOOD_CONTRACT}\n```\n\n'
    f'```aro\n{GOOD_CONTRACT_APP}\n```')
BAD_ANSWER = f'```aro\n{BAD_PROGRAM}\n```'


# ── framing ─────────────────────────────────────────────────────────────────

def test_http_shaped_prompts_ask_for_the_contract():
    instruction, is_contract = fa.build_instruction(
        'todo list API with create, list, complete, and delete')
    assert is_contract
    assert 'openapi.yaml' in instruction


def test_plain_prompts_ask_for_a_runnable_program():
    instruction, is_contract = fa.build_instruction(
        'password generator that accepts length and charset options')
    assert not is_contract
    assert '```aro' in instruction


def test_real_gen_todo_pool_parses_and_is_not_empty():
    pool = fa.prompt_pool(None, limit=0, seed=0)
    assert len(pool) >= 350


# ── retries ─────────────────────────────────────────────────────────────────

@needs_binary
def test_the_repair_loop_recovers_with_one_correction():
    # The GOOD answer must be *graded kept* for the loop to stop after one
    # correction, and keeping is the real checker's decision.
    chat = fake_chat([('todo list', BAD_ANSWER)], GOOD_ANSWER)
    instruction, _ = fa.build_instruction('todo list for books')
    main_aro, openapi, repair_turns = fa._attempt(chat, instruction, attempts=3)
    assert repair_turns == 1
    assert 'Frobnicate' not in main_aro          # the good answer came back
    assert openapi is None


def test_repair_loop_gives_up_after_attempts():
    chat = fake_chat([('todo list', BAD_ANSWER)], BAD_ANSWER)
    instruction, _ = fa.build_instruction('todo list for books')
    main_aro, _o, repair_turns = fa._attempt(chat, instruction, attempts=2)
    assert repair_turns == 1
    assert 'Frobnicate' in main_aro


# ── the keep gate ───────────────────────────────────────────────────────────

@needs_binary
def test_a_program_that_runs_is_kept():
    ok, reason, grade = fa.grade_application(GOOD_PROGRAM, None)
    assert ok, reason
    assert grade['check'] is True
    assert grade['run'] is True
    assert grade['run_output'].splitlines()[0] == '3'


@needs_binary
def test_a_program_the_check_rejects_is_not_kept():
    ok, reason, grade = fa.grade_application(BAD_PROGRAM, None)
    assert not ok
    assert reason.startswith('check failed')
    assert 'Frobnicate' in grade['check_output']


@needs_binary
def test_a_program_that_checks_but_does_not_run_is_not_kept():
    ok, reason, grade = fa.grade_application(RUNTIME_ERROR_PROGRAM, None)
    assert not ok, reason
    assert reason.startswith('passes check but does not run'), reason
    assert 'not published' in grade['run_output'] or 'never-defined' in grade['run_output']


@needs_binary
def test_a_server_program_is_kept_without_being_run():
    ok, reason, grade = fa.grade_application(GOOD_CONTRACT_APP, GOOD_CONTRACT)
    assert ok, reason
    assert grade['run'] is None
    assert 'not a batch program' in grade['run_output']


@needs_binary
def test_the_contract_must_actually_match_the_handlers():
    yml = GOOD_CONTRACT.replace('listContracts', 'listOrders')
    ok, reason, _grade = fa.grade_application(GOOD_CONTRACT_APP, yml)
    assert not ok
    assert 'contract' in reason


@needs_binary
def test_the_empty_answer_is_refused_without_touching_the_binary():
    ok, reason, grade = fa.grade_application('', None)
    assert not ok
    assert reason == 'no ```aro block in the output'


# ── the loop ────────────────────────────────────────────────────────────────

@needs_binary
def test_recover_saves_only_kept_pairs_and_counts_the_rest(tmp_path, monkeypatch):
    monkeypatch.setattr(fa, 'JOURNAL_NAME', 'nb36_journal_test.jsonl')
    chat = fake_chat(
        [('todo list', GOOD_CONTRACT_ANSWER),
         ('password generator', GOOD_ANSWER),
         ('inbox classifier', BAD_ANSWER)],
        repair_turn=BAD_ANSWER)
    rows, stats = fa.recover(
        ['todo list API with create, list, complete, and delete',
         'password generator that accepts length and charset options',
         'inbox classifier that watches a folder'], chat, attempts=2)
    assert stats['kept'] == 2
    assert stats['dropped_check'] == 1
    kinds = {r['_gen_todo_recovery']['kind'] for r in rows}
    assert kinds == {'contract', 'program'}
    # every kept row is a complete application with the grade on it
    assert all(r['_gen_todo_recovery']['grade']['check'] is True for r in rows)
    app = next(r for r in rows if r['_gen_todo_recovery']['kind'] == 'program')
    assert app['task_type'] == 'full_application'
    assert 'Application-Start' in app['output']


@needs_binary
def test_the_novelty_gate_skips_what_the_caller_seeded(tmp_path, monkeypatch):
    monkeypatch.setattr(fa, 'JOURNAL_NAME', 'nb36_journal_test.jsonl')
    chat = fake_chat([('todo list', GOOD_CONTRACT_ANSWER)], BAD_ANSWER)
    novel = __import__('config').NearDuplicateIndex()
    novel.add('todo list API with create, list, complete, and delete')
    rows, stats = fa.recover(
        ['todo list API with create, list, complete, and delete'],
        chat, novel=novel)
    assert rows == []
    assert stats['dropped_novelty'] == 1
    assert stats['no_answer'] == 0
