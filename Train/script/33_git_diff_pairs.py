#!/usr/bin/env python3
"""Error→fix pairs mined from real ARO history — with the generator in the
repository this time (GitLab #781).

`git_examples_pairs.jsonl` (3 514 rows) and `git_applications_pairs.jsonl`
(110) were 36% of the corpus and no notebook or script in this repository
produced them. They paired "Why was this ARO code changed?" plus a *hunk* —
often a single line, sometimes half a `when` clause — with the raw commit
subject, and the reverse direction paired the subject with the new hunk. Every
row was tagged `debugging`, nothing was ever run through `aro check`, and the
source tag was the file path plus a SHA, so the share machinery saw three
thousand distinct sources rather than one source at a third of the corpus.

This is the generator, and it differs in four ways.

**Whole files, not hunks.** A hunk cannot be checked; a file can. Both
revisions of the file are checked out with `git show` and run through
`aro check`, and the pair records both verdicts.

**The new side must be valid.** A pair whose answer does not check is not a
fix, whatever the commit message claimed. The old side is allowed to fail —
that is what makes the pair a correction rather than a refactor, and the pair
is labelled accordingly rather than everything being `debugging`.

**The answer says what changed and why.** The commit subject alone is not an
answer to "why was this changed" that anybody wants; it is a label. The answer
here is the commit subject, the body where there is one, and the unified diff
of the file, so the model learns the change as well as its justification.

**The source is `git:<path>@<sha>`.** One family, visible to every consumer
that splits a source tag on ':' — the share cap, the quality score, the
dataset report.

    python3 Train/script/33_git_diff_pairs.py --repo . --limit 200 --dry-run
    python3 Train/script/33_git_diff_pairs.py --repo . --repo ../ARO-Application
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402

SYSTEM_PROMPT = (
    'You are an expert ARO (Action Result Object) programmer. ARO is a DSL '
    'where every statement is: Verb the <Result> preposition [the] <Object>. '
    'Feature sets follow (Name: Business Activity) { statements }. Variables '
    'are immutable.')

# A commit whose message says it fixed something, used only to order the
# candidates: the verdicts decide what a pair is called.
FIX_WORDS = ('fix', 'correct', 'repair', 'bug', 'broken', 'wrong', 'error')


def git(repo: Path, *args, binary=False):
    result = subprocess.run(['git', '-C', str(repo), *args],
                            capture_output=True, timeout=120)
    if result.returncode != 0:
        return None
    if binary:
        return result.stdout
    return result.stdout.decode('utf-8', 'replace')


def commits_touching_aro(repo: Path, limit: int, since: str | None):
    args = ['log', '--format=%H', '--no-merges']
    if since:
        args += [f'--since={since}']
    args += [f'-n{limit}', '--', '*.aro']
    out = git(repo, *args)
    return [line.strip() for line in (out or '').splitlines() if line.strip()]


def files_changed(repo: Path, sha: str):
    out = git(repo, 'show', '--format=', '--name-only', sha, '--', '*.aro')
    return [line.strip() for line in (out or '').splitlines() if line.strip()]


def commit_message(repo: Path, sha: str):
    out = git(repo, 'log', '-1', '--format=%s%n%n%b', sha) or ''
    lines = out.rstrip().split('\n')
    return lines[0].strip(), '\n'.join(lines[1:]).strip()


def file_at(repo: Path, sha: str, path: str):
    return git(repo, 'show', f'{sha}:{path}')


def file_diff(repo: Path, sha: str, path: str):
    return git(repo, 'show', '--format=', '--unified=3', sha, '--', path) or ''


def build_pairs(repo: Path, limit=200, since=None, max_chars=8000,
                require_new_valid=True, progress=False):
    """Yield (pair, stats-key) for every commit that changed a checkable .aro
    file and left it in a state the runtime accepts."""
    repo_name = repo.resolve().name
    stats = {'commits': 0, 'files': 0, 'no_parent': 0, 'too_big': 0,
             'new_invalid': 0, 'unchanged': 0, 'pairs': 0,
             'correction': 0, 'code_transformation': 0}
    pairs = []
    for sha in commits_touching_aro(repo, limit, since):
        stats['commits'] += 1
        subject, body = commit_message(repo, sha)
        for path in files_changed(repo, sha):
            stats['files'] += 1
            new_text = file_at(repo, sha, path)
            old_text = file_at(repo, f'{sha}~1', path)
            if new_text is None or old_text is None:
                stats['no_parent'] += 1       # added file, or a root commit
                continue
            if old_text.strip() == new_text.strip():
                stats['unchanged'] += 1
                continue
            if len(new_text) > max_chars or len(old_text) > max_chars:
                stats['too_big'] += 1
                continue
            new_ok, new_error = aro_oracle.check_block(new_text)
            if require_new_valid and new_ok is not True:
                # Whatever the message claimed, the answer does not check.
                stats['new_invalid'] += 1
                continue
            old_ok, old_error = aro_oracle.check_block(old_text)
            task_type = 'correction' if old_ok is False else 'code_transformation'
            stats[task_type] += 1
            diff = file_diff(repo, sha, path)
            why = subject if not body else f'{subject}\n\n{body}'
            explanation = (
                f'{why}\n\nWhat changed in `{path}`:\n\n'
                f'```diff\n{diff.strip()[:2500]}\n```')
            if old_ok is False:
                explanation += (
                    f'\n\nThe previous version did not pass `aro check`:\n\n'
                    f'```\n{(old_error or "").strip()[:400]}\n```')
            source = f'git:{repo_name}/{path}@{sha[:10]}'
            base = {
                'task_type': task_type,
                'source': source,
                'validation': {
                    'aro_version': aro_oracle.aro_version(),
                    'old_checks': old_ok, 'new_checks': new_ok,
                },
            }
            pairs.append(dict(base, messages=[
                {'role': 'system', 'content': SYSTEM_PROMPT},
                {'role': 'user',
                 'content': f'This ARO file was changed. What changed, and '
                            f'why?\n\n```aro\n{old_text.strip()}\n```'},
                {'role': 'assistant', 'content': explanation},
            ]))
            pairs.append(dict(base, messages=[
                {'role': 'system', 'content': SYSTEM_PROMPT},
                {'role': 'user',
                 'content': f'{why}\n\nApply that change to this ARO '
                            f'file:\n\n```aro\n{old_text.strip()}\n```'},
                {'role': 'assistant', 'content': f'```aro\n{new_text.strip()}\n```'},
            ]))
            stats['pairs'] += 2
            if progress and stats['pairs'] % 50 == 0:
                print(f'  … {stats["pairs"]} pairs', flush=True)
    return pairs, stats


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--repo', action='append', type=Path, default=None,
                        help='repository to mine (repeatable; default: this one)')
    parser.add_argument('--limit', type=int, default=200,
                        help='commits per repository (default: 200)')
    parser.add_argument('--since', help='git --since expression, e.g. "1 year ago"')
    parser.add_argument('--out', type=Path,
                        help='write the pairs here instead of the corpus')
    parser.add_argument('--dry-run', action='store_true',
                        help='report what would be produced, write nothing')
    parser.add_argument('--allow-invalid-new', action='store_true',
                        help='keep pairs whose new side does not check '
                             '(off by default, and it should stay off)')
    args = parser.parse_args(argv)

    repos = args.repo or [Path(__file__).resolve().parents[2]]
    if not aro_oracle.aro_bin():
        print('no `aro` binary — both sides of every pair must be checked, '
              'so there is nothing to do. Set ARO_BIN or build one.',
              file=sys.stderr)
        return 2

    all_pairs, totals = [], {}
    for repo in repos:
        if not (repo / '.git').exists():
            print(f'{repo}: not a git repository', file=sys.stderr)
            continue
        pairs, stats = build_pairs(repo, args.limit, args.since,
                                   require_new_valid=not args.allow_invalid_new,
                                   progress=not args.dry_run)
        print(f'{repo}: {stats}')
        all_pairs += pairs
        for key, value in stats.items():
            totals[key] = totals.get(key, 0) + value

    print(f'\ntotal: {len(all_pairs)} pairs  {totals}')
    if args.dry_run:
        for pair in all_pairs[:2]:
            print('\n--- sample ---')
            print(pair['messages'][1]['content'][:300])
            print('  ->')
            print(pair['messages'][2]['content'][:300])
        return 0
    if args.out:
        with open(args.out, 'w') as handle:
            for pair in all_pairs:
                handle.write(json.dumps(pair) + '\n')
        print(f'wrote {len(all_pairs)} pairs -> {args.out}')
        return 0
    written = config.save_notebook_pairs('NB33_git', all_pairs)
    print(f'saved {written} of {len(all_pairs)} pairs to the corpus')
    config.pair_gate_report()
    config.dedup_report()
    return 0


if __name__ == '__main__':
    sys.exit(main())
