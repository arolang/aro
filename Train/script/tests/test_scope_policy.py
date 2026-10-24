"""scope_policy — what the trained model is being trained to be.

Unit tests with fakes and one test anchored to the real Book layout (the
policy's path markers mean nothing if the books they name move).
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

spec = importlib.util.spec_from_file_location(
    'scope_policy', SCRIPT_DIR / 'scope_policy.py')
scope_policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope_policy)


def row(instruction='Write a program.', output='(Application-Start: A) {}',
        **kw):
    r = {'instruction': instruction, 'output': output,
         'source': 'wiki', 'task_type': 'syntax_qa'}
    r.update(kw)
    return r


# ── the source leg ───────────────────────────────────────────────────────────

def test_the_implementation_books_are_flagged_by_their_paths():
    for ref in (
        'book:Book/TheConstructionStudies/Chapter02-LexicalAnalysis.md',
        'book_qa:Book/TheConstructionStudies/Chapter04-AbstractSyntax.md',
        'book:Book/TheShortStudies/TheShortStudies.md',
        'Book/TheConstructionStudies',                    # bare dir mention
    ):
        reason = scope_policy.scan_row(row(doc_ref=ref))
        assert reason is not None, ref
        assert 'implementation book' in reason


def test_the_real_book_files_match_the_markers():
    # The policy names books that exist in this repository; if the directory
    # moves, this is the test that complains first.
    root = SCRIPT_DIR.parent.parent          # the repository root next to Train/
    cs = sorted((root / 'Book' / 'TheConstructionStudies').glob('*.md'))
    assert cs, 'The Construction Studies vanished from Book/'
    ref = f'book:Book/TheConstructionStudies/{cs[0].name}'
    assert scope_policy.is_internals_source(ref)


def test_the_grammar_appendix_is_language_not_internals():
    r = row(doc_ref='book:Book/TheConstructionStudies/AppendixB-Grammar.md')
    assert scope_policy.scan_row(r) is None


def test_a_user_facing_source_is_never_flagged_on_provenance():
    assert scope_policy.scan_row(
        row(doc_ref='book:Book/TheDebuggingGuide/Chapter03-Breakpoints.md')
    ) is None
    assert scope_policy.scan_row(
        row(source='book_qa', doc_ref='book:Book/TheLanguageGuide/index.md')
    ) is None


# ── the content leg ──────────────────────────────────────────────────────────

@pytest.mark.parametrize('topic_text', [
    'ARO uses a Pratt parser for expressions.',
    'The parser is a hybrid: recursive descent with Pratt binding.',
    'the parser keeps three dispatch tables for operator precedence',
    'the generator uses the Swifty-LLVM C API for type-safe IR',
    'the pipeline lives in LLVMCodeGenerator.swift',
    'execution follows the ExecutionContext protocol',
    'the FeatureSetExecutor runs feature sets one statement at a time',
    'lowered through the SIL pipeline of the compiler',
    'a tour of ARO for language implementers',
    'the rest of this chapter is compiler internals',
])
def test_internals_vocabulary_flags_rows_from_anywhere(topic_text):
    flagged = scope_policy.scan_row(row(output=topic_text, source='wiki'))
    assert flagged is not None, topic_text
    assert flagged.startswith('internals topic')


def test_the_words_the_user_guides_teach_are_not_internals():
    # Sentences lifted near-verbatim from the sanctioned user-facing books:
    # the Language Guide teaches the build pipeline and the symbol table, the
    # Plugin Guide documents @_cdecl, the Debugging Guide teaches DWARF.
    # Dropping those rows would gut the guides the model exists to answer
    # from — so the content leg only ever names implementer machinery.
    keep = [
        row(instruction='Why is my raw string unterminated?',
            output='A newline inside a raw string is a lexer error; a '
                   'backslash before the closing quote is read as the escape.'),
        row(instruction='What does aro build do?',
            output='It generates LLVM IR from your source, compiles it to '
                   'machine code, and links the ARO runtime library.'),
        row(instruction='How do I extend the language?',
            output='When the built-in actions are not enough, ARO provides '
                   'custom actions written in Swift and distributable plugins.'),
        row(instruction='Where do plugin results land?',
            output='The result is bound to `<hash>` in ARO\'s symbol table, '
                   'then execution continues.'),
        row(instruction='Can lldb name my feature sets?',
            output='The compiled binary carries real DWARF — a DISubprogram '
                   'per feature set — so backtraces name Application-Start.'),
        row(instruction='How do I publish a value?',
            output='Publish as <shared> <v>. in one feature set; Require the '
                   '<shared> from the <Activity>. in another.'),
        row(instruction='When does a statement get deferred?',
            output='Statements whose inputs are not ready yet run later; that '
                   'is observable in `aro run` output.'),
        row(instruction='Count the fast rows.',
            output='Compute the <fast_count> as Integer from the <fast>.'),
    ]
    assert all(scope_policy.scan_row(r) is None for r in keep), [
        scope_policy.scan_row(r) for r in keep]


def test_provenance_outranks_innocent_text():
    # A row from the implementation book is out of scope even when the text
    # is clean — answering from Chapter 2 teaches from Chapter 2.
    r = row(doc_ref='book:Book/TheConstructionStudies/Chapter02-LexicalAnalysis.md')
    r['instruction'] = 'When is a statement deferred?'
    r['output'] = 'Statements with unmet inputs run later.'
    assert scope_policy.scan_row(r) == (
        'implementation book: \'book:Book/TheConstructionStudies/'
        'Chapter02-LexicalAnalysis.md\'')


# ── the mode ─────────────────────────────────────────────────────────────────

def test_default_mode_is_all(monkeypatch):
    monkeypatch.delenv('ARO_TRAIN_SCOPE', raising=False)
    assert scope_policy.scope_mode() == 'all'


def test_whitespace_env_is_all(monkeypatch):
    monkeypatch.setenv('ARO_TRAIN_SCOPE', '   ')
    assert scope_policy.scope_mode() == 'all'


def test_language_mode_reads_the_env_at_call_time(monkeypatch):
    monkeypatch.setenv('ARO_TRAIN_SCOPE', 'language')
    assert scope_policy.scope_mode() == 'language'
    monkeypatch.setenv('ARO_TRAIN_SCOPE', 'all')
    assert scope_policy.scope_mode() == 'all'


def test_an_unknown_mode_is_a_refusal(monkeypatch):
    monkeypatch.setenv('ARO_TRAIN_SCOPE', 'swift')
    with pytest.raises(ValueError, match='ARO_TRAIN_SCOPE'):
        scope_policy.scope_mode()


def test_mode_names_are_case_insensitive(monkeypatch):
    monkeypatch.setenv('ARO_TRAIN_SCOPE', ' Language ')
    assert scope_policy.scope_mode() == 'language'


# ── the filter ───────────────────────────────────────────────────────────────

def test_all_mode_moves_nothing():
    rows = [row(), row(doc_ref='book:Book/TheConstructionStudies/x.md')]
    kept, dropped, reasons = scope_policy.filter_rows(rows, mode='all')
    assert kept == rows and dropped == [] and reasons == {}


def test_language_mode_drops_and_counts():
    rows = [
        row(),                                          # kept
        row(doc_ref='book:Book/TheConstructionStudies/x.md'),
        row(output='the parser is a Pratt parser.', source='wiki'),
        row(output='execution follows the ExecutionContext protocol.',
            source='wiki'),
        row(),                                          # kept
    ]
    kept, dropped, reasons = scope_policy.filter_rows(rows, mode='language')
    assert [rows.index(r) for _i, r, _reason in dropped] == [1, 2, 3]
    assert len(kept) == 2
    assert sum(reasons.values()) == 3
    assert any('implementation book' in k for k in reasons)
    assert any('Pratt' in k for k in reasons)


def test_language_mode_drops_in_corpus_order():
    rows = [row(doc_ref='book:Book/TheShortStudies/s.md'),
            row(), row(output='a recursive-descent engine with a Pratt '
                             'front end.')]
    _kept, dropped, _reasons = scope_policy.filter_rows(rows, mode='language')
    assert [i for i, _r, _r2 in dropped] == [0, 2]


# ── the audit entry point ────────────────────────────────────────────────────

def test_audit_file_counts_a_real_jsonl(tmp_path):
    f = tmp_path / 'rows.jsonl'
    f.write_text('\n'.join(json.dumps(r) for r in [
        row(),
        row(doc_ref='book:Book/TheConstructionStudies/x.md'),
        row(output='Pratt parsing binds operators.'),
        row(), row(),
    ]) + '\n')
    n, dropped, reasons = scope_policy.audit_file(f, mode='language')
    assert n == 5
    assert dropped == 2
    assert sum(reasons.values()) == 2


def test_rows_without_instruction_output_are_kept():
    # tool_calling traces carry `messages`, which the scanner does not read;
    # keep them rather than invent a text extractor for a list-of-dicts the
    # corpus already gates elsewhere.
    trace = {'messages': [{'role': 'user', 'content': 'Pratt parser?'}],
             'source': 'wiki', 'task_type': 'tool_calling'}
    assert scope_policy.scan_row(trace) is None
