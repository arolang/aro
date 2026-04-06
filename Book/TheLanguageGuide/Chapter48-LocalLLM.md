# Chapter 48: The Local LLM (`aro lm`)

> "The best documentation is a conversation that remembers where you left off."

---

## 48.1 Why a Local Coding Assistant?

Most coding assistants live in the cloud. They see your source, your history, and the questions you ask. They also fail at ARO, because almost nothing about ARO exists in their training data — the action vocabulary, the qualifier-as-name syntax, the contract-first HTTP model, and the "code is the error message" philosophy are all unique to this language.

`aro lm` solves both problems. It ships as a CLI subcommand of `aro`, runs a fine-tuned model on your own machine, and persists the conversation next to your source code. No cloud, no usage quota, no surprise bills. When you close your laptop and open it two days later, the conversation is still there.

---

## 48.2 Installing the Model

The first time you run `aro lm`, it will offer to download the default model from Hugging Face.

```
$ aro lm "write a hello world feature set"
Model 'ARO-Lang/aro-coder-4bit' (~4.5 GB) is not installed. Download from Hugging Face? [y/N] y
model.gguf: 100%
...
```

The cache lives at `~/.cache/aro/models/<repo>/`. Set `$HF_HOME` to put it somewhere else. If the model is gated, set `$HF_TOKEN` and `aro lm` will use it as a bearer token for the download.

You need a local runner to actually execute inference. `aro lm` auto-detects these in order:

1. **`$ARO_LM_ENDPOINT`** — any OpenAI-compatible URL. Useful for pointing `aro lm` at a shared inference server or another local runner you already trust.
2. **`llama-server`** — part of `llama.cpp`. Install via your package manager (`brew install llama.cpp`, `apt install llama.cpp`).
3. **`mlx_lm.server`** — part of `mlx-lm`. Install with `pip install mlx-lm`. Works only on Apple Silicon.

If none of these are available, `aro lm` prints a clear error. There is no other fallback.

---

## 48.3 Asking the First Question

The simplest form is one-shot: everything after `aro lm` is treated as a prompt.

```bash
$ aro lm "write a feature set that returns OK for GET /health"
```

The assistant replies with ARO source, optionally wrapped in markdown fences, and writes the conversation to `.context` in the current directory. Run the same command a second time and the previous turn is part of the context — the model "remembers" what it just told you.

Running `aro lm` with no arguments drops you into an interactive REPL. The prompt is `lm>`. Type `/quit` (or press Ctrl+D) to exit.

```
$ aro lm
aro lm — backend: llama.cpp, model: ARO-Lang/aro-coder-4bit
type /quit to exit, /help for commands
lm> explain the difference between Compute and Transform
…
lm> now show me a Compute example using qualifier-as-name
…
lm> /quit
```

---

## 48.4 Slash Commands

Slash commands work the same way in one-shot and REPL mode. In one-shot mode the command is the first argument; in the REPL it's typed at the prompt.

| Command              | What it does                                                       |
|----------------------|--------------------------------------------------------------------|
| `/clean`             | Delete `.context` in the current directory. Start fresh.           |
| `/show`              | Print a short summary of the current conversation.                 |
| `/tools`             | List every tool the model can call, including MCP-bridged ones.    |
| `/model`             | Print the active model, its path, and the selected backend.       |
| `/mcp`               | List the MCP servers currently bridged into the session.          |
| `/index`             | Walk the project and (re)build the retrieval index.                |
| `/search <query>`    | Debug retrieval: print the top 5 matches for a query.             |
| `/quit`              | Leave the REPL.                                                   |

Slash commands that don't talk to the model (`/clean`, `/tools`, `/model`, `/mcp`, `/index`, `/search`, `/show`) are fast — they don't start the backend runner.

---

## 48.5 Tool Calling

`aro lm` isn't a glorified autocomplete. It can read your files, run your toolchain, and search the specification. It does this by calling *tools* — small, sandboxed functions the model invokes during a turn. Every tool call is logged to `.context` so you can see exactly what happened after the fact.

### Built-in tools

| Tool                 | Purpose                                                    |
|----------------------|------------------------------------------------------------|
| `read_file`          | Read a file with line numbers                              |
| `write_file`         | Create or overwrite a file                                 |
| `edit_file`          | Exact-string replacement (must be unique)                  |
| `list_dir`           | Directory listing                                          |
| `grep`               | Regex search across files                                  |
| `run_shell`          | Execute a shell command — approval-gated in interactive mode |
| `aro_check`          | Run `aro check`                                            |
| `aro_run`            | Run `aro run`                                              |
| `aro_test`           | Run `aro test`                                             |
| `aro_build`          | Compile to a native binary                                 |
| `parse_aro`          | Parse ARO source without touching disk                     |
| `list_actions`       | List every registered action verb                          |
| `list_proposals`     | List proposals in the `Proposals/` directory               |
| `read_proposal`      | Read a proposal by number (e.g. `0001`, `0052`)            |
| `search_project`     | Semantic search over the project index                    |

