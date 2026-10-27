"""37_best_of_n_rft — N independent draws, one grade gate, best kept.

The fake model returns scripted candidates; the judge is the real `aro`
binary through the shared 36 gate. What has to hold: every candidate is
graded (the tallies are the diagnosis), only a passing candidate is kept,
the kept row carries its provenance, and the novelty index stops prompts
the corpus already answers.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'best_of_n', SCRIPT_DIR / '37_best_of_n_rft.py')
bon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bon)

# The same fixtures stage 36's tests pin — these two stages must agree on
# what passing even means.
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

GOOD_ANSWER = f'```aro\n{GOOD_PROGRAM}\n```'
GOOD_CONTRACT_ANSWER = (
    f'```yaml\n{GOOD_CONTRACT}\n```\n\n'
    f'```aro\n{GOOD_CONTRACT_APP}\n```')
BAD_ANSWER = f'```aro\n{BAD_PROGRAM}\n```'
RUNTIME_ERROR_ANSWER = f'```aro\n{RUNTIME_ERROR_PROGRAM}\n```'

# The judge is the real `aro` binary — kept, graded and run-time-selected
# candidates are only what it says they are. Without a binary these skip;
# `train:oracle` (the job that has one) selects them with `-m needs_binary`.
needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')


def scripted_chat(script):
    """A chat fn that hands out the script in order, then repeats the last
    entry for as long as sampling keeps asking."""
    calls = {'n': 0}

    def chat(messages, **_kw):
        i = min(calls['n'], len(script) - 1)
        calls['n'] += 1
        return script[i]
    chat.system_prompt = 'You are an expert ARO programmer.'
    chat._calls = calls
    return chat


# ── the shape of the loop ────────────────────────────────────────────────────

@needs_binary
def test_a_passing_candidate_is_kept_with_its_provenance():
    chat = scripted_chat([GOOD_ANSWER])
    rows, stats = bon.best_of_n(['counter that counts up by one each tick'],
                                chat, samples=2, novel=None)
    assert stats['kept'] == 1 and len(rows) == 1
    row = rows[0]
    assert row['task_type'] == 'full_application'
    assert row['source'] == 'best_of_n'
    assert row['_best_of_n']['candidate'] == 0
    assert row['_best_of_n']['samples'] == 2
    assert 'threshold' in row['output']


@needs_binary
def test_every_candidate_is_graded_even_when_an_early_one_passes():
    # N samples, N grades: the tallies across all of them say where
    # generation fails, which is the diagnostic a bigger N rides on. An
    # early success does not stop the remaining samples.
    chat = scripted_chat([GOOD_ANSWER, BAD_ANSWER, BAD_ANSWER, BAD_ANSWER])
    _rows, stats = bon.best_of_n(['counter that counts up by one each tick'],
                                 chat, samples=4, novel=None)
    assert stats['candidates'] == 4
    assert stats['dropped_check'] == 3
    assert stats['kept'] == 1


def test_no_passing_candidate_drops_the_prompt_as_a_whole():
    chat = scripted_chat([BAD_ANSWER])
    rows, stats = bon.best_of_n(['count words in a sentence'], chat,
                                samples=3, novel=None)
    assert rows == []
    assert stats['candidates'] == 3
    assert stats['no_accepted'] == 1
    assert stats['dropped_check'] == 3


def test_an_answer_without_a_block_is_counted_not_silently_kept():
    chat = scripted_chat(['I have no idea what ARO is.'])
    rows, stats = bon.best_of_n(['publish a topic'], chat, samples=2,
                                novel=None)
    assert rows == []
    assert stats['no_candidates'] == 2
    assert stats['no_accepted'] == 1


@needs_binary
def test_the_best_candidate_beats_one_that_merely_parses():
    # Candidate 0 passes check and dies at run time; candidate 1 runs.
    # Selection is the whole point of the stage.
    chat = scripted_chat([RUNTIME_ERROR_ANSWER, GOOD_ANSWER])
    rows, stats = bon.best_of_n(['counter that counts up by one each tick'],
                                chat, samples=2, novel=None)
    assert stats['dropped_run'] == 1
    assert stats['kept'] == 1
    assert rows[0]['_best_of_n']['candidate'] == 1
    assert 'never-defined-name' not in rows[0]['output']


@needs_binary
def test_the_instruction_shape_matches_stage_36():
    chat = scripted_chat([GOOD_CONTRACT_ANSWER])
    rows, _ = bon.best_of_n(['key value store as an http api'], chat,
                            samples=1, novel=None)
    assert len(rows) == 1
    assert 'openapi.yaml' in rows[0]['instruction']
    assert rows[0]['_best_of_n']['openapi'] is True
    assert rows[0]['output'].count('```aro') == 1


def test_samples_are_independent_not_a_repair_chain():
    # No repair turn is ever sent: each candidate message is the original
    # ask, not the checker's complaint fed back.
    seen = []

    def chat(messages, **_kw):
        seen.append([m['content'] for m in messages])
        return GOOD_ANSWER
    chat.system_prompt = 'SYS'
    bon.best_of_n(['counter that counts up by one each tick'], chat,
                  samples=3, novel=None)
    assert len(seen) == 3
    for messages in seen:
        assert len(messages) == 2          # system + user, no history
        assert 'aro check says' not in messages[-1]


# ── novelty ─────────────────────────────────────────────────────────────────

@needs_binary
def test_the_novelty_index_stops_what_the_corpus_already_answers():
    index = config.NearDuplicateIndex(threshold=0.9)
    index.add('todo list API with create, list, complete, and delete')
    chat = scripted_chat([GOOD_ANSWER])
    rows, stats = bon.best_of_n(
        ['todo list API with create, list, complete, and delete'],
        chat, samples=1, novel=index)
    assert rows == []
    assert stats['dropped_novelty'] == 1
    assert stats['candidates'] == 0          # never generated a thing
    # ...and the prompt that WAS kept joins the index, so an exact repeat
    # later in the same run drops too — which is the real in-run case: the
    # GEN_TODO pool carries duplicates.
    fresh = config.NearDuplicateIndex(threshold=0.9)
    rows2, stats2 = bon.best_of_n(
        ['todo list API with create, list, complete, and delete',
         'todo list API with create, list, complete, and delete'],
        chat, samples=1, novel=fresh)
    assert len(rows2) == 1
    assert stats2['dropped_novelty'] == 1


# ── the shared gate ─────────────────────────────────────────────────────────

def test_the_gate_function_is_the_imported_one():
    # If 36's gate ever tightens, this stage must tighten with it — hence
    # the gate is imported, not copied. Loading the file fresh must yield
    # the same file as the stage's module (a local redefinition would not).
    spec = importlib.util.spec_from_file_location(
        'full_app_fixture', SCRIPT_DIR / '36_full_application_pairs.py')
    fa = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fa)
    assert Path(bon.full_app.__file__).resolve() == Path(fa.__file__).resolve()
    assert bon.full_app.grade_application.__qualname__ == \
        fa.grade_application.__qualname__


@needs_binary
def test_a_contract_failure_drops_despite_check_passing():
    # A handler answering to an operation the contract never declared is
    # the failure NB12's contract-aware eval was built to catch.
    ok, reason, _grade = bon.full_app.grade_application(
        GOOD_CONTRACT_APP,
        GOOD_CONTRACT.replace('operationId: listContracts',
                              'operationId: renamedContracts'))
    assert ok is False and 'contract' in reason


# ── CLI plumbing ────────────────────────────────────────────────────────────

def test_default_samples_are_four():
    assert bon.DEFAULT_SAMPLES == 4


def test_main_requires_the_binary_when_it_would_grade(
        tmp_path, capsys):
    prompts = tmp_path / 'p.txt'
    prompts.write_text('counter that counts up by one each tick\n')
    if aro_oracle.aro_bin():
        pytest.skip('a binary is present; this test asserts the no-binary path')
    rc = bon.main(['--prompts', str(prompts), '--no-save'])
    assert rc == 2


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
