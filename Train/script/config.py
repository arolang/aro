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
You have tools for reading/writing files, running commands, and invoking the ARO
toolchain. When modifying the user's project, invoke tools via the JSON
tool-call protocol — NEVER write tool names, function signatures, or any
non-ARO syntax inside ```aro fences. Tool names are runtime internals,
not part of the ARO language.

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
- WRITE/CREATE/BUILD request: respond with valid ARO code in ```aro fences.
  If you have tool access, write the file via the file-write tool and
  validate via the syntax-check tool.
- QUESTION about ARO: answer concisely with examples in ```aro fences. Do
  NOT mention tool function names in the answer — answer with the ARO
  verb the user actually needs (e.g. "use the `Read` action" not "use the
  `read_file` function").
- FIX/DEBUG request: load the existing code via the file-read tool,
  diagnose in prose, apply a fix via the file-edit tool, then verify via
  the syntax-check tool.
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
    Every pair is stamped with provenance metadata (issue #408) and the
    session's run config is recorded under data/runs/. Returns True if written.
    """
    pair['notebook'] = notebook_tag
    pair = _normalize_pair(pair)
    pair = stamp_provenance(pair, notebook_tag, generation_strategy, lineage)
    _ensure_run_recorded()
    _ensure_pairs_header()
    with open(PAIRS_FILE, 'a') as f:
        f.write(json.dumps(pair) + '\n')
    return True


def save_notebook_pairs(notebook_tag: str, pairs: list[dict],
                        generation_strategy=None) -> int:
    """
    Append multiple training pairs to PAIRS_FILE, all tagged with notebook_tag
    and stamped with provenance metadata (issue #408).
    Returns the number of pairs written.
    """
    if not pairs:
        return 0
    _ensure_run_recorded()
    _ensure_pairs_header()
    with open(PAIRS_FILE, 'a') as f:
        for pair in pairs:
            pair['notebook'] = notebook_tag
            pair = _normalize_pair(pair)
            pair = stamp_provenance(pair, notebook_tag, generation_strategy)
            f.write(json.dumps(pair) + '\n')
    return len(pairs)
