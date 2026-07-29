#!/usr/bin/env python3
"""End-to-end generation pipeline: rebuild + expand base pool, run every
generator, assemble to Train/eval_derived. Idempotent; safe to re-run."""
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def main():
    # Lazy, ordered imports: each generator reads base_pool.json at import
    # time, so the pool must be built and expanded BEFORE they are imported.
    log("build_pool"); import build_pool; build_pool.main()
    log("expand_pool x6"); import expand_pool; expand_pool.main(6)
    log("gen_errorfix"); import gen_errorfix; gen_errorfix.main()
    log("gen_codegen"); import gen_codegen; gen_codegen.main()
    log("gen_openapi"); import gen_openapi; gen_openapi.main()
    log("gen_knowledge"); import gen_knowledge; gen_knowledge.main()
    log("gen_probefill"); import gen_probefill; gen_probefill.main()
    log("gen_translation"); import gen_translation; gen_translation.main()
    log("gen_verbfill"); import gen_verbfill; gen_verbfill.main()
    log("gen_reducer"); import gen_reducer; gen_reducer.main()
    log("gen_toolcalls"); import gen_toolcalls; gen_toolcalls.main()
    log("assemble"); import assemble; assemble.main()
    log("DONE")


if __name__ == "__main__":
    main()
