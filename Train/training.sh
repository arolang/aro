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

# Pick a python that has jupyter installed. Prefer the project's venv if
# one exists; otherwise use system python3.
PYTHON="${PYTHON:-python3}"
if ! "${PYTHON}" -c 'import jupyter' 2>/dev/null; then
  echo "Jupyter not found in ${PYTHON}; installing nbconvert + nbclient + nbformat..."
  "${PYTHON}" -m pip install -q nbconvert nbclient nbformat ipykernel
fi

# Forward SKIP / STOP_ON_FAILURE into the meta notebook via env vars. The
# meta notebook reads them at runtime (the cell sets defaults only when
# the var is unset), so this is the seam for the CLI options above.
[[ -n "${SKIP}" ]] && export ARO_TRAIN_SKIP="${SKIP}"
[[ -n "${STOP_ON_FAILURE}" ]] && export ARO_TRAIN_STOP_ON_FAILURE="${STOP_ON_FAILURE}"

# Pick the kernel name. nbconvert defaults to 'python3'; if you maintain a
# named project kernel, set KERNEL_NAME=<name> before invoking.
KERNEL_NAME="${KERNEL_NAME:-python3}"

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
exec "${PYTHON}" -m jupyter nbconvert "${EXEC_FLAGS[@]}" "${EXTRA_ARGS[@]}" "${META_NB}"
