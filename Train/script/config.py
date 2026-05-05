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
import subprocess
import sys
from pathlib import Path

# ── Root paths ────────────────────────────────────────────────────────────────

SCRIPT_DIR           = Path(__file__).parent.resolve()
TRAIN_ROOT           = SCRIPT_DIR.parent              # .../Train
ARO_ROOT             = (TRAIN_ROOT / '..').resolve()   # .../ARO-Train
EXAMPLES_DIR         = ARO_ROOT / 'Examples'
BOOK_ROOT            = ARO_ROOT / 'Book'
ARO_APPLICATION_ROOT = Path('/Users/kris/Projects/ARO/ARO-Application').resolve()

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
toolchain. When modifying the user's project, use tools instead of guessing.

Key tools:
- read_file(path) — Read a file before suggesting changes
- write_file(path, content) — Create or overwrite a file
- edit_file(path, old_string, new_string) — Exact string replacement
- grep(pattern, path?) — Search files with regex
- aro_check(path) — Validate ARO syntax (always run after writing code)
- aro_run(path) — Execute an ARO application
- aro_test(path) — Run tests
- create_plugin(name, language, handle) — Scaffold a new plugin
- write_openapi(title, paths) — Generate an openapi.yaml contract

IMPORTANT: After writing or editing ARO code, ALWAYS validate with aro_check.
When debugging, read_file first to see the current state.

RESPONSE BEHAVIOUR:
- WRITE/CREATE/BUILD request: respond with valid ARO code in ```aro fences.
  If you have tool access, write the file and validate with aro_check.
- QUESTION about ARO: answer concisely with examples in ```aro fences.
- FIX/DEBUG request: read the code first (read_file), diagnose, apply fix
  (edit_file), then verify (aro_check).
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

def clean_notebook_pairs(notebook_tag: str) -> int:
    """
    Remove all pairs tagged with `notebook_tag` from PAIRS_FILE.
    Returns the number of pairs removed.
    Only acts when CLEAN_ON_RESTART is True.
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
            if rec.get('notebook') == notebook_tag:
                removed += 1
                continue
        except Exception:
            pass
        kept.append(line)

    if removed > 0:
        PAIRS_FILE.write_text('\n'.join(kept) + '\n' if kept else '')
        print(f'[{notebook_tag}] Cleaned {removed} pairs from previous run')
    return removed


def save_notebook_pair(notebook_tag: str, pair: dict) -> bool:
    """
    Append a single training pair to PAIRS_FILE with the notebook tag.
    The pair dict should contain at minimum `instruction`+`output` or `messages`.
    Returns True if written.
    """
    pair['notebook'] = notebook_tag
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(PAIRS_FILE, 'a') as f:
        f.write(json.dumps(pair) + '\n')
    return True


def save_notebook_pairs(notebook_tag: str, pairs: list[dict]) -> int:
    """
    Append multiple training pairs to PAIRS_FILE, all tagged with notebook_tag.
    Returns the number of pairs written.
    """
    if not pairs:
        return 0
    PAIRS_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(PAIRS_FILE, 'a') as f:
        for pair in pairs:
            pair['notebook'] = notebook_tag
            f.write(json.dumps(pair) + '\n')
    return len(pairs)
