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

SCRIPT_DIR          = Path(__file__).parent.resolve()
ARO_ROOT            = (SCRIPT_DIR / '../../').resolve()
EXAMPLES_DIR        = ARO_ROOT / 'Examples'
BOOK_ROOT           = ARO_ROOT / 'Book'
ARO_APPLICATION_ROOT = Path('/Users/kris/Projects/ARO-Application').resolve()

# ── Output root (override this to redirect all data to a different location) ──
# SCRIPT_DIR
GLOBAL_OUT_DIR = Path('/Volumes/Models/data').resolve()

# ── Data directories ──────────────────────────────────────────────────────────

DATA_ROOT    = GLOBAL_OUT_DIR / '../data'
DATA_IN      = DATA_ROOT / '02_knowledge'   # primary knowledge base
DATA_DIR     = DATA_IN                       # alias used by some notebooks

KB_FILE      = DATA_IN / 'knowledge.json'
PAIRS_FILE   = DATA_IN / 'knowledge_pairs.jsonl'

ADAPTER_DIR  = DATA_ROOT / 'adapters'
ADAPTER_DIR.mkdir(parents=True, exist_ok=True)

WARM_ADAPTER = ADAPTER_DIR / 'warm_start'

WIKI_DIR     = DATA_ROOT / 'wiki'

# ── Model ─────────────────────────────────────────────────────────────────────
# Preferred: the published fine-tuned ARO model (bootstrapped from this pipeline).
# Fallback:  base Qwen3 used for initial training data generation.
# Change only these two lines to swap models across the whole pipeline.

PREFERRED_MODEL_ID = 'ARO-Lang/aro-coder-4bit'
FALLBACK_MODEL_ID  = 'mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit'


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
    Check HuggingFace for the fine-tuned ARO model.
    Returns (model_id, is_finetuned) so callers know whether to skip the warm adapter.
    """
    if _hf_model_exists(PREFERRED_MODEL_ID):
        print(f'Fine-tuned model found: {PREFERRED_MODEL_ID}')
        return PREFERRED_MODEL_ID, True
    print(f'Fine-tuned model not found on HuggingFace, using base: {FALLBACK_MODEL_ID}')
    return FALLBACK_MODEL_ID, False


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

def build_system_prompt(kb=None, max_syntax_chars=3000):
    """
    Build the standard ARO system prompt from the knowledge base.
    """
    kb = kb or load_knowledge()

    action_lines = []
    for a in kb.get('actions', []):
        verbs = ', '.join(a['verbs'][:3])
        preps = ', '.join(a.get('prepositions', [])[:3])
        action_lines.append(f'  {verbs:<30} prepositions: {preps}')
    action_ref = '\n'.join(action_lines)

    syntax_summary = kb.get('aro_syntax', '')[:max_syntax_chars]

    return f"""You are an expert ARO (Action Result Object) programmer.
ARO is a DSL where every statement is: Verb the <Result> preposition [the] <Object>.

ARO SYNTAX RULES:
{syntax_summary}

AVAILABLE ACTIONS (verb → prepositions):
{action_ref}

RULES:
- Every feature set: (Name: Business Activity) {{ statements }}
- Exactly one Application-Start per application
- Variables are immutable — use a new name for each transformation
- Articles (a/an/the) are optional everywhere
- String concatenation: <a> ++ <b>  (NOT +)
- For-each: For each <item> in <list> {{ ... }}
- Conditions: when <var> = value or when <expr>
- Return an <OK: status> ... to end a feature set

Output ONLY valid ARO code. No markdown fences unless asked."""
