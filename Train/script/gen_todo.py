#!/usr/bin/env python3
"""GEN_TODO.md — the generation-failure inventory — as structured data.

`GEN_TODO.md` holds 369 prompts that NB10 code generation failed on: the model
produced no valid ARO, or (one entry) nothing but comments. They were appended
automatically so the failure would not evaporate with the session, which means
the file is the largest single source of "prompts this model family actually
fails on" the repository has — and it is markdown, so nothing could consume it.

`parse()` turns it into records. Everything downstream of it — the
full-application recovery stage (36_full_application_pairs.py), the report —
reads prompts from here, never from the file's text.

    python3 Train/script/gen_todo.py                 # count by kind, list a sample
    python3 Train/script/gen_todo.py --json          # machine-readable
    python3 Train/script/gen_todo.py --kind no_output --limit 5
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = REPO_ROOT / 'GEN_TODO.md'

# `## 173. comment_heavy [grounded]` — the number is the run's own entry id,
# the kind is the failure class NB10 recorded, the bracket tag is optional.
ENTRY_RE = re.compile(r'^##\s+(\d+)\.\s+([a-z_]+)(?:\s+\[([a-z]+)\])?\s*$', re.MULTILINE)


def parse(path: Path | None = None) -> list[dict]:
    """Every entry in GEN_TODO.md: {'n', 'kind', 'tag', 'prompt'}.

    The prompt is everything between the header and the next header or a
    `---` separator, whitespace-normalised. A blank prompt is recorded as
    found (empty) rather than dropped — an entry that says nothing is itself
    a data-quality problem, and silently skipping it would understate the
    count the file's own title asserts.
    """
    text = Path(path or DEFAULT_SOURCE).read_text()
    marks = list(ENTRY_RE.finditer(text))
    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        body = text[m.end():end]
        body = re.split(r'^---\s*$', body, maxsplit=1, flags=re.MULTILINE)[0]
        prompt = ' '.join(body.split())
        out.append({'n': int(m.group(1)), 'kind': m.group(2),
                    'tag': m.group(3), 'prompt': prompt,
                    'line': text[:m.start()].count('\n') + 1})
    return out


def stats(entries: list[dict]) -> dict:
    by_kind = Counter(e['kind'] for e in entries)
    by_tag = Counter(e['tag'] for e in entries if e['tag'])
    return {'total': len(entries), 'by_kind': by_kind, 'by_tag': by_tag,
            'empty_prompts': sum(1 for e in entries if not e['prompt'])}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--kind', help='only this failure kind')
    parser.add_argument('--tag', help='only entries carrying this tag')
    parser.add_argument('--limit', type=int, default=0,
                        help='print at most this many prompts')
    parser.add_argument('--json', action='store_true',
                        help='print the parsed entries as JSON')
    args = parser.parse_args(argv)

    if not args.source.exists():
        print(f'{args.source}: not found', file=sys.stderr)
        return 2
    entries = parse(args.source)
    sel = entries
    if args.kind:
        sel = [e for e in sel if e['kind'] == args.kind]
    if args.tag:
        sel = [e for e in sel if e['tag'] == args.tag]

    if args.json:
        import json
        print(json.dumps(sel, indent=1))
        return 0

    print(f'{args.source}: {stats(entries)}')
    print(f'  selected: {len(sel)}')
    for e in sel[:args.limit or 5]:
        print(f'  #{e["n"]:>3} {e["kind"]}{" [" + e["tag"] + "]" if e["tag"] else ""}: '
              f'{e["prompt"][:100]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
