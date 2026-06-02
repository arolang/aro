"""Corpus sanitiser used by NB01/NB04/NB10/NB14 to scrub training data.

Drops or rewrites samples that contain:
  * Markdown image / badge / link URLs scraped from README files
  * Tool function signatures (read_file, edit_file, aro_check, ...)
  * Raw HTML tags

The chat-template system-prompt baked into every NB17 sample is exempt —
the strict gate applies only to the assistant content. The system prompt
itself is cleaned at its source in config.build_system_prompt().
"""
from __future__ import annotations
import re

# Patterns that should never appear in an ARO assistant turn.
_IMAGE_RE = re.compile(
    r'!\[[^\]]*\]\(\s*https?://[^\s)]+\s*\)'
)
_BADGE_RE = re.compile(
    r'\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)'
)
_LINK_RE = re.compile(
    r'\[([^\]]+)\]\(\s*https?://[^\s)]+\s*\)'
)
_RAW_URL_RE = re.compile(
    r'\bhttps?://[\w./?#%=&+~:-]+'
)
_HTML_TAG_RE = re.compile(
    r'</?(?:img|a|div|span|p|br|h[1-6]|table|tr|td|th|ul|ol|li|strong|em|code|pre|center)(?:\s[^>]*)?/?>',
    re.IGNORECASE,
)
_TOOL_SIG_RE = re.compile(
    r'\b(read_file|write_file|edit_file|aro_check|aro_run|aro_test|create_plugin|write_openapi|list_files|grep)\s*\([^)]*\)'
)

# When we strip a link, replace it with its display text (or empty if none).
def _strip_link(m: re.Match) -> str:
    return m.group(1)

def sanitize_assistant_text(text: str) -> str:
    """Strip URLs, HTML, and tool signatures from a single assistant turn.

    Idempotent. Always returns a string. Leaves ARO fences and prose intact;
    only removes the polluting patterns. Used by NB01/04/10/14 before
    appending pairs and by NB16 dataset_assembly as the final cleaner.
    """
    if not text:
        return text
    # Order matters: badges before plain links, links before raw URLs.
    text = _IMAGE_RE.sub('', text)
    text = _BADGE_RE.sub('', text)
    text = _LINK_RE.sub(_strip_link, text)
    text = _RAW_URL_RE.sub('', text)
    text = _HTML_TAG_RE.sub('', text)
    text = _TOOL_SIG_RE.sub('', text)
    # Collapse the whitespace left behind.
    text = re.sub(r'[ \t]+\n', '\n', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


# ── Contamination scoring (used by the NB16 cleanliness gate) ─────────────

_GATE_PATTERNS = {
    'image_md':       _IMAGE_RE,
    'badge_md':       _BADGE_RE,
    'tool_signature': _TOOL_SIG_RE,
    'html_tag':       _HTML_TAG_RE,
    'raw_url':        _RAW_URL_RE,
}


def contamination_report(samples: list, get_text=None) -> dict:
    """Score a list of samples (or assistant-content strings). Returns a
    dict of pattern → count of samples containing at least one match.

    Pass `get_text=` to extract the relevant text per sample; default
    treats each sample as the text itself.
    """
    if get_text is None:
        get_text = lambda s: s if isinstance(s, str) else str(s)
    hits = {k: 0 for k in _GATE_PATTERNS}
    for s in samples:
        t = get_text(s) or ''
        for name, pat in _GATE_PATTERNS.items():
            if pat.search(t):
                hits[name] += 1
    return hits


def gate_check(samples: list, get_text=None, *,
               max_url_pct: float = 0.02,
               max_tool_pct: float = 0.005,
               max_html_pct: float = 0.005) -> None:
    """Raise RuntimeError if contamination exceeds thresholds.

    Defaults are tight (≤ 2% URL, ≤ 0.5% tool/html) — assistant outputs
    that contain markdown images or tool function signatures are corpus
    pollution by definition.
    """
    n = len(samples)
    if n == 0:
        return
    hits = contamination_report(samples, get_text)
    url_pct = (hits['image_md'] + hits['badge_md'] + hits['raw_url']) / n
    tool_pct = hits['tool_signature'] / n
    html_pct = hits['html_tag'] / n

    parts = [
        f'gate: url_pct={url_pct:.1%} (≤ {max_url_pct:.0%})',
        f'tool_pct={tool_pct:.1%} (≤ {max_tool_pct:.0%})',
        f'html_pct={html_pct:.1%} (≤ {max_html_pct:.0%})',
    ]
    breaches = []
    if url_pct > max_url_pct:
        breaches.append(f'URL contamination {url_pct:.1%} > {max_url_pct:.0%}')
    if tool_pct > max_tool_pct:
        breaches.append(f'tool-signature contamination {tool_pct:.1%} > {max_tool_pct:.0%}')
    if html_pct > max_html_pct:
        breaches.append(f'HTML-tag contamination {html_pct:.1%} > {max_html_pct:.0%}')

    print('  ' + '  ·  '.join(parts), flush=True)
    if breaches:
        raise RuntimeError(
            'CORPUS CLEANLINESS GATE FAILED:\n  - ' + '\n  - '.join(breaches) +
            '\n\nThe sanitiser in corpus_sanitize.py should remove these. If a '
            'pattern is leaking through, extend the regex set.'
        )
