"""
Evaluation metrics for NB19 (and the NB20 loop).

  - ROUGE-L (LCS-based, no external deps)                       (issue #419)
  - KB concept-overlap metric (action verbs / qualifiers)       (issue #419)
  - Stratified per-task-type evaluation sampling                (issue #417)
  - Semantic-correctness validators: expected-operation check,
    keyword match, and actual execution via `aro run`           (issue #418)
"""

import re
import random
import subprocess
import tempfile
from pathlib import Path

# ── ROUGE-L ──────────────────────────────────────────────────────────────────

_TOKEN_RE = re.compile(r'\w+')

# Cap token counts so the O(n*m) LCS stays cheap on long generations.
_MAX_ROUGE_TOKENS = 400


def _tokens(text):
    return _TOKEN_RE.findall((text or '').lower())[:_MAX_ROUGE_TOKENS]


def lcs_length(a, b):
    """Length of the longest common subsequence (O(len(a)*len(b)), two rows)."""
    if not a or not b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    prev = [0] * (len(b) + 1)
    for x in a:
        curr = [0]
        for j, y in enumerate(b, 1):
            if x == y:
                curr.append(prev[j - 1] + 1)
            else:
                curr.append(max(prev[j], curr[j - 1]))
        prev = curr
    return prev[-1]


def rouge_l(reference, candidate):
    """ROUGE-L F1 between two texts (word-level LCS). Returns a float 0..1."""
    ref = _tokens(reference)
    cand = _tokens(candidate)
    if not ref or not cand:
        return 0.0
    lcs = lcs_length(ref, cand)
    if lcs == 0:
        return 0.0
    precision = lcs / len(cand)
    recall = lcs / len(ref)
    return 2 * precision * recall / (precision + recall)


# ── KB concept overlap ───────────────────────────────────────────────────────

def kb_concepts(kb):
    """Set of ARO concept terms (lowercased) from the knowledge base:
    action verbs, prepositions used as vocabulary, and qualifier names
    when present."""
    concepts = set()
    for a in kb.get('actions', []):
        for v in a.get('verbs', []):
            concepts.add(v.lower())
    for q in kb.get('qualifiers', []):
        name = q.get('name') if isinstance(q, dict) else q
        if name:
            concepts.add(str(name).lower())
    return concepts


_WORD_RE = re.compile(r'[A-Za-z][A-Za-z\-]*')


def concepts_in_text(text, concepts):
    """Which of `concepts` are mentioned (as whole words) in `text`."""
    words = {w.lower() for w in _WORD_RE.findall(text or '')}
    return words & concepts


def concept_overlap(reference, candidate, concepts):
    """F1 overlap between the ARO concepts mentioned in the reference answer
    and the generated answer. Returns None when the reference mentions no
    concepts (metric undefined)."""
    ref_c = concepts_in_text(reference, concepts)
    if not ref_c:
        return None
    cand_c = concepts_in_text(candidate, concepts)
    if not cand_c:
        return 0.0
    inter = len(ref_c & cand_c)
    precision = inter / len(cand_c)
    recall = inter / len(ref_c)
    if precision + recall == 0:
        return 0.0
    return 2 * precision * recall / (precision + recall)


# ── Stratified sampling (issue #417) ─────────────────────────────────────────

def stratified_sample(samples, budget, key_fn=None, seed=0):
    """Sample up to `budget` items, allocating the budget as evenly as
    possible across task types (minority categories get their full data
    before any majority category exceeds the even share).

    Returns (sampled_list, composition_dict).
    """
    if key_fn is None:
        key_fn = lambda s: s.get('task_type', 'unknown')
    rng = random.Random(seed)

    by_key = {}
    for s in samples:
        by_key.setdefault(key_fn(s), []).append(s)

    if budget is None or budget >= len(samples):
        composition = {k: len(v) for k, v in sorted(by_key.items())}
        out = list(samples)
        rng.shuffle(out)
        return out, composition

    # Water-filling allocation: repeatedly grant one slot per type (smallest
    # remaining first) until the budget is exhausted.
    quotas = {k: 0 for k in by_key}
    remaining = budget
    while remaining > 0:
        open_keys = [k for k in sorted(by_key, key=lambda k: (len(by_key[k]), k))
                     if quotas[k] < len(by_key[k])]
        if not open_keys:
            break
        for k in open_keys:
            if remaining == 0:
                break
            quotas[k] += 1
            remaining -= 1

    sampled = []
    for k, group in sorted(by_key.items()):
        sampled.extend(rng.sample(group, quotas[k]))
    rng.shuffle(sampled)
    composition = {k: quotas[k] for k in sorted(quotas) if quotas[k] > 0}
    return sampled, composition


