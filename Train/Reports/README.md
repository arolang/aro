# Training Reports

`training.sh` writes a PDF here after every training round:
`training_report_<date>.pdf`.

Each report contains:
- **Management summary** — headline numbers in plain English
- The charts that best describe training quality (base-vs-fine-tuned evaluation,
  post-release validation gate, dataset composition, fine-tune / distillation
  loss, action-verb coverage), each with a short passage written by the local
  Qwen model (`aro ask`)
- **Conclusion** — main strength + top area to improve next

Regenerate manually for the latest run:

```bash
Train/.venv/bin/python3 Train/script/generate_training_report.py
```

Options: `--run-glob`, `--aro <path>`, `--days <n>` (how many recent run dirs to
scan; a training round spans several dated dirs under `Train/script/run/`).

The generated `*.pdf` files are git-ignored (regenerable artifacts); commit one
deliberately if you want it kept as a record.
