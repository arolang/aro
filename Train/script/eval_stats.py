"""
Sample-size and confidence machinery for the evaluation (GitLab #786).

Every pass rate the pipeline reports is a proportion measured on a handful of
prompts, and until now it was reported as a bare number. `0.70` and `0.52` look
like a 18-point regression; on 60 prompts they are two draws whose 95 %
intervals overlap by a wide margin. The iterative loop's own record shows what
that costs: `round_results.json` has code-generation at
0.700 0.467 0.617 0.333 0.283 0.500 0.533 0.517 across eight rounds, a range of
41.7 points on a metric whose smallest expressible step is 1/60 = 1.7 points.
Every one of those rates is an exact sixtieth, so the set really was 60 prompts;
debugging and translation were twelfths — 12 prompts, 8.3 points per prompt.

This module gives the pipeline the three things it was missing:

  * an interval, so a rate is reported with the precision it actually has
    (`wilson_interval`, `proportion`);
  * a verdict that can say "indistinguishable" (`compare`, `converged_by_overlap`),
    replacing `train_utils.check_convergence`'s flat-delta test, whose 0.02
    tolerance is finer than the instrument it is applied to;
  * an answer to "how many prompts would I need" (`required_n`,
    `detectable_effect`, `sufficiency_report`), so an under-powered task set is
    a reported fact rather than a silent one.

Pure stdlib — no numpy, no scipy — so it imports on the slim CI image next to
the rest of `Train/script/tests/`.
"""

import math

# ── Evaluation budget ────────────────────────────────────────────────────────
# The floor below which a per-task rate is not a measurement. At n = 100 a rate
# near 0.5 carries a 95 % half-width of about 9.8 points, so a 10-point change
# is at the edge of visibility; at n = 12 the half-width is 26 points and
# nothing short of a total collapse can be seen.
MIN_PROMPTS_PER_TASK = 100

# Three samples per prompt at a non-zero temperature, so pass@1 and pass@3 are
# both available and a single unlucky decode is not recorded as a capability.
SAMPLES_PER_PROMPT = 3

# Fixed so two runs of the same evaluation draw the same prompts. Changing this
# invalidates comparisons against previously recorded numbers.
EVAL_SEED = 20260921

# `aro run` wall-clock budget for one generated program (GitLab #786).
EXEC_TIMEOUT_SECONDS = 10

# Standard normal quantiles, hard-coded so the module needs no scipy.
Z_95 = 1.959963984540054      # two-sided alpha = 0.05
Z_90 = 1.6448536269514722     # two-sided alpha = 0.10
Z_POWER_80 = 0.8416212335729143   # one-sided beta = 0.20


# ── Intervals ────────────────────────────────────────────────────────────────

def wilson_interval(successes, n, z=Z_95):
    """Wilson score interval for a binomial proportion.

    Preferred over the normal approximation because it stays inside [0, 1] and
    behaves at the extremes — `aro check` pass rates of 0/12 and 12/12 both
    occur in the recorded artefacts, and the normal interval is degenerate
    (zero width) for both.

    Returns (low, high). n == 0 gives the uninformative interval (0.0, 1.0).
    """
    n = int(n)
    if n <= 0:
        return 0.0, 1.0
    successes = int(successes)
    if not 0 <= successes <= n:
        raise ValueError(f'successes {successes} out of range for n {n}')
    p = successes / n
    denom = 1.0 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    low = 0.0 if successes == 0 else max(0.0, centre - half)
    high = 1.0 if successes == n else min(1.0, centre + half)
    return low, high


def proportion(successes, n, z=Z_95, label=None):
    """A measured rate with the precision it actually has.

    The dict this returns is what the evaluation should write instead of a bare
    float: `rate` for continuity, `low`/`high` so a reader can see whether two
    numbers differ, `resolution` (1/n) so a 0.02 convergence tolerance on a
    60-prompt set is visibly finer than one prompt.
    """
    n = int(n)
    low, high = wilson_interval(successes, n, z)
    out = {
        'successes': int(successes),
        'n': n,
        'rate': (successes / n) if n else None,
        'low': low,
        'high': high,
        'half_width': (high - low) / 2 if n else None,
        'resolution': (1.0 / n) if n else None,
        'underpowered': n < MIN_PROMPTS_PER_TASK,
    }
    if label is not None:
        out['label'] = label
    return out


