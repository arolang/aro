"""
ARO Training Pipeline — shared configuration.

Import in any notebook setup cell:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent if '__file__' in dir() else Path('.')))
    from config import *

Or, from a notebook where __file__ is not defined:

    import sys, importlib
    sys.path.insert(0, str(Path('.').resolve()))
    import config; importlib.reload(config); from config import *
"""

import json
import os
import shutil
import subprocess
import sys
from collections import Counter as _Counter
import uuid
from datetime import datetime, timezone
from pathlib import Path

# ── Root paths ────────────────────────────────────────────────────────────────

SCRIPT_DIR           = Path(__file__).parent.resolve()
TRAIN_ROOT           = SCRIPT_DIR.parent              # .../Train
ARO_ROOT             = (TRAIN_ROOT / '..').resolve()   # .../ARO-Train
EXAMPLES_DIR         = ARO_ROOT / 'Examples'
BOOK_ROOT            = ARO_ROOT / 'Book'


def _resolve_aro_application_root() -> Path:
    """Resolve the ARO-Application corpus root.

    Priority (issue #385 — portable, no silent data loss):
      1. `ARO_APPLICATION_PATH` environment variable
      2. `../ARO-Application` next to the ARO-Lang checkout
      3. Legacy hardcoded developer path

    When nothing exists, the first candidate is returned unresolved so
    `corpus_preflight()` can report it as missing and fail loudly.
    """
    env = os.environ.get('ARO_APPLICATION_PATH')
    if env:
        return Path(env).expanduser().resolve()
    candidates = [
        ARO_ROOT.parent / 'ARO-Application',
        Path('/Users/kris/Projects/ARO/ARO-Application'),
    ]
    for cand in candidates:
        if cand.exists():
            return cand.resolve()
    return candidates[0].resolve()


ARO_APPLICATION_ROOT = _resolve_aro_application_root()

# ── Data directories ──────────────────────────────────────────────────────────
# All pipeline artifacts live under TRAIN_ROOT.  Individual notebooks write to
# stage-specific subdirectories of DATA_ROOT.

DATA_ROOT    = TRAIN_ROOT / 'data'
DATA_IN      = DATA_ROOT / '02_knowledge'   # primary knowledge base
DATA_DIR     = DATA_IN                       # alias used by some notebooks

KB_FILE      = DATA_IN / 'knowledge.json'
PAIRS_FILE   = DATA_IN / 'knowledge_pairs.jsonl'

ADAPTER_DIR  = DATA_ROOT / 'adapters'
ADAPTER_DIR.mkdir(parents=True, exist_ok=True)

WARM_ADAPTER = ADAPTER_DIR / 'warm_start'

WIKI_DIR     = DATA_ROOT / 'wiki'

# ── Notebook restart behavior ────────────────────────────────────────────────
# When True, each notebook removes its own pairs from knowledge_pairs.jsonl
# on startup, so re-running a notebook replaces its data instead of appending
# duplicates.  Set to False to keep accumulating across runs.
CLEAN_ON_RESTART = True

MODELS_DIR   = TRAIN_ROOT / 'models'
RELEASE_DIR  = TRAIN_ROOT / 'release'

# Timestamped backups of knowledge_pairs.jsonl (issue #384) — written by
# clean_notebook_pairs() before it deletes rows.
BACKUP_DIR        = DATA_ROOT / 'backups'
PAIRS_BACKUP_KEEP = 10

# Per-run provenance metadata (issue #408) — one JSON per session under
# data/runs/, written lazily the first time a pair is saved.
RUNS_DIR = DATA_ROOT / 'runs'

# ── Pipeline identity / provenance ────────────────────────────────────────────
# PIPELINE_VERSION is a manual marker for the *shape* of the pipeline; bump it
# when notebooks change what/how they emit. SESSION_ID identifies one notebook
# (or full-pipeline) execution — the META pipeline can pin a single session
# across all notebooks by exporting ARO_TRAIN_SESSION.

PIPELINE_VERSION = '2026.07'

RUN_TIMESTAMP = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
SESSION_ID    = (os.environ.get('ARO_TRAIN_SESSION')
                 or f"{datetime.now().strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:8]}")

# ── Dataset assembly type caps (used by 16_dataset_assembly) ─────────────────
# Versioned so stats.json records which caps produced a given dataset
# (issue #406). Changelog:
#   v1 (initial): hard caps on every category (code_generation=600,
#       syntax_qa=450, minority categories capped). A 2026-04-22 pipeline
#       review found these caps dropped 84% of the assembled data
#       (7,580 → 1,202 samples).
#   v2 (2026-04-22): majority caps doubled (code_generation=1200,
#       syntax_qa=900); minority categories uncapped (None) so every
#       sample we have is kept.
# Bump TYPE_CAPS_VERSION whenever the caps change.
TYPE_CAPS_VERSION = 'v2-2026-04-22'

TYPE_CAPS = {
    'code_generation':     1200,   # doubled — primary task
    'syntax_qa':           900,    # doubled — knowledge Q&A
    'code_explanation':    None,   # uncapped (minority)
    'fim':                 None,   # uncapped (minority)
    'code_transformation': None,   # uncapped (minority)
    'tool_calling':        None,   # uncapped — critical for aro ask
    'debugging':           None,   # uncapped — always useful
    'correction':          None,   # uncapped — teaches model what actions DON'T exist
    'full_application':    None,   # uncapped — plan → complete multi-file app
}
DEFAULT_TYPE_CAP = None   # uncapped by default for any new task types

FINETUNE_MODELS_DIR = MODELS_DIR / 'finetune'
ITERATIVE_MODELS_DIR = MODELS_DIR / 'iterative'
DISTILL_MODELS_DIR = MODELS_DIR / 'distill'

# ── Distillation ─────────────────────────────────────────────────────────────
# The teacher is the best 30B MoE model produced by the pipeline (NB19/17/16).
# The student is a smaller 8B dense Qwen3 model that learns from the teacher.
#
# Use a non-quantized base. LoRA-on-4bit-base + fuse is fragile in MLX-LM and
# has produced collapsed students (output of only `!`). BF16 is fully reliable;
# fall back to `mlx-community/Qwen3-8B-8bit` (8.7 GB) if training OOMs.
STUDENT_MODEL_ID = 'mlx-community/Qwen3-8B-bf16'

# ── Model ─────────────────────────────────────────────────────────────────────
# TRAIN_ON_BASE controls whether to train from the base Qwen model (True) or
# from the previously-uploaded fine-tuned teacher on HuggingFace (False).
#   True  → always use BASE_MODEL_ID (fresh training / new base model)
#   False → use TEACHER_MODEL_ID if available on HF, else fall back to BASE_MODEL_ID
# After the first complete pipeline run, set to False for iterative improvement.
TRAIN_ON_BASE = True

PREFERRED_MODEL_ID = 'ARO-Lang/aro-coder-4bit'       # distilled 8B student (for inference)
TEACHER_MODEL_ID   = 'ARO-Lang/aro-teacher-30b-4bit'  # fine-tuned 30B teacher (for retraining)
BASE_MODEL_ID      = 'mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit'

# Legacy alias — notebooks that reference FALLBACK_MODEL_ID still work.
FALLBACK_MODEL_ID  = BASE_MODEL_ID


def _hf_model_exists(repo_id: str, timeout: int = 6) -> bool:
    """Return True if repo_id exists on HuggingFace Hub AND contains config.json.
    A repo page existing is not enough — it may be an empty placeholder."""
    try:
        import urllib.request
        # Check for config.json specifically — required by mlx-lm to load the model.
        url = f'https://huggingface.co/{repo_id}/resolve/main/config.json'
        urllib.request.urlopen(urllib.request.Request(url), timeout=timeout)
        return True
    except Exception:
        return False


def resolve_model_id() -> tuple[str, bool]:
    """
    Resolve which model to use for training / generation.
    Returns (model_id, is_finetuned) so callers know whether to skip the warm adapter.

    When TRAIN_ON_BASE is True, always returns the base model — useful for
    initial training or switching to a new base architecture.

    When False, checks for the previously-uploaded teacher model on HuggingFace
    so each training cycle builds on the last one.
    """
    if TRAIN_ON_BASE:
        print(f'TRAIN_ON_BASE=True → using base model: {BASE_MODEL_ID}')
        return BASE_MODEL_ID, False
    if _hf_model_exists(TEACHER_MODEL_ID):
        print(f'Fine-tuned teacher found on HF: {TEACHER_MODEL_ID}')
        return TEACHER_MODEL_ID, True
    print(f'Teacher not found on HuggingFace, using base: {BASE_MODEL_ID}')
    return BASE_MODEL_ID, False


# Resolved once at import time — used by all notebooks via `MODEL_ID`.
MODEL_ID, _MODEL_IS_FINETUNED = resolve_model_id()

# ── Remote URLs ───────────────────────────────────────────────────────────────

GITLAB_WIKI  = 'git@git.ausdertechnik.de:arolang/aro.wiki.git'
GITHUB_WIKI  = 'git@github.com:arolang/aro.wiki.git'

# ── mlx-lm loader ────────────────────────────────────────────────────────────

def ensure_mlx_lm():
    """Import mlx_lm, installing it if missing. Returns (load, generate, make_sampler)."""
    try:
        from mlx_lm import load, generate as mlx_generate
        from mlx_lm.sample_utils import make_sampler
        return load, mlx_generate, make_sampler
    except ModuleNotFoundError:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', 'mlx-lm'], check=True)
        from mlx_lm import load, generate as mlx_generate
        from mlx_lm.sample_utils import make_sampler
        return load, mlx_generate, make_sampler


# ── Knowledge base loader ─────────────────────────────────────────────────────

def load_knowledge():
    """Load and return the knowledge base dict from KB_FILE."""
    with open(KB_FILE) as f:
        return json.load(f)


# ── Corpus preflight (issue #385) ─────────────────────────────────────────────

def corpus_preflight(require_application=None, raise_on_missing=True):
    """Verify that all expected corpus roots exist BEFORE mining starts.

    A missing root (most commonly ARO-Application on a fresh machine) used to
    print a one-line "not found" and continue with an incomplete corpus — the
    resulting model silently never saw real-world application code. This check
    fails loudly with an actionable report instead.

    `require_application` defaults to True unless ARO_APPLICATION_OPTIONAL=1
    is set in the environment. Returns a {label: {path, exists, required}}
    report dict.
    """
    if require_application is None:
        require_application = os.environ.get('ARO_APPLICATION_OPTIONAL', '') != '1'

    checks = [
        ('ARO-Lang repository',       ARO_ROOT,                                      True),
        ('Examples/',                 EXAMPLES_DIR,                                  True),
        ('Book/',                     BOOK_ROOT,                                     True),
        ('Proposals/',                ARO_ROOT / 'Proposals',                        True),
        ('Sources/ARORuntime/Actions', ARO_ROOT / 'Sources' / 'ARORuntime' / 'Actions', True),
        ('ARO-Application',           ARO_APPLICATION_ROOT,                          require_application),
    ]

    print('Corpus preflight check:')
    report = {}
    missing_required = []
    for label, path, required in checks:
        exists = path.exists()
        detail = ''
        if exists and path.is_dir():
            if label in ('Examples/', 'ARO-Application'):
                detail = f'  ({sum(1 for _ in path.rglob("*.aro"))} .aro files)'
            elif label in ('Book/', 'Proposals/'):
                detail = f'  ({sum(1 for _ in path.rglob("*.md"))} .md files)'
        mark = '✓' if exists else ('✗' if required else '–')
        print(f'  {mark}  {label:<30} {path}{detail}')
        report[label] = {'path': str(path), 'exists': exists, 'required': bool(required)}
        if required and not exists:
            missing_required.append((label, path))

    if missing_required:
        details = '\n'.join(f'  - {label}: {path}' for label, path in missing_required)
        message = (
            'Corpus preflight FAILED — missing corpus roots:\n' + details + '\n\n'
            'Fixes:\n'
            '  - Set ARO_APPLICATION_PATH=/path/to/ARO-Application to point at the applications corpus.\n'
            '  - Or clone ARO-Application next to the ARO-Lang checkout (../ARO-Application).\n'
            '  - Or set ARO_APPLICATION_OPTIONAL=1 to knowingly continue with an incomplete corpus.'
        )
        if raise_on_missing:
            raise FileNotFoundError(message)
        print(message)
    else:
        print('  All corpus roots present.')
    return report


