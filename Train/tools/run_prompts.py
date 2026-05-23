#!/usr/bin/env python3
"""Run every prompt in `prompts.txt` through `aro ask -v` and classify the
result.

For each prompt we save one JSON file under `Train/Material/`:

  Train/Material/raw/<slug>.json          raw run record (always written)

After the run, prompts whose result matches our expectations are appended
to `correct.log` and prompts whose result is wrong land in
`Train/Material/<slug>.json` as a training pair:

  {
    "prompt":   "<the user prompt>",
    "actual":   "<what aro ask printed>",
    "expected": "<canonical answer from canonical.json, or null if unknown>",
    "aro_check_passed": true|false|null,
    "judge":    "ok" | "no_code" | "fails_aro_check" | "hallucinated_request" | ...
  }

Idempotent / resumable: skips prompts whose raw JSON already exists.

Usage:
    python3 run_prompts.py                  # full run
    python3 run_prompts.py --limit 5        # first 5 prompts only
    python3 run_prompts.py --aro <path>     # use a specific aro binary
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
MATERIAL_DIR = TOOLS_DIR.parent / 'Material'
PROMPTS = MATERIAL_DIR / 'prompts.txt'
CANONICAL = MATERIAL_DIR / 'canonical.json'
RAW_DIR = MATERIAL_DIR / 'raw'
CORRECT_LOG = MATERIAL_DIR / 'correct.log'

RAW_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_ARO = str(TOOLS_DIR.parent.parent / '.build/release/aro')

# Words that, if absent from the prompt, indicate the model shouldn't be
# inventing an HTTP request context. Used by the "hallucinated request"
# check.
_HTTP_HINTS = re.compile(
    r'\b(http|api|route|endpoint|get|post|put|patch|delete|request|response|openapi|server|webhook|url|fetch|call)\b',
    re.IGNORECASE,
)
_REQUEST_USAGE = re.compile(r'<request:\s*\w+>|<pathParameters:\s*\w+>')

# `(Name: Activity) {` — the feature-set header. ARO requires every code
# block to live inside one.
_FEATURE_SET = re.compile(r'\([\w\- ]+:\s*[\w\- ]+(?:\s+takes\s+<[\w\-]+>)?\s*\)\s*\{')

# missing-space-before-`<` bug — caught by the runtime stripper too, but
# we still want to flag it in the raw output so we know the model produced it.
_MISSING_SPACE = re.compile(r'\w<[a-z]')


def slugify(s: str) -> str:
    s = re.sub(r'\W+', '_', s.strip().lower()).strip('_')
    return s[:60] or 'prompt'


def extract_aro_blocks(text: str):
    return [b.strip() for b in re.findall(r'```aro\n(.*?)```', text, re.DOTALL) if b.strip()]


def run_aro_check(code: str, aro: str):
    if not code.strip():
        return None
    try:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'main.aro').write_text(code)
            r = subprocess.run([aro, 'check', tmp],
                               capture_output=True, text=True, timeout=15)
            return r.returncode == 0
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return False


def judge(prompt: str, final_text: str, aro_check_ok):
    """Return (verdict, reason). Verdict is 'ok', 'needs_review', or one of
    several specific failure tags. Conservative: 'needs_review' for anything
    structural but unparseable rather than dropping silently."""
    if not final_text or not final_text.strip():
        return 'no_output', 'final answer was empty'

    blocks = extract_aro_blocks(final_text)
    if not blocks:
        # Some prompts deserve prose-only answers ("how to" questions can
        # be answered in words). Without code we can't run aro check, so
        # flag for review.
        return 'no_code', 'no ```aro``` block in final output'

    code = '\n\n'.join(blocks)

    if not _FEATURE_SET.search(code):
        return 'no_feature_set', 'code block is missing the (Name: Activity) { ... } wrapper'

    if aro_check_ok is False:
        return 'fails_aro_check', 'extracted code does not pass `aro check`'

    if _MISSING_SPACE.search(code):
        return 'whitespace_bug', "code contains a missing-space-before-`<` artefact"

    prompt_lower = prompt.lower()
    if not _HTTP_HINTS.search(prompt_lower) and _REQUEST_USAGE.search(code):
        return 'hallucinated_request', 'code uses <request: …> / <pathParameters: …> when the prompt never asked about HTTP'

    if aro_check_ok is None:
        return 'needs_review', 'aro binary unavailable — could not verify syntax'

    return 'ok', 'passes structural checks + aro check'


def run_one(prompt: str, aro: str, canonical: dict, timeout: int):
    slug = slugify(prompt)
    raw_path = RAW_DIR / f'{slug}.json'
    if raw_path.exists():
        return json.loads(raw_path.read_text()), True  # already done

    t0 = time.time()
    try:
        proc = subprocess.run(
            [aro, 'ask', '-v', prompt],
            capture_output=True, text=True, timeout=timeout,
            env={**os.environ, 'ARO_ASK_VERBOSE': '1'},
        )
        final = proc.stdout
        stderr = proc.stderr
        rc = proc.returncode
        timed_out = False
    except subprocess.TimeoutExpired as e:
        final = (e.stdout or b'').decode('utf-8', errors='replace') if isinstance(e.stdout, bytes) else (e.stdout or '')
        stderr = (e.stderr or b'').decode('utf-8', errors='replace') if isinstance(e.stderr, bytes) else (e.stderr or '')
        rc = -1
        timed_out = True

    elapsed = round(time.time() - t0, 1)

    # Pull the model's raw output (the `=== model raw output === ... === end raw ===`
    # block printed by aro ask -v) out of stderr.
    raw_m = re.search(
        r'=== model raw output ===\n(.*?)\n=== end raw ===',
        stderr, re.DOTALL,
    )
    model_raw = raw_m.group(1) if raw_m else ''

    blocks = extract_aro_blocks(final)
    code = '\n\n'.join(blocks) if blocks else ''
    aro_ok = run_aro_check(code, aro) if code else None
    verdict, reason = judge(prompt, final, aro_ok)

    record = {
        'prompt': prompt,
        'slug': slug,
        'actual': final.rstrip(),
        'model_raw': model_raw.rstrip(),
        'aro_check_passed': aro_ok,
        'judge': verdict,
        'judge_reason': reason,
        'expected': canonical.get(prompt),
        'elapsed_s': elapsed,
        'returncode': rc,
        'timed_out': timed_out,
    }
    raw_path.write_text(json.dumps(record, indent=2, ensure_ascii=False) + '\n')
    return record, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--aro', default=DEFAULT_ARO,
                    help=f'path to the aro binary (default: {DEFAULT_ARO})')
    ap.add_argument('--limit', type=int, default=None,
                    help='only run the first N prompts')
    ap.add_argument('--timeout', type=int, default=300,
                    help='per-prompt timeout in seconds (default 300)')
    args = ap.parse_args()

    if not Path(args.aro).exists():
        print(f'error: aro binary not found at {args.aro}', file=sys.stderr)
        sys.exit(2)

    prompts = [p.strip() for p in PROMPTS.read_text().splitlines() if p.strip()]
    canonical = json.loads(CANONICAL.read_text())

    if args.limit:
        prompts = prompts[:args.limit]

    print(f'running {len(prompts)} prompts against {args.aro}', flush=True)
    correct, wrong, skipped, no_canonical = 0, 0, 0, 0

    for i, prompt in enumerate(prompts, 1):
        rec, cached = run_one(prompt, args.aro, canonical, args.timeout)
        tag = 'cached' if cached else f'{rec["elapsed_s"]}s'
        verdict = rec['judge']

        if verdict == 'ok':
            correct += 1
            with open(CORRECT_LOG, 'a') as f:
                f.write(json.dumps({
                    'prompt': rec['prompt'],
                    'judge_reason': rec['judge_reason'],
                }) + '\n')
            print(f'[{i:3}/{len(prompts)}] ok            ({tag}) — {prompt[:60]}', flush=True)
        else:
            wrong += 1
            # Write the training-pair file in Material/<slug>.json
            pair = {
                'prompt': rec['prompt'],
                'actual': rec['actual'],
                'expected': rec['expected'],
                'aro_check_passed': rec['aro_check_passed'],
                'judge': rec['judge'],
                'judge_reason': rec['judge_reason'],
                'has_canonical_answer': rec['expected'] is not None,
            }
            (MATERIAL_DIR / f'{rec["slug"]}.json').write_text(
                json.dumps(pair, indent=2, ensure_ascii=False) + '\n')
            if rec['expected'] is None:
                no_canonical += 1
            print(f'[{i:3}/{len(prompts)}] {verdict:18} ({tag}) — {prompt[:60]}', flush=True)

        if cached:
            skipped += 1

    print(f'\n=== summary ===', flush=True)
    print(f'  total:                 {len(prompts)}', flush=True)
    print(f'  correct (logged):      {correct}', flush=True)
    print(f'  wrong (with canonical): {wrong - no_canonical}', flush=True)
    print(f'  wrong (no canonical):  {no_canonical}  ← fill in canonical.json then rerun', flush=True)
    print(f'  cached / skipped:      {skipped}', flush=True)


if __name__ == '__main__':
    main()
