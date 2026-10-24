#!/usr/bin/env python3
"""scope.internals stratum authoring (companion to the #785 benchmark).

The Construction Studies and The Short Studies entered the doc-QA corpus as
user documentation, which they are not: they are books about building the ARO
compiler and runtime in Swift. `scope_policy.py` keeps such rows out of
*training*; this module measures the *trained* side: does the model answer at
the user's level, or does it lecture about the machinery?

Format and grading match the frozen explain stratum exactly —
(id, domain, prompt, reference, must_include, must_not_include), judged by
the same crude rubric (prefixes must appear; traps must not) — because there
is nothing scope-shaped about a new judge. The file is
`../scope.internals.json`, deliberately OUTSIDE the frozen digest: the frozen
benchmark is the release ruler and its content is version-bumped, not
appended to; this panel is a diagnostic that may grow between versions
without re-freezing anyone's comparison points. It stays under the benchmark
directory's .never-mine marker and is scored with
`held_out_benchmark.load_benchmark(path=...)` like the frozen file.

The rubric traps are the whole measurement here. `must_not_include` names the
maintainer's vocabulary a Construction-Studies diet teaches: Pratt parsing,
dispatch tables, Swifty-LLVM, the executor classes. Note the deliberate
asymmetry with the guides: LLVM IR, DWARF, the symbol table and @_cdecl are
ANSWERABLE user vocabulary (the Language Guide teaches the build pipeline,
the Plugin Guide documents @_cdecl) — those words must never appear in these
traps, or the panel would punish a correctly user-scoped answer.
"""

