#!/usr/bin/env bash
# Run the full ARO training pipeline from the command line.
#
# Executes Train/script/00_META_PIPELINE.ipynb headlessly via jupyter
# nbconvert. The META_PIPELINE itself runs every numbered notebook
# (01 → 24) in sequence, each in its own kernel, with live status output.
#
# Usage:
#   Train/training.sh                  # run the full pipeline
#   Train/training.sh --from 17        # resume: run notebook 17 onward, skip
#                                        every notebook numbered below it.
#                                        Accepts "17" or "17_finetune".
#   Train/training.sh --skip 03,07     # skip specific notebooks (forwarded
#                                        as SKIP env var read by the meta
#                                        notebook). Combine with --from.
#   Train/training.sh --no-stop        # keep going past failing notebooks
#                                        (default: STOP_ON_FAILURE=True)
#   Train/training.sh --no-execute     # generate the meta script but don't
#                                        run it (smoke test the wiring without
#                                        burning GPU time)
#
# The meta notebook is converted to a plain script and run with `python -u`
# so per-notebook progress streams live to your terminal (▶ / ✅ done / a
# running done/failed/skipped tally after each notebook) instead of being
# buffered inside nbconvert until the whole run ends.
#
# Outputs:
#   Train/script/run/outputs/00_META_PIPELINE.gen.py           generated script
#   Train/script/run/outputs/<NN>_*.ipynb                       per-step executed
#                                                                notebooks
#   Train/script/run/outputs/<NN>_*.log                         per-step full logs
#   Per-notebook progress streams live to your terminal.

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
FROM=""
STOP_ON_FAILURE=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      SKIP="$2"
      shift 2
      ;;
    --from)
      # Start at notebook N: skip every notebook numbered below it. Accepts
      # "17" or "17_finetune" — only the leading number is used.
      FROM="${2%%_*}"
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
      sed -n '2,32p' "$0"
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
[[ -n "${FROM}" ]] && export ARO_TRAIN_FROM="${FROM}"
[[ -n "${STOP_ON_FAILURE}" ]] && export ARO_TRAIN_STOP_ON_FAILURE="${STOP_ON_FAILURE}"

# Default to the venv kernel we just registered so notebook cells run
# with the requirements.txt environment, not the system one. Export so
# child subprocesses (the meta notebook spawns one per child notebook
# via `jupyter nbconvert --execute`) inherit the same choice.
export KERNEL_NAME="${KERNEL_NAME:-aro-train}"

# Run the orchestrator as a plain, UNBUFFERED Python script instead of via
# `jupyter nbconvert --execute`. nbconvert captures every cell's stdout into
# the output .ipynb and never echoes it to the terminal, so the per-notebook
# progress (the run loop's ▶ / ✅ done / running done/failed/skipped tally)
# was invisible until the entire run finished — which looked like the pipeline
# "just stopping". Converting the meta notebook to a script and running it with
# `python -u` streams each line live. The CHILD notebooks are still executed
# via nbconvert from inside the orchestrator; their full output lands in
# ${OUT_DIR}/<NN>_*.log and their executed copies in ${OUT_DIR}.
META_PY="${OUT_DIR}/00_META_PIPELINE.gen.py"
"${PYTHON}" -m jupyter nbconvert --to script --stdout "${META_NB}" > "${META_PY}"

echo "==> Running META_PIPELINE (live)"
echo "    notebook:  ${META_NB}"
echo "    script:    ${META_PY}"
echo "    logs:      ${OUT_DIR}/<NN>_*.log  (per child notebook)"
echo "    from:      ${ARO_TRAIN_FROM:-(start)}"
echo "    skip:      ${ARO_TRAIN_SKIP:-(none)}"
echo "    stop-on-failure: ${ARO_TRAIN_STOP_ON_FAILURE:-True (default)}"
echo "    kernel:    ${KERNEL_NAME}"
echo

if [[ "${EXECUTE}" -eq 0 ]]; then
  echo "--no-execute: generated ${META_PY} without running it."
  exit 0
fi

# Run from the notebook directory (Train/script), NOT training.sh's own dir.
# The meta notebook derives SCRIPT_DIR/OUTPUT_DIR and the child-notebook paths
# from `Path('.')`, i.e. the process cwd. `nbconvert --execute` used to set the
# kernel cwd to the notebook's directory for us; running as a script we must cd
# there ourselves, or it looks for 01_corpus_collection.ipynb in the wrong place.
cd "${NB_DIR}"
# -u: unbuffered stdout/stderr so progress streams line-by-line. `exec` so the
# script's exit status becomes the script's, and Ctrl-C reaches it directly.
exec "${PYTHON}" -u "${META_PY}"