def intervals_overlap(a, b):
    """Do two (low, high) intervals share any point?"""
    return not (a[1] < b[0] or b[1] < a[0])


def compare(baseline, candidate, z=Z_95):
    """Compare a candidate against a baseline. Each is (successes, n) or a
    `proportion` dict.

    Returns (verdict, detail) where the verdict is *about the candidate*:
    'better', 'worse', or 'indistinguishable' — the third being the one the
    pipeline could never say. Overlapping Wilson intervals is a conservative
    test (it under-reports significance relative to a two-proportion test),
    which is the right way round for a gate that must not wave through noise.
    """
    kb_, nb_ = _as_counts(baseline)
    kc, nc = _as_counts(candidate)
    i_base = wilson_interval(kb_, nb_, z)
    i_cand = wilson_interval(kc, nc, z)
    detail = {
        'baseline': proportion(kb_, nb_, z),
        'candidate': proportion(kc, nc, z),
        'overlap': intervals_overlap(i_base, i_cand),
    }
    if detail['overlap']:
        return 'indistinguishable', detail
    p_base = (kb_ / nb_) if nb_ else 0.0
    p_cand = (kc / nc) if nc else 0.0
    return ('better' if p_cand > p_base else 'worse'), detail


def _as_counts(m):
    if isinstance(m, dict):
        return int(m['successes']), int(m['n'])
    k, n = m
    return int(k), int(n)


# ── How many prompts would be needed ─────────────────────────────────────────

def required_n(p1, p2, alpha=0.05, power=0.80):
    """Prompts per arm needed to call a p1 → p2 change, at the given alpha and
    power. The standard two-proportion sample size:

        n = (z_a*sqrt(2*pbar*(1-pbar)) + z_b*sqrt(p1(1-p1)+p2(1-p2)))^2 / d^2

    Answers the question the iterative loop never asked: the loop's biggest
    claimed round-to-round move was 0.617 → 0.333, and calling even that
    reliably needs ~48 prompts; the 0.70 → 0.52 it shipped on needs ~118.
    Returns math.inf when p1 == p2.
    """
    d = abs(p1 - p2)
    if d == 0:
        return math.inf
    z_a = Z_95 if abs(alpha - 0.05) < 1e-9 else _z_two_sided(alpha)
    z_b = Z_POWER_80 if abs(power - 0.80) < 1e-9 else _z_one_sided(1 - power)
    pbar = (p1 + p2) / 2
    term = (z_a * math.sqrt(2 * pbar * (1 - pbar))
            + z_b * math.sqrt(p1 * (1 - p1) + p2 * (1 - p2)))
    return int(math.ceil(term * term / (d * d)))


def detectable_effect(n, p=0.5, alpha=0.05, power=0.80, tol=1e-4):
    """The smallest absolute change an n-prompt set can resolve around `p`.

    Inverts `required_n` by bisection. At n = 60 around p = 0.5 this is roughly
    a 25-point change, which is why the loop's 0.02 convergence tolerance and
    its 0.10 regression threshold were both measuring nothing.
    """
    lo, hi = 0.0, min(p, 1 - p) if min(p, 1 - p) > 0 else 0.5
    hi = max(hi, 0.01)
    while required_n(p, min(1.0, p + hi), alpha, power) > n:
        hi *= 2
        if hi >= 1.0:
            hi = 1.0
            break
    if required_n(p, min(1.0, p + hi), alpha, power) > n:
        return None            # not resolvable at any effect size for this n
    while hi - lo > tol:
        mid = (lo + hi) / 2
        if required_n(p, min(1.0, p + mid), alpha, power) <= n:
            hi = mid
        else:
            lo = mid
    return hi


