#!/usr/bin/env python3
"""36_full_application_pairs.py — recover the GEN_TODO failures as full
applications, graded by running them.

GEN_TODO.md holds 369 prompts that NB10 code generation failed on. Nearly every
one describes a whole application — a todo-list API, an inbox file classifier,
a UUID batch writer — and each is a prompt the model family has actually
failed on, which is the most valuable shape of instruction data there is. The
corpus's application rung is ~5% of the data; the repair rung got years of
attention and the model is correspondingly lopsided: better at fixing broken
ARO than at first-drafting working ARO.

This stage takes those prompts (and same-shaped prompts from a file the
operator hands it) and runs the loop the corpus otherwise never runs:

    generate → extract openapi.yaml + main.aro → `aro check`
             → repair attempts with the checker's own error fed back
             → `aro run`  (sandboxed, only when the program terminates alone)
             → `aro test` when the program carries colocated tests
             → keep only what runs, or what is honestly a server

Every kept pair is a complete multi-file application, and the full grade
record travels with it so an audit can tell a kept program from a merely
parsed one. Nothing is kept that the toolchain did not verify.

The stage needs the GPU and so runs then; it is dry-runnable now, and its
unit tests use a fake model with the real binary as the judge.

    python3 Train/script/36_full_application_pairs.py --dry-run
    python3 Train/script/36_full_application_pairs.py \
        --model models/distill/fused --n 120
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import aro_oracle  # noqa: E402
import config  # noqa: E402
import eval_metrics  # noqa: E402
import gen_todo  # noqa: E402
import sandbox  # noqa: E402

DEFAULT_TAG = 'NB36_recovery'
JOURNAL_NAME = 'nb36_journal.jsonl'

HTTP_RE = re.compile(r'\b(api|rest|endpoint|webhook|http)\b', re.IGNORECASE)

# The response shape NB21's own eval parses: contract first, then program.
OPENAPI_PROMPT = (
    'Write a complete ARO HTTP API for: {prompt}.\n'
    'Include openapi.yaml and main.aro with Application-Start and all '
    'operationId handlers.\n'
    'Format the answer as two fenced blocks: a ```yaml block holding the '
    'openapi.yaml contract and a ```aro block holding the application.')
PROGRAM_PROMPT = (
    'Write a complete ARO program for the following use case:\n\n'
    '{prompt}\n\n'
    'Answer with a single ```aro fenced block: an (Application-Start) entry '
    'point, every feature set the program needs, and its outputs. Every ARO '
    'statement ends with a period; strings concatenate with ++.')


def build_instruction(prompt: str) -> tuple[str, bool]:
    """(instruction, is_contract). HTTP-shaped prompts get the contract-first
    framing the corpus and NB21's eval both use; the rest ask for a runnable
    program outright."""
    if HTTP_RE.search(prompt or ''):
        return OPENAPI_PROMPT.format(prompt=prompt.strip()), True
    return PROGRAM_PROMPT.format(prompt=prompt.strip()), False


# The canonicalizer is env-gated (ARO_TRAIN_CANONICALIZE, default off) for
# the corpus, but this stage's job is to deposit canonical programs, so the
# generated code is canonicalized explicitly before the first check — an
# alias spelt at generation time must not be what the repair loop then
# preserves.
def _canonicalize(main_aro, openapi_yaml):
    if not config.canonicalize_enabled():
        return main_aro, openapi_yaml
    if main_aro:
        main_aro = config.canonicalize_aro_code(main_aro)
    return main_aro, openapi_yaml


def extract_answer(text: str) -> tuple[str | None, str | None]:
    """(main.aro, openapi.yaml) out of a generated answer."""
    yaml_blocks = re.findall(r'```yaml\w*\s*\n(.*?)```', text or '', re.DOTALL)
    openapi = next((b.strip() for b in yaml_blocks
                    if 'openapi' in b.lower()), None)
    blocks = aro_oracle.aro_blocks(text or '')
    if not blocks:
        return None, openapi
    return '\n\n'.join(b.strip() for b in blocks), openapi


def _extra_files(openapi_yaml):
    return {'openapi.yaml': openapi_yaml} if openapi_yaml else None


def repair_followup(instruction, error):
    """The text of a repair turn. The checker's own complaint is the signal;
    the ask is repeated so a distracted restart does not drift off-template."""
    return (
        'That program does not check clean yet. `aro check` says:\n\n'
        f'```\n{(error or "").strip()[:1500]}\n```\n\n'
        'Fix exactly that, and answer again with the same fenced blocks — '
        'nothing added and nothing removed but the repair. The original ask, '
        f'for reference:\n\n{instruction.strip()}')


def _attempt(chat_fn, instruction, attempts):
    """One prompt's generation + self-repair. On each repair attempt the
    checker's complaint is fed back verbatim, the way NB21 does it.

    Returns (main_aro, openapi) from the LAST attempt, whatever it was: how
    it graded is the caller's question.
    """
    system_prompt = getattr(chat_fn, 'system_prompt', None)
    messages = [{'role': 'user', 'content': instruction}]
    if system_prompt:
        messages = [{'role': 'system', 'content': system_prompt}] + messages
    output = chat_fn(messages)
    repair_turns = 0
    for _ in range(max(0, attempts - 1)):
        main_aro, _openapi = _canonicalize(*extract_answer(output))
        if main_aro:
            # The repair loop checks the program alone; a half-repaired
            # contract is itself one of the things worth reporting.
            ok, error = aro_oracle.check_block(main_aro)
            if ok is True:
                break
        else:
            error = 'no ```aro block in the answer'
        messages = messages + [
            {'role': 'assistant', 'content': output},
            {'role': 'user', 'content': repair_followup(instruction, error)},
        ]
        output = chat_fn(messages)
        repair_turns += 1
    main_aro, openapi = _canonicalize(*extract_answer(output))
    return main_aro, openapi, repair_turns


def _sandbox_run_and_test(main_aro, openapi_yaml, run_timeout):
    """(run_ok, run_out, test_ok, test_out), sandboxed (GitLab #804).

    run_ok None means the question was not asked — server or network shape
    that never terminates, or no entry point — which is not a failure.
    test_ok None means the program carries no tests.
    """
    run_ok = run_out = None
    if eval_metrics.is_safely_runnable(main_aro):
        try:
            ok, out = eval_metrics.run_aro_program(
                main_aro, openapi_yaml=openapi_yaml, timeout=run_timeout)
            run_ok, run_out = ok, (out or '')[:2000]
        except subprocess.TimeoutExpired:
            run_ok, run_out = False, f'timeout after {run_timeout}s'
    else:
        run_out = ('not a batch program (server or network shape, or no '
                   'Application-Start) — not run')
    test_ok = test_out = None
    if aro_oracle.has_tests(main_aro):
        try:
            r = sandbox.run_program_dir(
                ['aro', 'test'], main_aro, extra_files=_extra_files(openapi_yaml),
                timeout=30)
            test_ok = r.returncode == 0
            test_out = ((r.stdout or '') + (r.stderr or '')).strip()[:2000]
            if 'No tests found' in test_out:
                test_ok, test_out = None, 'no tests'
        except FileNotFoundError:
            test_ok, test_out = None, 'aro binary unavailable'
        except subprocess.TimeoutExpired:
            test_ok, test_out = False, 'timeout after 30s'
    return run_ok, run_out, test_ok, test_out


def grade_application(main_aro, openapi_yaml, run_timeout=10):
    """(accepted, reason, grade) — the decision this stage exists for.

    Parsing is the floor, not the bar: `check` must pass; a program that can
    run must actually run (the recorded failure class "valid but wrong" is
    exactly what `aro run` sees and `aro check` does not); colocated tests
    must pass; and, when the model emitted an openapi contract, its handlers
    must satisfy it.
    """
    if not (main_aro or '').strip():
        return False, 'no ```aro block in the output', {}
    check_ok, check_out = aro_oracle.check_block(
        main_aro, extra_files=_extra_files(openapi_yaml))
    if check_ok is not True:
        return False, f'check failed: {(check_out or "")[:200]}', {
            'check': check_ok, 'check_output': (check_out or '')[:2000],
            'aro_version': aro_oracle.aro_version(),
        }
    run_ok, run_out, test_ok, test_out = _sandbox_run_and_test(
        main_aro, openapi_yaml, run_timeout)
    grade = {
        'check': True,
        'run': run_ok, 'run_output': run_out,
        'test': test_ok, 'test_output': test_out,
        'aro_version': aro_oracle.aro_version(),
    }
    if run_ok is False:
        return False, f'passes check but does not run: {(run_out or "")[:200]}', grade
    if test_ok is False:
        return False, f'colocated tests fail: {(test_out or "")[:200]}', grade
    if openapi_yaml and config.check_openapi_contract(main_aro, openapi_yaml):
        # a non-empty list of contract problems, not a boolean (the checker's
        # own convention): the handlers must satisfy the contract, because
        # "the API answers to an operation nobody declared" is precisely the
        # failure NB12's contract-aware eval was built to catch.
        return False, 'openapi contract does not match the emitted handlers', grade
    return True, 'accepted', grade


def make_chat_fn(model_path, temperature=0.6, max_tokens=1600):
    """The model as a chat function, the way the notebooks build one.
    Returns None when mlx or the model itself cannot be loaded — the caller
    decides whether that is fatal or a dry run."""
    try:
        load, generate, make_sampler = config.ensure_mlx_lm()
        model, tokenizer = load(str(config.local_model_path(model_path)))
    except Exception as exc:                      # pragma: no cover — GPU only
        print(f'cannot load model {model_path}: {exc}', file=sys.stderr)
        return None
    sampler = make_sampler(temp=temperature)

    def chat(messages, max_toks=max_tokens):
        prompt = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True)
        return generate(model, tokenizer, prompt=prompt,
                        max_tokens=max_toks, sampler=sampler, verbose=False)

    chat.system_prompt = config.build_system_prompt()
    return chat


def recover(prompts, chat_fn, *, attempts=3, novel=None):
    """(rows, stats). One row per prompt that ended in a kept application.

    `novel` is a config.NearDuplicateIndex the caller seeds with the corpus;
    None disables the novelty check.
    """
    stats = {'prompts': 0, 'no_answer': 0, 'repair_turns': 0,
             'kept': 0, 'dropped_check': 0, 'dropped_run': 0,
             'dropped_tests': 0, 'dropped_contract': 0, 'dropped_novelty': 0,
             'by_kind': {}}
    rows = []
    for prompt in prompts:
        stats['prompts'] += 1
        if novel is not None and novel.seen(prompt):
            stats['dropped_novelty'] += 1
            continue
        instruction, is_contract = build_instruction(prompt)
        main_aro, openapi, repair_turns = _attempt(
            chat_fn, instruction, attempts)
        stats['repair_turns'] += repair_turns
        accepted, reason, grade = grade_application(main_aro, openapi)
        kind = 'contract' if is_contract else 'program'
        _journal(prompt, kept=accepted, reason=reason, kind=kind,
                 repair_turns=repair_turns)
        if not accepted:
            key = ('no_answer' if reason.startswith('no ```aro')
                   else 'dropped_run' if reason.startswith('passes check but does not run')
                   else 'dropped_tests' if reason.startswith('colocated tests')
                   else 'dropped_contract' if reason.startswith('openapi contract')
                   else 'dropped_check')
            stats[key] += 1
            continue
        kind = 'contract' if is_contract else 'program'
        stats['kept'] += 1
        stats['by_kind'][kind] = stats['by_kind'].get(kind, 0) + 1
        if openapi:
            output = (f'## openapi.yaml\n```yaml\n{openapi}\n```\n\n'
                      f'## main.aro\n```aro\n{main_aro.strip()}\n```')
        else:
            output = main_aro.strip()
        rows.append({
            'instruction': instruction,
            'output': output,
            'task_type': 'full_application',
            'source': 'gen_todo_recovery',
            '_gen_todo_recovery': {
                'prompt': prompt, 'kind': kind,
                'reason': reason, 'grade': grade, 'openapi': bool(openapi),
            },
        })
    return rows, stats


def _journal(prompt, kept, reason, kind, repair_turns):
    """One line per prompt, whatever the outcome — an interrupted run's
    record of what was tried, so nothing is tried twice by accident."""
    path = config.RUNS_DIR / JOURNAL_NAME
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, 'a') as fh:
            fh.write(json.dumps({'prompt': prompt, 'kept': kept,
                                 'reason': reason[:300], 'kind': kind,
                                 'repair_turns': repair_turns}) + '\n')
    except OSError:                               # pragma: no cover
        pass


def prompt_pool(source: Path | None, limit: int, seed: int) -> list[str]:
    """The prompts this run tries, shuffled once under a recorded seed."""
    import random
    if source:
        prompts = [ln.strip() for ln in source.read_text().splitlines()
                   if ln.strip()]
    else:
        prompts = [e['prompt'] for e in gen_todo.parse() if e['prompt']]
    random.Random(seed).shuffle(prompts)
    return prompts[:limit] if limit else prompts


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--prompts', type=Path, default=None,
                        help='prompt file (one per line); default GEN_TODO.md')
    parser.add_argument('--n', type=int, default=0,
                        help='try at most this many prompts (default all)')
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--attempts', type=int, default=3)
    parser.add_argument('--model', default=None,
                        help='model dir or HF id; default config.MODEL_ID')
    parser.add_argument('--temperature', type=float, default=0.6)
    parser.add_argument('--out', type=Path, default=None,
                        help='write pairs as jsonl here; the corpus is not touched')
    parser.add_argument('--no-save', action='store_true',
                        help='report only, write nothing')
    parser.add_argument('--dry-run', action='store_true',
                        help='print the pool and the framing, and stop')
    args = parser.parse_args(argv)

    prompts = prompt_pool(args.prompts, args.n, args.seed)
    print(f'prompt pool: {len(prompts)} prompts')
    if args.dry_run:
        for p in prompts[:5]:
            instruction, is_contract = build_instruction(p)
            print(f'  [{"contract" if is_contract else "program":8s}] '
                  f'{instruction.splitlines()[0][:110]}')
        return 0
    if not aro_oracle.aro_bin():
        print('no `aro` binary — nothing here is kept without it.',
              file=sys.stderr)
        return 2
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)

    chat_fn = make_chat_fn(args.model or config.MODEL_ID,
                           temperature=args.temperature)
    if chat_fn is None:
        return 2

    rows, stats = recover(prompts, chat_fn, attempts=args.attempts)
    print(stats)
    graded = (stats['dropped_check'] + stats['dropped_run']
              + stats['dropped_tests'] + stats['dropped_contract'])
    print(f'kept {stats["kept"]}/{stats["prompts"]} prompts '
          f'({graded} graded drops, {stats["dropped_novelty"]} near-duplicates)')
    if args.out:
        with open(args.out, 'w') as fh:
            for row in rows:
                fh.write(json.dumps(row) + '\n')
        print(f'wrote {len(rows)} pairs -> {args.out}')
        return 0
    if args.no_save:
        print('nothing written (--no-save)')
        return 0
    written = config.save_notebook_pairs(DEFAULT_TAG, rows)
    print(f'saved {written}/{len(rows)} pairs to the corpus ({DEFAULT_TAG})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