### Sandboxing

All file and shell tools are scoped to the current working directory. `read_file ../../etc/passwd` fails with `Path outside the working directory`. `write_file` cannot overwrite files outside the project root either.

### Shell approval

`run_shell` asks you for approval on every call:

```
[aro lm] approve shell command? [y/N]
  swift test --filter AROLMTests
>
```

Pass `--yes` to auto-approve everything — handy for non-interactive CI-like invocations, dangerous everywhere else.

---

## 48.6 MCP Bridging

ARO already ships an MCP server (`aro mcp`). `aro lm` bridges it into the same tool registry the built-ins use, so any tool the ARO runtime exposes via MCP is immediately available to the model — with no changes to `aro lm` itself.

You can add more MCP servers per project by editing `.context`:

```yaml
mcp_servers:
  - command: aro
    args: [mcp]
  - command: /opt/homebrew/bin/my-other-mcp
    args: [--stdio]
```

Run `aro lm /mcp` to see which bridges are live, and `aro lm /tools` to see every tool — both built-in and bridged — in one list.

---

## 48.7 Project Retrieval

Large projects don't fit in a context window, and cramming the whole repo into the system prompt wastes tokens on files the model doesn't need. `aro lm` instead indexes the project and lets the model pull relevant chunks via the `search_project` tool.

To build the index:

```bash
$ aro lm /index
indexed 842 chunks
```

The index is stored at `.context.index/vectors.json`. It's a flat cosine-similarity store of 80-line chunks over `.aro`, `.md`, `.swift`, `.yaml`, `.json` and `.toml` files, using a deterministic hashing embedder that requires no external model.

Debug retrieval by searching directly:

```bash
$ aro lm /search "openapi contract"
Examples/UserService/openapi.yaml:1-80  (0.712)
Book/TheLanguageGuide/Chapter17-OpenAPI.md:1-80  (0.643)
...
```

When the model asks for help with something project-specific, it can now call `search_project` and cite the exact file and line range it's using.

---

## 48.8 Good Habits

A few practices that make the difference between a useful assistant and a frustrating one.

**One `.context` per feature.** When you finish a task, run `/clean`. Long contexts drift; a focused one stays sharp.

**Let it call tools.** If the model asks you to paste a file, stop and tell it to use `read_file`. That's what the tool loop is for.

**Rebuild the index after big changes.** `/index` is cheap. Run it whenever you move files or add proposals.

**Approve shell commands deliberately.** Read what's in the prompt before typing `y`. The model's suggestions are usually fine — but "usually" is not "always".

**Use `parse_aro` for speculative edits.** It's the fastest way to have the model validate syntax before writing to disk.

**Stay in-project.** The path guard will stop the model from escaping the working directory, but you can make its life easier by running `aro lm` from the root of your application.

---

## 48.9 Automation Patterns

`aro lm --yes <prompt>` is scriptable. A few patterns worth knowing:

**Check a new feature**:
```bash
aro lm --yes "run aro_check on ./Examples/UserService and fix any diagnostics"
```

**Generate boilerplate for a new operationId**:
```bash
aro lm --yes "add a feature set called deleteUser that handles DELETE /users/{id} in ./MyApp"
```

**Explain a proposal to a new contributor**:
```bash
aro lm --no-mcp "summarise ARO-0018 in three bullets" > data-pipelines.md
```

**Use a shared endpoint in CI**:
```bash
ARO_LM_ENDPOINT=http://192.168.1.42:8080 aro lm --yes "check examples/"
```

---

## 48.10 When Something Goes Wrong

- **`No LM backend is available`** — install `llama-server`, `mlx_lm.server`, or set `$ARO_LM_ENDPOINT`.
- **Runner never starts** — set `ARO_LM_VERBOSE=1` to see its stdout/stderr on your terminal instead of `/dev/null`.
- **Model download stalls** — the download is resumable. Re-run the same command; files already fully present are skipped.
- **Tool call failed with "Path outside the working directory"** — the model tried to escape the sandbox. Rephrase so it stays in-project, or change directories before launching `aro lm`.

---

## 48.11 Summary

`aro lm` is a local, ARO-aware coding assistant that:

- Runs a fine-tuned model on your machine
- Persists conversations per directory in a human-readable `.context` file
- Speaks the OpenAI tool-calling dialect to call sandboxed file, shell and `aro` tools
- Bridges the `aro mcp` server (and any third-party MCP server you configure)
- Searches the project via an in-process semantic index
- Works one-shot or in a REPL with LineNoise history

You now have a coding assistant that lives in the same directory as the code it's helping you write. Use it the same way you'd use a coworker sitting next to you: give it context, let it read the project, and ask it to do the boring parts.
