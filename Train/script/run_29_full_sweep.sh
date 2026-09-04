#!/bin/bash
# run_29_full_sweep.sh — launch the full NB29 documentation sweep, unattended.
#
# What it runs: 29_multimodel_doc_qa.py over ALL of Book/, Proposals/ and the
# wiki (~3,173 sections) with both local models (Mistral-Small-24B +
# Qwen3.6-27B). Expect 26-44 hours. The run is RESUMABLE: killing it costs at
# most the section in flight — just launch this script again and it continues
# from data/29_doc_qa/progress.jsonl.
#
# What this wrapper adds over calling the script directly:
#   caffeinate -is   the machine must not sleep for two days
#   nohup + log      survives the terminal closing; output in sweep.log
#   date-stamped     start/end recorded in the log
#
# Monitor:
#   tail -f Train/data/29_doc_qa/sweep.log
#   wc -l Train/data/29_doc_qa/generated.jsonl     # survivors so far
#   wc -l Train/data/29_doc_qa/progress.jsonl      # sections done (x2 models)
#
# When it finishes, review data/29_doc_qa/coverage.json (the `uncovered` list
# is the TODO for "every aspect"), then push the survivors into the corpus:
#   python3 Train/script/29_multimodel_doc_qa.py --limit 1 --save
# (--save re-reads generated.jsonl; the tiny --limit just skips regeneration
#  of work progress.jsonl already records as done.)

set -euo pipefail
cd "$(dirname "$0")"

LOG="../data/29_doc_qa/sweep.log"
mkdir -p ../data/29_doc_qa

if pgrep -f "29_multimodel_doc_qa.py" >/dev/null; then
    echo "A sweep is already running:"
    pgrep -fl "29_multimodel_doc_qa.py"
    exit 1
fi

echo "=== sweep started $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG"
nohup caffeinate -is python3 29_multimodel_doc_qa.py >> "$LOG" 2>&1 &
PID=$!
echo "launched (pid $PID) — tail -f $LOG"
