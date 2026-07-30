#!/usr/bin/env python3
"""Post-training PDF report.

Collects the charts that best describe a training round (evaluation, post-release
validation, dataset balance, fine-tune / distillation loss, action coverage),
asks the local Qwen model (via `aro ask`) to write a short passage for each plus
a management summary and a conclusion, and writes a PDF to Train/Reports/.

Run with the training venv:  Train/.venv/bin/python3 Train/script/generate_training_report.py
A training round spans several dated run dirs; the newest version of each
artifact across Train/script/run/<date>/ is used.

Usage:
    generate_training_report.py [--run-glob 'Train/script/run/2026-*'] [--aro <path>]
"""
import argparse
import csv
import json
import subprocess
import textwrap
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
import matplotlib.image as mpimg         # noqa: E402
from matplotlib.backends.backend_pdf import PdfPages  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
RUN_ROOT = REPO / "Train" / "script" / "run"
REPORT_DIR = REPO / "Train" / "Reports"

# Charts that describe training quality, newest-first substring match.
# (substring, human title, what-this-chart-shows focus for the passage prompt)
CHARTS = [
    ("20_evaluation", "Model Quality: Base vs Fine-tuned",
     "per-task metrics comparing the fine-tuned model against the base model: syntax pass rate, answer-quality F1, and hallucination rate"),
    ("25_post_release_validation", "Post-Release Validation Gate",
     "the released model's pass/fail rate on aro-check code probes and whether each release gate (reply rate, empty-think, syntax pass, tool leak, URL contamination) cleared its threshold"),
    ("17_dataset_assembly", "Training Dataset Composition",
     "how many training samples of each task type were assembled after dedup and caps"),
    ("18_finetune", "Fine-tune Training Loss",
     "the training/validation loss curve of the supervised fine-tune over steps — lower and converging is better"),
    ("22_distillation", "Teacher → Student Distillation",
     "the distillation loss and acceptance as the small student model learns from the larger teacher"),
    ("10_action_coverage", "Action Verb Coverage",
     "how often each ARO action verb appears in the training corpus — a long tail means rare verbs are under-represented"),
]


def newest(substring, suffix, run_dirs):
    hits = []
    for d in run_dirs:
        for p in d.glob(f"*{substring}*{suffix}"):
            hits.append(p)
    return max(hits, key=lambda p: p.stat().st_mtime) if hits else None


def read_csv(path):
    if not path or not path.exists():
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def collect_facts(run_dirs):
    """Pull headline numbers for the summary/passages."""
    facts = {}
    ev = read_csv(newest("20_evaluation", ".csv", run_dirs))
    for r in ev:
        if r.get("task_type") == "code_generation" and r.get("metric") == "syntax_pass_rate":
            facts["syntax_pass_ft"] = r.get("fine_tuned_score")
            facts["syntax_pass_base"] = r.get("base_score")
    hall = [r for r in ev if r.get("metric") == "hallucination_rate"]
    if hall:
        facts["hallucination_ft"] = hall[0].get("fine_tuned_score")
    # dataset stats live in data/05_dataset/stats.json, not the run dirs
    stats = REPO / "Train" / "data" / "05_dataset" / "stats.json"
    if not stats.exists():
        stats = newest("stats", ".json", run_dirs)
    if stats and stats.exists():
        try:
            s = json.loads(stats.read_text())
            facts["dataset_total"] = s.get("total")
            facts["task_counts"] = s.get("task_counts")
        except Exception:
            pass
    vl = read_csv(newest("pertask_val_loss", ".csv", run_dirs))
    sel = [r for r in vl if r.get("selected")]
    if sel:
        facts["selected_checkpoint"] = sel[-1].get("checkpoint")
    return facts


class LLM:
    def __init__(self, aro):
        self.aro = aro

    def ask(self, prompt, fallback=""):
        try:
            r = subprocess.run([self.aro, "ask", "--no-think", prompt],
                               capture_output=True, text=True, timeout=90)
            out = r.stdout.strip()
            return out if out else fallback
        except Exception:
            return fallback


