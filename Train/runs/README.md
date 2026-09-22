# Run archive

One directory per release, holding the part of a pipeline run that can be
checked in: what the dataset looked like, which caps shaped it, which gate it
passed, what the loop measured, and which versions of everything produced it.

`data/`, `models/` and `release/` are gitignored, and they should be — they are
gigabytes of weights and intermediate JSONL. The cost was that a finished run
left nothing behind in the repository at all, so the released model could not be
traced back to the data or the code that made it (GitLab #792). This directory
is the durable half.

```
Train/runs/<release>/
├── run.json              # what was collected, from where, sha256 of each file,
│                         # pipeline/TYPE_CAPS versions, aro + package versions,
│                         # git commits of ARO-Lang and ARO-Application
├── stats.json            # dataset composition after caps
├── dataset_report.md     # retention funnel and drop reasons
├── drop_reasons.csv
├── corpus_manifest.json
├── loop_metrics.json     # per-round iterative-loop metrics
├── promotion_gate.json   # what the release had to clear
├── model_manifest.json
├── version_history.json
└── experiments.csv       # every stage of the run, exported from experiments.db
```

Write one:

```bash
python3 Train/script/run_archive.py --release 2026.09.1
python3 Train/script/experiment_db.py --export --release 2026.09.1
```

Verify one (re-hashes every file against `run.json`):

```bash
python3 Train/script/run_archive.py --check --release 2026.09.1
```

Nothing here is large. If something you want to archive is, it does not belong
in this directory — record its hash and its Hub coordinates in `run.json`
instead.
