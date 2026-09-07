"""
Unit tests for the pure-python half of Train/script/32_notebook_pairs.py —
the `.repl` notebook miner.

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_notebook_pairs.py

No model and no `aro` binary: everything tested here is parsing, pairing, and
rendering. The parts that need a REPL (executing cells, the reproducibility
gate, the aro-check audit) are exercised by running the script itself against
Learning/ — see its module docstring.
"""

import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _load_miner():
    """Import 32_notebook_pairs.py — a module whose name starts with a digit,
    so it cannot be `import`ed by name."""
    spec = importlib.util.spec_from_file_location(
        'notebook_pairs', SCRIPT_DIR / '32_notebook_pairs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


nb = _load_miner()


# ── the file format ──────────────────────────────────────────────────────────

def _json_objects(block: str):
    """Every JSON value in a fenced block — one document, or a list of output
    objects written one per line."""
    try:
        return [json.loads(block)]
    except json.JSONDecodeError:
        return [json.loads(line) for line in block.splitlines() if line.strip()]


def test_format_pairs_emit_decodable_repl_json():
    """The hand-written format pairs must describe the format correctly — a
    wrong example here teaches the wrong shape to every notebook skill."""
    documents = outputs = 0
    for pair in nb.format_pairs():
        for block in pair['output'].split('```json\n')[1:]:
            for value in _json_objects(block.split('\n```')[0]):
                if 'cells' in value:
                    documents += 1
                    assert value['version'] == 1
                    for cell in value['cells']:
                        assert cell['kind'] in ('markdown', 'code')
                        assert isinstance(cell['id'], str) and cell['id']
                        assert isinstance(cell['source'], str)
                        assert isinstance(cell['outputs'], list)
                        if cell['kind'] == 'markdown':
                            assert cell['outputs'] == []
                else:
                    outputs += 1
                    assert value['kind'] in ('stream', 'result', 'error')
    assert documents >= 1 and outputs >= 3    # all three output kinds shown


def test_notebook_cell_json_matches_the_solaro_model():
    cell = {'id': 'nb01-c02', 'kind': 'code',
            'source': 'Log "hi" to the <console>.'}
    run = {'status': 'ok', 'stdout': 'hi\n', 'display': {'text/plain': 'hi'},
           'durationMs': 3.14159}
    stored = nb.notebook_cell_json(cell, run, execution_count=2)

    assert stored['id'] == 'nb01-c02'
    assert stored['kind'] == 'code'
    assert stored['executionCount'] == 2
    assert stored['durationMs'] == 3.142            # rounded, not raw float noise
    assert stored['outputs'][0] == {'kind': 'stream', 'streamName': 'stdout',
                                    'text': 'hi\n'}
    assert stored['outputs'][1]['kind'] == 'result'
    assert stored['outputs'][1]['plainText'] == 'hi'
    json.dumps(stored)                               # must be serializable


def test_notebook_cell_json_omits_absent_display():
    stored = nb.notebook_cell_json({'id': 'c', 'source': 'x'},
                                   {'stdout': 'out\n', 'display': {}}, 1)
    assert [o['kind'] for o in stored['outputs']] == ['stream']


# ── rendering an output ──────────────────────────────────────────────────────

def test_render_output_joins_streams_and_display():
    run = {'stdout': 'first\n', 'display': {'text/plain': 'second'}}
    assert nb.render_output(run) == 'first\nsecond'


def test_render_output_does_not_duplicate_a_logged_value():
    """A cell that Logs and then displays the same value must not show it
    twice — the notebook does not, and neither should the training target."""
    run = {'stdout': '6.8\n', 'display': {'text/plain': '6.8'}}
    assert nb.render_output(run) == '6.8'


# ── the reproducibility gate ─────────────────────────────────────────────────

def test_signature_ignores_duration_and_stderr():
    base = {'status': 'ok', 'stdout': 'x', 'display': {}, 'durationMs': 1.0,
            'stderr': ''}
    slower = dict(base, durationMs=99.0, stderr='a deferred warning raced in')
    assert nb._signature(base) == nb._signature(slower)


def test_signature_separates_different_output():
    a = {'status': 'ok', 'stdout': '2026-09-07', 'display': {}}
    b = {'status': 'ok', 'stdout': '2026-09-08', 'display': {}}
    assert nb._signature(a) != nb._signature(b)


# ── cell shapes ──────────────────────────────────────────────────────────────

def test_repl_only_shape_detects_definition_plus_call():
    code = ('(PriceOrder: Action takes <base>) {\n'
            '    Extract the <b> from the <input: base>.\n'
            '    Return an <OK: status> with <b>.\n'
            '}\n'
            'Application.PriceOrder the <p> from 2.4.')
    assert nb.is_repl_only_shape(code) is True


def test_plain_feature_set_is_not_repl_only():
    code = ('(PriceOrder: Action) {\n'
            '    Return an <OK: status> with 1.\n'
            '}')
    assert nb.is_repl_only_shape(code) is False


def test_bare_statements_are_not_repl_only():
    assert nb.is_repl_only_shape('Log "hi" to the <console>.') is False


# ── notebook structure ───────────────────────────────────────────────────────

SAMPLE = {
    'version': 1,
    'cells': [
        {'id': 'c1', 'kind': 'markdown',
         'source': '# 42 — Sample\n\nAn opening paragraph.', 'outputs': []},
        {'id': 'c2', 'kind': 'code',
         'source': 'Create the <a> with 1.', 'outputs': []},
        {'id': 'c3', 'kind': 'markdown',
         'source': '## What just happened\n\nStructural.', 'outputs': []},
        {'id': 'c4', 'kind': 'markdown',
         'source': '## Pricing an order\n\n' + 'Prose. ' * 40, 'outputs': []},
        {'id': 'c5', 'kind': 'code',
         'source': 'Compute the <b> from <a> * 2.', 'outputs': []},
    ],
}


def test_notebook_title_is_the_h1():
    assert nb.notebook_title(SAMPLE['cells']) == '42 — Sample'


def test_headings_exclude_the_title_and_structural_sections():
    found = []
    for cell in SAMPLE['cells']:
        if cell['kind'] == 'markdown':
            found.extend(h for h in nb._HEADING_RE.findall(cell['source'])
                         if h.lower() not in nb._STRUCTURAL_HEADINGS)
    assert found == ['Pricing an order']          # not '42 — Sample', not 'What just happened'


def test_session_context_only_quotes_cells_that_ran():
    runs = {1: {'status': 'ok'}}                  # index 1 = c2; c5 has not run
    context = nb.session_context(SAMPLE['cells'], 4, runs)
    assert context == 'Create the <a> with 1.'


def test_preceding_prose_is_the_markdown_above_the_cell():
    prose = nb.preceding_prose(SAMPLE['cells'], 4)
    # Two consecutive markdown cells, kept in source order.
    assert prose.startswith('## What just happened')
    assert prose.index('## What just happened') < prose.index('## Pricing an order')


def test_course_index_pairs_read_the_readme_table(tmp_path):
    readme = tmp_path / 'README.md'
    readme.write_text(
        '| # | Notebook | Teaches | Café capability |\n'
        '|---|----------|---------|-----------------|\n'
        '| 01 | [Hello, ARO](01-hello-aro.repl) | Statements: the console '
        '| The shop says hello |\n')
    pairs = nb.course_index_pairs(readme)
    assert len(pairs) == 2                         # the index + one per row
    assert all(p['task_type'] == 'notebook_qa' for p in pairs)
    assert '01-hello-aro.repl' in pairs[0]['output']
    assert 'Hello, ARO' in pairs[1]['output']


def test_course_index_pairs_tolerate_a_missing_readme(tmp_path):
    assert nb.course_index_pairs(tmp_path / 'nope.md') == []


# ── the corpus source registry (config.py) ───────────────────────────────────

def test_learning_is_a_declared_corpus_source():
    """Learning/ was mined by nothing for as long as the roots lived inside
    corpus_preflight(); the registry is what stops that recurring."""
    learning = config.corpus_source('Learning/')
    assert learning.kind == 'notebooks'
    assert learning.glob == '*.repl'
    assert 'NB32' in learning.consumers


def test_every_corpus_source_declares_a_consumer():
    for source in config.CORPUS_SOURCES:
        assert source.consumers, f'{source.label} is mined by nobody'


def test_corpus_source_rejects_an_unknown_label():
    try:
        config.corpus_source('Nowhere/')
    except KeyError:
        return
    raise AssertionError('expected KeyError for an undeclared source')


def test_notebook_task_types_are_declared_in_type_caps():
    """A task type missing from TYPE_CAPS still trains (DEFAULT_TYPE_CAP is
    None) but stops appearing in the caps inventory and in stats.json."""
    for task_type in ('notebook_output', 'notebook_cell', 'notebook_qa',
                      'notebook_authoring'):
        assert task_type in config.TYPE_CAPS


# ── the auto-wrap fix this stage depends on ──────────────────────────────────

def test_auto_wrap_looks_past_a_leading_comment_banner():
    """`(* main.aro *)` opens countless doc and notebook blocks. Treating the
    banner as the start of a fragment wrapped an already-complete feature set
    in another one, and the gate then rejected valid documented code."""
    code = ('(* main.aro *)\n'
            '(Application-Start: Demo) {\n'
            '    Log "hi" to the <console>.\n'
            '    Return an <OK: status> for the <startup>.\n'
            '}')
    wrapped, was_wrapped = config.auto_wrap_aro(code)
    assert was_wrapped is False
    assert wrapped == code


def test_auto_wrap_still_wraps_bare_statements():
    wrapped, was_wrapped = config.auto_wrap_aro('Log "hi" to the <console>.')
    assert was_wrapped is True
    assert wrapped.startswith('(Application-Start:')


if __name__ == '__main__':
    import pytest
    sys.exit(pytest.main([__file__, '-q']))