def sufficiency_report(per_task_counts, floor=MIN_PROMPTS_PER_TASK):
    """Which task sets are too small to be read as measurements.

    per_task_counts: {task: n} or {task: (successes, n)}.
    Returns {task: {n, sufficient, shortfall, detectable_effect}}, and the
    caller is expected to print it next to the rates rather than print the
    rates alone.
    """
    report = {}
    for task, value in sorted(per_task_counts.items()):
        n = value[1] if isinstance(value, (tuple, list)) else int(value)
        eff = detectable_effect(n) if n > 0 else None
        report[task] = {
            'n': n,
            'sufficient': n >= floor,
            'shortfall': max(0, floor - n),
            'detectable_effect': eff,
        }
    return report


# ── pass@k ───────────────────────────────────────────────────────────────────

def pass_at_k(n_samples, n_correct, k):
    """Unbiased pass@k for one problem (Chen et al. 2021):

        pass@k = 1 - C(n - c, k) / C(n, k)

    With SAMPLES_PER_PROMPT = 3 the evaluation can report pass@1 (what a user
    sees on one try) and pass@3 (whether the capability is there at all)
    without pretending a single greedy decode measured either.
    """
    n, c, k = int(n_samples), int(n_correct), int(k)
    if n <= 0 or k <= 0:
        raise ValueError('n_samples and k must be positive')
    if not 0 <= c <= n:
        raise ValueError(f'n_correct {c} out of range for n_samples {n}')
    if k > n:
        raise ValueError(f'pass@{k} needs at least {k} samples, got {n}')
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def aggregate_pass_at_k(per_prompt, k):
    """Mean pass@k over problems. per_prompt: [(n_samples, n_correct), ...]."""
    rows = list(per_prompt)
    if not rows:
        return None
    return sum(pass_at_k(n, c, k) for n, c in rows) / len(rows)


# ── Convergence by interval overlap (replaces the 0.02 flat-delta test) ──────

def converged_by_overlap(series, patience=2, z=Z_95):
    """Has the loop stopped moving, judged at the precision it actually has?

    series: chronological [(successes, n), ...] or `proportion` dicts.
    Converged when the last `patience` consecutive rounds are each
    indistinguishable from their predecessor.

    This is the replacement for `train_utils.check_convergence`, whose
    `pass_tol=0.02` was smaller than one prompt on a 60-prompt set (1/60 =
    0.0167) and 4x smaller on a 12-prompt one (1/12 = 0.083): a tolerance the
    instrument cannot express, so the test was reporting the graduation of the
    ruler rather than anything about the model.

    Returns (converged, reason). An under-powered series never converges —
    with intervals that wide, everything overlaps everything and "flat" would
    only mean "unmeasured"; the reason says so.
    """
    rows = [_as_counts(s) for s in series]
    if len(rows) < patience + 1:
        return False, (f'not enough rounds ({len(rows)}) for convergence check '
                       f'(need {patience + 1})')
    recent = rows[-(patience + 1):]
    if any(n < MIN_PROMPTS_PER_TASK for _, n in recent):
        smallest = min(n for _, n in recent)
        return False, (f'cannot judge convergence: {smallest} prompts per round '
                       f'(floor {MIN_PROMPTS_PER_TASK}); every round overlaps '
                       f'every other at this sample size')
    verdicts = []
    for i in range(patience):
        verdict, _ = compare(recent[i], recent[i + 1], z)
        verdicts.append(verdict)
    if all(v == 'indistinguishable' for v in verdicts):
        return True, (f'converged: {patience} consecutive rounds '
                      f'indistinguishable at 95% '
                      f'({_fmt_series(recent)})')
    moved = [v for v in verdicts if v != 'indistinguishable']
    return False, (f'not converged — last {patience} transitions {verdicts} '
                   f'({len(moved)} real move(s)); {_fmt_series(recent)}')


