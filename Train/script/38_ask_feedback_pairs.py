#!/usr/bin/env python3
"""38_ask_feedback_pairs.py — turn the exported `aro ask` repair seeds into
preference and repair pairs (GitLab #800).

`aro ask --export-training Train/seeds/ask_feedback` writes RepairSeed jsonl
files (prompt / rejected / chosen / diagnostic_class / attempts / timestamp /
origin) out of Sessions/.context.repairs.jsonl. The seed's two sides were
re-validated by the build that exported them and anonymised there — which is
a different build on a different machine from the one that trains. So this
stage re-validates its input instead of trusting it:

    read seeds → extract fenced blocks → `aro check` both sides
    → keep the pair only when the claim is true again
      (chosen: checks clean, no invented verb;
       rejected: fails a check or invented one)
    → DPO triples to data/dpo/  +  repair-correction rows to the corpus

A seed whose sides no longer obey the claim is dropped and counted, exactly
like the notebook's own _verify_pair_grounding — the point is that the claim
is true NOW, not that it was true whenever the session ran.

The repair-correction rows are the SFT mirror of the same seed: the ask, the
broken attempt, and the corrected answer, pooled into the pairs corpus as
`correction` — the rung the repair family (NB34) trains, while the DPO side
feeds NB19's reject pool with a chosen side attached.

    python3 Train/script/38_ask_feedback_pairs.py --dry-run
    python3 Train/script/38_ask_feedback_pairs.py --audit --out data/dpo/ask_feedback_pairs.jsonl
"""
from __future__ import annotations

import argparse
import getpass
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402
import revalidate_corpus as rc  # noqa: E402

SEEDS_DIR = SCRIPT_DIR.parent / 'seeds' / 'ask_feedback'
DEFAULT_OUT = SCRIPT_DIR.parent / 'data' / 'dpo' / 'ask_feedback_pairs.jsonl'
DEFAULT_TAG = 'NB38_ask'

REPAIR_INSTRUCTION = (
    'A first attempt produced this program:\n'
    '\n'
    '```aro\n{broken}\n```\n'
    '\n'
    'It does not check clean. Review what is wrong with it and return a '
    'corrected program for the same task.')

# Anonymisation happened at export time, on the exporting machine. A seed
# whose text still carries an absolute user path names that person anyway
# — refuse to re-import it rather than smuggle it into training data.
_ABSOLUTE_USER_PATH_RE = re.compile(r'/(?:Users|home)/[^/\s"\']+')


def _side_quality(text, verbs):
    """(clean_blocks|None, error) — the fenced ARO in one answer and whether
    it checks clean with no invented verb. None when the answer holds no ARO
    at all, which is its own thing to count, not an error quote."""
    blocks = aro_oracle.aro_blocks(text or '')
    if not blocks:
        return None, 'no ```aro block in the answer'
    errors = []
    for block in blocks:
        ok, out = aro_oracle.check_block(block.strip())
        if ok is not True:
            errors.append(_first_error(out))
            continue
        unknown = rc.hallucinated_verbs(block.strip(), verbs) or []
        if unknown:
            errors.append(f'invented verb: {", ".join(sorted(unknown)[:3])}')
    if errors:
        return None, errors[0]
    return blocks, None


def _first_error(check_output):
    """The line a person reads first — the first `error:` and its hint."""
    for line in (check_output or '').splitlines():
        if 'error:' in line:
            return line.strip()[:300]
    return (check_output or 'unknown check failure')[:300]


def _names_a_person(texts, username):
    """Defence in depth for anonymisation done elsewhere."""
    for text in texts:
        if _ABSOLUTE_USER_PATH_RE.search(text or ''):
            return True
        if username and len(username) >= 3 and username.lower() in (text or '').lower():
            return True
    return False


