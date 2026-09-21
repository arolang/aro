#!/usr/bin/env python3
"""Re-ask the runtime whether the corpus is still true (GitLab #783).

Every pair in this pipeline was validated — if it was validated at all —
against the `aro` binary of the day it was generated, and then never asked
again. The language moved underneath it. `where id = <id>` became legal
(GitLab #545/#573) after rows were written teaching that the field must be
bracketed; the qualifier namespace closed (GitLab #486) after rows were
written using qualifiers that no longer resolve; `Compare` grew a result
binding (GitLab #469) after rows were written in the two-operand form. The
metadata records an `aro_lang_commit` stamped when the file was *saved*, not
when its rows were generated, so nothing even shows which binary judged what.

This script is the standing answer: point it at a corpus file and it re-checks
every ```aro block with the current binary, records the verdict and the
version on each pair, prints where the failures are concentrated, and exits
non-zero when the corpus is worse than a threshold you name.

    # look
    python3 Train/script/revalidate_corpus.py Train/data/02_knowledge/knowledge_pairs.jsonl

    # look, and fail a pipeline on regression
    python3 Train/script/revalidate_corpus.py CORPUS --fail-under 95

    # write the verdicts back / write a cleaned copy
    python3 Train/script/revalidate_corpus.py CORPUS --annotate out.jsonl
    python3 Train/script/revalidate_corpus.py CORPUS --drop-failures out.jsonl

Four oracles, in the order they cost:

  lint        the FIXTRAIN rules and the closed qualifier namespace
  verbs       statement verbs against the generated action catalog
  preps       verb+preposition against the same catalog
  aro check   the binary itself

`aro check` is the last word on syntax but not on verbs: an invented `Hash`
statement passes it with only a use-before-definition warning, which is
exactly why the catalog gates exist alongside it (and why GitLab #798 asks
for `aro run` on top of both).
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402

DEFAULT_CORPUS = (SCRIPT_DIR.parent / 'data' / '02_knowledge'
                  / 'knowledge_pairs.jsonl')

# Prose around a block that frames it as something deliberately wrong. Such a
# block failing `aro check` is the point of it, not a defect in the corpus.
NEGATIVE_MARKERS = (
    'wrong', 'incorrect', 'invalid', "doesn't work", 'does not work',
    'fails', 'error:', 'bad example', 'anti-pattern', 'antipattern',
    '❌', 'instead of', 'not valid', 'rejected',
)

# Fence content that is not ARO the runtime could ever accept: template
# placeholders, diagrams, annotation carets, C-style comments.
NON_CODE_MARKERS = ('<statements>', '<statement', '^^^^', '───', '│', '└')

_COMMENT_RE = re.compile(r'\(\*.*?\*\)', re.DOTALL)
_STATEMENT_VERB_RE = re.compile(r'^\s*([A-Z][a-z]+(?:[A-Z][a-z]+)*)\s+',
                                re.MULTILINE)
_VP_STMT_RE = re.compile(r'^\s*([A-Z][A-Za-z]+)\s+(?:the\s+|an?\s+)?<[^>]*>\s+([a-z]+)\b')
# `Compute the <total: sum>` — the qualifier slot only. A space inside the
# brackets means it is not a qualifier but a result type (`<n: List <Int>>`),
# so the character class stops at one.
_QUALIFIER_RE = re.compile(r'Compute\s+(?:the\s+|an?\s+)?<[\w-]+:\s*([\w.\-|+]+)\s*>')

# `as` is deliberately absent: it introduces a result type
# (`Compute the <n> as Float from <s>.`) and the Publish alias
# (`Publish as <alias> <variable>.`), never an action's object.
ARO_PREPOSITIONS = frozenset({
    'from', 'to', 'with', 'for', 'on', 'into', 'at', 'by',
    'where', 'against', 'via', 'using', 'in',
})
ALWAYS_ALLOWED_PREPS = frozenset({'when', 'where'})
CONTROL_FLOW_WORDS = frozenset({'for', 'when', 'match', 'if', 'case',
                                'parallel', 'otherwise', 'given', 'then'})


# ── catalogs ─────────────────────────────────────────────────────────────────

def load_catalogs():
    """(verbs, verb→prepositions, qualifier-known predicate) from the committed
    catalogs, which `train:catalogs` keeps equal to the binary."""
    import extract_action_catalog
    import extract_action_verbs
    import extract_qualifier_catalog
    catalog = extract_action_catalog.load()
    verbs = {v.lower() for v in extract_action_verbs.load()} | CONTROL_FLOW_WORDS
    vp = {}
    for meta in catalog.values():
        preps = {p.lower() for p in meta.get('prepositions', [])}
        for alias in meta.get('aliases', []):
            vp.setdefault(alias.lower(), set()).update(preps)
    qual_catalog = extract_qualifier_catalog.load()

    def qualifier_known(name):
        return extract_qualifier_catalog.is_known(name, qual_catalog)

    return verbs, vp, qualifier_known


# ── pair shapes ──────────────────────────────────────────────────────────────

def answer_text(pair: dict) -> str:
    """What the model is being trained to produce."""
    msgs = pair.get('messages')
    if isinstance(msgs, list):
        for msg in reversed(msgs):
            if isinstance(msg, dict) and msg.get('role') == 'assistant':
                return msg.get('content') or ''
        return ''
    for key in ('output', 'response', 'chosen', 'completion', 'answer'):
        value = pair.get(key)
        if isinstance(value, str):
            return value
    return pair.get('text') or ''


def prompt_text(pair: dict) -> str:
    msgs = pair.get('messages')
    if isinstance(msgs, list):
        for msg in msgs:
            if isinstance(msg, dict) and msg.get('role') == 'user':
                return msg.get('content') or ''
        return ''
    for key in ('instruction', 'prompt', 'question'):
        value = pair.get(key)
        if isinstance(value, str):
            return value
    return ''


def pair_source(pair: dict) -> str:
    prov = pair.get('provenance')
    if isinstance(prov, dict):
        for key in ('source', 'generation_strategy', 'notebook'):
            if prov.get(key):
                return str(prov[key])
    for key in ('source', 'category'):
        if pair.get(key):
            return str(pair[key])
    return pair.get('notebook') or '(unattributed)'


def is_metadata(record: dict) -> bool:
    return '_metadata' in record


# ── block classification ─────────────────────────────────────────────────────

def block_is_checkable(code: str, preceding: str = '') -> tuple[bool, str]:
    """Should this fence be held to the runtime's standard?

    Returns (checkable, reason-when-not). Blocks framed as counter-examples
    and blocks that are not ARO at all are skipped rather than counted as
    failures — a corpus that teaches what is wrong needs wrong code in it.
    """
    stripped = (code or '').strip()
    if not stripped:
        return False, 'empty'
    if any(marker in stripped for marker in NON_CODE_MARKERS):
        return False, 'not-code'
    tail = (preceding or '')[-240:].lower()
    if any(marker in tail for marker in NEGATIVE_MARKERS):
        return False, 'negative-example'
    if '❌' in stripped:
        return False, 'negative-example'
    if '//' in stripped and '(*' not in stripped:
        return False, 'not-code'
    body = _COMMENT_RE.sub('', stripped)
    if not re.search(r'<[A-Za-z]', body):
        return False, 'not-code'
    return True, ''


def blocks_with_context(text: str):
    """(code, preceding-prose) for every ```aro fence."""
    for m in aro_oracle.ARO_FENCE_RE.finditer(text or ''):
        yield m.group(1), text[max(0, m.start() - 240):m.start()]


# ── the static gates ─────────────────────────────────────────────────────────

def hallucinated_verbs(code: str, verbs: set) -> list[str]:
    body = _COMMENT_RE.sub('', code or '')
    found = []
    for m in _STATEMENT_VERB_RE.finditer(body):
        verb = m.group(1)
        if verb.lower() not in verbs and verb not in found:
            found.append(verb)
    return found


def preposition_violations(code: str, vp: dict) -> list[str]:
    """Catalog-based preposition check — the fallback for `--no-binary`.

    The binary says this better and says it itself (see
    `preposition_warnings`): `aro check` emits "Action 'Render' does not
    accept the preposition 'from'" as a warning. This regex cannot tell a
    preposition from the `as` of a result type — `Compute the <n> as Float
    from <s>.` is valid and it flagged seventeen of them — so it only runs
    when there is no binary to ask.
    """
    body = _COMMENT_RE.sub('', code or '')
    out = []
    for line in body.splitlines():
        m = _VP_STMT_RE.match(line)
        if not m:
            continue
        verb, word = m.group(1).lower(), m.group(2).lower()
        if word not in ARO_PREPOSITIONS or word in ALWAYS_ALLOWED_PREPS:
            continue
        allowed = vp.get(verb)
        if not allowed or word in allowed:
            continue
        out.append(f'{m.group(1)} … {word} (takes {", ".join(sorted(allowed))})')
    return out


_PREP_WARNING_RE = re.compile(
    r"Action '(\w+)' does not accept the preposition '(\w+)'")


def preposition_warnings(check_output: str) -> list[str]:
    """Preposition violations as the binary reports them.

    `aro check` accepts a statement whose preposition the action does not
    take — it is a warning, not an error, so the exit code stays 0 and a
    corpus graded on exit codes alone never sees it. The corpus had ninety of
    them.
    """
    return [f'{verb} … {prep}'
            for verb, prep in _PREP_WARNING_RE.findall(check_output or '')]


def unknown_qualifiers(code: str, qualifier_known) -> list[str]:
    body = _COMMENT_RE.sub('', code or '')
    out = []
    for m in _QUALIFIER_RE.finditer(body):
        name = m.group(1).strip()
        if name and not qualifier_known(name) and name not in out:
            out.append(name)
    return out


# ── error classification ─────────────────────────────────────────────────────

# A bare statement lifted out of a feature set has free variables by
# construction: `Publish the <result> as <alias>.` is exactly the right way to
# teach Publish, and `aro check` is exactly right to say `result` is undefined
# — in a file with nothing else in it. Holding a fragment to that standard
# marks correct teaching material as broken, so an unresolved reference in a
# fragment is reported under its own name and does not fail the pair. Inside a
# feature set, where the program is supposed to be complete, it does.
_FREE_VARIABLE_RE = re.compile(
    r'undefined variable|used before definition|unknown variable|'
    r'not defined in this scope', re.IGNORECASE)


def error_is_only_free_variables(error: str) -> bool:
    lines = [ln.strip() for ln in (error or '').splitlines()
             if 'error:' in ln]
    return bool(lines) and all(_FREE_VARIABLE_RE.search(ln) for ln in lines)


# ── the binary ───────────────────────────────────────────────────────────────

class CheckCache:
    """`aro check` verdicts keyed by block, because a corpus repeats itself."""

    def __init__(self, binary, timeout=20):
        self.binary = binary
        self.timeout = timeout
        self._cache: dict[str, tuple] = {}
        self.calls = 0

    def check(self, code: str):
        key = hashlib.sha1(code.encode('utf-8', 'replace')).hexdigest()
        hit = self._cache.get(key)
        if hit is not None:
            return hit
        self.calls += 1
        verdict = aro_oracle.check_block(code, timeout=self.timeout,
                                         binary=self.binary)
        self._cache[key] = verdict
        return verdict


# ── validation ───────────────────────────────────────────────────────────────

def validate_pair(pair: dict, verbs, vp, qualifier_known, cache,
                  both_sides=False, strict_fragments=False) -> dict:
    """The verdict for one pair: a dict fit to be stored as `validation`."""
    texts = [answer_text(pair)]
    if both_sides:
        texts.append(prompt_text(pair))
    checked = skipped = passed = 0
    free_vars: list[str] = []
    errors: list[str] = []
    bad_verbs: list[str] = []
    bad_preps: list[str] = []
    bad_quals: list[str] = []
    for text in texts:
        for code, preceding in blocks_with_context(text):
            ok_to_check, _reason = block_is_checkable(code, preceding)
            if not ok_to_check:
                skipped += 1
                continue
            checked += 1
            bad_verbs += [v for v in hallucinated_verbs(code, verbs)
                          if v not in bad_verbs]
            bad_quals += [q for q in unknown_qualifiers(code, qualifier_known)
                          if q not in bad_quals]
            if cache is None:
                bad_preps += [p for p in preposition_violations(code, vp)
                              if p not in bad_preps]
                passed += 1
                continue
            ok, error = cache.check(code)
            bad_preps += [p for p in preposition_warnings(error)
                          if p not in bad_preps]
            is_fragment = not aro_oracle.FEATURE_SET_RE.search(code)
            if ok:
                passed += 1
            elif ok is None:
                skipped += 1
                checked -= 1
            elif (not strict_fragments and is_fragment
                  and error_is_only_free_variables(error)):
                passed += 1
                free_vars.append(error)
            else:
                errors.append(error)
    verdict = {
        'aro_version': aro_oracle.aro_version(),
        'checked_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'blocks_checked': checked,
        'blocks_skipped': skipped,
        'check_passed': passed,
        'valid': (not errors and not bad_verbs and not bad_preps
                  and not bad_quals),
    }
    if free_vars:
        verdict['free_variable_fragments'] = len(free_vars)
    if errors:
        verdict['check_errors'] = [e[:600] for e in errors[:3]]
    if bad_verbs:
        verdict['unknown_verbs'] = bad_verbs
    if bad_preps:
        verdict['bad_prepositions'] = bad_preps
    if bad_quals:
        verdict['unknown_qualifiers'] = bad_quals
    return verdict


def failure_reasons(verdict: dict) -> list[str]:
    reasons = []
    if verdict.get('check_errors'):
        reasons.append('aro_check')
    if verdict.get('unknown_verbs'):
        reasons.append('unknown_verb')
    if verdict.get('bad_prepositions'):
        reasons.append('bad_preposition')
    if verdict.get('unknown_qualifiers'):
        reasons.append('unknown_qualifier')
    return reasons


def read_corpus(path: Path):
    """(records, metadata-line-or-None). Malformed lines are reported, not
    swallowed: a corpus that half-parses is a corpus nobody validated."""
    records, metadata, malformed = [], None, 0
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            if isinstance(record, dict) and is_metadata(record):
                metadata = record
                continue
            records.append(record)
    return records, metadata, malformed


# ── reporting ────────────────────────────────────────────────────────────────

def source_table(rows, verdicts, top=25):
    by_source = collections.defaultdict(lambda: [0, 0])
    for row, verdict in zip(rows, verdicts):
        bucket = by_source[pair_source(row)]
        bucket[0] += 1
        if not verdict['valid']:
            bucket[1] += 1
    ordered = sorted(by_source.items(), key=lambda kv: (-kv[1][1], kv[0]))
    lines = [f'{"source":<44} {"pairs":>7} {"failing":>8} {"pass %":>7}']
    for source, (total, failing) in ordered[:top]:
        rate = 100.0 * (total - failing) / total if total else 0.0
        lines.append(f'{source[:44]:<44} {total:>7} {failing:>8} {rate:>6.1f}%')
    if len(ordered) > top:
        lines.append(f'… {len(ordered) - top} more sources')
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Re-check a training corpus against the current `aro`.')
    parser.add_argument('corpus', nargs='*', type=Path,
                        default=[DEFAULT_CORPUS],
                        help='JSONL corpus files (default: knowledge_pairs.jsonl)')
    parser.add_argument('--jobs', type=int, default=8,
                        help='parallel `aro check` processes (default: 8)')
    parser.add_argument('--limit', type=int, default=0,
                        help='validate only the first N pairs (a smoke run)')
    parser.add_argument('--both-sides', action='store_true',
                        help='also check ```aro blocks in the prompt')
    parser.add_argument('--no-binary', action='store_true',
                        help='static gates only; do not run `aro check`')
    parser.add_argument('--strict-fragments', action='store_true',
                        help='fail bare statements whose only error is a free '
                             'variable (default: report them, do not fail)')
    parser.add_argument('--annotate', type=Path,
                        help='write the corpus back with a `validation` field')
    parser.add_argument('--drop-failures', type=Path,
                        help='write only the pairs that pass')
    parser.add_argument('--report', type=Path, help='write a JSON report')
    parser.add_argument('--fail-under', type=float, default=None,
                        help='exit 1 when the pass rate is below this percent')
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args(argv)

    binary = None if args.no_binary else aro_oracle.aro_bin()
    if not args.no_binary and not binary:
        print('no `aro` binary found — set ARO_BIN, build one, or pass '
              '--no-binary to run the static gates alone.', file=sys.stderr)
        return 2
    verbs, vp, qualifier_known = load_catalogs()
    cache = CheckCache(binary) if binary else None

    overall = {'files': [], 'aro_version': aro_oracle.aro_version()}
    worst_rate = 100.0
    for path in args.corpus:
        if not path.exists():
            print(f'{path}: not found', file=sys.stderr)
            return 2
        rows, metadata, malformed = read_corpus(path)
        if args.limit:
            rows = rows[:args.limit]
        started = time.time()
        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            verdicts = list(pool.map(
                lambda row: validate_pair(row, verbs, vp, qualifier_known,
                                          cache, args.both_sides,
                                          args.strict_fragments),
                rows))
        elapsed = time.time() - started

        failing = [i for i, v in enumerate(verdicts) if not v['valid']]
        with_code = sum(1 for v in verdicts if v['blocks_checked'])
        rate = 100.0 * (len(rows) - len(failing)) / len(rows) if rows else 100.0
        worst_rate = min(worst_rate, rate)
        reasons = collections.Counter()
        for i in failing:
            reasons.update(failure_reasons(verdicts[i]) or ['unknown'])

        if not args.quiet:
            print(f'\n── {path}')
            print(f'   aro          : {aro_oracle.aro_version()} ({binary or "static gates only"})')
            if metadata:
                stamped = metadata.get('_metadata', {}).get('aro_lang_commit')
                print(f'   stamped at   : {stamped}')
            print(f'   pairs        : {len(rows)} '
                  f'({with_code} carry ```aro blocks, {malformed} malformed lines)')
            print(f'   failing      : {len(failing)}  → pass rate {rate:.1f}%')
            print(f'   reasons      : {dict(reasons)}')
            if cache:
                print(f'   aro check    : {cache.calls} unique blocks in {elapsed:.0f}s')
            print()
            print(source_table(rows, verdicts))

        overall['files'].append({
            'path': str(path),
            'pairs': len(rows),
            'failing': len(failing),
            'pass_rate': round(rate, 2),
            'reasons': dict(reasons),
            'malformed_lines': malformed,
            'examples': [
                {'source': pair_source(rows[i]),
                 'prompt': prompt_text(rows[i])[:120],
                 'verdict': verdicts[i]}
                for i in failing[:20]
            ],
        })

        if args.annotate:
            with open(args.annotate, 'w') as handle:
                if metadata:
                    handle.write(json.dumps(metadata) + '\n')
                for row, verdict in zip(rows, verdicts):
                    row = dict(row)
                    row['validation'] = verdict
                    handle.write(json.dumps(row) + '\n')
            print(f'   annotated    -> {args.annotate}')
        if args.drop_failures:
            kept = 0
            with open(args.drop_failures, 'w') as handle:
                if metadata:
                    handle.write(json.dumps(metadata) + '\n')
                for row, verdict in zip(rows, verdicts):
                    if not verdict['valid']:
                        continue
                    row = dict(row)
                    row['validation'] = verdict
                    handle.write(json.dumps(row) + '\n')
                    kept += 1
            print(f'   kept {kept}/{len(rows)} -> {args.drop_failures}')

    if args.report:
        args.report.write_text(json.dumps(overall, indent=1) + '\n')
        print(f'report -> {args.report}')

    if args.fail_under is not None and worst_rate < args.fail_under:
        print(f'\npass rate {worst_rate:.1f}% is below the required '
              f'{args.fail_under:.1f}%', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