# ── Semantic correctness (issue #418) ────────────────────────────────────────
# Map instruction keywords to the ARO action verbs a correct solution should
# contain. Only verbs present in the knowledge base are kept, so the check
# never expects a verb the language doesn't have.

KEYWORD_VERB_MAP = {
    # keyword (regex, matched on the instruction) → candidate ARO verbs.
    # The expectation is satisfied when ANY of the verbs appears in the code.
    r'\blogs?\b|\blogging\b|\bprint\b': ['log'],
    r'\bread(s|ing)?\b': ['read', 'retrieve', 'extract'],
    r'\bwrit(e|es|ing)\b': ['write', 'store'],
    r'\bstor(e|es|ing)\b|\bsav(e|es|ing)\b': ['store', 'write'],
    r'\bretriev(e|es|ing)\b': ['retrieve'],
    r'\bextract(s|ing)?\b': ['extract'],
    r'\bfetch(es|ing)?\b|\bexternal (url|api)\b': ['fetch', 'request', 'pull'],
    r'\bcomput(e|es|ing)\b|\bcalculat(e|es|ing)\b': ['compute'],
    r'\bvalidat(e|es|ing)\b': ['validate'],
    r'\bfilter(s|ing)?\b': ['filter'],
    r'\btransform(s|ing)?\b|\bconvert(s|ing)?\b': ['transform', 'compute'],
    r'\bemit(s|ting)?\b|\bevent\b': ['emit'],
    r'\bsend(s|ing)?\b|\bemail\b': ['send'],
    r'\bcreat(e|es|ing)\b': ['create', 'store'],
    r'\bdelet(e|es|ing)\b|\bremov(e|es|ing)\b': ['delete', 'remove'],
    r'\bupdat(e|es|ing)\b': ['update', 'store'],
    r'\breturn(s|ing)?\b': ['return'],
    r'\bwatch(es|ing)?\b|\bmonitor(s|ing)?\b': ['start'],
    r'\bhttp server\b|\bhttp api\b|\bkeepalive\b': ['start'],
    r'\bsplit(s|ting)?\b': ['split'],
    r'\brender(s|ing)?\b|\btemplate\b': ['render'],
    r'\bmerg(e|es|ing)\b|\bunion\b': ['merge', 'compute'],
    r'\bgroup(s|ing)?\b': ['group'],
    r'\bcopy(ing)?\b|\bcopies\b': ['copy'],
    r'\bmov(e|es|ing)\b': ['move'],
    r'\bcompar(e|es|ing)\b': ['compare'],
}

_VERB_LINE_RE = re.compile(r'^\s*([A-Z][A-Za-z]+)\b', re.MULTILINE)


def code_verbs(code):
    """Lowercased set of statement-leading verbs found in ARO code."""
    return {v.lower() for v in _VERB_LINE_RE.findall(code or '')}


def expected_operations(instruction, kb_verbs):
    """Derive expected operations from an instruction.

    Returns a list of verb-alternative sets: each entry is a set of
    acceptable verbs for one expected operation (restricted to verbs the KB
    actually knows). Empty list → no expectations derivable.
    """
    instr = (instruction or '').lower()
    expectations = []
    for pattern, verbs in KEYWORD_VERB_MAP.items():
        if re.search(pattern, instr):
            valid = {v for v in verbs if v in kb_verbs}
            if valid and valid not in expectations:
                expectations.append(valid)
    return expectations


