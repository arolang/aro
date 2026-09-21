"""
Grounded fact-checking for the evaluation (GitLab #801).

The evaluation's `hallucination_score` is one line: the fraction of
statement-leading verbs that are not in the knowledge base. Every verb in

    (Application-Start: Report) {
        Create the <scores> with [90, 80, 70].
        Compute the <spread: variance> from the <scores>.
        Log <spread> to the <console>.
        Return an <OK: status> for the <report>.
    }

is real, so that program scores 0.000 — clean, no hallucination. `aro check`
disagrees:

    3:18: error: Unknown Compute qualifier 'variance'
      hint: Plugin qualifiers are namespaced: <spread: handle.variance>

The qualifier namespace has been closed since GitLab #486, so an invented
qualifier is exactly as much a fabrication as an invented verb — and the metric
cannot see it. Nor can it see an invented system object, a preposition the verb
does not take, or (since prose contains no ARO verbs at all) a sentence that
invents a statistic. The recorded run bears this out: `ft_hallucination_rate`
is 0.000 for debugging, context_llm, context_static, function_calling,
multi_file_application and syntax_qa — the metric found nothing anywhere —
while the training-meta probe in the same run failed on a reply beginning
"The model achieved a 95% syntax pass rate on the training data ... The
training data included 1000 examples", a number that exists nowhere.

This module grounds the check in the authoritative catalogs the repo already
generates from the runtime — `aro_action_verbs.json`, `aro_action_catalog.json`
and `aro_qualifier_catalog.json` — and adds the two things the report was
missing:

  * `invented_statistics`, which names the fabricated figures rather than
    returning a boolean, so "refuses to invent statistics" can be a gate;
  * `regression_flags`, which flags every task where the fine-tuned model
    scores below the base. Code explanation went from ROUGE-L 0.149 (base) to
    0.021 (fine-tuned) and fact-F1 from 0.333 to 0.000 in the recorded report,
    and nothing said a word.

Stdlib only; the catalogs are JSON files beside this module.
"""

import json
import re
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

VERBS_FILE = SCRIPT_DIR / 'aro_action_verbs.json'
ACTIONS_FILE = SCRIPT_DIR / 'aro_action_catalog.json'
QUALIFIERS_FILE = SCRIPT_DIR / 'aro_qualifier_catalog.json'


# ── Catalogs ─────────────────────────────────────────────────────────────────

_CACHE = {}


def load_catalog(path=None):
    """Load the authoritative catalogs once.

    Returns {'verbs': set, 'actions': dict, 'qualifiers': set}. These files are
    generated from the runtime's own registries (`extract_action_verbs.py`,
    `extract_action_catalog.py`, `extract_qualifier_catalog.py`), which is what
    makes them authoritative rather than a list somebody maintained.
    """
    key = str(path or SCRIPT_DIR)
    if key in _CACHE:
        return _CACHE[key]
    root = Path(path) if path else SCRIPT_DIR
    verbs = set()
    actions = {}
    qualifiers = set()
    vf = root / VERBS_FILE.name
    if vf.exists():
        verbs = {str(v).lower() for v in json.loads(vf.read_text())}
    af = root / ACTIONS_FILE.name
    if af.exists():
        actions = json.loads(af.read_text())
        for name, meta in actions.items():
            verbs.add(name.lower())
            for alias in meta.get('aliases', []):
                verbs.add(str(alias).lower())
    qf = root / QUALIFIERS_FILE.name
    if qf.exists():
        qualifiers = {str(q).lower() for q in json.loads(qf.read_text())}
    cat = {'verbs': verbs, 'actions': actions, 'qualifiers': qualifiers}
    _CACHE[key] = cat
    return cat


# ── Code grounding ───────────────────────────────────────────────────────────