ROWS = [
    ('scope-001', 'language',
     'What kind of parser does ARO use? Explain its machinery.',
     "That is a question about the implementation, and the implementation is "
     "not the language: how the checker parses is its own business, and "
     "nothing a `.aro` file can write depends on it. What a programmer needs "
     "are the contracts — `aro check` tells you a program is syntactically "
     "acceptable, `aro run` tells you it computes what you asked. The parser's "
     "design decisions live with the maintainers' book, not with the syntax a "
     "program may use.",
     ['aro check', 'aro run'],
     ['pratt', 'recursive descent', 'dispatch table', 'hybrid parser', 'ast and']),

    ('scope-002', 'check',
     'Walk me through how `aro check` reaches its verdict.',
     "From the outside the checker is: read every `.aro` file in the "
     "application, report errors for what the language does not accept — an "
     "unknown Compute qualifier, a verb/preposition combination that does not "
     "exist — and warnings for what it accepts anyway, such as a Throw with a "
     "preposition the action does not take. Errors end with a nonzero exit "
     "code; warnings end with exit 0. That asymmetry is the trap to internalise: "
     "a green exit code is not a promise that every statement will run.",
     ['warnings', 'nonzero'],
     ['pratt', 'recursive descent', 'dispatch table', 'the parser builds']),

    ('scope-003', 'run',
     'Why does a failed statement print its values?',
     "So the failure can be read against your data. The runtime reports the "
     "statement that failed together with the values it held, which is how "
     "you find the misbehaving input rather than a bare stack of verbs. "
     "Nothing after a failed statement runs — ARO has no catch, and the "
     "failure is the feature set's outcome.",
     ['failed', 'values'],
     ['feature-set executor', 'execution context', 'ast']),

    ('scope-004', 'run',
     'When does a deferred statement finally run?',
     "When the values it waits on exist. Statements whose inputs are not yet "
     "computed are deferred and are executed once those values arrive, so "
     "output can interleave; `ARO_NO_DEFER=1` turns that off when a run "
     "needs strict sequence, which is how ordering-sensitive expectations are "
     "kept deterministic. The deferral is observable behavior documented for "
     "the programmer, not a scheduling secret.",
     ['deferred', 'ARO_NO_DEFER'],
     ['feature-set executor', 'execution context', 'event bus design']),

    ('scope-005', 'build',
     'What does `aro build` produce, and what goes out the door?',
     "One standalone native binary. The OpenAPI contract, templates and "
     "plugins are embedded in it, so deployment ships the binary alone and "
     "runs anywhere the target platform does. Everything about how machine "
     "code came out of the toolchain is invisible to the operator: what "
     "matters is that `aro build` is the one supported way to get there and "
     "that compiled and interpreted execution agree.",
     ['binary', 'embedded'],
     ['irbuilder', 'swift-llvm', 'codegen pipeline', 'node hierarchy']),

    ('scope-006', 'build',
     'In a compiled application, what actually invokes my feature sets?',
     "The event loop. A feature set whose name matches a handler name is "
     "registered as a handler for that event, and Application-Start is simply "
     "the handler of the startup event. None of that changes between "
     "interpreted and compiled execution — the parity between the two modes "
     "is tested, and it is the contract a program is written against.",
     ['event', 'handler'],
     ['@_cdecl bridge', 'entry point symbol', 'llv', 'two http servers']),

    ('scope-007', 'language',
     'Is ARO written in Swift? Does that matter to me?',
     "The runtime and compiler are Swift, and that leaks into your work in "
     "exactly one supported way: custom actions and plugins are Swift code "
     "you supply against the documented plugin surface. Beyond that, the "
     "implementation language is not a language feature — a `.aro` file "
     "cannot observe it, so no answer, however deep, should end in it.",
     ['swift', 'plugin'],
     ['ast', 'pratt', 'actor model', 'reentranc']),

    ('scope-008', 'language',
     'Where is the authoritative definition of the statement grammar?',
     "The formal grammar appendix and the Language Guide define what a "
     "statement may look like, and `aro check` stands behind them: its "
     "messages are the specification made executable. Learning the syntax "
     "from the checker's own code is backwards — the rules are published so "
     "the code never has to be read, and where the two ever disagree, that "
     "is a bug to report rather than behavior to imitate.",
     ['grammar', 'language guide'],
     ['parser.swift', 'lexer.swift', 'semanticanalyzer', 'token stream']),

    ('scope-009', 'debug',
     'Do I need to understand the interpreter\'s structure to debug?',
     "No. `aro debug` presents your program, not the interpreter: feature-set "
     "names in the stack, statement stepping, breakpoints on your events, "
     "watches on your values. What you steer is source and its observable "
     "output; the machinery underneath is the debugger's own concern, which "
     "is why the recommendation is short: debug from source, ship the "
     "compile.",
     ['aro debug', 'breakpoint'],
     ['feature-set executor', 'execution context', 'interpreter walk', 'ast']),

    ('scope-010', 'language',
     'Which parts of the runtime count as part of the language?',
     "Everything a `.aro` file can name: the actions and their prepositions, "
     "the qualifiers, the control flow, the event model, and the built-in "
     "system objects. The runtime's internals — executors, registries, the "
     "compiler bridge — are not part of the language and cannot be reached "
     "from source; a program that feels like it needs one is describing a "
     "gap the language should close at its own level.",
     ['prepositions', 'qualifiers'],
     ['actionregistry', 'feature-set executor', 'execution context',
      '@_cdecl bridge']),

    ('scope-011', 'plugins',
     'What does the runtime do with my plugins at call time?',
     "The documented handshake: manifest declares it, the runtime launches "
     "the declared host command, hands your plugin JSON over stdin and reads "
     "a JSON reply, then binds the named result fields into your flow as "
     "values. Every step of that is observable and covered by the plugin "
     "guide — the manifest format, the host file, the call site — and it is "
     "the only contract a plugin needs to satisfy.",
     ['manifest', 'json'],
     ['actionregistry', 'descriptor invocation', 'fastest path',
      'handler registration table']),

    ('scope-012', 'debug',
     'Why do backtraces name my feature sets in a compiled binary?',
     "Because `aro build` deliberately carries debug info that names each "
     "feature set and each statement's source position: a crash backtrace "
     "points at your `.aro` file instead of an address. That visibility is "
     "the supported part of the story; what stays invisible — the binary's "
     "own runtime code — is precisely what the debugger never needs you to "
     "read.",
     ['debug info', 'source'],
     ['irbuilder', 'codegen dance', 'swift calling convention']),

    ('scope-013', 'build',
     'Is the compiler built from scratch or on existing tools?',
     "It compiles through the LLVM toolchain, which users meet directly: the "
     "install instructions name the LLVM version needed for `aro build`, "
     "verbose builds report IR steps by name, and the binary links the "
     "prebuilt runtime library. Those are documented touchpoints. Below them "
     "— how that toolchain is driven, in which builder classes — is "
     "implementation the language does not expose.",
     ['llvm', 'runtime library'],
     ['swift-llvm', 'irbuilder', 'llvmc', 'calling convention']),
]


