#!/usr/bin/env python3
"""Re-apply `mx.stop_gradient` to the MoE router indices in the installed
mlx-lm, so LoRA fine-tuning of Mixture-of-Experts models can compute a
gradient.

Why this exists
---------------
An MoE block picks its experts with `argpartition` and then reads the
matching gate values back with `take_along_axis`:

    inds   = mx.argpartition(gates, kth=-k, axis=-1)[..., -k:]
    scores = mx.take_along_axis(gates, inds, axis=-1)

`inds` descends from `gates`, which descends from a trainable parameter, so
MLX traces it as differentiable and tries to build a VJP for the *indices*
of the gather. It cannot, and the training step dies at the first backward
pass (the forward pass, and therefore validation, is unaffected):

    ValueError: [gather_axis] Cannot calculate VJP with respect to indices.
                Use stop_gradient on indices to stop gradients from being
                computed.

Every other MoE model in mlx-lm wraps the indices — `qwen2_moe.py` has
`inds = mx.stop_gradient(mx.argpartition(...))` — but `qwen3_moe.py` and
`qwen3_next.py` lost the call, which breaks LoRA on the Qwen3 MoE family we
fine-tune (Qwen3-Coder-30B-A3B). This is an upstream bug in mlx-lm 0.31.3;
selecting an expert is a discrete choice, so stopping the gradient there is
the mathematically correct behaviour, not a workaround that costs us signal.

`Train/requirements.txt` deliberately tracks the latest mlx-lm, so pinning
would forfeit the MoE Metal-kernel fixes we waited for (see ISSUE-MLX.md).
Instead `training.sh` calls this script after every `pip install`. It is
idempotent, and it becomes a silent no-op the moment upstream restores the
`stop_gradient`.

Usage:
    python3 Train/tools/patch_mlx_lm.py          # patch the running venv
    python3 Train/tools/patch_mlx_lm.py --check  # report only, exit 1 if unpatched
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The exact routing line as shipped by mlx-lm, and its patched form. Matching
# the whole statement (rather than just `argpartition`) keeps us from touching
# a file whose router upstream has since rewritten into a different shape.
UNPATCHED = re.compile(
    r"^(?P<indent>\s*)inds = (?P<expr>mx\.argpartition\(.*?\)\[\.\.\., -k:\])\s*$",
    re.MULTILINE,
)
PATCHED = "inds = mx.stop_gradient("

# Files known to route without stopping the gradient. Others are checked too;
# this list only documents what we expect to find.
KNOWN_AFFECTED = ("qwen3_moe.py", "qwen3_next.py")


def models_dir() -> Path:
    """The mlx_lm/models directory of the interpreter running this script."""
    try:
        import mlx_lm
    except ImportError:
        return Path()
    return Path(mlx_lm.__file__).resolve().parent / "models"


def patch_file(path: Path, *, dry_run: bool) -> bool:
    """Wrap the router indices in stop_gradient. True if the file needed it."""
    source = path.read_text()
    patched, count = UNPATCHED.subn(
        lambda m: f"{m.group('indent')}inds = mx.stop_gradient({m.group('expr')})",
        source,
    )
    if count == 0:
        return False
    if not dry_run:
        path.write_text(patched)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="report what would be patched and exit 1 if anything is unpatched",
    )
    args = parser.parse_args()

    models = models_dir()
    if not models.is_dir():
        # Not an Apple Silicon box, or MLX is not installed: nothing to do.
        # requirements.txt already marks mlx/mlx-lm as darwin-only.
        print("[patch-mlx-lm] mlx-lm not installed — nothing to patch.")
        return 0

    touched = []
    for path in sorted(models.glob("*.py")):
        if patch_file(path, dry_run=args.check):
            touched.append(path.name)

    if not touched:
        print(f"[patch-mlx-lm] MoE routers already stop gradients ({models}).")
        return 0

    verb = "needs" if args.check else "patched"
    print(f"[patch-mlx-lm] stop_gradient {verb}: {', '.join(touched)}")
    missing = [f for f in KNOWN_AFFECTED if f not in touched]
    if missing and args.check:
        print(f"[patch-mlx-lm] (already fixed upstream: {', '.join(missing)})")
    return 1 if args.check else 0


if __name__ == "__main__":
    sys.exit(main())
