"""
Tests for Train/script/32_notebook_pairs.py — the `.repl` notebook miner.

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_notebook_pairs.py

Most of this file is pure python — parsing, pairing, rendering, and the
coverage arithmetic — so `train:unit` (python:3.12-slim, no toolchain) runs
it. The tests at the bottom carry the shared
`skipif(aro_oracle.aro_bin() is None)` that conftest tags `needs_binary`, and
those actually **run the stage against the course**: `train:oracle` selects
them and has a real `aro` from `build:linux`'s artefact.

That division is the subject of GitLab #907. This file used to be unit tests
only, and the consequence was that nobody could say whether the Learning
course reached the training dataset at all — the stage was registered, ordered
correctly in the pipeline, and had 22 green tests about its plumbing, which is
the same reassurance #900 and #785 each turned out to be. The binary-gated
tests below answer the question instead of restating it: a fixed two-notebook
subset is mined end to end, every pair family must be non-empty, and the
coverage figure the stage now reports is floored.
"""

import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import pytest  # noqa: E402

import aro_oracle  # noqa: E402
import config  # noqa: E402
import leakage  # noqa: E402

# The shared spelling conftest reads off the marker to tag a test
# `needs_binary`. `unittest.skipIf` would skip identically and be invisible to
# that hook, so the test would sit deselected in the one job that has a binary
# (GitLab #900).
needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')


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


# ── the coverage figure: cells mined / cells present (GitLab #907) ───────────
# Arithmetic, so it runs in train:unit with no binary. The measurement it
# describes is made by the binary-gated tests further down.

def _stats(code_cells, ok=0, nondeterministic=0, failed=0, expected_error=0,
           not_reached=0):
    return {'code_cells': code_cells, 'ok': ok,
            'nondeterministic': nondeterministic, 'failed': failed,
            'expected_error': expected_error, 'not_reached': not_reached}


def test_coverage_row_reports_both_ratios():
    row = nb.coverage_row(_stats(10, ok=8, nondeterministic=1,
                                 expected_error=1))
    assert row['present'] == 10
    assert row['mined'] == 8
    assert row['eligible'] == 9                   # the expect-error cell cannot be mined
    assert row['of_present'] == 0.8
    assert row['of_eligible'] == 8 / 9


def test_coverage_row_refuses_to_lose_a_cell():
    """The assertion is the whole mechanism.

    Before #907 the buckets were three and did not sum to `code_cells`: a cell
    after a dead REPL session was attributed to nothing, so the course could
    be losing cells to a filter with no name and the report would still look
    tidy. An unbalanced row now raises rather than printing a percentage of a
    denominator it cannot account for.
    """
    with pytest.raises(AssertionError) as caught:
        nb.coverage_row(_stats(10, ok=4))          # six cells unexplained
    assert 'account for every cell' in str(caught.value)


def test_a_notebook_with_no_mineable_cell_has_no_percentage():
    """`None`, not `0.0` — and rendered as a dash.

    A notebook whose only code cells are `(* expect-error *)` has an empty
    eligible set. "0%" would say the miner failed on cells it was never
    allowed to mine, which is a wrong number where there is no number.
    """
    row = nb.coverage_row(_stats(2, expected_error=2))
    assert row['of_eligible'] is None
    assert row['of_present'] == 0.0               # of the file, honestly zero
    assert nb._percent(row['of_eligible']) == '—'
    assert nb._percent(None) == '—'

    empty = nb.coverage_row(_stats(0))
    assert empty['of_present'] is None and empty['of_eligible'] is None


def test_an_expect_error_cell_is_not_counted_as_a_miss():
    """`(* expect-error *)` cells run *because* they fail (they teach the
    diagnostic), so they are excluded by design, not missed. Counting them as
    failures made the `failed` column unreadable: nine of the course's cells
    are marked, and they looked like nine regressions."""
    row = nb.coverage_row(_stats(5, ok=4, expected_error=1))
    assert row['failed'] == 0
    assert row['expected_error'] == 1
    assert row['of_eligible'] == 1.0


