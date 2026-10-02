# `aro ask` feedback seeds

Preference pairs harvested from real `aro ask` sessions: the model answered,
`aro check` rejected it, the model repaired it, and the repair was accepted.
Both sides of a preference pair with the reason attached — produced by someone
using the assistant, not by sampling it.

Nothing writes here automatically. The log that feeds it,
`.context.repairs.jsonl`, is a transcript of somebody's project, so copying any
of it is a thing you ask for:

```bash
cd ~/my-project
aro ask --export-training /path/to/ARO-Lang/Train/seeds/ask_feedback
```

The export re-validates every pair against the build doing the exporting — the
fixed side must check clean and the broken side must not, because that is the
claim the pair makes — strips home directories, usernames and absolute paths,
and labels each pair with the `aro check` diagnostic it repaired. It prints what
it kept and what it dropped, and why.

`--export-from DIR` points it somewhere other than the current directory; one
level of subdirectories is searched, so a folder of projects exports in one go.

## What lands here

One `ask_repairs_<timestamp>.jsonl` per export. Each line:

| field | |
|---|---|
| `prompt` | the diagnostic the user hit, anonymised |
| `rejected` | the answer that failed |
| `chosen` | the answer that passed |
| `diagnostic_class` | `unknown_verb`, `wrong_preposition`, `immutability`, … |
| `attempts` | how many tries the repair took |
| `timestamp` | when the repair happened |
| `origin` | always `ask_feedback`, so the share cap sees one source |

`19_preference_sft` reads every `*.jsonl` here and reports the counts per
diagnostic class, which is what makes "which diagnostics do we have real
repair data for" a number rather than a guess.

## Read before committing

The export removes what it can identify: paths, home directories, usernames.
It cannot remove what it cannot recognise — a project name inside a path, an
identifier from a private schema, a string literal with a customer in it. The
diagnostic has to keep enough context to be worth training on, so the last
judgement is yours. These files are versioned deliberately: a pair in here is
one somebody looked at.
