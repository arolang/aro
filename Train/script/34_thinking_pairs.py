#!/usr/bin/env python3
"""Thinking traces distilled from the repair loop, not from a template
(GitLab #789).

`data/26_thinking/mlx/train.jsonl` holds 2 348 rows. 1 156 carry a `<think>`
block and 1 154 of those are the same template — a per-statement enumeration
reading "`Log` — a EXPORT action (exports data…). It takes the preposition
`to`." — averaging 1 640 characters of it. The other 1 192 rows have no think
block at all, so the behaviour the booster teaches is "think, or don't, at
random"; that is why packaging needs an empty-think gate and AskSession has
three separate retry paths for a stalled think. None of the rows carries a
system prompt, although `aro ask` always sends one. And the template is not
even right: it calls `Log` an EXPORT action, while the registry says RESPONSE.

Reasoning about ARO is not reciting a verb's role. It is: I wrote this, the
checker said that, therefore this edit. So each trace here is a real repair
loop, and every part of it is observed rather than asserted.

  1. Start from a program the runtime accepts.
  2. Break it in one known way — a preposition the action does not take, a
     missing period, `+` between strings, an invented verb, an invented
     qualifier, a missing entry point.
  3. Ask `aro check`. If it does not complain, the mutation was not a
     mistake and the case is dropped.
  4. Write the think block from *that diagnostic*: what was asked, what was
     written, what the checker said, which edit follows.
  5. Answer with the original program, and check it again.

Every row carries the system prompt `aro ask` sends and every row thinks, so
think and no-think never mix.

    python3 Train/script/34_thinking_pairs.py --source Train/Material/curated.jsonl --dry-run
    python3 Train/script/34_thinking_pairs.py --out data/26_thinking/repairs.jsonl
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

DEFAULT_SOURCE = SCRIPT_DIR.parent / 'Material' / 'curated.jsonl'


# ── the mutations ────────────────────────────────────────────────────────────
# Each returns the broken code, or None when it does not apply. The
# explanation is what the think block reasons *to*; the diagnostic it reasons
# *from* comes from the binary, never from here.

def _mutate_preposition(code):
    m = re.search(r'\b(Store|Write|Append)\b([^\n.]*?)\binto\b', code)
    if not m:
        return None
    broken = code[:m.start()] + m.group(0).replace(' into', ' in') + code[m.end():]
    return broken, (
        'the preposition. `in` is a keyword, not a preposition, and the '
        'action does not take it — the valid ones are listed in the hint')


def _mutate_missing_period(code):
    lines = code.split('\n')
    for i, line in enumerate(lines):
        if line.strip().endswith('.') and '<' in line and not line.strip().startswith('(*'):
            lines[i] = line.rstrip()[:-1]
            return '\n'.join(lines), (
                'the statement terminator. Every ARO statement ends with a '
                'period; without one the parser reads the next line as a '
                'continuation of this one')
    return None


def _mutate_concat(code):
    if '++' not in code:
        return None
    return code.replace('++', '+', 1), (
        'string concatenation. ARO concatenates with `++`; `+` is arithmetic')


def _mutate_invented_verb(code):
    m = re.search(r'^(\s*)(Compute|Create|Extract|Retrieve)\b', code, re.MULTILINE)
    if not m:
        return None
    broken = code[:m.start(2)] + 'Process' + code[m.end(2):]
    return broken, (
        'the verb. No action in the registry answers to `Process` — which is '
        'the one mistake `aro check` will not catch for you, because an '
        'unknown verb is a name it has no opinion about')


def _mutate_qualifier(code):
    m = re.search(r'Compute\s+(?:the\s+|an?\s+)?<([\w-]+):\s*([\w-]+)>', code)
    if not m:
        return None
    broken = code[:m.start(2)] + 'summarize' + code[m.end(2):]
    return broken, (
        'the qualifier. The Compute qualifier namespace is closed — a name '
        'that is not a built-in, a plugin `handle.qualifier` or a chain is an '
        'error, not a no-op')


def _mutate_entry_point(code):
    if 'Application-Start' not in code:
        return None
    broken = code.replace('Application-Start', 'Application Start', 1)
    return broken, (
        'the entry point. The lifecycle feature set is spelled '
        '`Application-Start`, with the hyphen; without it the application has '
        'no entry point')


# (category, mutate, oracle). Most mistakes the checker catches; an invented
# verb it does not — `Process the <x> from <y>.` passes `aro check` with
# nothing worse than a use-before-definition warning — so that one is graded
# against the generated action catalog instead, and the trace says so.
MUTATIONS = (
    ('wrong_preposition', _mutate_preposition, 'check'),
    ('missing_period', _mutate_missing_period, 'check'),
    ('string_concat_plus', _mutate_concat, 'check'),
    ('invalid_verb', _mutate_invented_verb, 'catalog'),
    ('unknown_qualifier', _mutate_qualifier, 'check'),
    ('missing_application_start', _mutate_entry_point, 'check'),
)


def first_diagnostic(error: str) -> str:
    """The line a person would read first: the first `error:` and its hint."""
    lines = [ln.rstrip() for ln in (error or '').splitlines()]
    out = []
    for i, line in enumerate(lines):
        if 'error:' in line:
            out.append(line.strip())
            if i + 1 < len(lines) and 'hint:' in lines[i + 1]:
                out.append(lines[i + 1].strip())
            break
    return '\n'.join(out) or (error or '').strip()[:200]


def think_block(instruction, broken, diagnostic, explanation, oracle):
    who = ('`aro check` rejects it' if oracle == 'check'
           else 'the action catalog rejects it')
    return (
        f'The instruction is: {instruction.strip()}\n\n'
        f'My first attempt was this:\n\n```aro\n{broken.strip()}\n```\n\n'
        f'{who}:\n\n```\n{diagnostic}\n```\n\n'
        f'That is {explanation}. So the edit is confined to the statement the '
        f'diagnostic points at — everything else stays byte for byte as it '
        f'was — and I check again before answering.')


def build_traces(source: Path, limit=0, seed=0, system_prompt=None):
    """(rows, stats). One row per (program, mutation) that the binary agrees
    is broken and whose repair it agrees is not."""
    rng = random.Random(seed)
    stats = {'pairs_read': 0, 'programs': 0, 'mutations_tried': 0,
             'not_broken': 0, 'traces': 0}
    by_category = {}
    verbs, _vp, _known = rc.load_catalogs()
    rows = []
    for line in open(source):
        line = line.strip()
        if not line:
            continue
        pair = json.loads(line)
        if config.is_jsonl_metadata_record(pair):
            continue
        stats['pairs_read'] += 1
        instruction = rc.prompt_text(pair)
        blocks = aro_oracle.aro_blocks(rc.answer_text(pair))
        if not instruction or len(blocks) != 1:
            continue
        code = blocks[0].strip()
        ok, _error = aro_oracle.check_block(code)
        if ok is not True:
            continue
        stats['programs'] += 1
        order = list(MUTATIONS)
        rng.shuffle(order)
        # Least-represented category first, so one mutation that applies to
        # nearly every program does not become four fifths of the corpus.
        order.sort(key=lambda entry: by_category.get(entry[0], 0))
        for category, mutate, oracle in order:
            result = mutate(code)
            if not result:
                continue
            broken, explanation = result
            if broken.strip() == code:
                continue
            stats['mutations_tried'] += 1
            if oracle == 'catalog':
                unknown = rc.hallucinated_verbs(broken, verbs)
                if not unknown:
                    stats['not_broken'] += 1
                    continue
                diagnostic = (
                    f"`{unknown[0]}` is not a registered action verb.\n"
                    f"Run `aro actions` for the ones that are.")
            else:
                broken_ok, broken_error = aro_oracle.check_block(broken)
                if broken_ok is not False:
                    # The mutation did not actually break anything, so there
                    # is no repair to reason about.
                    stats['not_broken'] += 1
                    continue
                diagnostic = first_diagnostic(broken_error)
            messages = []
            if system_prompt:
                messages.append({'role': 'system', 'content': system_prompt})
            messages += [
                {'role': 'user', 'content': instruction},
                {'role': 'assistant',
                 'content': (f'<think>\n'
                             f'{think_block(instruction, broken, diagnostic, explanation, oracle)}\n'
                             f'</think>\n\n```aro\n{code}\n```')},
            ]
            rows.append({
                'messages': messages,
                'task_type': 'correction',
                'source': f'repair_loop:{category}',
                'validation': {'aro_version': aro_oracle.aro_version(),
                               'broken_checks': False, 'fixed_checks': True},
            })
            by_category[category] = by_category.get(category, 0) + 1
            stats['traces'] += 1
            break                      # one trace per program, not six
        if limit and stats['traces'] >= limit:
            break
    stats['by_category'] = by_category
    return rows, stats


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE,
                        help='validated corpus to start from')
    parser.add_argument('--out', type=Path, help='write the traces here')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--no-system-prompt', action='store_true',
                        help='omit the system prompt (the old behaviour; '
                             '`aro ask` always sends one)')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)

    if not aro_oracle.aro_bin():
        print('no `aro` binary — every trace is grounded in a real '
              'diagnostic, so there is nothing to do.', file=sys.stderr)
        return 2
    if not args.source.exists():
        print(f'{args.source}: not found', file=sys.stderr)
        return 2

    system_prompt = None
    if not args.no_system_prompt:
        try:
            system_prompt = config.build_system_prompt()
        except Exception:
            system_prompt = (
                'You are an expert ARO (Action Result Object) programmer. '
                'Think through the problem inside <think></think>, then answer '
                'with the ARO program.')

    rows, stats = build_traces(args.source, args.limit, args.seed, system_prompt)
    print(f'{args.source}: {stats}')
    templated = sum(1 for r in rows
                    if config.thinking_trace_is_templated(
                        r['messages'][-1]['content']))
    print(f'  traces: {len(rows)}   templated: {templated}   '
          f'with a system prompt: {sum(1 for r in rows if r["messages"][0]["role"] == "system")}')
    if args.dry_run:
        if rows:
            print('\n--- sample ---')
            print(rows[0]['messages'][-1]['content'][:1200])
        return 0
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with open(args.out, 'w') as handle:
            for row in rows:
                handle.write(json.dumps(row) + '\n')
        print(f'wrote {len(rows)} traces -> {args.out}')
        return 0
    written = config.save_notebook_pairs('NB34_thinking', rows)
    print(f'saved {written} of {len(rows)} traces to the corpus')
    return 0


if __name__ == '__main__':
    sys.exit(main())
