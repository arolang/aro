"""
Make sure the pipeline's model is fully on disk before any stage starts.

Run by training.sh after the mlx preflight. A stage that has to download its
model does so silently, inside the stall watchdog: the Hub's progress bars
never reach the stage log, so a 60 GB download looks like a hang and a slow
one is killed as a hang (NB14, after the HF cache was wiped). Here it
runs in the terminal, with visible progress and no watchdog, and an
interrupted download resumes where it stopped.

Exit codes: 0 model is complete, 1 download failed.
Set ARO_TRAIN_SKIP_MODEL_PREFETCH=1 to skip.
"""

import sys
import time

import config

ATTEMPTS = 5


def main():
    model_id = config.MODEL_ID
    if config.complete_local_snapshot(model_id):
        print(f'model prefetch OK — {model_id} is cached')
        return 0
    from huggingface_hub import snapshot_download
    print(f'model prefetch — {model_id} is not fully cached; downloading')
    for attempt in range(1, ATTEMPTS + 1):
        try:
            snapshot_download(model_id)
        except Exception as exc:          # network errors: retry, resume
            print(f'  attempt {attempt}/{ATTEMPTS} failed: {exc}', file=sys.stderr)
            time.sleep(min(60, 10 * attempt))
            continue
        if config.complete_local_snapshot(model_id):
            print(f'model prefetch OK — {model_id} downloaded')
            return 0
    print(f'model prefetch FAILED — {model_id} is still incomplete', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
