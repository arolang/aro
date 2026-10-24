"""The 2026-10-24 Material batch: prompts whose generation previously failed
(GEN_TODO pool) now carry hand-written canonical answers, and every block in
those answers re-verified in this same commit.

Why the batch is a constant here rather than the file being swept: the
`_version` 1.1.0 stamp on canonical.json is dated 2026-07-15 and the language
has moved since — of the 146 entries with code that predate this batch, 26 no
 longer pass `aro check`. A blanket assertion would enshrine that drift as a
test failure; re-verifying all of them is NB23's re-stamp job. This test pins
exactly the entries whose block passed against the current binary, so the
next batch of edits either extends the list or re-verifies first.

Pairing key is the literal prompt string: run_prompts.py does
`canonical.get(prompt)` over prompts.txt's lines, so the prompts.txt lines and
the canonical.json keys here must match byte for byte. Leakage against the
frozen benchmark is enforced one layer down (leakage.benchmark_leakage walks
prompts.txt and canonical.json; see test_held_out_benchmark.py).
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent.parent
sys.path.insert(0, str(REPO / 'Train' / 'script'))

import aro_oracle  # noqa: E402

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

# The 8 prompts whose answers were hand-written and block-validated against
# aro 0.13.4 on 2026-10-24. Four are HTTP-shaped APIs (two-block answers), four
# are CLI/file idioms (single program).
NEW_MATERIAL_PROMPTS = [
    'todo list API with create, list, complete, and delete',
    'customer orders API with status state machine',
    'inventory tracking API with low-stock email alerts',
    'API key management with rate limits',
    'UUID generator that creates batch UUIDs and writes them to a file',
    'JSON config merger that reads multiple config files and deep-merges them',
    'password generator that accepts length and charset options and outputs random strings',
    'file classifier that watches an inbox folder and moves files to subfolders by extension',
]

API_PROMPTS = set(NEW_MATERIAL_PROMPTS[:4])


def _canonical():
    return json.loads((REPO / 'Train' / 'Material' / 'canonical.json').read_text())


def _prompts_lines():
    return (REPO / 'Train' / 'Material' / 'prompts.txt').read_text().splitlines()


# ── inventory pairing ────────────────────────────────────────────────────────

def test_every_batch_prompt_is_in_prompts_txt():
    lines = _prompts_lines()
    for prompt in NEW_MATERIAL_PROMPTS:
        assert prompt in lines, prompt


def test_every_batch_prompt_has_a_canonical_answer():
    can = _canonical()
    for prompt in NEW_MATERIAL_PROMPTS:
        assert prompt in can, prompt
        answer = can[prompt]
        assert '```aro' in answer, prompt


def test_responses_and_sections_stay_paired():
    # run_prompts.py pairs by the literal line; a key with trailing
    # whitespace or a doubled space would silently produce `expected: null`.
    can = _canonical()
    lines = _prompts_lines()
    assert len(lines) == len(set(lines)), 'duplicate lines in prompts.txt'
    for prompt in NEW_MATERIAL_PROMPTS:
        assert lines.count(prompt) == 1
        assert prompt in can


def test_api_entries_carry_the_contract_and_their_routes():
    # The four HTTP-shaped answers are two-block: the contract declares the
    # operationIds the handlers below it implement. A missing route shows up
    # as `aro check` documenting it only when the contract is there to
    # compare against (issue #800).
    can = _canonical()
    for prompt in sorted(API_PROMPTS):
        answer = can[prompt]
        assert answer.startswith('```yaml'), prompt
        operations = set(re.findall(r'operationId:\s*(\w+)', answer))
        handlers = set(re.findall(r'^\((\w+):', answer, re.MULTILINE))
        assert handlers <= operations, (prompt, sorted(handlers - operations))
        assert operations, prompt


def test_the_batch_never_touches_the_frozen_stamp():
    # The batch is an append; the 1.1.0 stamp keeps describing the 229
    # entries verified on 2026-07-15. Re-stamping without re-verifying would
    # claim validity wholesale (NB23's warning exists for that).
    can = _canonical()
    assert can['_version'] == '1.1.0'
    assert can['_stamped_at'] == '2026-07-15'
    assert '2026-10-24' in can['_meta_doc']


# ── the live gate: every block in the batch passes the current binary ───────

def _blocks_and_contract(answer):
    yaml_text = re.search(r'```yaml\n(.*?)```', answer, re.DOTALL)
    blocks = re.findall(r'```aro\n(.*?)```', answer, re.DOTALL)
    return blocks, ({'openapi.yaml': yaml_text.group(1)} if yaml_text else None)


@needs_binary
def test_every_aro_block_in_the_batch_passes_check():
    can = _canonical()
    for prompt in NEW_MATERIAL_PROMPTS:
        blocks, extra = _blocks_and_contract(can[prompt])
        assert blocks, prompt
        for i, block in enumerate(blocks):
            ok, out = aro_oracle.check_block(block, extra_files=extra)
            assert ok is True, (
                f'{prompt} — block {i} no longer passes `aro check`:\n{out}')


@needs_binary
def test_the_batch_code_is_warning_free():
    # The batch set the corpus's style bar; a warning is the checker
    # telling us an action got a noise word it does not need.
    can = _canonical()
    for prompt in NEW_MATERIAL_PROMPTS:
        blocks, extra = _blocks_and_contract(can[prompt])
        for block in blocks:
            ok, out = aro_oracle.check_block(block, extra_files=extra)
            warnings = [ln for ln in out.splitlines()
                        if 'warning' in ln and 'warning(s)' not in ln
                        and not ln.startswith('⚠')]
            assert not warnings, (prompt, warnings)


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