def build_rows(seeds_dir=SEEDS_DIR, limit=0, username=None):
    """(pairs, correction_rows, stats) — one pass, both outputs.

    Pairs land in the flat triple shape 35 writes and the DPO audit reads;
    correction rows go through save_notebook_pairs so the corpus's own lint
    and dedup gates get a vote.
    """
    verbs, _vp, _known = rc.load_catalogs()
    stats = {'files': 0, 'seeds': 0, 'exported': 0,
             'dropped_empty': 0, 'dropped_duplicate': 0,
             'dropped_paths': 0, 'dropped_no_aro': 0,
             'dropped_still_fails': 0,
             'dropped_broken_already_passed': 0}
    by_diagnostic: dict[str, int] = {}
    pairs, corrections = [], []
    seen = set()
    username = username or getpass.getuser()

    for seed_file in sorted(Path(seeds_dir).glob('*.jsonl')):
        stats['files'] += 1
        for line in open(seed_file):
            line = line.strip()
            if not line:
                continue
            seed = json.loads(line)
            stats['seeds'] += 1
            prompt = seed.get('prompt') or ''
            rejected = seed.get('rejected') or ''
            chosen = seed.get('chosen') or ''
            if not (prompt and rejected and chosen):
                stats['dropped_empty'] += 1
                continue
            key = (prompt, rejected, chosen)
            if key in seen:
                stats['dropped_duplicate'] += 1
                continue
            seen.add(key)
            if _names_a_person((prompt, rejected, chosen), username):
                stats['dropped_paths'] += 1
                continue
            chosen_blocks, chosen_err = _side_quality(chosen, verbs)
            if chosen_blocks is None:
                if 'no ```aro' in chosen_err:
                    stats['dropped_no_aro'] += 1
                else:
                    # the fix does not pass in this build — the pair's
                    # claim is not true now, however it was then
                    stats['dropped_still_fails'] += 1
                continue
            rejected_blocks, rejected_err = _side_quality(rejected, verbs)
            if rejected_blocks is not None:
                # the wrong side passes clean in this build — the repair may
                # have been about a diagnostic that this build no longer has
                stats['dropped_broken_already_passed'] += 1
                continue
            if 'no ```aro' in rejected_err:
                # a rejected side with no ARO teaches empty-vs-valid, which
                # #414's synthetic penalty pairs already teach deliberately
                stats['dropped_no_aro'] += 1
                continue
            diagnostic = seed.get('diagnostic_class') or 'other'
            broken_code = '\n\n'.join(b.strip() for b in aro_oracle.aro_blocks(rejected))
            reason = rejected_err
            pairs.append({
                'prompt': prompt,
                'chosen': chosen,
                'rejected': rejected,
                'reason': reason,
                'reason_class': diagnostic,
                'origin': f'ask_feedback:{diagnostic}',
                'attempts': seed.get('attempts'),
                'timestamp': seed.get('timestamp'),
                'aro_version': aro_oracle.aro_version(),
            })
            by_diagnostic[diagnostic] = by_diagnostic.get(diagnostic, 0) + 1
            stats['exported'] += 1

            corrections.append({
                'instruction': REPAIR_INSTRUCTION.format(broken=broken_code),
                'output': chosen,
                'task_type': 'correction',
                'source': f'ask_feedback:{diagnostic}',
                '_ask_feedback': {
                    'diagnostic_class': diagnostic,
                    'attempts': seed.get('attempts'),
                    'timestamp': seed.get('timestamp'),
                    'origin': seed.get('origin') or 'ask_feedback',
                },
            })
            if limit and stats['exported'] >= limit:
                break
        if limit and stats['exported'] >= limit:
            break
    stats['by_diagnostic'] = by_diagnostic
    return pairs, corrections, stats


def audit(path: Path):
    rows = []
    seen = set()
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        seen.add((record.get('chosen'), record.get('rejected'),
                  record.get('prompt')))
        rows.append(record)
    print(f'{path}')
    print(f'  rows           : {len(rows)}')
    print(f'  unique         : {len(seen)}')
    print(f'  reason logged  '
          f': {all(r.get("reason") for r in rows)}')
    print(f'  origin logged  '
          f': {all(r.get("origin") for r in rows)}')


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seeds', type=Path, default=SEEDS_DIR,
                        help='directory of RepairSeed exports (default '
                             'Train/seeds/ask_feedback)')
    parser.add_argument('--out', type=Path, default=DEFAULT_OUT,
                        help='DPO triples destination (default '
                             'Train/data/dpo/ask_feedback_pairs.jsonl)')
    parser.add_argument('--no-save', action='store_true',
                        help='skip the corpus append of the repair rows')
    parser.add_argument('--limit', type=int, default=0)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--audit', action='store_true',
                        help='report an existing output file, change nothing')
    args = parser.parse_args(argv)

    if args.audit:
        audit(args.out)
        return 0
    if not Path(args.seeds).is_dir():
        # an explicit, non-dramatic answer to the common case: nothing has
        # been exported yet. The stage is opt-in downstream of the export.
        # Asked before the binary: "no seeds yet" is answerable without the
        # toolchain, and a slim CI run must not reply "no `aro` binary" to a
        # question that never needed one.
        print(f'no seed directory at {args.seeds} — run '
              f'`aro ask --export-training {args.seeds}` first.',
              file=sys.stderr)
        return 0
    if not aro_oracle.aro_bin():
        print('no `aro` binary — the pair claim is verified against it, so '
              'there is nothing to do.', file=sys.stderr)
        return 2

    pairs, corrections, stats = build_rows(args.seeds, limit=args.limit)
    print(json.dumps({k: v for k, v in stats.items()
                      if k != 'by_diagnostic'}))
    for diagnostic, n in sorted(stats['by_diagnostic'].items(),
                               key=lambda kv: -kv[1]):
        print(f'  {diagnostic:<28} {n}')
    if args.dry_run:
        for pair in pairs[:2]:
            print('\n--- sample ---')
            print(f'prompt  : {pair["prompt"][:100]}')
            print(f'reason  : {pair["reason"]}')
            print(f'origin  : {pair["origin"]}')
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, 'w') as handle:
        for pair in pairs:
            handle.write(json.dumps(pair) + '\n')
    print(f'wrote {len(pairs)} DPO rows -> {args.out}')
    if args.no_save:
        print('corpus append skipped (--no-save)')
    else:
        written = config.save_notebook_pairs(DEFAULT_TAG, corrections)
        print(f'saved {written}/{len(corrections)} repair rows to the corpus '
              f'({DEFAULT_TAG})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