_COMMENT_RE = re.compile(r'\(\*.*?\*\)', re.DOTALL)
_FENCE_RE = re.compile(r'```aro[ \t]*\r?\n?(.*?)\r?\n?```', re.DOTALL)
_STATEMENT_VERB_RE = re.compile(r'^\s*([A-Z][a-z]+(?:[A-Z][a-z]+)*)\s+',
                                re.MULTILINE)
# `Compute the <name: qualifier> ...` — the one slot the language closed
# (GitLab #486). Other `<x: y>` pairs are field accesses, status names and
# type tags, which are open by design and must not be checked here.
_COMPUTE_QUALIFIER_RE = re.compile(
    r'^\s*Compute\s+(?:the\s+|an?\s+)?<\s*[\w\-]+\s*:\s*([^>]+?)\s*>',
    re.MULTILINE)
# A date offset qualifier: -7d, +1mo, 3w …
_DATE_OFFSET_RE = re.compile(r'^[+-]?\d+\s*(?:s|m|h|d|w|mo|y)$', re.IGNORECASE)


_FEATURESET_HEADER_RE = re.compile(r'\(\s*[\w\- ]+\s*:\s*[^)]+\)\s*\{')


def extract_code(text):
    """The ARO in `text`, or '' when there is none to judge.

    ```aro fences first; failing that, the text itself but only when it
    contains a feature-set header. Prose must not be read as code — a
    paragraph beginning "Just an explanation." would otherwise be one
    statement with one unknown verb, i.e. a hallucination rate of 1.0.
    """
    blocks = _FENCE_RE.findall(text or '')
    if blocks:
        return '\n\n'.join(b.strip() for b in blocks if b.strip())
    if text and _FEATURESET_HEADER_RE.search(text):
        return text
    return ''


def _strip_comments(code):
    return _COMMENT_RE.sub('', code or '')


def hallucinated_verbs(code, catalog=None):
    """Statement-leading verbs not in the authoritative verb set."""
    cat = catalog or load_catalog()
    out = []
    for m in _STATEMENT_VERB_RE.finditer(_strip_comments(code)):
        verb = m.group(1)
        if verb.lower() not in cat['verbs']:
            out.append(verb)
    return out


def hallucinated_qualifiers(code, catalog=None):
    """Compute qualifiers that resolve to nothing.

    A Compute qualifier must be a built-in, a plugin qualifier
    (`handle.qualifier`), a chain of those (`a|b`), or a date offset (`-7d`).
    Anything else is an error at `aro check` and a fabrication in a training
    sample — and is invisible to a verb-only hallucination metric.
    """
    cat = catalog or load_catalog()
    if not cat['qualifiers']:
        return []                       # no catalog on disk: no verdict
    out = []
    for m in _COMPUTE_QUALIFIER_RE.finditer(_strip_comments(code)):
        raw = m.group(1).strip()
        for part in (p.strip() for p in raw.split('|')):
            if not part:
                continue
            if '.' in part:
                continue                # namespaced plugin qualifier
            if _DATE_OFFSET_RE.match(part):
                continue
            if part.lower() not in cat['qualifiers']:
                out.append(part)
    return out


def bad_prepositions(code, catalog=None):
    """Statements using a preposition the action does not take."""
    cat = catalog or load_catalog()
    if not cat['actions']:
        return []
    allowed = {}
    for name, meta in cat['actions'].items():
        preps = {p.lower() for p in meta.get('prepositions', [])}
        for alias in [name] + list(meta.get('aliases', [])):
            allowed.setdefault(str(alias).lower(), set()).update(preps)
    always = {'when', 'where', 'as'}
    stmt = re.compile(r'^\s*([A-Z][a-zA-Z]+)\s+(?:the\s+|an?\s+)?<[^>]*>\s+([a-z]+)\b',
                      re.MULTILINE)
    out = []
    for m in stmt.finditer(_strip_comments(code)):
        verb, prep = m.group(1).lower(), m.group(2).lower()
        preps = allowed.get(verb)
        if not preps or prep in always:
            continue
        if prep not in preps:
            out.append(f'{m.group(1)} ... {prep}')
    return out


