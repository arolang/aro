# ARO-0092: The `aro ask` Assistant

* Proposal: ARO-0092
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0034, ARO-0084

## Abstract

`aro ask` is a coding assistant that ships inside the `aro` binary and runs a
local language model. It reads and writes files in the project, runs the
toolchain, searches the specification, and answers in ARO. This proposal
specifies its backends, its tools, its approval model, and the `.context` file
it keeps.

It supersedes ARO-0084, which specified `aro lm` — a prompt-in, text-out
subcommand with no tools, removed in 0.10.0. Until now the shipped assistant had
no proposal at all (GitLab #833), which is a gap worth naming: `aro ask` writes
files and executes shell commands, so its boundaries belong in the
specification rather than only in `--help`.

## Motivation

ARO's vocabulary is closed and its grammar is regular, so a model can be held to
it — and, unusually, *checked*. `aro check` knows every preposition and every
qualifier and names the closest match when one is wrong, which makes it a real
oracle rather than a similarity score. That is the bet `aro ask` is built on: a
small fine-tuned model plus a verifier beats a large general model with none.

The alternative — copying documentation into a cloud assistant — fails twice
over. The assistant does not know the language, and the project's own files are
what it most needs to see.

## 1. Invocation

```bash
aro ask                              # interactive REPL
aro ask "write a feature set that greets a user"
aro ask /fix ./MyApp/main.aro
aro ask /plugin my-analytics
aro ask /docs ./MyApp
```

| Flag | Meaning |
|------|---------|
| `--model <id>` | Model identifier; default `ARO-Lang/aro-coder-6bit` |
| `--yes` | Approve every tool call without prompting |
| `--no-mcp` | Do not connect to any MCP server |
| `--temperature <t>` | Sampling temperature, default `0.2` |
| `--verbose` | Print backend chatter and the raw output, `<think>` blocks included |
| `--no-think` | Disable the model's thinking mode for this turn |
| `--file <path>` | Treat this file as "the open file"; its content is injected into every request |

In the REPL, `/file <path>` changes the focused file and `/clean` discards the
conversation.

## 2. Backends

Inference is delegated to a local runner speaking an OpenAI-compatible
`/v1/chat/completions` dialect. Selection is automatic, in this order:

1. `$ARO_ASK_ENDPOINT` — any OpenAI-compatible URL;
2. native MLX on Apple Silicon;
3. `llama-server` (GGUF via llama.cpp), downloaded on first use.

The model is fetched on first run and cached. `aro ask` is not available on
Windows (GitLab #701).

## 3. Tools

The model acts through a fixed registry (`Sources/AROAsk/Tools`), not through
free-form shell:

| Group | Tools |
|---|---|
| Toolchain | `aro_check`, `aro_run`, `aro_test`, `aro_build`, `parse_aro`, `list_actions` |
| Files | `read_file`, `write_file`, `edit_file`, `list_dir`, `grep` |
| Project | `create_plugin`, `write_openapi`, `generate_docs` |
| Specification | `aro_knowledge`, `list_proposals`, `read_proposal` |
| Escape hatch | `run_shell` |

`aro_check` is the one that matters most: the assistant is expected to check
what it wrote before claiming it works, and the checker's diagnostics go back
into the conversation.

Additional tools may come from MCP servers, unless `--no-mcp` is given.

## 4. Approval

Every tool call that writes a file or runs a command is shown and approved
before it runs. `--yes` approves everything for the session and is the
documented way to use `aro ask` non-interactively; it should not be the default
in anything that runs unattended against a repository you care about.

Paths are confined by `PathGuard` to the working directory. `run_shell` is the
deliberate hole in that: it runs what it is given, under the same approval
prompt, and it exists because the alternative is a model that cannot run the
project's own build.

## 5. Context

The conversation is persisted as YAML in `.context` in the current working
directory, so a session survives restarting the process and two projects do not
share a history. `/clean` deletes it. `.context` records the prompts, the
replies and the tool calls; treat it as you would a shell history — it can
contain whatever was in the files the model read.

Project files are indexed for retrieval (`Sources/AROAsk/Retrieval`), so the
model can search the project by meaning rather than only by `grep`.

## 6. Relationship to the training pipeline

The model is fine-tuned on this repository's own corpus — the proposals, the
examples and the books. That is why the documentation layers' correctness is a
functional concern and not only a courtesy: a proposal that teaches a verb the
parser rejects teaches it to the assistant too. `Scripts/check-doc-examples.py`
exists for that reason (GitLab #834), and grading the pipeline on `aro check`
rather than on text similarity follows from the same argument.

## 7. Out of scope

- Cloud models. `$ARO_ASK_ENDPOINT` will point at whatever you give it, but
  nothing ships configured to send a project anywhere.
- Editing outside the working directory.
- Any claim that the output is correct because the model said so. The checker
  says so, or nothing does.

## References

- ARO-0084 — `aro lm`, superseded
- ARO-0034 — Language Server Protocol, the other tool that consumes the parser
- `Book/TheLanguageGuide/Chapter49-LocalLLM.md`
