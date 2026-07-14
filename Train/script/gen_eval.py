"""
Generation-based syntax/alignment eval for a model (+ optional adapter).

Used as a subprocess (so the model is unloaded on exit) by:
  - NB05 warm-start ablation (issue #393): base vs base+warm-adapter on a
    fixed prompt set — `aro check` pass rate + semantic-alignment rate.
  - NB17 hyperparameter sweep (issue #411): syntax pass rate per sweep
    variant adapter.

    python gen_eval.py --model <id-or-path> [--adapter <dir>] \
        --prompts prompts.json --out result.json \
        [--max-tokens 800] [--temp 0.0] [--judge]

`--prompts` is a JSON list of prompt strings (or {"prompt": ...} dicts).
Output JSON: {"n", "checked", "pass_rate", "alignment_rate", "results": [...]}
pass_rate is over prompts where `aro check` could run (None when the aro
binary is missing). With --judge, the loaded model itself judges whether
each generated program addresses its instruction (conservative gate — same
prompt as config.semantic_alignment_check).
"""

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from eval_metrics import extract_openapi_and_aro, aro_check_dir  # noqa: E402


def _load_prompts(path):
    with open(path) as f:
        data = json.load(f)
    prompts = []
    for item in data:
        if isinstance(item, str):
            prompts.append(item)
        elif isinstance(item, dict) and item.get('prompt'):
            prompts.append(item['prompt'])
    return prompts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', required=True)
    ap.add_argument('--adapter', default=None)
    ap.add_argument('--prompts', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--max-tokens', type=int, default=800)
    ap.add_argument('--temp', type=float, default=0.0)
    ap.add_argument('--judge', action='store_true',
                    help='also compute semantic-alignment rate (self-judge)')
    ap.add_argument('--system-prompt-file', default=None,
                    help='file containing the system prompt; defaults to '
                         'config.build_system_prompt()')
    args = ap.parse_args(argv)

    from mlx_lm import load, generate as mlx_generate
    from mlx_lm.sample_utils import make_sampler
    import config as cfg

    prompts = _load_prompts(args.prompts)
    if args.system_prompt_file:
        system_prompt = Path(args.system_prompt_file).read_text()
    else:
        system_prompt = cfg.build_system_prompt()

    if args.adapter:
        print(f'Loading {args.model} + adapter {args.adapter} ...', flush=True)
        model, tokenizer = load(args.model, adapter_path=args.adapter)
    else:
        print(f'Loading {args.model} (no adapter) ...', flush=True)
        model, tokenizer = load(args.model)

    sampler = make_sampler(temp=args.temp)

    def chat(messages, max_tokens=args.max_tokens, temp=None):
        # `temp` accepted for config.semantic_alignment_check compatibility;
        # the sampler is fixed per process.
        text = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True)
        return mlx_generate(model, tokenizer, prompt=text,
                            max_tokens=max_tokens, sampler=sampler,
                            verbose=False)

    results = []
    n_pass, n_checked, aro_missing = 0, 0, False
    n_aligned, n_judged = 0, 0

    for i, prompt in enumerate(prompts):
        output = chat([
            {'role': 'system', 'content': system_prompt},
            {'role': 'user', 'content': prompt},
        ])
        openapi, main_aro = extract_openapi_and_aro(output)
        row = {'prompt': prompt[:200], 'has_code': bool(main_aro)}

        if main_aro:
            ok = aro_check_dir(main_aro, openapi)
            row['aro_check'] = ok
            if ok is None:
                aro_missing = True
            else:
                n_checked += 1
                if ok:
                    n_pass += 1
        else:
            row['aro_check'] = False
            n_checked += 1

        if args.judge:
            aligned, reason = cfg.semantic_alignment_check(prompt, output, chat)
            row['aligned'] = aligned
            row['judge'] = reason[:160]
            n_judged += 1
            if aligned:
                n_aligned += 1

        results.append(row)
        print(f'  [{i + 1}/{len(prompts)}] code={row["has_code"]} '
              f'check={row.get("aro_check")} aligned={row.get("aligned", "-")}',
              flush=True)

    out = {
        'model': args.model,
        'adapter': args.adapter,
        'n': len(prompts),
        'checked': n_checked,
        'pass_rate': round(n_pass / n_checked, 4) if n_checked else None,
        'alignment_rate': round(n_aligned / n_judged, 4) if n_judged else None,
        'aro_missing': aro_missing,
        'results': results,
    }
    with open(args.out, 'w') as f:
        json.dump(out, f, indent=2)
    print(f'\npass_rate={out["pass_rate"]}  alignment_rate={out["alignment_rate"]}')
    print(f'Wrote {args.out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
