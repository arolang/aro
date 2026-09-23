"""
Unit tests for the stale-teaching guard on the curated material and the
system prompt (GitLab #809).

Run with either:
    python3 -m pytest Train/script/tests/
    python3 Train/script/tests/test_stale_teaching.py

Train/Material carries quality 1.0 — the highest weight in the mixture — and
the system prompt is generated from the same reference. Both had drifted
behind the language: the shipped prompt still taught the two-operand
`Compare`, which GitLab #469 made unrunnable, and the curated corpus taught
Compare was unusable altogether.
"""

import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

CURATED = SCRIPT_DIR.parent / 'Material' / 'curated.jsonl'

needs_binary = pytest.mark.skipif(
    aro_oracle.aro_bin() is None, reason='no `aro` binary available')


# ── the guard ────────────────────────────────────────────────────────────────

def test_the_two_operand_compare_is_caught():
    stale = config.stale_teaching(
        'Compute the <first-length: length> from the <first-message>.\n'
        'Compare the <first-length> against the <second-length>.')
    assert stale and 'Compare' in stale[0]


def test_the_current_compare_is_not_caught():
    assert config.stale_teaching(
        'Compare the <same-length> from the <first-length> '
        'against the <second-length>.') == []


def test_the_other_stale_forms_are_caught():
    assert config.stale_teaching('Store the <u> in the <user-repository>.')
    assert config.stale_teaching('Render the <html> from the <template>.')
    assert config.stale_teaching('Split the <words> from <text> with " ".')
    assert config.stale_teaching('Compute the <t: last> from <items>.')


def test_the_corrected_forms_are_not_caught():
    assert config.stale_teaching('Store the <u> into the <user-repository>.') == []
    assert config.stale_teaching(
        'Transform the <html> from the <template> with <data>.') == []
    assert config.stale_teaching('Split the <words> from <text> by " ".') == []
    assert config.stale_teaching(
        'Extract the <t: last> from the <items>.') == []


def test_a_reference_teaching_a_dead_form_fails_validation():
    """The system prompt is generated from this reference; a stale form here
    is a stale form in every prompt the model is trained and served with."""
    reference = ('## Core Syntax\n' + 'x' * 1600 + '\n## Key Rules\n'
                 '## Action Semantic Roles\n'
                 'Compare the <a> against the <b>.\n')
    with pytest.raises(ValueError) as caught:
        config.validate_syntax_reference(reference)
    assert 'Compare' in str(caught.value)


def test_a_clean_reference_still_validates():
    reference = ('## Core Syntax\n' + 'x' * 1600 + '\n## Key Rules\n'
                 '## Action Semantic Roles\n'
                 'Compare the <r> from the <a> against the <b>.\n')
    assert config.validate_syntax_reference(reference) is True


# ── the curated corpus itself ────────────────────────────────────────────────

def test_the_curated_corpus_teaches_nothing_the_runtime_rejects():
    stale = []
    for line in CURATED.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        for why in config.stale_teaching(record.get('output') or ''):
            stale.append((record.get('instruction', '')[:60], why))
    assert stale == []


@needs_binary
@pytest.mark.parametrize('sample_size', [120])
def test_a_sample_of_the_curated_corpus_still_checks(sample_size):
    """The whole file is validated by the train:corpus CI job; this keeps a
    fast slice of it in the unit suite."""
    verbs, vp, known = rc.load_catalogs()
    cache = rc.CheckCache(aro_oracle.aro_bin())
    rows = [json.loads(line) for line in CURATED.read_text().splitlines()
            if line.strip()][:sample_size]
    bad = [(rc.prompt_text(r)[:60], rc.failure_reasons(v))
           for r, v in ((r, rc.validate_pair(r, verbs, vp, known, cache))
                        for r in rows)
           if not v['valid']]
    assert bad == []


# ── language keywords are not hallucinations ─────────────────────────────────

def test_require_is_a_keyword_not_a_hallucinated_verb():
    """`Require the <console> from the <framework>.` is the `require` keyword;
    Examples/Conditionals runs on it, and the verb gate used to drop it."""
    verbs, _vp, _known = rc.load_catalogs()
    assert rc.hallucinated_verbs(
        'Require the <console> from the <framework>.', verbs) == []
    assert 'require' in aro_oracle.LANGUAGE_KEYWORDS


if __name__ == '__main__':
    sys.exit(pytest.main([__file__, '-q']))
