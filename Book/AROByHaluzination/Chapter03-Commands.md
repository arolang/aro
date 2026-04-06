# Chapter 3: The Commands

> "There is a difference between a tool you can use and a tool you already know. This chapter is about closing that gap."

---

## 3.1 The First Invocation

```bash
$ aro lm "write a feature set that returns OK for GET /health"
```

That is the entire interface. Everything after `aro lm` is a prompt. The first time you run this, the CLI will notice it has no model cached and offer to download one:

```
Model 'ARO-Lang/aro-coder-4bit' (~4.5 GB) is not installed.
Download from Hugging Face? [y/N]
```

Say yes. The weights land in `~/.cache/aro/models/ARO-Lang/aro-coder-4bit/`. Subsequent invocations find them there and skip the download.

If you would rather put the cache somewhere else — a shared network drive, an external SSD — set the `HF_HOME` environment variable before running `aro lm`. If the model is gated and you have a token, set `HF_TOKEN`. Neither is required for the default model.

## 3.2 Backends

`aro lm` does not ship its own inference engine. It relies on a local runner. It will use whichever of the following it finds first, in order:

1. **Any OpenAI-compatible endpoint** specified by `ARO_LM_ENDPOINT`. This is how you point `aro lm` at a shared inference server — an office GPU box, a colleague's machine, a dev container. Set `ARO_LM_API_KEY` if the endpoint needs one.
2. **`llama-server`** from `llama.cpp`. Install with your package manager. This is the preferred backend on Linux and on Intel Macs.
3. **`mlx_lm.server`** from `mlx-lm`. Install with `pip install mlx-lm`. This is the preferred backend on Apple Silicon.

If none of these are available the command fails with a clear error, not a cryptic one. There is no "automatic fallback to cloud" — the whole point of the local model is that it is local. You choose when to involve anyone else's machine.

Run `aro lm /model` to see which backend `aro lm` picked and where the weights live.

## 3.3 One-shot vs. REPL

`aro lm` runs in two modes. If you pass a prompt as arguments, it runs one-shot: send the prompt, run tools, print the reply, save the context, exit.

```bash
$ aro lm "show me how to extract a path parameter"
```

If you run it with no arguments *and* stdin is a terminal, it drops into an interactive REPL.

```
$ aro lm
aro lm — backend: llama.cpp, model: ARO-Lang/aro-coder-4bit
type /quit to exit, /help for commands
lm>
```

The REPL is built on LineNoise, so arrow keys, history, and Ctrl+R search all work the way you expect. Press Ctrl+D or type `/quit` to leave. Type `/help` at any time to see the list of slash commands.

## 3.4 The Slash Commands

Slash commands are how you talk to `aro lm` itself, instead of to the model. They work in both modes: pass them as the first argument in one-shot, or type them at the REPL prompt.

```
/clean               Delete .context in the current directory.
/show                Print a short summary of the current conversation.
/tools               List every tool the model can call.
/model               Print the active model, its path, and the backend.
/mcp                 List the MCP servers currently bridged into the session.
/index               Walk the project and (re)build the retrieval index.
/search <query>      Debug retrieval: print the top 5 matches for a query.
/quit                Leave the REPL.
```

A few of these are worth a paragraph of their own.

**`/clean`** deletes the `.context` file in the current directory. Contexts drift over long conversations — the model starts to "remember" things from three tasks ago and applies them to the thing in front of it. When a conversation has clearly lost the plot, `/clean` and start again.

**`/tools`** is how you discover what the model can actually do. The built-in tools are listed, plus any tool the bridged MCP servers expose. If a colleague ships a new ARO plugin that registers an MCP tool, you'll see it here without any extra configuration on your side.

**`/index`** walks the project and builds a retrieval index at `.context.index/vectors.json`. Run this once after a fresh clone, and then again any time you move or add a lot of files. Chapter 5 explains what the index is used for.

**`/search`** is a debugging tool. It shows you which chunks of the project the model would see if it called `search_project` with the same query. Use it to understand why the model did or did not find the thing you expected it to find.

## 3.5 Flags

`aro lm` has five flags, and you will probably only ever use two of them.

- **`--model <id>`** — override the default model. Only useful if you have trained your own variant.
- **`--yes`** — auto-approve every shell tool call. Use this in scripts and in CI. Never use it when you are about to walk away from the terminal.
- **`--no-mcp`** — skip the MCP bridge bootstrap. Faster startup for slash commands that don't need tools.
- **`--temperature <value>`** — sampling temperature. Defaults to `0.2`, which is deliberately low; the fine-tune was trained to be confident about ARO syntax, and high temperatures make it start inventing verbs again. Raise it only if you want the model to be more creative in non-code explanations.

## 3.6 The Context File

Every conversation lives in a single file, `.context`, in the current working directory. It is YAML. It is human-readable. You can open it in your editor and read it, you can commit fragments of it into your project if you want to preserve a particularly useful conversation, and you can hand it to a colleague so they can see exactly what you asked and what the model replied.

A shortened example:

```yaml
model: ARO-Lang/aro-coder-4bit
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

The file is written atomically — the CLI writes a `.context.tmp` sibling and renames it into place — and its permissions are restricted to `0600` on Unix systems. It is yours, not the world's.
