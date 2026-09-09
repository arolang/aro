\newpage

# Chapter 3: The Commands

> "There is a difference between a tool you can use and a tool you already know. This chapter is about closing that gap."

---

## 3.1 The First Invocation

```bash
$ aro ask "write a feature set that returns OK for GET /health"
```

That is the entire interface. Everything after `aro ask` is a prompt. The first time you run this, the CLI will notice it has no model cached and offer to download one:

```
Model 'ARO-Lang/aro-coder-6bit' (~4.5 GB) is not installed.
Download from Hugging Face? [y/N]
```

Say yes. The weights land in `~/.cache/aro/ask/`. Subsequent invocations find them there and skip the download.

If you would rather put the cache somewhere else — a shared network drive, an external SSD — set the `HF_HOME` environment variable before running `aro ask`. If the model is gated and you have a token, set `HF_TOKEN`. Neither is required for the default model.

## 3.2 Backends

`aro ask` does not ship its own inference engine. It detects and uses whichever of the following it finds first, in order:

1. **Any OpenAI-compatible endpoint** specified by `ARO_ASK_ENDPOINT`. This is how you point `aro ask` at a shared inference server — an office GPU box, a colleague's machine, a dev container. Set `ARO_ASK_API_KEY` if the endpoint needs one.
2. **Native MLX** (macOS Apple Silicon only). In-process inference — no external server needed. This is the preferred backend on Apple Silicon and the fastest option.
3. **`llama-server`** from `llama.cpp`. Install with your package manager or let `aro ask` download it automatically. This is the preferred backend on Linux.
4. **`mlx_lm.server`** from `mlx-lm`. A Python-based fallback on macOS if native MLX is not available.

If none of these are available the command fails with a clear error, not a cryptic one. There is no "automatic fallback to cloud" — the whole point of the local model is that it is local. You choose when to involve anyone else's machine.

Run `aro ask /model` to see which backend `aro ask` picked and where the weights live.

## 3.3 One-shot vs. REPL

`aro ask` runs in two modes. If you pass a prompt as arguments, it runs one-shot: send the prompt, run tools, print the reply, save the context, exit.

```bash
$ aro ask "show me how to extract a path parameter"
```

If you run it with no arguments *and* stdin is a terminal, it drops into an interactive REPL.

```
$ aro ask
aro ask — backend: llama.cpp, model: ARO-Lang/aro-coder-6bit
type /quit to exit, /help for commands
lm>
```

The REPL is built on LineNoise, so arrow keys, history, and Ctrl+R search all work the way you expect. Press Ctrl+D or type `/quit` to leave. Type `/help` at any time to see the list of slash commands.

## 3.4 The Slash Commands

Slash commands are how you talk to `aro ask` itself, instead of to the model. They work in both modes: pass them as the first argument in one-shot, or type them at the REPL prompt.

```
/help                Show the command list.
/clean               Delete .context in the current directory.
/file <path>         Focus a file: its content is injected into every request.
/show                Print a short summary of the current conversation.
/tools               List every tool the model can call.
/model               Print the active model, its path, and the backend.
/mcp                 List the MCP servers currently bridged into the session.
/index               Walk the project and (re)build the retrieval index.
/search <query>      Debug retrieval: print the top 5 matches for a query.
/fix <path>          Run aro check, feed diagnostics to the model, auto-repair.
/explain <path>      Ask the model to explain a file or feature set in plain English.
/docs <path>         Generate documentation for an ARO application.
/plugin <name>       Scaffold a new plugin directory with plugin.yaml and stubs.
/openapi <spec>      Generate or update openapi.yaml from a natural-language description.
/quit                Leave the REPL (also /exit, Ctrl-D).
```

A few of these are worth a paragraph of their own.

**`/file`** is the one nobody discovers on their own. `/file users.aro` pins that file's current content into every subsequent request, so the model treats it as "the open file" and stops re-reading it on every turn. `/file off` clears it. There is a `--file` flag that does the same thing for one-shot mode.

**`/clean`** deletes the `.context` file in the current directory. Contexts drift over long conversations — the model starts to "remember" things from three tasks ago and applies them to the thing in front of it. When a conversation has clearly lost the plot, `/clean` and start again.

**`/tools`** is how you discover what the model can actually do. The built-in tools are listed, plus any tool the bridged MCP servers expose. If a colleague ships a new ARO plugin that registers an MCP tool, you'll see it here without any extra configuration on your side.

**`/index`** walks the project and builds a retrieval index at `.context.index/vectors.json`. Run this once after a fresh clone, and then again any time you move or add a lot of files. Section 4.5 explains what the index is used for — and, importantly, who uses it.

