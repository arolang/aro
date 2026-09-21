"""
Per-stage gate for the booster chain (GitLab #791).

Three LoRA adapters are fused in sequence onto the distilled student — material
(NB23), thinking (NB24), conversation (NB25) — and each `mlx_lm fuse` ran
unconditionally. NB24 computed `before` and `after` on a 120-item holdout,
drew a bar chart of the two, and then fused whichever it got. NB25's only
pre-fuse check was `_adapters_finite`, which catches NaN weights and nothing
else. NB23 had no before/after at all: its smoke test ran *after* the fuse, on
a model already written to disk and already the base for the next booster. The
only real gate was the 104-prompt sweep at the very end of the chain, by which
point three fuses had happened and a regression could not be attributed to any
one of them.

Two further sharp edges this module closes:

  * **Silent base substitution.** NB24 walks `material/fused`,
    `distill/student/fused`, and then falls through to `config.BASE_MODEL_ID` —
    the 30B mixture-of-experts teacher. A missing student directory therefore
    trains and fuses a 30B LoRA into what the rest of the pipeline calls "the
    student", announced by a `print`. NB25 anchors on `thinking/fused`, which
    by then is 30B, so the whole release chain changes architecture mid-way
    without anything failing. `resolve_base` refuses that substitution unless
    it is asked for explicitly.

  * **A learning rate ten times everybody else's.** NB23 runs at 1e-4 for up to
    1200 iterations over ~1069 curated rows — about four and a half epochs —
    against 1e-5 in NB24, NB25 and the iterative loop. That may well be
    deliberate, and this module does not change it; `check_learning_rate`
    reports it next to the gate result so a stage that loses points at ten
    times the rate is not a mystery.

The gate does not decide whether the *release* is good — that is the promotion
gate in NB27. It decides whether this one fuse is allowed to happen, which is
the decision nobody was making.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_stats  # noqa: E402


class FusionBlocked(RuntimeError):
    """Raised when a stage must not be fused."""


# A booster may cost at most this many points on any measured metric. Two
# points is well inside the noise of a 120-item holdout, so the gate blocks
# only losses that are both material and visible.
MAX_LOSS_POINTS = 2.0

# Reference learning rate for the booster stages. NB24, NB25 and the iterative
# loop all use this; NB23 is at 1e-4.
REFERENCE_LR = 1e-5
LR_RATIO_WARN = 3.0

# Set to 1 to allow a booster to anchor on a model outside its declared chain
# (normally the 30B base). Exists so a deliberate experiment is possible; it is
# not the default, because the default was how it happened by accident.
ALLOW_BASE_FALLBACK_ENV = 'ARO_TRAIN_ALLOW_BASE_FALLBACK'


# ── The gate ─────────────────────────────────────────────────────────────────

def evaluate_fuse(stage, before, after, n, max_loss_points=MAX_LOSS_POINTS,
                  metrics=None):
    """Should `stage`'s adapter be fused?

    before / after: {metric: percentage} as the booster notebooks already
    compute them (0-100, measured on the same holdout).
    n: the size of that holdout — the percentages are meaningless without it
    (GitLab #786), and a stage evaluated on fewer than
    `eval_stats.MIN_PROMPTS_PER_TASK` items is reported as underpowered.

    Returns a dict:
        {'allow': bool, 'reason': str, 'metrics': {...}, 'underpowered': bool}

    A metric blocks the fuse when it loses more than `max_loss_points` AND the
    two measurements are distinguishable at 95%. Both conditions matter: a
    9-point drop on 24 conversations is not evidence of anything, and a
    statistically clean 0.5-point drop is not worth refusing a release over.
    """
    keys = list(metrics) if metrics else sorted(set(before) & set(after))
    if not keys:
        return {'allow': False, 'reason': f'{stage}: no metrics in common '
                                          f'between before and after',
                'metrics': {}, 'underpowered': True}

    n = int(n)
    underpowered = n < eval_stats.MIN_PROMPTS_PER_TASK
    detail = {}
    blockers = []
    for k in keys:
        b, a = float(before[k]), float(after[k])
        delta = a - b
        kb = int(round(b / 100.0 * n))
        ka = int(round(a / 100.0 * n))
        verdict, _ = eval_stats.compare((kb, n), (ka, n))
        blocking = delta < -max_loss_points and verdict == 'worse'
        detail[k] = {
            'before': b, 'after': a, 'delta': delta,
            'verdict': verdict, 'blocking': blocking,
            'interval_before': eval_stats.wilson_interval(kb, n),
            'interval_after': eval_stats.wilson_interval(ka, n),
        }
        if blocking:
            blockers.append(f'{k} {b:.0f}% -> {a:.0f}% ({delta:+.0f} pts, '
                            f'distinguishably worse)')

    if blockers:
        return {
            'allow': False,
            'reason': (f'{stage}: refusing to fuse — ' + '; '.join(blockers)
                       + f' (n={n}, budget {max_loss_points:.0f} pts)'),
            'metrics': detail,
            'underpowered': underpowered,
        }

    moved = [f'{k} {d["delta"]:+.0f}' for k, d in sorted(detail.items())]
    reason = f'{stage}: fuse allowed — {", ".join(moved)} pts (n={n})'
    if underpowered:
        reason += (f'; WARNING n={n} is below the {eval_stats.MIN_PROMPTS_PER_TASK}-item '
                   f'floor, so only a collapse would have been visible')
    return {'allow': True, 'reason': reason, 'metrics': detail,
            'underpowered': underpowered}


def require_fuse_gate(stage, before, after, n, **kwargs):
    """`evaluate_fuse`, but raise when the answer is no.

    The booster notebooks call `subprocess.run(fuse_cmd, check=True)`, so a
    raise is the shape they already handle: the stage fails, the meta pipeline
    stops (STOP_ON_FAILURE), and nothing downstream anchors on a fused model
    that lost ground.
    """
    result = evaluate_fuse(stage, before, after, n, **kwargs)
    print(result['reason'])
    if not result['allow']:
        raise FusionBlocked(result['reason'])
    return result


# ── Base resolution ──────────────────────────────────────────────────────────

def resolve_base(stage, candidates, fallback=None, allow_fallback=None,
                 marker='config.json'):
    """First existing model in `candidates`, or a hard error.

    candidates: paths, in preference order, each expected to contain `marker`.
    fallback: what the notebook used to fall through to (normally
        `config.BASE_MODEL_ID`). Reaching it means the stage is about to train
        a different model from the one the release chain is built on, so it is
        refused unless `allow_fallback` (defaulting to the
        ARO_TRAIN_ALLOW_BASE_FALLBACK environment variable) says otherwise.

    Returns (path_str, reason).
    """
    for cand in candidates:
        cand = Path(cand)
        if (cand / marker).exists():
            return str(cand), f'{stage} base: {cand}'

    if allow_fallback is None:
        allow_fallback = os.environ.get(ALLOW_BASE_FALLBACK_ENV, '') == '1'

    tried = ', '.join(str(c) for c in candidates)
    if fallback is None:
        raise FusionBlocked(
            f'{stage}: no base model found. Tried: {tried}. '
            f'Run the upstream stage first.')
    if not allow_fallback:
        raise FusionBlocked(
            f'{stage}: none of the release-chain models exist ({tried}), and '
            f'falling back to {fallback} would train and fuse a DIFFERENT '
            f'model from the one the rest of the chain is built on — the '
            f'30B teacher rather than the distilled student. Run the upstream '
            f'stage, or set {ALLOW_BASE_FALLBACK_ENV}=1 to say you meant it.')
    return str(fallback), (f'{stage} base: {fallback} (FALLBACK — '
                           f'{ALLOW_BASE_FALLBACK_ENV}=1; this is not the '
                           f'release chain)')


# ── Hyperparameter sanity ────────────────────────────────────────────────────

def check_learning_rate(stage, lr, reference=REFERENCE_LR,
                        max_ratio=LR_RATIO_WARN):
    """Report a stage whose learning rate is far from the rest of the chain.

    Returns (ok, message). Does not block: an outlier rate may be intended,
    and the fuse gate is what catches the damage if it is not.
    """
    lr = float(lr)
    ratio = lr / float(reference)
    if ratio > max_ratio:
        return False, (f'{stage}: learning rate {lr:g} is {ratio:.0f}x the '
                       f'{reference:g} used by the other booster stages and the '
                       f'iterative loop. Not blocking, but if this stage loses '
                       f'points at the gate, start here.')
    if ratio < 1.0 / max_ratio:
        return False, (f'{stage}: learning rate {lr:g} is {1 / ratio:.0f}x '
                       f'LOWER than the {reference:g} used elsewhere; the '
                       f'stage may be training nothing.')
    return True, f'{stage}: learning rate {lr:g} is in line with the chain'


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse
    import json

    ap = argparse.ArgumentParser(
        description='Decide whether a booster stage may fuse (GitLab #791).')
    ap.add_argument('stage')
    ap.add_argument('--before', required=True,
                    help='JSON object of metric -> percentage')
    ap.add_argument('--after', required=True,
                    help='JSON object of metric -> percentage')
    ap.add_argument('--n', type=int, required=True,
                    help='holdout size the percentages were measured on')
    ap.add_argument('--max-loss', type=float, default=MAX_LOSS_POINTS)
    args = ap.parse_args(argv)

    result = evaluate_fuse(args.stage, json.loads(args.before),
                           json.loads(args.after), args.n,
                           max_loss_points=args.max_loss)
    for k, d in sorted(result['metrics'].items()):
        print(f'{k:>18}  {d["before"]:5.1f}% -> {d["after"]:5.1f}%  '
              f'{d["delta"]:+5.1f} pts  {d["verdict"]}'
              + ('  BLOCKING' if d['blocking'] else ''))
    print()
    print(result['reason'])
    return 0 if result['allow'] else 1


if __name__ == '__main__':
    raise SystemExit(_main())