def best_round_by_interval(series, z=Z_95):
    """The best round, and every round that ties with it.

    `train_utils.best_round` takes a plain max, which on a 60-prompt set picks
    whichever round got lucky. This returns (index_of_highest, [tied_indices])
    where the tied set is every round whose interval overlaps the highest —
    i.e. every round the evidence cannot separate from the winner. When that
    set is large, "best round" is not a finding.
    """
    rows = [_as_counts(s) for s in series]
    if not rows:
        return None, []
    rates = [(k / n if n else 0.0) for k, n in rows]
    top = max(range(len(rows)), key=lambda i: rates[i])
    tied = [i for i in range(len(rows))
            if compare(rows[i], rows[top], z)[0] == 'indistinguishable']
    return top, tied


def _fmt_series(rows):
    return ', '.join(f'{k}/{n}=' + f'{k / n:.3f}' if n else 'n/a' for k, n in rows)


# ── alpha/beta quantiles for non-default alpha/power ─────────────────────────

def _z_two_sided(alpha):
    return _inv_norm_cdf(1 - alpha / 2)


def _z_one_sided(beta):
    return _inv_norm_cdf(1 - beta)


def _inv_norm_cdf(p):
    """Acklam's rational approximation to the standard normal quantile.
    Accurate to ~1e-9 over (0, 1) — ample for sample-size arithmetic, and it
    keeps this module free of scipy."""
    if not 0.0 < p < 1.0:
        raise ValueError('p must be in (0, 1)')
    a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
         1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
         6.680131188771972e+01, -1.328068155288572e+01]
    c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
         -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
         3.754408661907416e+00]
    plow, phigh = 0.02425, 1 - 0.02425
    if p < plow:
        q = math.sqrt(-2 * math.log(p))
        return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / \
               ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    if p > phigh:
        q = math.sqrt(-2 * math.log(1 - p))
        return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / \
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    q = p - 0.5
    r = q * q
    return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q / \
           (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)


# ── CLI: read a loop record and say what it can actually support ─────────────

def _main(argv=None):
    import argparse
    import json

    ap = argparse.ArgumentParser(
        description='Report what an evaluation record is powered to detect '
                    '(GitLab #786).')
    ap.add_argument('results',
                    help="the loop's round_results.json")
    ap.add_argument('--n', type=int, default=None,
                    help='prompts per round, for records written before '
                         '`eval_n` was recorded (the 2026-08 runs: 60)')
    args = ap.parse_args(argv)

    with open(args.results) as fh:
        data = json.load(fh)
    rounds = [r for r in data.get('rounds', []) if r.get('round', -1) >= 0]
    if not rounds:
        print('no trained rounds in', args.results)
        return 1

    series = []
    for r in rounds:
        n = args.n or r.get('eval_n')
        if not n:
            print('no eval_n recorded and --n not given: the sample size behind '
                  'these rates is unknown, which is the whole problem (#786)')
            return 2
        series.append((round(r['syntax_pass_rate'] * n), n))

    print(f'{len(series)} rounds, n={series[0][1]} prompts each')
    print()
    print(f'{"round":>5}  {"rate":>6}  {"95% interval":>18}   vs round 0')
    for i, (k, n) in enumerate(series):
        prop = proportion(k, n)
        verdict = '-' if i == 0 else compare(series[0], (k, n))[0]
        print(f'{rounds[i]["round"]:>5}  {prop["rate"]:>6.3f}  '
              f'[{prop["low"]:.3f}, {prop["high"]:.3f}]   {verdict}')

    top, tied = best_round_by_interval(series)
    print()
    print(f'highest rate: round {rounds[top]["round"]}')
    print('rounds indistinguishable from it: '
          f'{[rounds[i]["round"] for i in tied]}')
    if len(tied) > 1:
        print('  "best round" is not a finding here: the evidence cannot '
              'separate these.')
    conv, reason = converged_by_overlap(series)
    print()
    print(f'convergence (interval overlap): {conv}, {reason}')
    eff = detectable_effect(series[0][1])
    print()
    print(f'smallest change this set can resolve at p=0.5: {eff:.1%}')
    print('prompts needed to call the 0.700 to 0.517 this run shipped on: '
          f'{required_n(0.700, 0.517)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(_main())