def semantic_expectation_score(instruction, code, kb_verbs):
    """Fraction of instruction-implied operations that the code performs.

    Returns (score or None, n_expected, n_found). None when no expectations
    can be derived from the instruction (score undefined, not zero).
    """
    expectations = expected_operations(instruction, kb_verbs)
    if not expectations:
        return None, 0, 0
    found_verbs = code_verbs(code)
    hits = sum(1 for alt in expectations if alt & found_verbs)
    return hits / len(expectations), len(expectations), hits


_NAME_STOPWORDS = {
    'the', 'a', 'an', 'and', 'or', 'that', 'with', 'for', 'from', 'to',
    'write', 'aro', 'feature', 'set', 'complete', 'api', 'create',
}
_FEATURESET_NAME_RE = re.compile(r'\(\s*([\w\- ]+?)\s*:\s*([^)]+)\)\s*\{')


def featureset_keyword_match(instruction, code):
    """Do the feature-set names/activities share vocabulary with the
    instruction? Returns True/False, or None when no feature set exists."""
    headers = _FEATURESET_NAME_RE.findall(code or '')
    if not headers:
        return None
    instr_words = {w for w in _TOKEN_RE.findall((instruction or '').lower())
                   if w not in _NAME_STOPWORDS and len(w) > 3}
    if not instr_words:
        return None
    for name, activity in headers:
        header_words = set(_TOKEN_RE.findall(f'{name} {activity}'.lower()))
        if header_words & instr_words:
            return True
    return False


# ── Execution check (issue #418): actually run generated programs ────────────

_UNSAFE_RUN_PATTERNS = (
    'Keepalive', '<http-server>', '<socket', '<file-monitor>',
    '<websocket', 'Start the', 'Request the', 'Fetch the', 'Pull the',
    'Push the', 'Clone the',
)


def is_safely_runnable(code):
    """Conservative gate: only run programs that terminate on their own and
    touch no network/service — i.e. plain Application-Start batch programs."""
    if not code or 'Application-Start' not in code:
        return False
    return not any(p in code for p in _UNSAFE_RUN_PATTERNS)


def run_aro_program(code, openapi_yaml=None, timeout=10):
    """Execute a generated ARO program with `aro run`.

    Returns (ok, output): ok True on exit 0, False on failure/timeout,
    None when the aro binary is missing.
    """
    try:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'main.aro').write_text(code)
            if openapi_yaml:
                (d / 'openapi.yaml').write_text(openapi_yaml)
            r = subprocess.run(['aro', 'run', str(d)],
                               capture_output=True, text=True, timeout=timeout)
            return r.returncode == 0, (r.stdout or r.stderr).strip()[:300]
    except FileNotFoundError:
        return None, 'aro_not_found'
    except subprocess.TimeoutExpired:
        return False, 'timeout'


# ── Shared extraction / check helpers (used by gen_eval.py, NB17 sweep) ──────

_YAML_FENCE_RE = re.compile(r'```yaml\s*\n(.*?)```', re.DOTALL)
_ARO_FENCE_RE = re.compile(r'```aro[ \t]*\r?\n?(.*?)\r?\n?```', re.DOTALL)


def extract_openapi_and_aro(text):
    """Extract (openapi_yaml_or_None, main_aro_or_None) from a reply that may
    contain `## openapi.yaml` + `## main.aro` fenced blocks."""
    yaml_blocks = _YAML_FENCE_RE.findall(text or '')
    aro_blocks = _ARO_FENCE_RE.findall(text or '')
    openapi = next((b.strip() for b in yaml_blocks if 'openapi' in b.lower()), None)
    main_aro = '\n\n'.join(b.strip() for b in aro_blocks if b.strip()) or None
    return openapi, main_aro


def aro_check_dir(main_aro, openapi_yaml=None, timeout=15):
    """Run `aro check` on a temp directory holding main.aro (+ contract).
    Returns True/False, or None when the aro binary is missing."""
    try:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            if openapi_yaml:
                (d / 'openapi.yaml').write_text(openapi_yaml)
            (d / 'main.aro').write_text(main_aro or '')
            r = subprocess.run(['aro', 'check', str(d)],
                               capture_output=True, text=True, timeout=timeout)
            return r.returncode == 0
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return False