# ── Artifact metadata (issue #382) ────────────────────────────────────────────

def _git_commit(path):
    """Return the HEAD commit hash of the git repo at `path`, or None.
    None (rather than raising) is deliberate: metadata should degrade
    gracefully when a corpus root is not a git checkout."""
    try:
        r = subprocess.run(
            ['git', '-C', str(path), 'rev-parse', 'HEAD'],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def build_artifact_metadata(num_source_files=None, extra=None):
    """Build the standard `_metadata` block stamped on every corpus artifact
    (manifest.json, knowledge.json, knowledge_pairs.jsonl, stats.json).

    Correlates model-quality changes with corpus changes: timestamp, the git
    commits of ARO-Lang and ARO-Application, source-file counts, and the
    pipeline version. For JSONL artifacts, write it as a flagged first line:
    `{"_metadata": {...}}`.
    """
    meta = {
        'generated_at':     datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'session_id':       SESSION_ID,
        'pipeline_version': PIPELINE_VERSION,
        'aro_lang_commit':  _git_commit(ARO_ROOT),
        'aro_app_commit':   _git_commit(ARO_APPLICATION_ROOT) if ARO_APPLICATION_ROOT.exists() else None,
    }
    if num_source_files is not None:
        meta['num_source_files'] = int(num_source_files)
    if extra:
        meta.update(extra)
    return meta


def _pairs_metadata_line(num_pairs=None):
    """The flagged JSONL first line for knowledge_pairs.jsonl."""
    extra = {'artifact': 'knowledge_pairs.jsonl'}
    if num_pairs is not None:
        extra['num_pairs'] = int(num_pairs)
    return json.dumps({'_metadata': build_artifact_metadata(extra=extra)})


def is_jsonl_metadata_record(rec) -> bool:
    """True when a parsed JSONL record is the flagged metadata header,
    not a training pair."""
    return isinstance(rec, dict) and '_metadata' in rec and 'instruction' not in rec and 'messages' not in rec


# ── Run provenance (issue #408) ───────────────────────────────────────────────

_RUN_RECORDED = False


def record_run_metadata(extra=None):
    """Write per-run config to data/runs/<SESSION_ID>.json.

    Called lazily by the pair-saving path so every session that emitted pairs
    has a config snapshot; safe to call explicitly (idempotent overwrite).
    """
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    path = RUNS_DIR / f'{SESSION_ID}.json'
    info = {
        'session_id':         SESSION_ID,
        'run_timestamp':      RUN_TIMESTAMP,
        'pipeline_version':   PIPELINE_VERSION,
        'model_id':           MODEL_ID,
        'model_is_finetuned': _MODEL_IS_FINETUNED,
        'base_model_id':      BASE_MODEL_ID,
        'teacher_model_id':   TEACHER_MODEL_ID,
        'student_model_id':   STUDENT_MODEL_ID,
        'train_on_base':      TRAIN_ON_BASE,
        'clean_on_restart':   CLEAN_ON_RESTART,
        'type_caps_version':  TYPE_CAPS_VERSION,
        'type_caps':          TYPE_CAPS,
        'aro_lang_commit':    _git_commit(ARO_ROOT),
        'aro_app_commit':     _git_commit(ARO_APPLICATION_ROOT) if ARO_APPLICATION_ROOT.exists() else None,
        'aro_application_root': str(ARO_APPLICATION_ROOT),
        'python':             sys.version.split()[0],
        'argv':               list(sys.argv),
    }
    if extra:
        info.update(extra)
    with open(path, 'w') as f:
        json.dump(info, f, indent=2)
    return path


def _ensure_run_recorded():
    global _RUN_RECORDED
    if not _RUN_RECORDED:
        record_run_metadata()
        _RUN_RECORDED = True


def stamp_provenance(pair: dict, notebook_tag: str, generation_strategy=None, lineage=None) -> dict:
    """Stamp lineage metadata onto a training pair (issue #408).

    Adds a `provenance` object with session_id, run_timestamp, model_version,
    notebook and generation_strategy (defaults to the pair's `source` tag).
    For distilled/derived pairs, pass `lineage` (e.g. {'variant_of': ...}).
    Existing provenance fields are preserved so re-saving never rewrites
    history.
    """
    prov = dict(pair.get('provenance') or {})
    prov.setdefault('session_id', SESSION_ID)
    prov.setdefault('run_timestamp', RUN_TIMESTAMP)
    prov.setdefault('model_version', MODEL_ID)
    prov.setdefault('notebook', notebook_tag)
    strategy = generation_strategy or pair.get('source') or pair.get('task_type')
    if strategy and 'generation_strategy' not in prov:
        prov['generation_strategy'] = str(strategy)
    if lineage and 'lineage' not in prov:
        prov['lineage'] = lineage
    pair['provenance'] = prov
    return pair


# ── Funnel accounting (issue #409) ────────────────────────────────────────────

class FunnelCounter:
    """Per-stage retention/drop accounting for dataset pipelines.

    Usage:
        funnel = FunnelCounter('dataset_assembly')
        funnel.record_stage('dedup', before=1000, after=940,
                            reasons={'duplicate_instruction': 60})
        print(funnel.render_markdown())
        funnel.write_drop_csv(path)
    """

    def __init__(self, name: str):
        self.name = name
        self.stages = []

    def record_stage(self, stage: str, before: int, after: int, reasons=None):
        """Record one filter/transform stage. `after` may exceed `before`
        for merge stages. `reasons` maps drop-reason → count."""
        reasons = {str(k): int(v) for k, v in dict(reasons or {}).items()}
        self.stages.append({
            'stage':   stage,
            'before':  int(before),
            'after':   int(after),
            'dropped': max(0, int(before) - int(after)),
            'reasons': reasons,
        })

    def to_dict(self):
        return {'name': self.name, 'stages': self.stages}

    def render_markdown(self):
        lines = [
            f'## Retention funnel — {self.name}',
            '',
            '| Stage | In | Out | Δ | Retention | Top drop reasons |',
            '|-------|---:|----:|--:|----------:|------------------|',
        ]
        for s in self.stages:
            delta = s['after'] - s['before']
            ret = f"{100 * s['after'] / s['before']:.1f}%" if s['before'] else '—'
            top = ', '.join(
                f'{k}={v}' for k, v in
                sorted(s['reasons'].items(), key=lambda kv: -kv[1])[:4]
            ) or '—'
            lines.append(
                f"| {s['stage']} | {s['before']:,} | {s['after']:,} "
                f"| {delta:+,} | {ret} | {top} |"
            )
        return '\n'.join(lines)

    def write_drop_csv(self, path):
        """Export every (stage, reason, count) triple for post-hoc analysis."""
        import csv
        path = Path(path)
        with open(path, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['stage', 'reason', 'count'])
            for s in self.stages:
                if s['reasons']:
                    for reason, count in sorted(s['reasons'].items(), key=lambda kv: -kv[1]):
                        w.writerow([s['stage'], reason, count])
                elif s['dropped']:
                    w.writerow([s['stage'], 'unspecified', s['dropped']])
        return path


# ── Near-duplicate detection (issue #387) ─────────────────────────────────────

class NearDuplicateIndex:
    """Token-Jaccard near-duplicate detector for instruction texts.

    Exact-hash dedup misses lightly reworded instructions; this catches them
    without any embedding dependency. O(n²) worst case — fine for the few
    hundred instructions a generation notebook produces.
    """

    def __init__(self, threshold: float = 0.9):
        self.threshold = threshold
        self._token_sets = []

    @staticmethod
    def _tokens(text: str):
        return set(_re.findall(r'\w+', (text or '').lower()))

    def seen(self, text: str) -> bool:
        """True when `text` is a near-duplicate of an already-added text."""
        t = self._tokens(text)
        if not t:
            return False
        for s in self._token_sets:
            inter = len(t & s)
            union = len(t) + len(s) - inter
            if union and inter / union >= self.threshold:
                return True
        return False

    def add(self, text: str):
        t = self._tokens(text)
        if t:
            self._token_sets.append(t)

    def check_and_add(self, text: str) -> bool:
        """Returns True (and does NOT add) when text is a near-duplicate;
        otherwise adds it and returns False."""
        if self.seen(text):
            return True
        self.add(text)
        return False


# Regex matching a feature-set header `(name: activity) {`. Used by training
# notebooks AND the runtime CLI gate so the same definition of "complete
# program" is applied everywhere. A reply containing only ARO statements
# without this wrapper is a fragment — fragments fail `aro check` and must
# not be used as code-generation training samples.
import re as _re

_FEATURESET_HEADER_RE = _re.compile(r"\(\s*[\w\- ]+\s*:\s*[^)]+\)\s*\{")


# ── Semantic alignment gate ────────────────────────────────────────────────
# Mirrors the gate added inside NB10. Any notebook that synthesises code via
# the base model should pipe each (instruction, code) pair through this
# helper before saving — otherwise hallucinated pairs (code is valid ARO
# but doesn't address the instruction) silently poison the training set.
#
# The judge is the same base model already loaded by the calling notebook
# — pass in its `chat` function (the one that takes a messages list and
# returns a string). Conservative behaviour: any answer that doesn't start
# with NO keeps the pair, so a single uncertain judgment never drops a
# genuine success.

_ALIGNMENT_JUDGE_SYSTEM_PROMPT = (
    'You are a strict code review judge. Compare a natural-language '
    "instruction to an ARO code snippet and decide whether the code "
    "carries out the instruction's main purpose. Be lenient on style "
    'and naming; strict on whether the requested behaviour is actually '
    'performed. If the instruction asks to add two numbers, the code '
    'must contain the addition. If the instruction asks to log a value, '
    'the code must contain a Log. Respond on a single line in the form '
    '`YES: <reason>` or `NO: <reason>`. If genuinely unsure, answer YES.'
)


def _extract_aro_blocks(text):
    return [b.strip() for b in _re.findall(r'```aro\n(.*?)```', text or '', _re.DOTALL) if b.strip()]


def semantic_alignment_check(instruction, output, chat_fn, max_tokens=160):
    """Ask the base model whether `output`'s ARO code carries out
    `instruction`'s main purpose. `output` may be a raw code block or a
    response containing ```aro``` fences.

    `chat_fn` is the calling notebook's already-loaded chat helper —
    something with signature `chat(messages, max_tokens=..., temp=...) -> str`.

    Returns (aligned: bool, judge_reason: str). Returns (True, 'skipped:
    empty') when there's no code to judge, so callers can pipe everything
    through this without special-casing prose-only outputs.
    """
    blocks = _extract_aro_blocks(output)
    code = '\n\n'.join(blocks) if blocks else (output or '').strip()
    if not code:
        return True, 'skipped: empty code'
    try:
        response = chat_fn(
            [
                {'role': 'system', 'content': _ALIGNMENT_JUDGE_SYSTEM_PROMPT},
                {'role': 'user', 'content':
                    f'Instruction:\n{instruction}\n\n'
                    f'Generated ARO code:\n```aro\n{code}\n```\n\n'
                    "Does the code carry out the instruction's main purpose?"},
            ],
            max_tokens=max_tokens,
            temp=0.0,
        )
    except TypeError:
        # Older chat_fn signatures don't accept `temp=`; fall back.
        response = chat_fn(
            [
                {'role': 'system', 'content': _ALIGNMENT_JUDGE_SYSTEM_PROMPT},
                {'role': 'user', 'content':
                    f'Instruction:\n{instruction}\n\n'
                    f'Generated ARO code:\n```aro\n{code}\n```\n\n'
                    "Does the code carry out the instruction's main purpose?"},
            ],
            max_tokens=max_tokens,
        )
    head = (response or '').strip().lstrip('`').split('\n', 1)[0].strip().lower()
    aligned = not head.startswith('no')
    return aligned, (response or '').strip()[:240]


def semantic_alignment_filter(pairs, model, tokenizer, mlx_generate, make_sampler,
                              max_tokens=120, label=''):
    """Run every pair in `pairs` through the base model as a judge, dropping
    pairs where the model says the code doesn't address the instruction.

    Designed for notebooks that have already loaded the model (NB05, NB11,
    etc.) — pass in the live handles instead of re-loading.

    Returns (kept_pairs, n_dropped). Prose-only pairs (no ARO code in the
    `output` field) pass through unchanged — judge skips them.
    """
    kept = []
    dropped = 0
    n = len(pairs)
    for idx, p in enumerate(pairs):
        instr = (p.get('instruction') or '').strip()
        out   = (p.get('output') or '').strip()
        if not instr or not out:
            kept.append(p)
            continue
        code = '\n\n'.join(_extract_aro_blocks(out)) or out
        if not code.strip():
            kept.append(p)
            continue
        msgs = [
            {'role': 'system', 'content': _ALIGNMENT_JUDGE_SYSTEM_PROMPT},
            {'role': 'user', 'content':
                f'Instruction:\n{instr}\n\n'
                f'Generated ARO code:\n```aro\n{code}\n```\n\n'
                "Does the code carry out the instruction's main purpose?"},
        ]
        text = tokenizer.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        prompt_tokens = tokenizer.encode(text)
        response = mlx_generate(
            model, tokenizer,
            prompt=prompt_tokens,
            max_tokens=max_tokens,
            sampler=make_sampler(temp=0.0),
            verbose=False,
        ).strip()
        head = response.lstrip('`').split('\n', 1)[0].strip().lower()
        if head.startswith('no'):
            dropped += 1
            if dropped <= 5:
                tag = f' [{label}]' if label else ''
                print(f'  semantic-gate drop{tag}: {response[:100]}', flush=True)
        else:
            kept.append(p)
        if (idx + 1) % 25 == 0:
            print(f'  semantic-gate: judged {idx + 1}/{n} '
                  f'(kept {len(kept)}, dropped {dropped})', flush=True)
    return kept, dropped


def is_complete_program(text_or_blocks):
    """True when the input contains valid ARO — either a complete feature
    set (any kind: `Application-Start`, user-defined `Action`, event
    handler, repository observer, HTTP operationId, etc.) or one or more
    bare REPL-style statements (each non-comment line ends with a period).

    Both forms pass `aro check`; the model needs to learn both. The bare-
    statement form is what `aro repl` and `echo '...' | aro` consume, and
    a model that can ONLY produce wrapped feature sets is worse at the
    interactive use case."""
    if isinstance(text_or_blocks, str):
        blocks = [m.group(1) for m in _re.finditer(r"```aro\n([\s\S]*?)```", text_or_blocks)]
    else:
        blocks = list(text_or_blocks)

    for body in blocks:
        if _FEATURESET_HEADER_RE.search(body):
            return True
        # Bare REPL: every non-empty, non-comment line ends with `.`
        nontrivial = [
            l.strip() for l in body.split('\n')
            if l.strip() and not l.strip().startswith('(*')
        ]
        if nontrivial and all(l.endswith('.') for l in nontrivial):
            return True
    return False


def filter_complete_program_samples(samples, code_task_types=None):
    """Drop code-generation/debugging samples whose assistant message has
    no complete ARO program. Q&A and explanation samples pass through —
    those expect fragments. Returns (kept, dropped_count)."""
    if code_task_types is None:
        code_task_types = {"code_generation", "debugging", "completion", "fim", "translation"}
    kept = []
    dropped = 0
    for s in samples:
        tt = s.get("task_type", "")
        if tt not in code_task_types:
            kept.append(s)
            continue
        msgs = s.get("messages") or []
        asst = msgs[-1].get("content", "") if msgs and msgs[-1].get("role") == "assistant" else s.get("output", "")
        if is_complete_program(asst):
            kept.append(s)
        else:
            dropped += 1
    return kept, dropped


def valid_action_verbs(kb=None):
    """Return the set of all valid ARO action verbs (lowercased) from knowledge.json."""
    kb = kb or load_knowledge()
    verbs = set()
    for a in kb.get('actions', []):
        for v in a.get('verbs', []):
            verbs.add(v.lower())
    return verbs


# ── Warm-start adapter resolver ───────────────────────────────────────────────

def resolve_warm_adapter(kb=None):
    """
    Return path string to the warm-start adapter if it exists, else None.
    Reads the path from knowledge.json (written by notebook 04).
    """
    try:
        kb = kb or load_knowledge()
        path = Path(kb.get('warm_start_adapter', ''))
        if path.exists() and (path / 'adapters.safetensors').exists():
            return str(path)
    except Exception:
        pass
    return None


# ── Model loader helper ───────────────────────────────────────────────────────

def load_model(with_adapter=True, kb=None):
    """
    Load MODEL_ID with optional warm-start adapter.

    When the fine-tuned model (PREFERRED_MODEL_ID) is active, the warm adapter
    is skipped — the fine-tuned weights already incorporate that knowledge.

    Returns (model, tokenizer, load_fn, generate_fn, make_sampler_fn).
    """
    load_fn, generate_fn, make_sampler_fn = ensure_mlx_lm()

    # Fine-tuned model has knowledge baked in — no adapter needed or useful.
    if _MODEL_IS_FINETUNED:
        print(f'Loading fine-tuned model {MODEL_ID} (no adapter)...')
        model, tokenizer = load_fn(MODEL_ID)
    else:
        adapter = resolve_warm_adapter(kb) if with_adapter else None
        if adapter:
            print(f'Loading {MODEL_ID} with warm-start adapter...')
            model, tokenizer = load_fn(MODEL_ID, adapter_path=adapter)
            print(f'  Adapter: {adapter}')
        else:
            print(f'Loading {MODEL_ID} (base weights)...')
            model, tokenizer = load_fn(MODEL_ID)

    print('Model ready.')
    return model, tokenizer, load_fn, generate_fn, make_sampler_fn


# ── System prompt builder ─────────────────────────────────────────────────────

def build_system_prompt(kb=None, max_syntax_chars=4000):
    """
    Build the standard ARO system prompt from the knowledge base.
    Includes syntax rules, action reference, tool calling instructions,
    common idioms, and response behaviour.
    """
    kb = kb or load_knowledge()

    action_lines = []
    for a in kb.get('actions', []):
        verbs = ', '.join(a['verbs'][:3])
        preps = ', '.join(a.get('prepositions', [])[:3])
        role = a.get('role', '')
        action_lines.append(f'  {verbs:<28} [{role:<8}]  prepositions: {preps}')
    action_ref = '\n'.join(action_lines)

    syntax_summary = kb.get('aro_syntax', '')[:max_syntax_chars]

    return f"""You are an expert ARO (Action Result Object) coding assistant.
ARO is a DSL where every statement follows: Verb the <Result> preposition [the] <Object>.

ARO SYNTAX RULES:
{syntax_summary}

AVAILABLE ACTIONS (verb [role] → prepositions):
{action_ref}

CORE RULES:
- Feature set: (Name: Business Activity) {{ statements }}
- Exactly one Application-Start per application
- Variables are immutable — use a new name for each transformation
- Articles (a/an/the) are optional everywhere
- String concatenation: <a> ++ <b>  (NOT + which is arithmetic)
- For-each: For each <item> in <list> {{ ... }}
- Conditions: when <var> = value or when <expr>
- Return an <OK: status> ... to end a feature set
- Emit a <Name: event> with <data> to publish events
- Extract the <x> from the <source: qualifier> to read fields

COMMON PATTERNS:

1. HTTP endpoint (operationId matches feature set name):
   (getUser: User API) {{
       Extract the <id> from the <pathParameters: id>.
       Retrieve the <user> from the <user-repository> where id = <id>.
       Return an <OK: status> with <user>.
   }}

2. Application startup with Keepalive:
   (Application-Start: My App) {{
       Log "Starting..." to the <console>.
       Start the <http-server> with <contract>.
       Keepalive the <application> for the <events>.
       Return an <OK: status> for the <startup>.
   }}

3. Event emission and handler:
   Emit a <UserCreated: event> with <user>.
   (Send Email: UserCreated Handler) {{
       Extract the <user> from the <event: user>.
       Send the <email> to the <user: email>.
       Return an <OK: status> for the <notification>.
   }}

4. Iteration with transformation:
   For each <item> in <items> {{
       Compute the <name: uppercase> from the <item: name>.
       Log <name> to the <console>.
   }}

TOOL CALLING:
You have tools to read and modify the user's project and to run the ARO
toolchain. Invoke them via the JSON tool-call protocol, one call per tool:
<tool_call>{{"name": "write_file", "arguments": {{"path": "main.aro", "content": "..."}}}}</tool_call>

AVAILABLE TOOLS (name(arguments) — purpose):
  read_file(path, offset?, limit?)          read a file with line numbers
  write_file(path, content)                 create or overwrite a file
  edit_file(path, old_string, new_string)   exact string replacement (old_string must be unique)
  list_dir(path?)                           list a directory
  grep(pattern, path?, glob?)               regex search across files
  search_project(query, k?)                 semantic search in the indexed project
  aro_check(path)                           syntax-check .aro files — run after every write
  aro_run(path, args?)                      run an ARO application (30s cap)
  aro_build(path)                           compile to a native binary
  aro_test(path)                            run colocated ARO tests
  parse_aro(path)                           parse a .aro file to its AST
  list_actions()                            list built-in and plugin actions
  list_proposals() / read_proposal(number)  ARO language specifications
  create_plugin(name, language, handle)     scaffold a new plugin
  write_openapi(title, version, paths, output_path?)  generate openapi.yaml
  generate_docs(path, output?)              generate a README.md
  run_shell(command)                        arbitrary shell command (last resort)

THE STANDARD WORKFLOW for changing a project:
  1. read_file — skip this when an OPEN FILE block already shows the file.
  2. edit_file for a targeted change; write_file for a new or rewritten file.
     Source code belongs in source files, not in the chat.
  3. aro_check on the file or directory you touched.
  4. If aro_check fails, fix the code and re-check before answering.
  5. Reply with a short summary — the file path and what changed. Do not
     paste the whole file back into the chat.

NEVER write tool names, function signatures, or any non-ARO syntax inside
```aro fences. Tool names are runtime internals, not part of the ARO language.

WRONG (tool names leaking into an ARO answer):
```aro
read_file(path: "foo.aro")
edit_file("foo.aro", old, new)
aro_check("./")
```

RIGHT (ARO syntax in ```aro fences, tool calls invoked separately):
```aro
Read the <content> from the <file: "foo.aro">.
```

RESPONSE BEHAVIOUR:
- WRITE/CREATE/BUILD request: write the code into the actual source file
  with write_file (new file) or edit_file (existing file), then validate
  with aro_check and fix any reported errors. Answer with a short summary
  of which file you wrote and what it does. Only answer with a bare
  ```aro block when the user explicitly asks to "show" code or when no
  project directory is available to write into.
- OPEN FILE block in context: that is the file the user has open in the
  editor right now — the default target for "this file", "this code", and
  unnamed change requests. Its content is already in the block (no
  read_file needed); modify it with edit_file using the block's path.
- QUESTION about ARO: answer concisely with examples in ```aro fences. Do
  NOT mention tool function names in the answer — answer with the ARO
  verb the user actually needs (e.g. "use the `Read` action" not "use the
  `read_file` function").
- FIX/DEBUG request: load the existing code via read_file (or the OPEN
  FILE block), diagnose in prose, apply a fix via edit_file, then verify
  via aro_check.
- ONLY use action verbs from the AVAILABLE ACTIONS list above. NEVER invent
  new actions. If a user asks for functionality not covered by an existing
  action, explain which available action(s) to use instead. For example,
  there is no "Tail" action — use the file-monitor (Start + File Event
  Handler) for watching files, or Read for reading file contents.
- Do not invent prepositions not listed above.
- If unsure whether an action exists, say so — do not guess.
- Always produce syntactically valid ARO."""


# ── Notebook pair tracking ───────────────────────────────────────────────────
# Every pair written to PAIRS_FILE gets a `notebook` tag (e.g. "NB07").
# On restart, clean_notebook_pairs() removes all pairs from that notebook
# so re-runs produce a clean replacement, not duplicates.
#
# Before any rows are deleted, the whole file is backed up to BACKUP_DIR
# (issue #384) so a crashing notebook never destroys hours of LLM-generation
# work. Use rollback_notebook_pairs() to restore a tag's rows.


def backup_pairs_file(reason: str = ''):
    """Copy PAIRS_FILE to a timestamped backup in BACKUP_DIR.

    Keeps the newest PAIRS_BACKUP_KEEP backups; older ones are pruned.
    Returns the backup Path, or None when there is nothing to back up.
    """
    if not PAIRS_FILE.exists():
        return None
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%dT%H%M%S_%f')
    safe = _re.sub(r'[^A-Za-z0-9_-]', '_', reason)[:40]
    name = f'knowledge_pairs.{ts}' + (f'.{safe}' if safe else '') + '.jsonl.bak'
    dest = BACKUP_DIR / name
    shutil.copy2(PAIRS_FILE, dest)

    backups = sorted(BACKUP_DIR.glob('knowledge_pairs.*.jsonl.bak'))
    for old in backups[:-PAIRS_BACKUP_KEEP]:
        try:
            old.unlink()
        except OSError:
            pass  # best-effort pruning — a stale backup is harmless
    return dest


def list_pairs_backups():
    """Return available knowledge_pairs backups, newest first."""
    if not BACKUP_DIR.exists():
        return []
    return sorted(BACKUP_DIR.glob('knowledge_pairs.*.jsonl.bak'), reverse=True)


def rollback_notebook_pairs(notebook_tag: str, backup_path=None) -> int:
    """Restore a notebook's pairs from backup (issue #384).

    Finds the newest backup containing rows tagged `notebook_tag` (or uses
    `backup_path` when given), removes any current rows for that tag from
    PAIRS_FILE, and appends the backed-up rows. Returns the number of rows
    restored.
    """
    candidates = [Path(backup_path)] if backup_path else list_pairs_backups()
    for bp in candidates:
        if not bp.exists():
            continue
        restored = []
        for line in bp.read_text().splitlines():
            if not line.strip():
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if isinstance(rec, dict) and rec.get('notebook') == notebook_tag:
                restored.append(line)
        if not restored:
            continue

        current = []
        if PAIRS_FILE.exists():
            for line in PAIRS_FILE.read_text().splitlines():
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                    if isinstance(rec, dict) and rec.get('notebook') == notebook_tag:
                        continue  # replaced by the backup's rows
                except Exception:
                    pass
                current.append(line)

        PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
        PAIRS_FILE.write_text('\n'.join(current + restored) + '\n')
        print(f'[rollback] Restored {len(restored)} "{notebook_tag}" pairs from {bp.name}')
        return len(restored)

    print(f'[rollback] No backup containing "{notebook_tag}" pairs found in {BACKUP_DIR}')
    return 0


def clean_notebook_pairs(notebook_tag: str) -> int:
    """
    Remove all pairs tagged with `notebook_tag` from PAIRS_FILE.
    Returns the number of pairs removed.
    Only acts when CLEAN_ON_RESTART is True.

    A timestamped backup of the whole file is written to BACKUP_DIR before
    anything is deleted (issue #384); the flagged `_metadata` first line
    (issue #382) is refreshed on rewrite.
    """
    if not CLEAN_ON_RESTART:
        return 0
    if not PAIRS_FILE.exists():
        return 0

    lines = PAIRS_FILE.read_text().splitlines()
    kept, removed = [], 0
    for line in lines:
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
            if is_jsonl_metadata_record(rec):
                continue  # old header — regenerated fresh below
            if rec.get('notebook') == notebook_tag:
                removed += 1
                continue
        except Exception:
            pass
        kept.append(line)

    if removed > 0:
        backup = backup_pairs_file(reason=notebook_tag)
        if backup is not None:
            print(f'[{notebook_tag}] Backup written: {backup}')
        header = _pairs_metadata_line(num_pairs=len(kept))
        PAIRS_FILE.write_text('\n'.join([header] + kept) + '\n')
        print(f'[{notebook_tag}] Cleaned {removed} pairs from previous run '
              f'(rollback_notebook_pairs({notebook_tag!r}) restores them)')
    return removed


# ---------------------------------------------------------------------------
# Training-pair normalisation
#
# The Qwen3-Coder base model — and therefore any pair the model generates as
# synthetic data (NB05/06/10/12/etc.) — sometimes emits ARO with the space
# missing before an angle-bracket token: `Log "x" to the<console>.`
# Canonical ARO always has whitespace before `<` for system objects,
# qualifiers and variables. Insert the missing space here so every saved
# pair lands clean in `pairs.jsonl` regardless of which notebook produced it.
# Hand-written corpus already has the space, so this regex is a no-op there.
# ---------------------------------------------------------------------------

_MISSING_SPACE_BEFORE_ANGLE_RE = _re.compile(r'(\w)<([a-z])')


def _normalize_aro_whitespace(text: str) -> str:
    """Insert the missing space before `<lower` in ARO source strings."""
    return _MISSING_SPACE_BEFORE_ANGLE_RE.sub(r'\1 <\2', text)


# Qwen3's chat template injects an empty `<think>\n\n</think>\n\n` block
# before every assistant turn when the assistant content does not already
# contain reasoning. Fine-tuning on text rendered this way teaches the
# model to emit `<think></think>` + EOS at inference — the round-2
# empty-content collapse documented in /tmp/aro_ask_eval/REPORT.md.
# This helper strips that injection from the rendered training text so
# the model sees assistant turns as pure content.
_EMPTY_THINK_BLOCK = '<think>\n\n</think>\n\n'


def strip_empty_think_blocks(text: str) -> str:
    """Remove the chat-template's empty <think></think> injections.

    Idempotent. Only removes the exact zero-content block that the
    Qwen3 chat template inserts before assistant turns; leaves any
    non-empty <think>...</think> reasoning untouched.
    """
    return text.replace(_EMPTY_THINK_BLOCK, '')


def render_for_training(tokenizer, messages, add_generation_prompt: bool = False) -> str:
    """Render chat messages for SFT/DPO without the empty-think injection.

    Use this everywhere training text is built — NB17, NB18, NB21,
    NB23 — instead of calling tokenizer.apply_chat_template directly.
    """
    text = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=add_generation_prompt,
    )
    return strip_empty_think_blocks(text)