def test_coverage_totals_weight_by_cell_not_by_notebook():
    """A five-cell notebook must not count as much as an eleven-cell one —
    summing first and dividing once is the difference between 50% and 75%
    here."""
    rows = {'small.repl': nb.coverage_row(_stats(2, ok=0, failed=2)),
            'big.repl':   nb.coverage_row(_stats(6, ok=6))}
    totals = nb.coverage_totals(rows)
    assert totals['notebooks'] == 2
    assert (totals['present'], totals['mined']) == (8, 6)
    assert totals['of_eligible'] == 0.75          # not the 50% a mean would give


def test_render_coverage_names_every_notebook_and_totals_them():
    rows = {'01.repl': nb.coverage_row(_stats(3, ok=3))}
    table = nb.render_coverage(rows, nb.coverage_totals(rows))
    assert '01.repl' in table
    assert '1 notebooks' in table                  # the totals line is present
    assert '100.0%' in table


# ── the course's notebooks are enumerated through the leakage exclusion ──────

def test_learning_notebooks_finds_the_course():
    names = [p.name for p in nb.learning_notebooks()]
    assert len(names) >= 20
    assert all(n.endswith('.repl') for n in names)
    for name in SUBSET:
        assert name in names, (
            f'{name} is the fixed subset the per-MR coverage test mines; '
            f'renaming it must fail here rather than silently shrink the test')


def test_learning_notebooks_honours_the_never_mine_marker(tmp_path):
    """One exclusion, not two (GitLab #785).

    `leakage` owns both mechanisms — a `.never-mine` marker on a directory and
    a `.benchmark.` infix on a filename — and `assert_mineable` raises instead
    of warning. The course carries neither today; what this test fixes in
    place is that dropping one in is all it would take, so this stage never
    needs an exclusion of its own invention.
    """
    (tmp_path / '01-sample.repl').write_text('{}')
    (tmp_path / leakage.NEVER_MINE_MARKER).write_text('')
    with pytest.raises(ValueError) as caught:
        nb.learning_notebooks(root=tmp_path)
    assert 'held-out benchmark' in str(caught.value)


def test_learning_notebooks_honours_the_benchmark_filename_infix(tmp_path):
    (tmp_path / f'01{leakage.BENCHMARK_NAME_INFIX}repl').write_text('{}')
    with pytest.raises(ValueError):
        nb.learning_notebooks(root=tmp_path)


# ── running the stage against the real course (GitLab #907) ──────────────────
# This is the half that was missing. Everything above is about the plumbing;
# these mine actual notebooks through `aro repl --json` and report what came
# out. `train:oracle` selects them by the needs_binary marker.
#
# A fixed, named two-notebook subset rather than the whole course: the per-MR
# job must stay fast and deterministic. These two are the course's simplest,
# carry no `(* expect-error *)` cell, and nothing in them reads a clock, a
# random source or a path, so the twice-and-agree gate has nothing to drop.
# Measured 2.3s for both, with the prose gate on. The full 29-notebook run is
# `train:notebook-coverage`, which is not a per-MR job.
SUBSET = ('01-hello-aro.repl', '02-values-and-literals.repl')

# Both subset notebooks mine 12/12 cells today. The floor is below that rather
# than at it: a changed output format would move a pair, not lose a cell, and
# a test that fails on a reformatting teaches people to delete tests. Below
# 80% of these two, the simplest notebooks in the course, something is broken
# that a reader needs to look at.
MIN_SUBSET_COVERAGE = 0.8

# Every family must be represented, because a family that quietly yields zero
# is the per-task version of the whole bug: TYPE_CAPS declares four notebook
# task types and nothing checked that four arrive.
FAMILIES = ('notebook_output', 'notebook_cell', 'notebook_authoring',
            'notebook_qa')


