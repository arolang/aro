#!/usr/bin/env bash
# Run the full ARO training pipeline from the command line.
#
# Executes Train/script/00_META_PIPELINE.ipynb headlessly via jupyter
# nbconvert. The META_PIPELINE itself runs every numbered notebook
# (01 → 24) in sequence, each in its own kernel, with live status output.
#
# Usage:
#   Train/training.sh                  # run the full pipeline
#   Train/training.sh --skip 03,07     # skip specific notebooks (forwarded
#                                        as SKIP env var read by the meta
#                                        notebook)
#   Train/training.sh --no-stop        # keep going past failing notebooks
#                                        (default: STOP_ON_FAILURE=True)
#   Train/training.sh --no-execute     # render the meta notebook unchanged
#                                        (smoke test the wiring without
#                                        burning GPU time)
#   Train/training.sh -- --help        # forward arbitrary nbconvert flags
#
# Outputs:
#   Train/script/run/outputs/00_META_PIPELINE.executed.ipynb   executed copy
#   Train/script/run/outputs/<NN>_*.executed.ipynb              per-step
#                                                                outputs
#   stdout/stderr of every notebook stream live to your terminal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NB_DIR="${SCRIPT_DIR}/script"
META_NB="${NB_DIR}/00_META_PIPELINE.ipynb"
OUT_DIR="${NB_DIR}/run/outputs"

if [[ ! -f "${META_NB}" ]]; then
  echo "error: META_PIPELINE not found at ${META_NB}" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"

# Parse our own flags before handing the remainder to nbconvert.
EXECUTE=1
SKIP=""
STOP_ON_FAILURE=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      SKIP="$2"
      shift 2
      ;;
    --no-stop)
      STOP_ON_FAILURE="False"
      shift
      ;;
    --no-execute)
      EXECUTE=0
      shift
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

# ── Virtualenv + requirements management ──────────────────────────────────
# Every run uses Train/.venv with the exact stack pinned in
# Train/requirements.txt. Creating a venv is idempotent: we recreate it
# only when missing; we run `pip install -r` every time but pip skips
# packages already at the right version, so the cost on warm runs is just
# the wheel-cache lookup.
#
# Set ARO_TRAIN_PYTHON to override the bootstrap python (the one that
# *creates* the venv). The venv's own python is used for everything else.

VENV_DIR="${SCRIPT_DIR}/.venv"
REQS_FILE="${SCRIPT_DIR}/requirements.txt"
BOOTSTRAP_PYTHON="${ARO_TRAIN_PYTHON:-python3}"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  echo "==> Creating venv at ${VENV_DIR}"
  "${BOOTSTRAP_PYTHON}" -m venv "${VENV_DIR}"
fi

PYTHON="${VENV_DIR}/bin/python"

# Always upgrade pip first — old pips silently drop newer wheel formats
# and confuse the error reporting later in the install.
"${PYTHON}" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true

if [[ -f "${REQS_FILE}" ]]; then
  echo "==> Installing/upgrading requirements from ${REQS_FILE#${SCRIPT_DIR}/}"
  "${PYTHON}" -m pip install --quiet --upgrade -r "${REQS_FILE}"
else
  echo "warning: ${REQS_FILE} missing; falling back to minimal install"
  "${PYTHON}" -m pip install --quiet nbconvert nbclient nbformat ipykernel
fi

# Register a Jupyter kernel inside the venv so nbconvert can resolve
# 'python3' to *our* interpreter instead of the system one. Idempotent.
"${PYTHON}" -m ipykernel install --user --name=aro-train --display-name='ARO Train' \
    >/dev/null 2>&1 || true

# Forward SKIP / STOP_ON_FAILURE into the meta notebook via env vars. The
# meta notebook reads them at runtime (the cell sets defaults only when
# the var is unset), so this is the seam for the CLI options above.
[[ -n "${SKIP}" ]] && export ARO_TRAIN_SKIP="${SKIP}"
[[ -n "${STOP_ON_FAILURE}" ]] && export ARO_TRAIN_STOP_ON_FAILURE="${STOP_ON_FAILURE}"

# Default to the venv kernel we just registered so notebook cells run
# with the requirements.txt environment, not the system one.
KERNEL_NAME="${KERNEL_NAME:-aro-train}"

EXEC_FLAGS=(
  --to notebook
  --ExecutePreprocessor.timeout=-1
  --ExecutePreprocessor.kernel_name="${KERNEL_NAME}"
  --output-dir="${OUT_DIR}"
  --output "00_META_PIPELINE.executed.ipynb"
)
if [[ "${EXECUTE}" -eq 1 ]]; then
  EXEC_FLAGS+=(--execute)
fi

echo "==> Running META_PIPELINE"
echo "    notebook:  ${META_NB}"
echo "    output:    ${OUT_DIR}/00_META_PIPELINE.executed.ipynb"
echo "    skip:      ${ARO_TRAIN_SKIP:-(none)}"
echo "    stop-on-failure: ${ARO_TRAIN_STOP_ON_FAILURE:-True (default)}"
echo "    kernel:    ${KERNEL_NAME}"
echo

cd "${SCRIPT_DIR}"
# `set -u` blows up on `"${EXTRA_ARGS[@]}"` when the array is empty.
# `${EXTRA_ARGS[@]+...}` only expands when the variable is set, which
# both keeps strict mode and preserves correct quoting per argument.
exec "${PYTHON}" -m jupyter nbconvert \
    "${EXEC_FLAGS[@]}" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    "${META_NB}"