def patch_qwen3_chat_template(tokenizer):
    """Modify tokenizer.chat_template so assistant turns without
    reasoning_content render WITHOUT the `<think>\\n\\n</think>\\n\\n`
    prefix.

    Stock Qwen3 template emits empty think blocks for every assistant
    turn regardless of content. Fine-tuning on text rendered this way
    teaches the model to produce empty think blocks at inference. This
    surgery keeps the think block only when the message actually has
    reasoning_content; otherwise the assistant content is emitted bare.

    Idempotent. Safe to call once per tokenizer load in any training
    notebook (NB17/18/21/23). Inference-side tokenizer loads should
    skip this and use the stock template.

    Returns the tokenizer for chaining.
    """
    tpl = tokenizer.chat_template
    if tpl is None or '<think>\\n' not in tpl:
        return tokenizer
    old = (
        "{%- if loop.last or (not loop.last and reasoning_content) %}\n"
        "                {{- '<|im_start|>' + message.role + '\\n<think>\\n' "
        "+ reasoning_content.strip('\\n') + '\\n</think>\\n\\n' + content.lstrip('\\n') }}\n"
        "            {%- else %}\n"
        "                {{- '<|im_start|>' + message.role + '\\n' + content }}\n"
        "            {%- endif %}"
    )
    new = (
        "{%- if reasoning_content %}\n"
        "                {{- '<|im_start|>' + message.role + '\\n<think>\\n' "
        "+ reasoning_content.strip('\\n') + '\\n</think>\\n\\n' + content.lstrip('\\n') }}\n"
        "            {%- else %}\n"
        "                {{- '<|im_start|>' + message.role + '\\n' + content }}\n"
        "            {%- endif %}"
    )
    if old in tpl:
        tokenizer.chat_template = tpl.replace(old, new)
    return tokenizer


