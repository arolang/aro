#!/usr/bin/env python3
"""scope_policy.py — what the trained model is being trained to be.

The pipeline's own system prompt draws the line: runtime internals "are runtime
internals, not part of the language" — the model answers as a user of ARO, not
as one of its maintainers. The corpus does not honor that line by construction:
`29_multimodel_doc_qa.py` sweeps every `Book/**/*.md` into doc-QA pairs, and the
Book carries two books about **implementing** ARO — The Construction Studies
(~90 pages of Pratt parsing, AST protocols, Swifty-LLVM codegen, the @_cdecl
bridge) and its condensation, The Short Studies. A `book_qa` pair generated
from Chapter 2 teaches "hybrid parser design: recursive descent + Pratt
parsing, the three dispatch tables" as if a user needed it. Nothing in a user's
question or an `aro ask` session can be answered by that material — but enough
of it in the corpus changes how the model talks: narration instead of code,
maintainer's vocabulary where a user's answer was asked for.

Detection is two-legged, because internals narrate from two places:

  * **source** — an entire book that is about the compiler: path markers below.
    The one carve-out is Appendix B, the formal EBNF grammar of ARO itself:
    the grammar is the language, not its implementation.
  * **content** — names that are nothing but implementer machinery appearing
    in any row, whatever its provenance. The vocabulary test the obvious way
    ('LLVM', 'lexer', 'symbol table' → internals) fails against this
    repository's own guides: a live sweep showed those words standing in
    *sanctioned user documentation* (the Language Guide teaches `aro build`'s
    AST→LLVM-IR pipeline and the symbol table; the Plugin Guide documents
    @_cdecl; the Debugging Guide teaches DWARF). So this leg matches only the
    names no user-facing page needs — Pratt parsing, recursive descent, the
    runtime's executor classes — where a hit is narration no question called
    for.

`ARO_TRAIN_SCOPE` selects the mode at call time — 'all' (default; nothing
changes) or 'language' (internals rows dropped). Every dropped row is counted
with its reason so the funnel and stats.json can attribute the corpus change
to the policy, not to a silent edit.
"""

import os
import re

# ── the source leg ────────────────────────────────────────────────────────────

# Whole books about building ARO. User-facing guides (ByExample, LanguageGuide,
# PluginGuide, DebuggingGuide, …) are deliberately NOT here: their internals
# asides are caught by the content leg instead, and their substance is exactly
# what the model should keep.
INTERNALS_PATH_MARKERS = ('TheConstructionStudies', 'TheShortStudies')

# The formal grammar of the language is language documentation. Dropping it
# would punish the corpus for containing the one thing a scope check wants.
GRAMMAR_APPENDIX = 'AppendixB-Grammar.md'


def is_internals_source(text):
    """True when a source/doc_ref string names an implementation book."""
    t = str(text or '')
    if not t:
        return False
    if not any(marker in t for marker in INTERNALS_PATH_MARKERS):
        return False
    if t.endswith(GRAMMAR_APPENDIX):
        return False
    return True


# ── the content leg ──────────────────────────────────────────────────────────

# Names that are nothing but implementer machinery. Deliberately narrow, and
# deliberately NOT a vocabulary test: a live sweep of the user-facing books
# showed the same words appearing as their sanctioned documentation — the
# Language Guide teaches `aro build`'s pipeline ("parses to AST, generates
# LLVM IR"), calls error messages "lexer errors", teaches the symbol table as
# a mental model, and the Plugin Guide documents @_cdecl as the plugin API,
# DWARF as what lldb sees. Dropping on those words would gut the very guides
# the model exists to answer from. What no user-facing page ever needs is the
# parser's family tree and the runtime's internal class names — so that is
# what this leg matches, wherever the row's provenance is innocent.
_TOPIC_PATTERNS = (
    r'Pratt', r'recursive[ \-]descent', r'dispatch table',
    r'Swifty-LLVM', r'LLVMCodeGenerator', r'\bSIL\b', r'IRBuilder',
    r'FeatureSetExecutor', r'ExecutionContext protocol',
    r'compiler internals', r'language implement(?:er|ation)',
)
INTERNALS_TOPIC_RE = re.compile('|'.join(_TOPIC_PATTERNS), re.IGNORECASE)


def internals_topic(text):
    """The first internals topic a text narrates, or None."""
    m = INTERNALS_TOPIC_RE.search(str(text or ''))
    return m.group(0) if m else None


# ── the policy ───────────────────────────────────────────────────────────────

SCOPE_ENV = 'ARO_TRAIN_SCOPE'
MODES = ('all', 'language')


def scope_mode(env=None):
    """The requested scope mode, read at call time.

    'all' keeps every row (the default; the corpus is untouched). 'language'
    drops the rows that teach how ARO is implemented. Anything else is a
    refusal, naming the modes — a typo that silently trains a different
    corpus is the failure this module exists to prevent.
    """
    value = (os.environ.get(SCOPE_ENV, '') if env is None else env).strip()
    if not value:
        return 'all'
    for mode in MODES:
        if value.lower() == mode:
            return mode
    raise ValueError(f'unknown {SCOPE_ENV}={value!r}; expected one of '
                     f'{", ".join(MODES)}')


def scan_row(row):
    """Why this row is out of scope, or None.

    Looks at the row's provenance first, then its text: a doc_ref pointing at
    the implementation book is out of scope however innocent the question,
    and the topic regex catches internals narration in rows from anywhere.
    """
    for key in ('doc_ref', 'source'):
        if is_internals_source(row.get(key)):
            return f'implementation book: {row.get(key)!r}'
    text = '\n'.join(
        str(row.get(k) or '') for k in ('instruction', 'output'))
    topic = internals_topic(text)
    if topic:
        return f'internals topic: {topic}'
    return None


def filter_rows(rows, mode=None):
    """The rows under the scope policy: (kept, dropped, reasons).

    `dropped` carries (index, row, reason) in corpus order; `reasons` maps
    reason → count for a funnel stage. With mode 'all' nothing moves.
    """
    mode = scope_mode() if mode is None else mode
    if mode == 'all':
        return list(rows), [], {}
    kept, dropped, reasons = [], [], {}
    for i, row in enumerate(rows):
        reason = scan_row(row)
        if reason:
            dropped.append((i, row, reason))
            reasons[reason] = reasons.get(reason, 0) + 1
        else:
            kept.append(row)
    return kept, dropped, reasons


def audit_file(path, mode='language'):
    """Counts for one jsonl file, as the CLI and a dry run report them."""
    import json

    rows = []
    with open(path) as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    _kept, dropped, reasons = filter_rows(rows, mode=mode)
    return len(rows), len(dropped), reasons


if __name__ == '__main__':
    import sys

    if len(sys.argv) != 2:
        sys.exit(f'usage: {sys.argv[0]} <jsonl file>')
    n, dropped, reasons = audit_file(sys.argv[1])
    print(f'{sys.argv[1]}: {n} rows, {len(dropped)} out of scope '
          f'(mode={scope_mode()!r} overridden by audit request)')
    for reason, count in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print(f'  {count:5d}  {reason}')
