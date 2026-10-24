"""The warning-class and canonical-alias mutations (34/35 oracle kinds).

The first six mutations make programs `aro check` *rejects*. Two quieter
classes now sit beside them, and both were verified against the binary before
a line of generator code was written for them (aro 0.13.4):

  * a preposition the action does not accept leaves exit 0 with
    `warning: Action 'Retrieve' does not accept the preposition 'into'` and
    dies at run time — the exit code is not the diagnostic;
  * an alias of an action (`build` for `create`) checks green both ways —
    the preference for the canonical verb is the registry's, not the
    checker's, so its think block cites the registry, never a fake error.
"""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

spec = importlib.util.spec_from_file_location(
    'thinking_pairs', SCRIPT_DIR / '34_thinking_pairs.py')
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')

BOOKS = ('(Application-Start: Books) {\n'
         '    Create the <id> with 1.\n'
         '    Retrieve the <book> from the <book-repository>.\n'
         '    Log <book: title> to the <console>.\n'
         '}\n')

_VERBS = None


def _catalog_verbs():
    global _VERBS
    if _VERBS is None:
        _VERBS, _vp, _known = rc.load_catalogs()
    return _VERBS


def _fresh_stats():
    return {'not_broken': 0}


# ── the warning class (unlisted preposition) ────────────────────────────────

@needs_binary
def test_preposition_swap_leaves_exit_0_and_warns():
    result = gen._mutate_unlisted_preposition(BOOKS)
    assert result is not None, 'Retrieve ... from ... had no wrong prepositions?'
    broken, explanation = result
    ok, out = aro_oracle.check_block(broken)
    assert ok is True, f'the swapped program must still parse: {out}'
    assert 'does not accept the preposition' in out
    assert 'preposition' in explanation


@needs_binary
def test_the_warning_diagnostic_carries_the_action_and_word():
    result = gen._mutate_unlisted_preposition(BOOKS)
    outcome = gen.handle_oracle_outcome(
        'unlisted_preposition', 'check_warning', *result,
        _fresh_stats(), verbs=_catalog_verbs())
    assert outcome is not None
    diagnostic, reason = outcome
    assert "warning: Action 'Retrieve' does not accept the preposition" in diagnostic
    assert 'does not accept the preposition' in reason


def test_a_swap_the_grammar_refuses_is_dropped_not_shipped():
    # `using` is not a preposition to the parser ("Expected preposition, but
    # got identifier(using)") — a victim that produces an error must not
    # enter a warning-class pair.
    stats = _fresh_stats()
    outcome = gen.handle_oracle_outcome(
        'unlisted_preposition', 'check_warning',
        '(Application-Start: R) {\n    Retrieve the <x> using the <idx>.\n}\n',
        'no-op', stats, verbs=_catalog_verbs())
    assert outcome is None
    assert stats['not_broken'] == 1


def test_literal_tailed_statements_are_not_victims():
    # `Create the <id> with 1.` — the mutation must not swap into a shape the
    # parser only accepts with the literal (`Expected object, but got int(1)`).
    assert gen._mutate_unlisted_preposition(
        '(Application-Start: C) {\n    Create the <id> with 1.\n}\n') is None


# ── the style class (canonical alias) ───────────────────────────────────────

@needs_binary
def test_alias_replacement_checks_green():
    result = gen._mutate_canonical_alias(BOOKS)
    assert result is not None, '`Create` has aliases in the catalog'
    broken, explanation = result
    ok, out = aro_oracle.check_block(broken)
    assert ok is True, f'an alias must still check clean: {out}'
    assert broken != BOOKS


@needs_binary
def test_the_style_pair_names_alias_and_canonical():
    result = gen._mutate_canonical_alias(BOOKS)
    outcome = gen.handle_oracle_outcome(
        'noncanonical_alias', 'style', *result,
        _fresh_stats(), verbs=_catalog_verbs())
    assert outcome is not None
    diagnostic, reason = outcome
    assert 'is a registered alias' in reason
    alias = reason.split('`')[1]
    others, _vp = gen._statement_catalog()
    canonical = next((k for k, alts in others.items() if alias in alts), alias)
    assert canonical == 'create'


def test_non_statement_lines_are_never_victims():
    # `Start` is not a catalog action at all — there is nothing to substitute.
    assert gen._mutate_canonical_alias(
        '(Application-Start: Books) {\n'
        '    Start the <http-server> with <contract>.\n'
        '}\n') is None


def test_a_style_victim_the_handler_cannot_map_back_is_dropped():
    stats = _fresh_stats()
    outcome = gen.handle_oracle_outcome(
        'noncanonical_alias', 'style',
        '(Application-Start: X) {\n    Create the <id> with 1.\n}\n',
        'no-op', stats, verbs=_catalog_verbs())
    assert outcome is None
    assert stats['not_broken'] == 1


# ── the shared decision helper ──────────────────────────────────────────────

def test_check_class_still_requires_a_failure():
    stats = _fresh_stats()
    outcome = gen.handle_oracle_outcome(
        'missing_period', 'check', BOOKS, 'no-op', stats,
        verbs=_catalog_verbs())
    assert outcome is None
    assert stats['not_broken'] == 1


@needs_binary
def test_check_class_accepts_a_real_failure():
    result = gen._mutate_missing_period(BOOKS)
    outcome = gen.handle_oracle_outcome(
        'missing_period', 'check', *result,
        _fresh_stats(), verbs=_catalog_verbs())
    assert outcome is not None
    diagnostic, reason = outcome
    assert "Expected '.'" in diagnostic
    assert reason == diagnostic


@needs_binary
def test_catalog_class_still_requires_an_unowned_verb():
    result = gen._mutate_invented_verb(BOOKS)
    outcome = gen.handle_oracle_outcome(
        'invalid_verb', 'catalog', *result,
        _fresh_stats(), verbs=_catalog_verbs())
    assert outcome is not None
    assert 'not a registered action verb' in outcome[1]


def test_first_warning_picks_the_preposition_line():
    out = ("main.aro:\n"
           "  2:30: warning: Action 'Retrieve' does not accept the preposition "
           "'into'\n"
           "  4:2: warning: Feature set 'R' has no Return or Throw statement\n"
           "  Found 2 warning(s) in main.aro\n")
    assert gen.first_warning(out).startswith(
        "2:30: warning: Action 'Retrieve'")


def test_the_registry_note_for_the_think_block():
    note = gen.registry_diagnostic('build', 'create')
    assert '`build` is an alias of the `create` action' in note
    assert '`aro actions`' in note


def test_the_think_block_says_who_for_each_oracle():
    for oracle, fragment in (('check', '`aro check` rejects it'),
                             ('catalog', 'the action catalog rejects it'),
                             ('check_warning', 'exits 0'),
                             ('style', 'both check green. The action registry '
                                       'is the one with an opinion')):
        block = gen.think_block('write x', BOOKS, 'diag', 'the preposition', oracle)
        assert fragment in block, oracle
        assert 'My first attempt was this:' in block