def _normalize_pair(pair: dict) -> dict:
    """Apply `_normalize_aro_whitespace` to every string field in a pair."""
    for key in ('instruction', 'output', 'input', 'prompt', 'response'):
        v = pair.get(key)
        if isinstance(v, str):
            pair[key] = _normalize_aro_whitespace(v)
    msgs = pair.get('messages')
    if isinstance(msgs, list):
        for msg in msgs:
            if isinstance(msg, dict) and isinstance(msg.get('content'), str):
                msg['content'] = _normalize_aro_whitespace(msg['content'])
    return pair


def _ensure_pairs_header():
    """Write the flagged `_metadata` first line when PAIRS_FILE is created
    (issue #382). Existing files are refreshed on the next
    clean_notebook_pairs() rewrite instead of on every append."""
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    if not PAIRS_FILE.exists() or PAIRS_FILE.stat().st_size == 0:
        PAIRS_FILE.write_text(_pairs_metadata_line(num_pairs=0) + '\n')


def save_notebook_pair(notebook_tag: str, pair: dict,
                       generation_strategy=None, lineage=None) -> bool:
    """
    Append a single training pair to PAIRS_FILE with the notebook tag.
    The pair dict should contain at minimum `instruction`+`output` or `messages`.
    Returns True if written; False when the FIXTRAIN lint gate dropped the
    pair (its output ARO contains a known-bad pattern — see
    check_fixtrain_issues / issue #410). Written pairs are stamped with
    provenance metadata (issue #408) and the session's run config is
    recorded under data/runs/.
    """
    pair['notebook'] = notebook_tag
    pair = _normalize_pair(pair)
    if not _fixtrain_gate_pair(pair, notebook_tag):
        return False
    pair = stamp_provenance(pair, notebook_tag, generation_strategy, lineage)
    _ensure_run_recorded()
    _ensure_pairs_header()
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(PAIRS_FILE, 'a') as f:
        f.write(json.dumps(pair) + '\n')
    return True