**`/search`** prints the top five chunks matching a query, with file, line range, and score. It is how you find the right file to point the model at — the model has no search tool of its own (Chapter 7), so retrieval is a thing you drive, not something it does behind your back.

**`/fix`** is the one you will reach for most often. It works deterministically — no tool-calling loop, no hoping the model picks the right tool. It runs `aro check` directly, reads the source files, builds a focused prompt with the code and the exact error, asks the model for a fix, validates the fix with `aro check` in a temp directory, and writes the corrected files back only if validation passes. It repeats up to five times with decreasing temperature. You can pass a file or a directory: `/fix ./MyApp/users.aro` or `/fix ./MyApp`. The workflow it replaces — read error, open file, find line, fix it, re-run check — takes minutes by hand and seconds with `/fix`.

**`/explain`** is for reading code you did not write. Point it at a file and it produces a paragraph-level explanation of what each feature set does, what events trigger it, and what data flows through it. It is not a substitute for reading the code yourself, but it is a good first pass when you inherit a project.

**`/docs`** generates documentation from the project in its current state. It reads the relevant `.aro` files, the `openapi.yaml` if one exists, and produces a markdown summary of the application's endpoints, events, and feature sets. Useful for onboarding, and for keeping a wiki page in sync with the code without writing it by hand.

**`/plugin`** scaffolds a new plugin. Give it a name and it creates the directory under `Plugins/`, writes a `plugin.yaml` with sensible defaults, and stubs out the source files for the plugin type it infers from your environment (Swift on macOS, Rust or C elsewhere). You still have to write the logic, but the boilerplate is done.

**`/openapi`** is the inverse of the usual workflow. Instead of writing `openapi.yaml` by hand and then writing feature sets to match, you describe your API in plain English — "a user service with CRUD operations and a health check" — and the model generates the OpenAPI spec. It is a starting point, not a final draft. Review it, adjust the schemas, and then let the model write the feature sets to match.

## 3.5 Flags

`aro ask` has seven flags, and you will probably only ever use two of them.

- **`--model <id>`** — override the default model. Only useful if you have trained your own variant.
- **`--yes`** — auto-approve every shell tool call. Use this in scripts and in CI. Never use it when you are about to walk away from the terminal.
- **`--no-mcp`** — skip the MCP bridge bootstrap. Faster startup for slash commands that don't need tools.
- **`--temperature <value>`** — sampling temperature. Defaults to `0.2`, which is deliberately low; the fine-tune was trained to be confident about ARO syntax, and high temperatures make it start inventing verbs again. Raise it only if you want the model to be more creative in non-code explanations.
- **`--file <path>`** — pin a file's content into every request, the one-shot equivalent of `/file`.
- **`--verbose`** (or `-v`) — print backend chatter: model loading, runner output, and the raw reply including the `<think>` block the CLI normally strips. This is the flag to reach for when the model appears to hang.
- **`--no-think`** — disable the base model's thinking mode for this turn. Worth trying when a simple prompt burns its whole token budget reasoning and never gets to an answer.

## 3.6 The Context File

Every conversation lives in a single file, `.context`, in the current working directory. It is YAML. It is human-readable. You can open it in your editor and read it, you can commit fragments of it into your project if you want to preserve a particularly useful conversation, and you can hand it to a colleague so they can see exactly what you asked and what the model replied.

A shortened example:

```yaml
model: ARO-Lang/aro-coder-6bit
created: 2026-04-06T12:00:00Z
messages:
  - role: system
    content: "You are ARO-Coder, an assistant specialised in the ARO ..."
  - role: user
    content: "write a feature set that greets a user"
  - role: assistant
    content: |
      ```aro
      (greetUser: User API) {
          Extract the <name> from the <pathParameters: name>.
          Compute the <greeting> from "Hello, " ++ <name> ++ "!".
          Return an <OK: status> with <greeting>.
      }
      ```
```

You can also add an `mcp_servers:` section at the top to bring additional MCP servers into the session:

```yaml
mcp_servers:
  - command: aro
    args: [mcp]
  - command: /opt/my-tools/docs-mcp
    args: [--stdio]
```

The file is written in place with your umask's default permissions, so if you keep anything sensitive in a conversation, `chmod 600 .context` yourself. It never leaves the machine — but it is a plain file in your working directory, and it will be picked up by a `git add .` that is not paying attention. Put `.context` in `.gitignore` unless you have decided otherwise (section 4.5).

A sibling file, `.context.repairs.jsonl`, accumulates the read/fix/verify conversations that `/fix` produces. Same rules apply.