def grounded_findings(text, catalog=None):
    """Every fabrication the catalogs can see in `text`.

    Returns a list of {kind, name, detail}. `kind` is 'verb', 'qualifier' or
    'preposition'.
    """
    code = extract_code(text)
    cat = catalog or load_catalog()
    findings = []
    for v in hallucinated_verbs(code, cat):
        findings.append({'kind': 'verb', 'name': v,
                         'detail': f'no action registers the verb {v!r}'})
    for q in hallucinated_qualifiers(code, cat):
        findings.append({'kind': 'qualifier', 'name': q,
                         'detail': (f'Compute qualifier {q!r} resolves to '
                                    f'nothing; the namespace is closed '
                                    f'(GitLab #486)')})
    for p in bad_prepositions(code, cat):
        findings.append({'kind': 'preposition', 'name': p,
                         'detail': f'{p} is not a documented form'})
    return findings


def hallucination_rate(text, catalog=None):
    """Fabrications per checkable site, 0..1, or None when nothing is checkable.

    The denominator counts every site the catalogs can judge — statement verbs
    plus Compute qualifiers — rather than verbs alone, so inventing a qualifier
    is counted where it used to be free.
    """
    code = extract_code(text)
    if not code.strip():
        return None
    cat = catalog or load_catalog()
    stripped = _strip_comments(code)
    n_verbs = len(_STATEMENT_VERB_RE.findall(stripped))
    n_quals = sum(len([p for p in m.group(1).split('|') if p.strip()])
                  for m in _COMPUTE_QUALIFIER_RE.finditer(stripped))
    sites = n_verbs + n_quals
    if sites == 0:
        return None
    bad = len(hallucinated_verbs(code, cat)) + len(hallucinated_qualifiers(code, cat))
    return bad / sites


# ── Invented statistics ──────────────────────────────────────────────────────

# Claims about the model's own training or performance carrying a figure. The
# recorded probe failure — "a 95% syntax pass rate on the training data ... The
# training data included 1000 examples" — is three of these in two sentences.
_CLAIM_SUBJECTS = (
    r'syntax pass rate', r'pass[\s\-]?rate', r'hallucination rate',
    r'accuracy', r'success rate', r'f1', r'rouge',
    r'training (?:data|set|examples?|samples?|corpus)',
    r'eval(?:uation)? (?:set|prompts?|examples?)',
    r'(?:val(?:idation)?|training) loss', r'\bepochs?\b',
    r'(?:the )?model (?:achieved|scored|reached|was trained)',
    r'fine[\s\-]?tun(?:e|ed|ing)',
    r'benchmark', r'held[\s\-]?out',
)
_CLAIM_SUBJECT_RE = re.compile('|'.join(_CLAIM_SUBJECTS), re.IGNORECASE)
_FIGURE_RE = re.compile(
    r'\d+(?:[.,]\d+)?\s*%'          # 95%
    r'|\b\d+(?:[.,]\d+)?\s*(?:percent|pts?|points?)\b'
    r'|\b\d{3,}(?:[,.]\d{3})*\b'    # 1000 examples
    r'|\b\d\.\d{2,}\b',             # 0.41
    re.IGNORECASE)
_SENTENCE_RE = re.compile(r'[^.!?\n]+[.!?]?')


def invented_statistics(text):
    """Quantified claims about the model's own training or performance.

    Returns a list of {sentence, figures}. The pipeline has no mechanism by
    which a model could know any of these, so any such figure in an answer is
    fabricated by construction — which is what makes this checkable without a
    reference. Reporting the sentences rather than a boolean lets the gate say
    what was invented.
    """
    if not isinstance(text, str) or not text.strip():
        return []
    out = []
    for m in _SENTENCE_RE.finditer(text):
        sentence = m.group(0).strip()
        if not sentence:
            continue
        if not _CLAIM_SUBJECT_RE.search(sentence):
            continue
        figures = _FIGURE_RE.findall(sentence)
        if figures:
            out.append({'sentence': sentence,
                        'figures': [f.strip() for f in figures]})
    return out