def save_notebook_pairs(notebook_tag: str, pairs: list[dict],
                        generation_strategy=None) -> int:
    """
    Append multiple training pairs to PAIRS_FILE, all tagged with notebook_tag
    and stamped with provenance metadata (issue #408). Pairs that fail the
    FIXTRAIN lint gate (issue #410) are dropped and reported. Returns the
    number of pairs actually written.
    """
    if not pairs:
        return 0
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    _ensure_run_recorded()
    _ensure_pairs_header()
    written = 0
    gate_dropped = 0
    with open(PAIRS_FILE, 'a') as f:
        for pair in pairs:
            pair['notebook'] = notebook_tag
            pair = _normalize_pair(pair)
            if not _fixtrain_gate_pair(pair, notebook_tag):
                gate_dropped += 1
                continue
            pair = stamp_provenance(pair, notebook_tag, generation_strategy)
            f.write(json.dumps(pair) + '\n')
            written += 1
    if gate_dropped:
        print(f'[{notebook_tag}] fixtrain-gate dropped {gate_dropped} pairs '
              f'(run fixtrain_report() for the per-rule breakdown)')
    return written


# ═════════════════════════════════════════════════════════════════════════════
# Shared data-quality helpers (train::data-quality issues #377–#410)
# ═════════════════════════════════════════════════════════════════════════════

# ── Syntax-reference guard (issue #377) ──────────────────────────────────────
# The CLAUDE.md-derived `aro_syntax` reference is the foundation of every
# system prompt in the pipeline. A previous pipeline version silently stored a
# CLI error string as the reference; this guard turns any regression into a
# hard error instead of a poisoned training run.

SYNTAX_REFERENCE_REQUIRED_SECTIONS = (
    'Core Syntax',
    'Key Rules',
    'Action Semantic Roles',
)
SYNTAX_REFERENCE_MIN_CHARS = 1500


def validate_syntax_reference(text,
                              min_chars=SYNTAX_REFERENCE_MIN_CHARS,
                              required_sections=SYNTAX_REFERENCE_REQUIRED_SECTIONS):
    """Assert the extracted `aro_syntax` reference looks like the real thing.

    Raises ValueError listing every problem found; returns True when valid.
    Called by NB01 right after extraction and by NB02 before the knowledge
    base is written, so a reorganised CLAUDE.md can never silently produce
    an empty or truncated syntax reference again.
    """
    text = text or ''
    problems = []
    if len(text) < min_chars:
        problems.append(f'too short: {len(text)} chars (minimum {min_chars})')
    for section in required_sections:
        if section.lower() not in text.lower():
            problems.append(f'missing required section: {section!r}')
    # The historic failure mode: a CLI error string stored as the reference.
    for marker in ('command not found', 'unknown subcommand', 'traceback (most recent call last)'):
        if marker in text[:400].lower():
            problems.append(f'looks like an error message (contains {marker!r})')
    if problems:
        raise ValueError(
            'aro_syntax reference failed validation:\n  - ' + '\n  - '.join(problems)
        )
    return True


# ── Canonical ARO snippet helpers ────────────────────────────────────────────

def extract_aro_blocks(text):
    """Public alias for the ```aro fence extractor used across notebooks."""
    return _extract_aro_blocks(text)


def aro_check_snippet(code, timeout=10, extra_files=None):
    """Run `aro check` on a code string in a temp dir.

    Returns (passed: bool | None, error: str). None means the aro binary is
    not available (caller decides whether that is fatal).
    """
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'main.aro').write_text(code)
            if extra_files:
                for name, content in extra_files.items():
                    (Path(tmp) / name).write_text(content)
            r = subprocess.run(['aro', 'check', tmp],
                               capture_output=True, text=True, timeout=timeout)
            return r.returncode == 0, (r.stderr or r.stdout).strip()[:500]
    except FileNotFoundError:
        return None, 'aro_not_found'
    except subprocess.TimeoutExpired:
        return False, 'timeout'


def auto_wrap_aro(code):
    """Wrap bare ARO statements in a feature set if they don't already have one.

    Canonical version of the helper previously duplicated in NB04/NB06.
    Returns (wrapped_code, was_wrapped) or (None, False) if the block is
    template/meta-syntax/negative-example content that should be skipped.
    """
    stripped = code.strip()

    # Already has a feature set wrapper — use as-is
    if stripped.startswith('(') and '{' in stripped.split('\n')[0]:
        return code, False
    # Template placeholders
    if '<statements>' in stripped or '<statement' in stripped.lower():
        return None, False
    # Annotation/diagram markers
    if '^^^^' in stripped or '───' in stripped:
        return None, False
    # Negative examples showing deliberate errors
    if '❌' in stripped:
        return None, False
    # C-style comments instead of ARO comments
    if '//' in stripped and '(*' not in stripped:
        return None, False
    # Check any line looks like a real ARO statement (angle-bracket variables)
    has_aro_stmt = any(_re.search(r'<[a-z][-a-z0-9]*', line)
                       for line in stripped.split('\n')
                       if not line.strip().startswith('(*'))
    if not has_aro_stmt:
        return None, False

    has_return = any(_re.match(r'\s*(Return|Throw)\b', line)
                     for line in stripped.split('\n'))
    indented = '\n'.join(f'    {line}' for line in stripped.split('\n'))
    if has_return:
        wrapped = f'(Application-Start: Example) {{\n{indented}\n}}'
    else:
        wrapped = (f'(Application-Start: Example) {{\n{indented}\n'
                   f'    Return an <OK: status> for the <result>.\n}}')
    return wrapped, True


# ── Canonical verb validation (issue #386) ───────────────────────────────────
# Hallucinated action verbs are one of the most damaging error classes
# (FIXTRAIN.md catalogues Subscribe/Set/Build/while among others). Every
# generating notebook should verify verbs against this shared set instead of
# maintaining its own list.

_ARO_COMMENT_RE = _re.compile(r'\(\*.*?\*\)', _re.DOTALL)

# Core verbs that knowledge.json extraction sometimes misses (documented in
# CLAUDE.md action roles and the language proposals).
VERB_SUPPLEMENT = frozenset({
    'return', 'compute', 'throw',            # RESPONSE / OWN roles
    'publish',                                # EXPORT role
    'split',                                  # ARO-0037 regex split
    'configure',                              # ARO-0035 configurable runtime
    'parameters',                             # ARO-0047 CLI parameters
    'intersect', 'difference', 'union',       # ARO-0042 set operations
    'tee',                                    # ARO-0051 streaming
})

# Control-flow keywords that can start a statement-like line.
CONTROL_FLOW_WORDS = frozenset({'for', 'when', 'match', 'if', 'case', 'parallel', 'otherwise'})


def canonical_verb_set(kb=None):
    """All valid ARO action verbs (lowercased) from knowledge.json plus the
    documented supplement and control-flow keywords."""
    try:
        verbs = valid_action_verbs(kb)
    except Exception:
        # knowledge.json not built yet — fall back to the static supplement
        verbs = set()
    return set(verbs) | set(VERB_SUPPLEMENT) | set(CONTROL_FLOW_WORDS)


_STATEMENT_VERB_RE = _re.compile(r'^\s*([A-Z][a-z]+(?:[A-Z][a-z]+)*)\s+', _re.MULTILINE)


def hallucinated_verbs_in_code(code, valid_verbs=None):
    """Return the set of statement-leading verbs in `code` that are not in
    `valid_verbs` (defaults to canonical_verb_set()). Comments are stripped
    first so English prose inside (* ... *) is not misidentified."""
    valid = valid_verbs if valid_verbs is not None else canonical_verb_set()
    valid = {v.lower() for v in valid}
    stripped = _ARO_COMMENT_RE.sub('', code or '')
    used = set()
    for m in _STATEMENT_VERB_RE.finditer(stripped):
        verb = m.group(1)
        if verb.lower() not in valid:
            used.add(verb)
    return used


# ── Verb + preposition signature validation (issue #402) ─────────────────────
# `aro check` validates syntax, not action signatures. These helpers validate
# extracted verb+preposition combinations against the metadata mined from
# Swift source in knowledge.json (e.g. `Log … to`, never `Log … for`).

ARO_PREPOSITIONS = frozenset({
    'from', 'to', 'with', 'for', 'on', 'into', 'at', 'by',
    'where', 'against', 'via', 'using', 'in', 'as',
})
# Always allowed regardless of the action: `when` guards and `where` queries.
_ALWAYS_ALLOWED_PREPS = frozenset({'when', 'where'})

_VP_STMT_RE = _re.compile(r'^\s*([A-Z][A-Za-z]+)\s+(?:the\s+|an?\s+)?<[^>]*>\s+([a-z]+)\b')


def build_verb_preposition_map(kb=None):
    """Return {verb(lower): set(prepositions)} from knowledge.json actions."""
    kb = kb or load_knowledge()
    vp = {}
    for a in kb.get('actions', []):
        preps = {p.lower() for p in a.get('prepositions', [])}
        for v in a.get('verbs', []):
            vp.setdefault(v.lower(), set()).update(preps)
    return vp


def check_verb_prepositions(code, vp_map):
    """Return a list of human-readable violations where a statement uses a
    preposition that is not documented for its verb. Verbs without documented
    prepositions are skipped (no data — no verdict)."""
    violations = []
    stripped = _ARO_COMMENT_RE.sub('', code or '')
    for line in stripped.splitlines():
        m = _VP_STMT_RE.match(line)
        if not m:
            continue
        verb, word = m.group(1).lower(), m.group(2).lower()
        if word not in ARO_PREPOSITIONS:
            continue
        allowed = vp_map.get(verb)
        if not allowed:
            continue
        if word in allowed or word in _ALWAYS_ALLOWED_PREPS:
            continue
        violations.append(
            f'`{m.group(1)} … {word}` — documented prepositions: '
            f'{", ".join(sorted(allowed))}'
        )
    return violations


# ── OpenAPI contract cross-check (issue #402) ────────────────────────────────

_OPENAPI_OPID_RE = _re.compile(r'operationId:\s*([\w.-]+)')
_OPENAPI_PATH_RE = _re.compile(r'^\s{0,6}(/[^\s:]*):\s*$', _re.MULTILINE)
_PATH_PARAM_RE = _re.compile(r'\{([\w-]+)\}')
_FEATURESET_NAME_RE = _re.compile(r'\(\s*([^:()\n]+?)\s*:\s*[^)]*\)\s*\{')
_PATHPARAM_EXTRACT_RE = _re.compile(r'<pathParameters:\s*([\w-]+)\s*>')