@pytest.fixture(scope='module')
def mined_subset():
    """Mine the fixed subset once: {name: (coverage row, pairs)}."""
    out = {}
    for name in SUBSET:
        path = config.LEARNING_DIR / name
        runs, stats = nb.execute_notebook(path, repeats=2)
        pairs = nb.pairs_for_notebook(path, runs, {}, prose_gate=True)
        out[name] = (nb.coverage_row(stats), pairs, runs)
    return out


@needs_binary
def test_the_course_contributes_pairs_in_every_family(mined_subset):
    counts = {family: 0 for family in FAMILIES}
    for _row, pairs, _runs in mined_subset.values():
        for pair in pairs:
            assert pair['task_type'] in counts, pair['task_type']
            assert pair['source'] == 'learning_notebook'
            counts[pair['task_type']] += 1
    empty = [family for family, n in counts.items() if n == 0]
    assert not empty, (
        f'the Learning course contributed no pairs for {empty} — the stage is '
        f'registered and ordered correctly and would still be adding nothing '
        f'(GitLab #907). Counts: {counts}')


@needs_binary
def test_subset_coverage_is_floored(mined_subset):
    for name, (row, _pairs, _runs) in mined_subset.items():
        assert row['of_eligible'] is not None, (
            f'{name} reported no coverage at all — either it has no code '
            f'cells or they are all expect-error cells, both of which make it '
            f'the wrong notebook for this test')
        assert row['of_eligible'] >= MIN_SUBSET_COVERAGE, (
            f'{name}: {row["mined"]}/{row["eligible"]} eligible cells mined '
            f'({100 * row["of_eligible"]:.1f}%), below the '
            f'{100 * MIN_SUBSET_COVERAGE:.0f}% floor. nondeterministic='
            f'{row["nondeterministic"]} failed={row["failed"]} '
            f'not_reached={row["not_reached"]}')


@needs_binary
def test_coverage_accounts_for_every_cell_of_a_real_notebook(mined_subset):
    """`coverage_row` raises on an unbalanced row, so reaching here is the
    assertion; the totals are checked too, since that is the figure reported."""
    rows = {name: row for name, (row, _p, _r) in mined_subset.items()}
    totals = nb.coverage_totals(rows)
    assert totals['notebooks'] == len(SUBSET)
    assert totals['present'] == sum(r['present'] for r in rows.values())
    assert totals['mined'] > 0
    assert (totals['mined'] + totals['nondeterministic'] + totals['failed']
            + totals['expected_error'] + totals['not_reached']
            == totals['present'])


@needs_binary
def test_a_mined_output_comes_from_the_run_not_from_the_file(mined_subset):
    """The ground truth is a run, and here is the proof rather than the claim.

    Neither subset notebook stores a single output — `outputs: []` on every
    code cell, which is how the course ships — so a non-empty expected output
    in a `notebook_output` pair cannot have been copied out of the file. If
    this ever passes with the executor stubbed out, it is because the file
    started carrying outputs, which the second assertion catches.
    """
    for name, (_row, pairs, runs) in mined_subset.items():
        document = json.loads((config.LEARNING_DIR / name).read_text())
        stored = [c for c in document['cells']
                  if c.get('kind') == 'code' and c.get('outputs')]
        assert not stored, (
            f'{name} now stores outputs; this test can no longer tell a '
            f'captured output from a copied one')

        predictions = [p for p in pairs if p['task_type'] == 'notebook_output']
        assert predictions, f'{name} produced no output-prediction pairs'
        for pair in predictions:
            body = pair['output'].strip('`\n ')
            assert body, f'{name}: an output pair promising nothing'
        assert any(run.get('stdout') for run in runs.values()), (
            f'{name}: no cell produced stdout, so nothing was executed')


if __name__ == '__main__':
    import pytest
    sys.exit(pytest.main([__file__, '-q']))