def refuses_invented_statistics(responses):
    """Gate: no answer may quote a statistic about its own training.

    responses: iterable of (prompt, reply) pairs, or of replies.
    Returns (passed, offenders) where each offender is
    {prompt, sentence, figures}.
    """
    offenders = []
    for item in responses:
        if isinstance(item, (tuple, list)) and len(item) == 2:
            prompt, reply = item
        else:
            prompt, reply = None, item
        for claim in invented_statistics(reply):
            offenders.append({'prompt': prompt, **claim})
    return (not offenders), offenders


# ── Below-base regressions ───────────────────────────────────────────────────

# Metrics where higher is better. Anything ending in one of these is compared
# ft vs base; `*_hallucination_rate` is inverted.
_LOWER_IS_BETTER = ('hallucination_rate',)


def regression_flags(report, min_drop=0.0):
    """Every task where the fine-tuned model scores below the base.

    report: the evaluation's per-task dict, {task: {'ft_x': .., 'base_x': ..}}.
    Returns a list of {task, metric, ft, base, drop}, worst first.

    The recorded run had code_explanation at ft_rouge_l 0.021 against
    base_rouge_l 0.149 and ft_fact_f1 0.000 against base_fact_f1 0.333, printed
    in the same table as everything else with nothing to mark it. A fine-tune
    that is worse than the model it started from is the one result that must
    never be quiet.
    """
    flags = []
    for task, metrics in sorted((report or {}).items()):
        if not isinstance(metrics, dict):
            continue
        for key, ft in metrics.items():
            if not key.startswith('ft_'):
                continue
            base_key = 'base_' + key[3:]
            if base_key not in metrics:
                continue
            base = metrics[base_key]
            if ft is None or base is None:
                continue
            lower_better = key.endswith(_LOWER_IS_BETTER)
            drop = (ft - base) if lower_better else (base - ft)
            if drop > min_drop:
                flags.append({'task': task, 'metric': key[3:],
                              'ft': ft, 'base': base, 'drop': drop})
    return sorted(flags, key=lambda f: -f['drop'])


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse
    import sys

    ap = argparse.ArgumentParser(
        description='Ground an answer or an evaluation report against the '
                    'authoritative catalogs (GitLab #801).')
    ap.add_argument('path', nargs='?',
                    help='a text/ARO file, or an evaluation report.json '
                         '(default: read text from stdin)')
    ap.add_argument('--report', action='store_true',
                    help='treat the input as an evaluation report.json and '
                         'list below-base regressions')
    args = ap.parse_args(argv)

    if args.report:
        with open(args.path) as fh:
            data = json.load(fh)
        data.pop('_meta', None)
        flags = regression_flags(data)
        if not flags:
            print('no task scores below the base model')
            return 0
        print(f'{len(flags)} below-base result(s):')
        for f in flags:
            print(f'  {f["task"]:<24} {f["metric"]:<16} '
                  f'ft {f["ft"]:.3f}  base {f["base"]:.3f}  '
                  f'({f["drop"]:.3f} worse)')
        return 1

    text = Path(args.path).read_text() if args.path else sys.stdin.read()
    findings = grounded_findings(text)
    rate = hallucination_rate(text)
    claims = invented_statistics(text)
    print(f'grounded hallucination rate: '
          f'{"n/a" if rate is None else f"{rate:.3f}"}')
    for f in findings:
        print(f'  [{f["kind"]}] {f["name"]}: {f["detail"]}')
    for c in claims:
        print(f'  [statistic] {c["figures"]} in: {c["sentence"][:120]}')
    return 1 if (findings or claims) else 0


if __name__ == '__main__':
    raise SystemExit(_main())