def check_openapi_contract(aro_code, openapi_yaml):
    """Cross-check ARO feature sets against an OpenAPI contract.

    Flags operationIds without a matching feature-set name and
    `<pathParameters: x>` extractions for parameters never declared in any
    path template. Returns a list of violation strings (empty = OK).
    """
    violations = []
    yaml_text = openapi_yaml or ''
    code = aro_code or ''
    op_ids = _OPENAPI_OPID_RE.findall(yaml_text)
    feature_names = {n.strip() for n in _FEATURESET_NAME_RE.findall(code)}
    for op in op_ids:
        if op not in feature_names:
            violations.append(f'operationId `{op}` has no matching feature set')
    declared_params = set()
    for path in _OPENAPI_PATH_RE.findall(yaml_text):
        declared_params.update(_PATH_PARAM_RE.findall(path))
    for param in _PATHPARAM_EXTRACT_RE.findall(code):
        if declared_params and param not in declared_params:
            violations.append(
                f'`pathParameters: {param}` is not declared in any openapi path'
            )
    return violations


# ── Paraphrase consistency judge (issue #401) ────────────────────────────────
# Replaces NB14's word-overlap heuristic: the LLM judges whether a reworded
# instruction still asks for what the source comment describes. Same
# conservative YES-on-uncertainty policy as semantic_alignment_check.

_PARAPHRASE_JUDGE_SYSTEM_PROMPT = (
    'You are a strict data-quality judge. Compare a SOURCE description '
    '(a code comment) with a REWRITTEN instruction. Decide whether the '
    'rewritten instruction asks for the same behaviour the source describes. '
    'Be lenient on style and phrasing; strict on meaning — the instruction '
    'must not add, drop, or change the described operation. Respond on a '
    'single line in the form `YES: <reason>` or `NO: <reason>`. '
    'If genuinely unsure, answer YES.'
)


def word_overlap_ratio(source, candidate, min_word_len=5):
    """Cheap lexical pre-filter: fraction of long source words present in the
    candidate. 1.0 when the source has no long words (nothing to test)."""
    s_words = {w.lower() for w in (source or '').split() if len(w) >= min_word_len}
    if not s_words:
        return 1.0
    c_words = {w.lower() for w in (candidate or '').split()}
    return len(s_words & c_words) / len(s_words)


def paraphrase_consistency_check(source_text, instruction, chat_fn, max_tokens=120):
    """Ask the local model whether `instruction` preserves the meaning of
    `source_text`. Returns (consistent: bool, judge_reason: str)."""
    msgs = [
        {'role': 'system', 'content': _PARAPHRASE_JUDGE_SYSTEM_PROMPT},
        {'role': 'user', 'content':
            f'Source comment:\n{source_text}\n\n'
            f'Rewritten instruction:\n{instruction}\n\n'
            'Does the rewritten instruction ask for the same thing the '
            'source comment describes?'},
    ]
    try:
        response = chat_fn(msgs, max_tokens=max_tokens, temp=0.0)
    except TypeError:
        # Older chat_fn signatures don't accept `temp=`; fall back.
        response = chat_fn(msgs, max_tokens=max_tokens)
    head = (response or '').strip().lstrip('`').split('\n', 1)[0].strip().lower()
    return (not head.startswith('no')), (response or '').strip()[:240]


# ── FIXTRAIN lint gate (issue #410) ──────────────────────────────────────────
# FIXTRAIN.md catalogues 83 concrete bad-data patterns found in
# knowledge_pairs.jsonl; fix_training_data.py hardcodes the wrong→right pairs.
# These rules encode the 13 issue *classes* as permanent guardrails so the
# same bad patterns cannot re-enter the dataset on the next run. Rule names
# reference the FIXTRAIN ISSUE ids they cover.
#
# The gate runs inside save_notebook_pair()/save_notebook_pairs(), i.e. on
# every pair any notebook emits. Only assistant/output ARO blocks are linted —
# instructions legitimately quote wrong code ("Fix this: …"), and blocks that
# an answer explicitly labels as wrong/negative examples are skipped.

FIXTRAIN_RULES = [
    {
        'name': 'string-concat-plus', 'severity': 'error',
        'message': 'string concatenation must use `++`, not `+` '
                   '(FIXTRAIN ISSUE-003/014/026/037)',
        'pattern': _re.compile(r'"[^"\n]*"\s*\+(?!\+)|(?<!\+)\+\s*"'),
    },
    {
        'name': 'emit-with-destination', 'severity': 'error',
        'message': 'Emit takes no destination — use `Emit a <Name: event> with <data>.` '
                   '(FIXTRAIN ISSUE-001/011/029/041)',
        'pattern': _re.compile(r'\bemit\b[^.\n]*\bto\s+the\b', _re.IGNORECASE),
    },
    {
        'name': 'emit-missing-event-qualifier', 'severity': 'error',
        'message': 'Emit result needs a lowercase `: event` qualifier '
                   '(FIXTRAIN ISSUE-021/029/041)',
        'pattern': _re.compile(r'\bEmit\s+(?:the\s+|an?\s+)?<(?![^>]*:\s*event\b)[^>]*>'),
    },
    {
        'name': 'log-for-console', 'severity': 'error',
        'message': 'Log uses `to the <console>`, never `for` (FIXTRAIN ISSUE-002)',
        'pattern': _re.compile(r'\bLog\b[^.\n]*\bfor\s+the\s+<console>'),
    },
    {
        'name': 'log-extra-clauses', 'severity': 'error',
        'message': 'Log accepts no clauses after `to the <console>` (FIXTRAIN ISSUE-010)',
        'pattern': _re.compile(r'to\s+the\s+<console>\s+(?:for|with)\b'),
    },
    {
        'name': 'publish-not-as-form', 'severity': 'error',
        'message': 'Publish syntax is `Publish as <alias> <variable>.` '
                   '(FIXTRAIN ISSUE-012/030)',
        'pattern': _re.compile(r'^\s*Publish\s+(?!as\b)', _re.MULTILINE),
    },
    {
        'name': 'when-block', 'severity': 'error',
        'message': '`when <cond> { … }` blocks do not exist — `when` is a '
                   'per-statement suffix guard (FIXTRAIN ISSUE-013/033)',
        'pattern': _re.compile(r'^\s*when\b[^.{}\n]*\{\s*$', _re.MULTILINE),
    },
    {
        'name': 'else-block', 'severity': 'error',
        'message': '`else { … }` does not exist in ARO (FIXTRAIN ISSUE-013)',
        'pattern': _re.compile(r'^\s*\}?\s*else\s*\{', _re.MULTILINE),
    },
    {
        'name': 'while-loop', 'severity': 'error',
        'message': '`while` loops do not exist — use For-each (FIXTRAIN ISSUE-005)',
        'pattern': _re.compile(r'^\s*while\b[^.\n]*\{', _re.MULTILINE),
    },
    {
        'name': 'hallucinated-subscribe', 'severity': 'error',
        'message': '`Subscribe` is not an ARO action — handlers register by '
                   'naming convention (FIXTRAIN ISSUE-022)',
        'pattern': _re.compile(r'^\s*Subscribe\b', _re.MULTILINE),
    },
    {
        'name': 'hallucinated-set', 'severity': 'error',
        'message': '`Set` is not an ARO action — variables are immutable '
                   '(FIXTRAIN ISSUE-023)',
        'pattern': _re.compile(r'^\s*Set\s+the\s+<', _re.MULTILINE),
    },
    {
        'name': 'hallucinated-build', 'severity': 'error',
        'message': '`Build` is not an ARO action (FIXTRAIN ISSUE-012)',
        'pattern': _re.compile(r'^\s*Build\s+(?:the\s+)?<', _re.MULTILINE),
    },
    {
        'name': 'missing-angle-brackets', 'severity': 'error',
        'message': 'variables must be wrapped in angle brackets (FIXTRAIN ISSUE-007)',
        'pattern': _re.compile(
            r'^\s*(?:Extract|Retrieve|Transform|Filter|Compute|Create|Store'
            r'|Delete|Update|Send)\s+the\s+[a-z][\w-]*\s+'
            r'(?:from|to|into|with|for)\s+the\s+[a-z]', _re.MULTILINE),
    },
    {
        'name': 'feature-set-missing-activity', 'severity': 'error',
        'message': 'feature set headers need `(Name: Business Activity)` — the '
                   'colon and activity are mandatory (FIXTRAIN ISSUE-019/020/025/032)',
        'pattern': _re.compile(r'^\s*\((?!\*)[^:()\n]*\)\s*\{', _re.MULTILINE),
    },
    {
        'name': 'feature-set-keyword-header', 'severity': 'error',
        'message': '`Application X {` / `Feature set X {` are not valid feature '
                   'set declarations (FIXTRAIN ISSUE-006)',
        'pattern': _re.compile(
            r'^\s*(?:Application\s+[A-Z][\w ]*|Feature\s+[Ss]et:?\s+[^\n{]*)\{',
            _re.MULTILINE),
    },
    {
        'name': 'compute-from-with-arithmetic', 'severity': 'error',
        'message': '`Compute … from X with Y` is only for set operations with a '
                   'qualifier; arithmetic goes entirely after `from` '
                   '(FIXTRAIN ISSUE-004/016/018)',
        'pattern': _re.compile(
            r'\bCompute\s+the\s+<[^>:]*>\s+from\s+(?:the\s+)?<[^>]*>\s+with\b'),
    },
    {
        'name': 'throw-wrong-preposition', 'severity': 'error',
        'message': 'Throw accepts only `for` (FIXTRAIN ISSUE-009/035)',
        'pattern': _re.compile(r'^\s*Throw\b[^.\n]*\b(?:with|to)\b', _re.MULTILINE),
    },
    {
        'name': 'transform-using', 'severity': 'error',
        'message': '`using` is not an ARO preposition — put the qualifier on the '
                   'result variable (FIXTRAIN ISSUE-027)',
        'pattern': _re.compile(r'^\s*Transform\b[^.\n]*\busing\b', _re.MULTILINE),
    },
    {
        'name': 'delete-with-dict', 'severity': 'error',
        'message': 'Delete uses `from … where`, not a `with { }` dictionary '
                   '(FIXTRAIN ISSUE-036)',
        'pattern': _re.compile(r'^\s*Delete\b[^.\n]*\bwith\s*\{', _re.MULTILINE),
    },
    {
        'name': 'execute-from', 'severity': 'error',
        'message': 'Execute identifies the command with `for`, not `from` '
                   '(FIXTRAIN ISSUE-008)',
        'pattern': _re.compile(r'^\s*Execute\b[^.\n]*\bfrom\s+the\b', _re.MULTILINE),
    },
    {
        'name': 'listen-from', 'severity': 'error',
        'message': 'Listen syntax is `Listen the <keyboard> to the <stdin>.` '
                   '(FIXTRAIN ISSUE-043)',
        'pattern': _re.compile(r'^\s*Listen\b[^.\n]*\bfrom\s+the\b', _re.MULTILINE),
    },
    {
        'name': 'return-from', 'severity': 'error',
        'message': 'Return uses `with`/`for`, never `from` (FIXTRAIN ISSUE-044)',
        'pattern': _re.compile(r'^\s*Return\b[^.\n]*\bfrom\b', _re.MULTILINE),
    },
    {
        'name': 'accept-wrong-preposition', 'severity': 'error',
        'message': 'Accept transitions state — `Accept the <entity: new-state>.`; '
                   'no `from`/`with` clauses (FIXTRAIN ISSUE-024/034)',
        'pattern': _re.compile(r'^\s*Accept\b[^.\n]*\b(?:from|with)\b', _re.MULTILINE),
    },
    {
        'name': 'arrow-assignment', 'severity': 'error',
        'message': '`<-` arrow assignment / type-annotated assignment is not ARO '
                   '(FIXTRAIN ISSUE-038/041)',
        'pattern': _re.compile(r'(?:\s|\))<-'),
    },
    # ── warn-severity: reported but not dropped ─────────────────────────────
    {
        'name': 'render-from', 'severity': 'warn',
        'message': 'Render normally targets `to the <console>` — check `from` '
                   'usage (FIXTRAIN ISSUE-040)',
        'pattern': _re.compile(r'^\s*Render\b[^.\n]*\bfrom\s+the\b', _re.MULTILINE),
    },
    {
        'name': 'store-in-preposition', 'severity': 'warn',
        'message': 'canonical Store preposition is `into` (the runtime accepts '
                   '`in`, docs use `into`) (FIXTRAIN ISSUE-028)',
        'pattern': _re.compile(r'\bStore\s+(?:the\s+)?<[^>]+>\s+in\s+the\b'),
    },
]