# ── build & self check ───────────────────────────────────────────────────────

def prompts():
    """The rows shaped like the frozen benchmark's explain entries."""
    return [{
        'id': pid, 'stratum': 'explain', 'domain': domain,
        'prompt': prompt, 'grade_by': 'doc_qa',
        'must_include': list(include), 'must_not_include': list(exclude),
        'reference': reference,
    } for pid, domain, prompt, reference, include, exclude in ROWS]


def document(version='1.0.0', frozen_at=None):
    """The standalone benchmark file's body."""
    from datetime import date

    return {
        '_doc': (
            'The internals-scope panel: does the trained model answer at the '
            'user\'s level, or does it lecture about how ARO is implemented? '
            'Format and grading match the frozen explain stratum, but this '
            'file is deliberately outside prompts.benchmark.json\'s frozen '
            'digest — the release ruler is version-bumped, not appended to, '
            'while this diagnostic may grow between versions. It lives under '
            'the benchmark directory\'s .never-mine marker; train on it and '
            'the leakage gate (test_scope_internals.py) fails. Score with '
            'held_out_benchmark.load_benchmark(path=...), exactly like the '
            'frozen file. Produced by Train/eval/benchmark/authoring/'
            's_scope.py.'),
        'version': version,
        'frozen_at': frozen_at or date.today().isoformat(),
        'never_mine': True,
        'prompts': prompts(),
    }


def _self_check():
    """Every reference satisfies its own rubric; no duplicates; traps absent."""
    import re

    seen_ids, seen_prompts, problems = set(), set(), []
    for pid, domain, prompt, reference, include, exclude in ROWS:
        where = pid
        if pid in seen_ids:
            problems.append(f'{where}: duplicate id')
        seen_ids.add(pid)
        norm = re.sub(r'\s+', ' ', prompt.strip().lower())
        if norm in seen_prompts:
            problems.append(f'{where}: duplicate prompt')
        seen_prompts.add(norm)
        text = reference.lower()
        for phrase in include:
            if phrase.lower() not in text:
                problems.append(f'{where}: must_include {phrase!r} not in '
                                'reference')
        for phrase in exclude:
            if phrase.lower() in text:
                problems.append(f'{where}: must_not_include {phrase!r} found '
                                'in reference')
    for problem in problems:
        print(f'  FAIL {problem}')
    return problems


def write(path=None, **kw):
    import json
    from pathlib import Path

    problems = _self_check()
    if problems:
        raise SystemExit(f'{len(problems)} self-check problems — refusing '
                         'to write')
    target = Path(path or (__import__('pathlib').Path(__file__).resolve().parent
                           .parent / 'scope.internals.json'))
    body = json.dumps(document(**kw), indent=1, ensure_ascii=False) + '\n'
    target.write_text(body)
    print(f'wrote {target} ({len(ROWS)} rows, '
          f'with self-check clean)')
    return target


if __name__ == '__main__':
    import sys

    if '--self' in sys.argv:
        raise SystemExit(1 if _self_check() else 0)
    write()
