"""
Promotion and acceptance policy for the iterative loop (GitLab #787).

The loop's own record says the best round was round 0 and the loop shipped
round 7 anyway. `round_results.json` from the 2026-08 run:

    round  -1   (the DPO model it started from)  0.000 / 0.500 / 0.083
    round   0                                    0.700
    rounds  1..7                                 0.467 0.617 0.333 0.283
                                                 0.500 0.533 0.517
    "best_round": 0,  "promotion_pass_rate": 0.667

and the file even carries its own regressions — debugging 0.50 to 0.25, code
generation 0.70 to 0.5167. Twelve hours of compute produced a model the loop
itself ranked below where it started, and the code carried it forward because
the promotion gate only printed a warning.

What this module changes:

  * **Promotion is a decision, not a warning.** `select_promotion` refuses to
    carry a round forward unless it is *distinguishably* better than the round
    the loop started from, judged by interval overlap (`eval_stats.compare`).
    On the recorded run no round qualifies, so the loop would have kept its
    starting model and said why — which is the correct outcome, and the one
    the recorded run's own numbers already implied.

  * **A round budget that matches what can be measured.** Eight rounds cost
    ~12 hours and produced a ranking across intervals that all overlap (the
    detectable effect at 60 prompts is about 25 points). `DEFAULT_MAX_ROUNDS`
    is 2, and `recommend_max_rounds` says how many rounds a given eval size
    could actually distinguish.

  * **Acceptance by execution, not by parse.** Rounds retrained on their own
    output filtered only by `aro check` — a program that parses but does not
    run, or one near-identical to something already in the corpus, was as good
    as any other. `accept_sample` requires the program to run when it is safely
    runnable, and to be novel against the corpus.

One claim in #787 no longer describes the code and is not re-fixed here: the
loop stopped chaining through the fused model some time ago (NB21 anchors
`TRAINING_BASE_MODEL = BASE_MODEL` and resumes from the previous round's
adapter; `fuse_model` still runs, but only for the downstream distillation and
packaging notebooks). The degradation is therefore not compounding fuses.

Pure-python apart from the optional execution check, which shells out to `aro`
through `eval_metrics`.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_stats  # noqa: E402


# How many rounds to run by default. The loop ran eight; at 60 prompts per
# round nothing under ~25 points was visible, so rounds 3 through 7 were
# compute spent on a ranking that could not be read. Two rounds is enough to
# tell "this stage helps" from "this stage does not" once the evaluation is at
# the #786 floor, and the hours saved are better spent on the benchmark.
DEFAULT_MAX_ROUNDS = 2

# A round must clear the starting model by a real margin, not by a draw.
# `select_promotion` uses interval overlap, so this is a second, absolute
# floor: even a statistically separated 1-point win is not worth a fuse.
MIN_PROMOTION_GAIN = 0.02

# Jaccard similarity against the existing corpus above which a generated
# sample teaches nothing new. Matches config.NearDuplicateIndex's default.
NOVELTY_THRESHOLD = 0.9


# ── Promotion ────────────────────────────────────────────────────────────────

def select_promotion(round_metrics, baseline=None, key='syntax_pass_rate',
                     n_key='eval_n', min_gain=MIN_PROMOTION_GAIN):
    """Which model should leave the loop?

    round_metrics: the loop's `round_metrics` list, chronological. Each entry
    needs `round`, `key` (a rate) and `n_key` (the prompts behind it).
    baseline: the entry to beat — defaults to round -1 when present (the model
    the loop started from), else round 0.

    Returns a dict:
        {'promote': bool, 'round': int|None, 'reason': str, 'comparisons': [...]}

    `promote` is False when no round is distinguishably better than the
    baseline. The caller must then keep the baseline model. This is the whole
    point: the 2026-08 run had `best_round: 0` recorded in the same file that
    recorded round 7 being carried forward.
    """
    trained = [m for m in round_metrics if m.get('round', -1) >= 0]
    if not trained:
        return {'promote': False, 'round': None,
                'reason': 'no trained rounds', 'comparisons': []}

    if baseline is None:
        pre = [m for m in round_metrics if m.get('round', 0) < 0]
        baseline = pre[0] if pre else trained[0]

    b_counts = _counts(baseline, key, n_key)
    if b_counts is None:
        return {'promote': False, 'round': None,
                'reason': (f'baseline round {baseline.get("round")} has no '
                           f'recorded sample size ({n_key}); a rate without an '
                           f'n cannot be compared (#786)'),
                'comparisons': []}

    comparisons = []
    winners = []
    for m in trained:
        c = _counts(m, key, n_key)
        if c is None:
            comparisons.append({'round': m.get('round'),
                                'verdict': 'unknown-n'})
            continue
        verdict, detail = eval_stats.compare(b_counts, c)
        gain = detail['candidate']['rate'] - detail['baseline']['rate']
        comparisons.append({
            'round': m.get('round'),
            'verdict': verdict,
            'gain': gain,
            'candidate': detail['candidate'],
            'baseline': detail['baseline'],
        })
        if verdict == 'better' and gain >= min_gain:
            winners.append((gain, m.get('round')))

    if not winners:
        best = max(comparisons, key=lambda c: c.get('gain', -1))
        return {
            'promote': False,
            'round': None,
            'reason': (
                f'no round is distinguishably better than the baseline '
                f'(round {baseline.get("round")}, '
                f'{_fmt(b_counts)}). Best attempt was round '
                f'{best.get("round")} at {best.get("gain", 0):+.1%}, verdict '
                f'{best.get("verdict")}. Keeping the baseline model.'),
            'comparisons': comparisons,
        }

    gain, round_num = max(winners)
    winner = next(m for m in trained if m.get('round') == round_num)
    w_counts = _counts(winner, key, n_key)
    tied = []
    for m in trained:
        if m.get('round') == round_num:
            continue
        c = _counts(m, key, n_key)
        if c and eval_stats.compare(w_counts, c)[0] == 'indistinguishable':
            tied.append(m.get('round'))
    later = [r for r in tied if r > round_num]
    return {
        'promote': True,
        'round': round_num,
        'reason': (f'round {round_num} beats the baseline by {gain:+.1%} with '
                   f'non-overlapping 95% intervals'),
        'tied_with_winner': tied,
        'wasted_rounds': later,
        'comparisons': comparisons,
    }


def promoted_model_dir(iterative_models_dir, round_results_path,
                       subdir='fused'):
    """The directory the promotion decision names, or None.

    NB22's `find_best_teacher` sorted `round_*/fused` by round number and took
    the last one — which is how round 7 was distilled while `best_round: 0`
    sat in `round_results.json` beside it. A function called
    `find_best_teacher` that returns the newest round is not selecting on
    quality at all; it is selecting on mtime by another name.

    Returns (path, reason). `path` is None when no round earned promotion or
    the record is unreadable, and the caller should fall back to the model the
    loop started from rather than to the last round.
    """
    import json
    from pathlib import Path as _Path

    results = _Path(round_results_path)
    if not results.exists():
        return None, f'no {results.name} — cannot tell which round is best'
    try:
        with open(results) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, f'{results.name} unreadable: {exc}'

    decision = select_promotion(data.get('rounds', []))
    if not decision['promote']:
        return None, decision['reason']
    cand = _Path(iterative_models_dir) / f'round_{decision["round"]}' / subdir
    if not (cand / 'config.json').exists():
        return None, (f'round {decision["round"]} was promoted but '
                      f'{cand} has no config.json')
    return str(cand), decision['reason']


def recommend_max_rounds(eval_n, expected_gain_per_round=0.05):
    """How many rounds an eval of this size can tell apart.

    A round that moves the model by `expected_gain_per_round` is invisible
    until the cumulative gain exceeds what `eval_n` can resolve. Returns the
    number of rounds it takes to get there — beyond which more rounds only add
    noise and hours. At eval_n = 60 and a hoped-for 5 points per round the
    answer is 5, and the loop ran 8; at the #786 floor of 100 it is 4.
    """
    eff = eval_stats.detectable_effect(int(eval_n))
    if eff is None or expected_gain_per_round <= 0:
        return DEFAULT_MAX_ROUNDS
    import math
    return max(1, int(math.ceil(eff / expected_gain_per_round)))


# ── Sample acceptance ────────────────────────────────────────────────────────

def accept_sample(code, *, novelty_index=None, run_program=None,
                  require_execution=True):
    """Should a generated sample join the corpus the next round trains on?

    code: the generated ARO program.
    novelty_index: a `config.NearDuplicateIndex` (or anything with
        `check_and_add`). None disables the novelty check.
    run_program: callable(code) -> (ok, output), normally
        `eval_metrics.run_aro_program`. None disables the execution check.
    require_execution: when False, a program that fails to run is kept with a
        note rather than rejected (for a dry run of the filter).

    Returns (accepted: bool, reason: str).

    The old filter was `aro check` alone, so a round could retrain on 405
    programs that parse and do nothing, or on 405 restatements of something
    already in the corpus. Both make the next round worse at no cost to the
    pass rate the loop was watching, which is one way a loop degrades while
    its own metric stays flat.
    """
    if not code or not code.strip():
        return False, 'empty'

    if novelty_index is not None:
        if novelty_index.check_and_add(code):
            return False, f'near-duplicate of the existing corpus (Jaccard >= {NOVELTY_THRESHOLD})'

    if run_program is not None:
        try:
            from eval_metrics import is_safely_runnable
        except ImportError:                      # pragma: no cover
            is_safely_runnable = lambda _c: False   # noqa: E731
        if is_safely_runnable(code):
            ok, out = run_program(code)
            if ok is None:
                # The binary is missing. Accepting unchecked is how a whole
                # round's output slipped past the filter before; say so.
                return (not require_execution), 'aro binary unavailable — not verified'
            if not ok:
                if require_execution:
                    return False, f'passes aro check but does not run: {out}'
                return True, f'does not run ({out}) — kept, execution not required'
    return True, 'accepted'


# ── helpers ──────────────────────────────────────────────────────────────────

def _counts(metrics, key, n_key):
    rate = metrics.get(key)
    n = metrics.get(n_key)
    if rate is None or not n:
        return None
    return int(round(rate * int(n))), int(n)


def _fmt(counts):
    k, n = counts
    lo, hi = eval_stats.wilson_interval(k, n)
    return f'{k}/{n} = {k / n:.3f} [{lo:.3f}, {hi:.3f}]'


# ── CLI ──────────────────────────────────────────────────────────────────────

def _main(argv=None):
    import argparse
    import json

    ap = argparse.ArgumentParser(
        description='Re-decide a finished iterative-loop run under the '
                    'promotion policy of GitLab #787.')
    ap.add_argument('results', help="the loop's round_results.json")
    ap.add_argument('--n', type=int, default=None,
                    help='prompts per round, for records written before the '
                         'loop recorded eval_n (the 2026-08 runs: 60)')
    args = ap.parse_args(argv)

    with open(args.results) as fh:
        data = json.load(fh)
    rounds = list(data.get('rounds', []))
    if args.n:
        for r in rounds:
            r.setdefault('eval_n', args.n)

    decision = select_promotion(rounds)
    print('recorded best_round:      ', data.get('best_round'))
    print('recorded promotion rate:  ', data.get('promotion_pass_rate'))
    print()
    print(f'{"round":>5}  {"rate":>6}  {"vs baseline":>12}  verdict')
    for c in decision['comparisons']:
        if c['verdict'] == 'unknown-n':
            print(f'{c["round"]:>5}  {"?":>6}  {"?":>12}  no sample size recorded')
            continue
        print(f'{c["round"]:>5}  {c["candidate"]["rate"]:>6.3f}  '
              f'{c["gain"]:>+11.1%}  {c["verdict"]}')
    print()
    print('promote:', decision['promote'],
          '' if decision['round'] is None else f'(round {decision["round"]})')
    print('reason: ', decision['reason'])
    if decision.get('wasted_rounds'):
        print(f'rounds after the winner that did not beat it: '
              f'{decision["wasted_rounds"]} — those hours bought nothing the '
              f'evaluation can see')
    if args.n:
        print()
        print(f'rounds this eval size could distinguish at 5 points each: '
              f'{recommend_max_rounds(args.n)} '
              f'(the run did {len([r for r in rounds if r.get("round", -1) >= 0])})')
    return 0


if __name__ == '__main__':
    raise SystemExit(_main())