def check_fixtrain_issues(code, include_warnings=False):
    """Lint ARO source against the FIXTRAIN.md catalogue of known-bad patterns.

    Returns a list of violation dicts {rule, severity, message, match}.
    ARO comments are stripped first so prose never triggers rules.
    """
    violations = []
    stripped = _ARO_COMMENT_RE.sub('', code or '')
    if not stripped.strip():
        return violations
    for rule in FIXTRAIN_RULES:
        if rule['severity'] == 'warn' and not include_warnings:
            continue
        m = rule['pattern'].search(stripped)
        if m:
            violations.append({
                'rule':     rule['name'],
                'severity': rule['severity'],
                'message':  rule['message'],
                'match':    stripped[m.start():m.end()][:80].strip(),
            })
    return violations


# Gate state — per-run report of everything the lint caught.
FIXTRAIN_GATE_ENABLED = True
FIXTRAIN_VIOLATION_COUNTS = _Counter()
_FIXTRAIN_DROP_LOG_LIMIT = 10
_fixtrain_drops_logged = {'count': 0}

# Blocks preceded by these markers are quoted as deliberate negative examples
# ("WRONG:", "Fix this…", "❌ …") and must not be linted as if they were
# training targets.
_NEGATIVE_CONTEXT_MARKERS = (
    'wrong', 'incorrect', 'invalid', 'not valid', 'instead', "don't", 'do not',
    'avoid', '❌', 'bad', 'error', 'fails', 'broken', 'bug',
)


def _pair_assistant_text(pair):
    """Assistant/output text of a training pair in either format."""
    msgs = pair.get('messages')
    if isinstance(msgs, list):
        for msg in reversed(msgs):
            if isinstance(msg, dict) and msg.get('role') == 'assistant':
                return msg.get('content') or ''
    return pair.get('output') or pair.get('response') or ''


def lint_pair_output(pair):
    """Run the FIXTRAIN lint over a pair's assistant/output ARO blocks.

    Returns the list of error-severity violations (empty = pair is clean).
    Warn-severity findings are counted in FIXTRAIN_VIOLATION_COUNTS but do
    not appear in the returned list. Blocks explicitly framed as negative
    examples are skipped.
    """
    text = _pair_assistant_text(pair)
    if '```aro' not in (text or ''):
        return []
    errors = []
    for m in _re.finditer(r'```aro\n(.*?)```', text, _re.DOTALL):
        preceding = text[max(0, m.start() - 200):m.start()].lower()
        if any(k in preceding for k in _NEGATIVE_CONTEXT_MARKERS):
            continue
        for v in check_fixtrain_issues(m.group(1), include_warnings=True):
            FIXTRAIN_VIOLATION_COUNTS[v['rule']] += 1
            if v['severity'] == 'error':
                errors.append(v)
    return errors


def fixtrain_report(reset=False):
    """Print the per-run FIXTRAIN violation report. Optionally reset counts."""
    if not FIXTRAIN_VIOLATION_COUNTS:
        print('fixtrain-gate: no violations recorded this run')
    else:
        print('fixtrain-gate violation report:')
        for rule, n in FIXTRAIN_VIOLATION_COUNTS.most_common():
            print(f'  {n:5d}x  {rule}')
    counts = dict(FIXTRAIN_VIOLATION_COUNTS)
    if reset:
        FIXTRAIN_VIOLATION_COUNTS.clear()
        _fixtrain_drops_logged['count'] = 0
    return counts


def _fixtrain_gate_pair(pair, notebook_tag=''):
    """True when the pair passes the gate; logs and counts drops."""
    if not FIXTRAIN_GATE_ENABLED:
        return True
    violations = lint_pair_output(pair)
    if not violations:
        return True
    _fixtrain_drops_logged['count'] += 1
    if _fixtrain_drops_logged['count'] <= _FIXTRAIN_DROP_LOG_LIMIT:
        v = violations[0]
        tag = f'[{notebook_tag}] ' if notebook_tag else ''
        print(f'  {tag}fixtrain-gate drop: {v["rule"]} — {v["match"][:60]!r}',
              flush=True)
    return False


# ── Semantic near-duplicate detection (issue #404) ───────────────────────────

def _dup_token_set(text):
    return set(_re.findall(r'[a-z0-9]+', (text or '').lower()))


def near_duplicate_filter(samples, get_text, get_score=None, threshold=0.92,
                          jaccard_threshold=0.65, use_embeddings=True, label=''):
    """Drop semantic near-duplicates, keeping the highest-scored representative
    per cluster.

    Prefers all-MiniLM sentence embeddings (cosine >= `threshold` = duplicate);
    falls back to token-set Jaccard (>= `jaccard_threshold`) when
    sentence-transformers is unavailable. Greedy: samples are visited in
    score-descending order and kept only if not too similar to anything
    already kept — so the best sample of each cluster survives.

    Returns (kept_samples, n_dropped). Original relative order is preserved.
    """
    n = len(samples)
    if n <= 1:
        return list(samples), 0
    texts = [get_text(s) or '' for s in samples]
    scores = [(get_score(s) if get_score else 1.0) for s in samples]
    order = sorted(range(n), key=lambda i: (-scores[i], i))

    emb = None
    if use_embeddings:
        try:
            from sentence_transformers import SentenceTransformer
            import numpy as np
            _st_model = SentenceTransformer('all-MiniLM-L6-v2')
            emb = np.asarray(_st_model.encode(
                texts, normalize_embeddings=True, show_progress_bar=False))
        except Exception as e:
            print(f'  near-dup: embeddings unavailable ({type(e).__name__}) — '
                  f'token-overlap fallback', flush=True)
            emb = None

    kept_flags = [False] * n
    dropped = 0

    if emb is not None:
        import numpy as np
        kept_matrix = np.empty((n, emb.shape[1]), dtype=emb.dtype)
        k = 0
        for i in order:
            v = emb[i]
            if k and float(np.max(kept_matrix[:k] @ v)) >= threshold:
                dropped += 1
                continue
            kept_matrix[k] = v
            k += 1
            kept_flags[i] = True
    else:
        token_sets = [_dup_token_set(t) for t in texts]
        index = {}  # token -> list of kept indices
        for i in order:
            toks = token_sets[i]
            if not toks:
                kept_flags[i] = True
                continue
            cand = _Counter()
            for t in toks:
                for j in index.get(t, ()):
                    cand[j] += 1
            is_dup = False
            for j, shared in cand.most_common(20):
                union = len(toks | token_sets[j])
                if union and shared / union >= jaccard_threshold:
                    is_dup = True
                    break
            if is_dup:
                dropped += 1
                continue
            kept_flags[i] = True
            for t in toks:
                index.setdefault(t, []).append(i)

    kept = [s for s, keep in zip(samples, kept_flags) if keep]
    if label:
        print(f'  near-dup [{label}]: {n} → {len(kept)} (dropped {dropped})',
              flush=True)
    return kept, dropped


# ── Per-source quality scores and soft weighting (issue #407) ────────────────
# Curated sources score 1.0; mined/noisy sources score lower. NB16 uses these
# for soft down-weighting instead of hard caps, and can blend in pass rates
# derived from NB15 validation results.

SOURCE_QUALITY_SCORES = {
    # curated, deterministic, or hand-verified
    'example':                1.0,
    'actions_usage':          1.0,
    'actions_explain':        1.0,
    'actions_which':          1.0,
    'actions_context_static': 1.0,
    'error_pattern':          1.0,
    'proposal':               0.95,
    'comment':                0.95,
    # book-grounded / validated LLM generations
    'book':                   0.9,
    'aro_by_example':         0.9,
    'actions_alias':          0.9,
    'actions_context':        0.85,
    'repair':                 0.85,
    'book_qa':                0.8,
    'wiki':                   0.8,
    'synthetic':              0.8,
    # mined / mutated — noisiest sources
    'mutation':               0.75,
    'recombination':          0.75,
    'readme':                 0.7,
    'external_repo':          0.7,
    'readme_to_code':         0.7,
}
DEFAULT_SOURCE_QUALITY = 0.8

# Assembly-time policy knobs (used by NB16)
AUTO_WRAP_MAX_SHARE   = 0.35   # max share of code_generation pairs that may be auto-wrapped (issue #380)
SOURCE_SOFT_CAP_SHARE = 0.30   # sources above this share get soft down-weighted
SOURCE_SHARE_FLAG     = 0.40   # flag any source above this share of the train set


def source_quality_score(source, notebook=None):
    """Quality score in (0, 1] for a pair's `source` tag."""
    src = (source or '').strip()
    # NB14 comment pairs carry a file path as source — real hand-written code.
    if src.startswith('/') or src.endswith('.aro'):
        return 0.95
    prefix = src.split(':')[0].strip().lower()
    return SOURCE_QUALITY_SCORES.get(prefix, DEFAULT_SOURCE_QUALITY)


def derive_source_quality_from_validation(validated_samples, min_count=20):
    """Auto-derive per-source-prefix pass rates from NB15's all_samples.jsonl
    records. Returns {source_prefix: pass_rate} for prefixes with at least
    `min_count` samples (fewer = too noisy to trust)."""
    totals, passed = _Counter(), _Counter()
    for s in validated_samples:
        prefix = (s.get('source') or 'unknown').split(':')[0].strip().lower()
        totals[prefix] += 1
        if s.get('valid') is True:
            passed[prefix] += 1
    return {p: passed[p] / totals[p] for p in totals if totals[p] >= min_count}


# ── Generation-failure feedback loop (issue #396) ─────────────────────────────
# When NB07/NB10 generation fails `aro check` / `aro run`, the failure is no
# longer thrown away: each one is categorized and appended to
# GENERATION_FAILURES_FILE. On the next pipeline run, NB06 reads this file and
# turns the most common *novel* error classes (classes not already covered by
# its static ERROR_PATTERNS) into wrong-code → fixed-code correction pairs.

GENERATION_FAILURES_FILE = DATA_ROOT / 'generation_failures.jsonl'