def wrap(text, width=92):
    return "\n".join(textwrap.fill(p, width) for p in text.split("\n") if p.strip())


def text_page(pdf, title, body):
    fig = plt.figure(figsize=(8.27, 11.69))  # A4
    fig.text(0.08, 0.93, title, fontsize=20, fontweight="bold", va="top")
    fig.text(0.08, 0.86, wrap(body), fontsize=11, va="top", family="sans-serif")
    plt.axis("off")
    pdf.savefig(fig)
    plt.close(fig)


def chart_page(pdf, title, img_path, passage):
    fig = plt.figure(figsize=(8.27, 11.69))
    fig.text(0.08, 0.95, title, fontsize=16, fontweight="bold", va="top")
    ax = fig.add_axes([0.06, 0.42, 0.88, 0.48])
    ax.imshow(mpimg.imread(str(img_path)))
    ax.axis("off")
    fig.text(0.08, 0.36, wrap(passage), fontsize=10.5, va="top")
    pdf.savefig(fig)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-glob", default=str(RUN_ROOT / "2026-*"))
    default_aro = REPO / ".build" / "debug" / "aro"
    ap.add_argument("--aro", default=str(default_aro) if default_aro.exists() else "aro")
    ap.add_argument("--days", type=int, default=8, help="how many most-recent run dirs to scan")
    args = ap.parse_args()

    run_dirs = sorted([p for p in RUN_ROOT.glob("2026-*") if p.is_dir()],
                      key=lambda p: p.name, reverse=True)[:args.days]
    if not run_dirs:
        raise SystemExit("no run dirs found")
    label = run_dirs[0].name
    llm = LLM(args.aro)
    facts = collect_facts(run_dirs)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    out_pdf = REPORT_DIR / f"training_report_{label}.pdf"

    print(f"[report] run={label} facts={facts}")

    # Management summary
    summary_ctx = (
        f"Fine-tuned syntax pass rate: {facts.get('syntax_pass_ft')} (base {facts.get('syntax_pass_base')}). "
        f"Hallucination rate: {facts.get('hallucination_ft')}. "
        f"Training dataset size: {facts.get('dataset_total')} samples. "
        f"Selected checkpoint: {facts.get('selected_checkpoint')}."
    )
    summary = llm.ask(
        "Write a 4-5 sentence management summary of this ARO language-model training round. "
        "Be concrete and non-technical. Data: " + summary_ctx,
        fallback=summary_ctx)

    with PdfPages(out_pdf) as pdf:
        text_page(pdf, f"ARO Model Training Report — {label}",
                  "MANAGEMENT SUMMARY\n\n" + summary + "\n\n\nKey figures\n" + summary_ctx)

        for sub, title, focus in CHARTS:
            img = newest(sub, ".png", run_dirs)
            if not img:
                continue
            extra = ""
            if sub == "17_dataset_assembly" and facts.get("task_counts"):
                extra = " Sample counts by task type: " + json.dumps(facts["task_counts"]) + "."
            elif sub == "20_evaluation":
                extra = (f" Syntax pass rate went {facts.get('syntax_pass_base')}→{facts.get('syntax_pass_ft')}; "
                         f"hallucination rate {facts.get('hallucination_ft')}.")
            passage = llm.ask(
                f"Write 2-3 sentences for a training report explaining ONLY the '{title}' chart. "
                f"This chart shows {focus}.{extra} "
                f"Describe what this specific chart tells us about training quality. "
                f"Do not restate unrelated overall metrics.",
                fallback=f"{title}: see chart.")
            chart_page(pdf, title, img, passage)
            print(f"[report] added {title} ({img.name})")

        conclusion = llm.ask(
            "Write a 3-4 sentence conclusion for this ARO model training round, noting the main "
            "strength and the top area to improve next. Data: " + summary_ctx,
            fallback="Conclusion: training improved syntax validity; reduce hallucination next.")
        text_page(pdf, "Conclusion", conclusion)

    print(f"[report] wrote {out_pdf}")


if __name__ == "__main__":
    main()