# (category, substring-or-regex patterns). First match wins. Categories that
# overlap the static NB06 ERROR_PATTERNS carry static_covered=True so the
# feedback loop can focus on genuinely novel error classes.
_ERROR_CATEGORY_PATTERNS = [
    ('string_concat_plus',       [r"Expected '?'?>'?, but got \+", r'\+\+ .*concat', r"got '\+'"], True),
    ('rebind_variable',          [r'Cannot rebind variable', r'rebind'], True),
    ('reserved_prefix',          [r"Reserved prefix", r"reserved prefix"], True),
    ('wrong_preposition',        [r'Expected preposition'], True),
    ('expr_in_angle_brackets',   [r"Expected '>', but got"], True),
    ('dot_in_angle_brackets',    [r"Expected '>'.*got \."], True),
    ('double_equals',            [r"got =="], True),
    ('where_misuse',             [r'Expected identifier, but got where', r"'where'"], True),
    ('invalid_verb',             [r'Expected action verb', r'Unknown action', r'unknown verb'], True),
    ('missing_application_start', [r'Entry point not found', r'Application-Start'], True),
    ('multiple_application_start', [r'[Mm]ultiple Application-Start'], False),
    ('missing_period',           [r"Expected '\.'"], False),
    ('unexpected_token',         [r'[Uu]nexpected token'], False),
    ('unknown_qualifier',        [r'[Uu]nknown qualifier', r'qualifier'], False),
    ('symbol_not_found',         [r'Symbol .* not found', r'SymbolLookupError', r'[Uu]ndefined symbol'], False),
    ('runtime_crash',            [r'Fatal error', r'[Cc]rashed', r'non-zero exit'], False),
    ('timeout',                  [r'^timeout$', r'TIMEOUT'], False),
    ('no_aro_block',             [r'No ```aro``` block'], False),
    ('comment_heavy',            [r'comment lines'], False),
    ('semantic_misalignment',    [r'does not address the original', r'semantic'], False),
]


def categorize_aro_error(error_text: str) -> str:
    """Map an `aro check`/`aro run` stderr string to a stable error category."""
    text = (error_text or '').strip()
    if not text:
        return 'empty_error'
    for category, patterns, _static in _ERROR_CATEGORY_PATTERNS:
        for pat in patterns:
            if _re.search(pat, text):
                return category
    return 'uncategorized'


def error_category_is_static(category: str) -> bool:
    """True when the category is already covered by NB06's static ERROR_PATTERNS."""
    for cat, _patterns, static in _ERROR_CATEGORY_PATTERNS:
        if cat == category:
            return static
    return False


def record_generation_failure(notebook_tag: str, task_type: str,
                              instruction: str, code: str, error: str,
                              phase: str = 'check') -> str:
    """Append one failed generation to GENERATION_FAILURES_FILE.

    `phase` is 'check' (aro check failed) or 'run' (aro run failed).
    Returns the assigned error category. Best-effort: any I/O problem is
    swallowed so a broken failure log can never break generation itself.
    """
    category = categorize_aro_error(error)
    rec = {
        'notebook':    notebook_tag,
        'task_type':   task_type,
        'phase':       phase,
        'category':    category,
        'instruction': (instruction or '')[:1500],
        'code':        (code or '')[:3000],
        'error':       (error or '')[:600],
    }
    try:
        GENERATION_FAILURES_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(GENERATION_FAILURES_FILE, 'a') as f:
            f.write(json.dumps(rec) + '\n')
    except Exception as e:  # pragma: no cover - diagnostics only
        sys.stderr.write(f'[config] Warning: could not record generation failure: {e}\n')
    return category


def load_generation_failures() -> list[dict]:
    """Load all recorded generation failures (may be empty)."""
    failures = []
    if not GENERATION_FAILURES_FILE.exists():
        return failures
    with open(GENERATION_FAILURES_FILE) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                failures.append(json.loads(line))
            except Exception:
                pass
    return failures


def summarize_generation_failures(failures=None, top_n: int = 15) -> list[dict]:
    """Aggregate failures by category. Returns a list of
    {category, count, novel, example} dicts sorted by count desc.
    `example` is one representative failure (code + error) per category."""
    from collections import Counter as _C
    failures = failures if failures is not None else load_generation_failures()
    counts = _C(f.get('category', 'uncategorized') for f in failures)
    summary = []
    for category, count in counts.most_common(top_n):
        example = next(
            (f for f in failures
             if f.get('category') == category and f.get('code') and f.get('error')),
            None,
        )
        summary.append({
            'category': category,
            'count':    count,
            'novel':    not error_category_is_static(category),
            'example':  example,
        })
    return summary


# ── `aro ask` tool inventory extraction (issue #397) ──────────────────────────
# NB11 trains function calling against the REAL `aro ask` toolset. The source
# of truth is the Swift sources under Sources/AROAsk/ — every tool is declared
# as an AskToolDescriptor(name:, description:, parameters:) where parameters
# is a JSON-schema literal built from JSONValue .object/.array/.string nodes.
# This extractor parses those literals at pipeline runtime so the training
# data can never drift from the shipped tool inventory.

_ASK_TOOL_SOURCE_DIRS = ('Sources/AROAsk/Tools', 'Sources/AROAsk/Retrieval')


def _swift_balanced_block(text: str, open_idx: int) -> str:
    """Return the text of a balanced [...] block starting at text[open_idx]=='['.
    String-literal aware (Swift double-quoted strings with backslash escapes)."""
    assert text[open_idx] == '['
    depth = 0
    in_string = False
    escape = False
    for i in range(open_idx, len(text)):
        ch = text[i]
        if escape:
            escape = False
            continue
        if ch == '\\' and in_string:
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth -= 1
            if depth == 0:
                return text[open_idx:i + 1]
    raise ValueError('unbalanced bracket block in Swift source')


def _swift_top_level_keys(block: str) -> list[tuple[str, int]]:
    """Given a `[ "key": value, ... ]` block, return [(key, position)] for keys
    at depth 1 only (nested object keys are ignored)."""
    keys = []
    depth = 0
    in_string = False
    escape = False
    string_start = None
    i = 0
    while i < len(block):
        ch = block[i]
        if escape:
            escape = False
        elif ch == '\\' and in_string:
            escape = True
        elif ch == '"':
            if in_string:
                # closing quote — is this a key at depth 1?
                if depth == 1:
                    j = i + 1
                    while j < len(block) and block[j] in ' \t\n':
                        j += 1
                    if j < len(block) and block[j] == ':':
                        keys.append((block[string_start + 1:i], string_start))
                in_string = False
            else:
                in_string = True
                string_start = i
        elif not in_string:
            if ch == '[':
                depth += 1
            elif ch == ']':
                depth -= 1
        i += 1
    return keys


def _swift_value_after_key(block: str, key_pos: int) -> str:
    """Return the raw value text following the `"key":` at key_pos in block."""
    colon = block.index(':', key_pos + 1)
    rest = block[colon + 1:]
    open_rel = rest.find('[')
    if open_rel == -1:
        # scalar value — up to next comma at this level (best effort)
        return rest.split(',', 1)[0].strip()
    inner = _swift_balanced_block(rest, open_rel)
    return rest[:open_rel] + inner


def _parse_parameters_block(params_block: str) -> tuple[list[str], list[str]]:
    """Parse a JSONValue `.object([ ... ])` parameters literal.
    Returns (property_names, required_names) at the TOP level of the schema."""
    props: list[str] = []
    required: list[str] = []
    for key, pos in _swift_top_level_keys(params_block):
        if key == 'properties':
            value = _swift_value_after_key(params_block, pos)
            open_idx = value.find('[')
            if open_idx != -1:
                inner = _swift_balanced_block(value, open_idx)
                props = [k for k, _ in _swift_top_level_keys(inner)]
        elif key == 'required':
            value = _swift_value_after_key(params_block, pos)
            required = _re.findall(r'\.string\("([^"]+)"\)', value)
    return props, required


def extract_ask_tools(aro_root=None) -> list[dict]:
    """Extract the real `aro ask` tool inventory from the Swift sources.

    Returns a list of dicts:
        {'name': str, 'description': str, 'params': [str],
         'required': [str], 'source_file': str}
    where `params` uses the NB11 convention of a trailing '?' for optional
    parameters (e.g. ['path', 'offset?', 'limit?']).

    Raises RuntimeError if no tool descriptors can be found — the training
    notebook must fail loudly rather than silently train on a stale copy.
    """
    root = Path(aro_root) if aro_root else ARO_ROOT
    swift_files = []
    for rel in _ASK_TOOL_SOURCE_DIRS:
        d = root / rel
        if d.is_dir():
            swift_files.extend(sorted(d.glob('*.swift')))
    if not swift_files:
        raise RuntimeError(
            f'aro ask tool sources not found under {root} '
            f'(looked in {", ".join(_ASK_TOOL_SOURCE_DIRS)})'
        )

    tools: list[dict] = []
    for path in swift_files:
        text = path.read_text(errors='replace')

        # Positions of named JSONValue parameter declarations, e.g.
        #   let params: JSONValue = .object([ ... ])
        decl_positions: list[tuple[int, str, int]] = []  # (pos, name, block_open_idx)
        for m in _re.finditer(r'let\s+(\w+)\s*:\s*JSONValue\s*=\s*\.object\(\s*\[', text):
            decl_positions.append((m.start(), m.group(1), m.end() - 1))

        descriptor_positions = [m.start() for m in _re.finditer(r'AskToolDescriptor\(', text)]
        for idx, pos in enumerate(descriptor_positions):
            end = descriptor_positions[idx + 1] if idx + 1 < len(descriptor_positions) else len(text)
            chunk = text[pos:end]

            name_m = _re.search(r'name:\s*"([^"]+)"', chunk)
            if not name_m:
                continue
            name = name_m.group(1)
            desc_m = _re.search(r'description:\s*"((?:[^"\\]|\\.)*)"', chunk)
            description = desc_m.group(1).replace('\\"', '"') if desc_m else ''

            props: list[str] = []
            required: list[str] = []
            inline_m = _re.search(r'parameters:\s*\.object\(\s*\[', chunk)
            if inline_m:
                block = _swift_balanced_block(chunk, inline_m.end() - 1)
                props, required = _parse_parameters_block(block)
            else:
                ref_m = _re.search(r'parameters:\s*(\w+)', chunk)
                if ref_m:
                    ref = ref_m.group(1)
                    candidates = [d for d in decl_positions if d[1] == ref and d[0] < pos]
                    if candidates:
                        _dpos, _dname, open_idx = candidates[-1]
                        block = _swift_balanced_block(text, open_idx)
                        props, required = _parse_parameters_block(block)

            params = [p if p in required else f'{p}?' for p in props]
            # required-first, then optional, preserving declaration order within each
            params.sort(key=lambda p: p.endswith('?'))
            tools.append({
                'name':        name,
                'description': description,
                'params':      params,
                'required':    required,
                'source_file': str(path.relative_to(root)),
            })

    if not tools:
        raise RuntimeError(
            f'No AskToolDescriptor definitions found in {len(swift_files)} Swift '
            f'files under {root} — the `aro ask` tool inventory could not be '
            f'extracted. Refusing to fall back silently.'
        )

    # Deduplicate by name (keep first occurrence) and sort for stable output.
    seen: dict[str, dict] = {}
    for t in tools:
        seen.setdefault(t['name'], t)
    return sorted(seen.values(), key=lambda t: t['name'])
