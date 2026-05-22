# ARO-0052: Local LLM Integration (`aro lm`)

**Status:** Superseded by `aro ask` (0.10.0)
**Author:** ARO team
**Related:** ARO-0005 (Application Architecture), ARO-0008 (I/O Services)

> **Note:** The `aro lm` subcommand described below was removed in 0.10.0.
> The local-LLM functionality lives in `aro ask`, which adds tool calling and
> project-aware retrieval on top of the same fine-tuned model and the same
> three-tier backend strategy (`$ARO_ASK_ENDPOINT` → native MLX on macOS →
> `llama-server`). See `Book/TheLanguageGuide/Chapter49-LocalLLM.md` for the
> shipped behaviour. The rest of this proposal is preserved as historical
> design context.

## 1. Motivation

ARO is a domain-specific language with a small, regular grammar. Large language
models trained on general-purpose code perform poorly on ARO because the action
vocabulary, qualifier syntax and contract-first HTTP conventions don't appear
in public training data.

Instead of asking users to copy-paste documentation into a cloud assistant, we
ship a local coding assistant as a first-class CLI subcommand: `aro lm`. It
runs a fine-tuned model (`ARO-Lang/aro-coder-4bit`) on the user's machine,
persists conversation context per working directory, and uses tool calling to
let the model read the project, run the toolchain and search the
specification.

The goal is to make the ARO installation self-sufficient: one binary, one
model download, no cloud dependency.

## 2. Backend strategy

Pure-Swift inference of a 4-bit quantised LLM is not realistic to ship today —
especially on Linux with CUDA. `aro lm` therefore delegates inference to a
local runner that speaks an OpenAI-compatible `/v1/chat/completions` dialect.
Three backends are supported, detected in priority order:

| Priority | Backend             | Detection              | Notes                                 |
|---------:|---------------------|------------------------|---------------------------------------|
| 1        | `RemoteBackend`     | `$ARO_LM_ENDPOINT` set | Any OpenAI-compatible endpoint        |
| 2        | `LlamaCppBackend`   | `llama-server` on PATH | Preferred for Linux/GGUF              |
| 3        | `MLXBackend`        | `mlx_lm.server` on PATH| Apple Silicon fallback                |

Local backends spawn their runner bound to `127.0.0.1` on a random dynamic
port and speak JSON over the local loopback interface. The runner is torn
down when the session exits.

A future revision may vendor `llama.cpp` as a C target and link it directly
into `aro`, so users see only a single binary and no runtime dependencies.
See §9.

## 3. Model download

Model files are cached at `~/.cache/aro/models/<repo>/` (override with
`$HF_HOME`). On first invocation, `aro lm` checks the bundled
`model-manifest.json` for required files. Missing files are streamed from
`https://huggingface.co/<repo>/resolve/main/<file>` with a progress bar.
`$HF_TOKEN` is honoured for gated models. The user is prompted before any
download starts.

Bundled manifest entries:

- `ARO-Lang/aro-coder-4bit` — primary chat model (~4.5 GB)
- `ARO-Lang/aro-embed` — optional embedding model (~150 MB)

## 4. Context management

Each working directory gets its own `.context` YAML file. The schema is a
simple, human-readable document:

```yaml
model: ARO-Lang/aro-coder-4bit
created: 2026-04-06T12:00:00Z
messages:
  - role: system
    content: "..."
  - role: user
    content: "..."
  - role: assistant
    content: "..."
    tool_calls: "[{...}]"    # JSON string
  - role: tool
    tool_call_id: "call_1"
    content: "..."
mcp_servers:
  - command: aro
    args: [mcp]
```

The file is rewritten atomically (`.context.tmp` → rename) after every turn,
with permissions restricted to `0600`. A short ARO-aware system prompt is
injected on first use.

## 5. CLI surface

| Invocation                     | Behaviour                                                           |
|--------------------------------|---------------------------------------------------------------------|
| `aro lm <prompt...>`           | One-shot: send the prompt, run tools, persist context, print reply |
| `aro lm` (no args, TTY)        | Interactive REPL (LineNoise-backed)                                 |
| `aro lm /clean`                | Delete `.context` in the current working directory                  |
| `aro lm /show`                 | Print the current context, truncated to 200 chars per message       |
| `aro lm /tools`                | List registered tools (built-ins + MCP bridges)                     |
| `aro lm /model`                | Print model name, path, backend hint                                |
| `aro lm /mcp`                  | List connected MCP bridges                                          |
| `aro lm /index`                | (Re)build the project vector index                                  |
| `aro lm /search <query>`       | Debug retrieval: print the top 5 matches                            |
| `aro lm /quit`                 | Exit the REPL                                                       |

Flags:

- `--model <id>` — override the model identifier (default
  `ARO-Lang/aro-coder-4bit`)
- `--yes` — auto-approve every `run_shell` tool call
- `--no-mcp` — skip MCP bridge bootstrap
- `--temperature <value>` — sampling temperature (default `0.2`)

## 6. Tool calling

Tools are exposed via the OpenAI-compatible `tools` array on
`/v1/chat/completions` and dispatched through an in-process `ToolRegistry`.
Each tool is an `LMToolDescriptor` value holding:

- A name
- A natural-language description
- A JSON schema for its parameters
- An async `execute(_:)` closure that receives a `JSONValue` and returns a
  `String`

Built-in tools (all path-scoped to the working directory):

| Tool             | Purpose                                                     |
|------------------|-------------------------------------------------------------|
| `read_file`      | Read a file with line numbers, optional offset/limit        |
| `write_file`     | Create or overwrite a file                                  |
| `edit_file`      | Exact-string replacement (must be unique)                   |
| `list_dir`       | Directory listing                                           |
| `grep`           | Regex search across files                                   |
| `run_shell`      | Execute a shell command — approval-gated in interactive mode |
| `aro_check`      | Run `aro check`                                             |
| `aro_run`        | Run `aro run`                                               |
| `aro_test`       | Run `aro test`                                              |
| `aro_build`      | Run `aro build`                                             |
| `parse_aro`      | Parse ARO source directly via `AROParser`                   |
| `list_actions`   | Return the verbs of every registered action                 |
| `list_proposals` | List proposals in the `Proposals/` directory                |
| `read_proposal`  | Read a proposal by ID                                       |
| `search_project` | Semantic search over the project index                     |

A tool-call loop runs up to 25 round-trips per `ask()`. Each tool result is
appended to the context as a `role: tool` message; the loop terminates when
the model returns an assistant message with no more tool calls.

### Safety

- All file/shell tools route paths through `PathGuard`, which normalises and
  verifies that the result stays inside the working directory.
- `run_shell` prompts the user for approval per command in interactive mode.
  `--yes` opts out; this is intended for one-shot CI-like invocations.
- `.context` is written `0600`.

## 7. Retrieval

`aro lm` ships an in-process retrieval subsystem so the model can look things
up on demand instead of receiving the whole project as context.

- **Indexer**: walks the working directory, skips `.git`, `.build`, vendor
  directories, chunks indexable files (`.aro`, `.md`, `.swift`, `.yaml`,
  `.yml`, `.json`, `.toml`) into 80-line windows.
- **Embedder**: default `HashingEmbedder` — a deterministic bag-of-hashed-
  n-grams vector with L2 normalisation. Requires no ML backend. A real
  embedding model can be plugged in by implementing the `Embedder` protocol.
- **Vector store**: flat cosine similarity, persisted as JSON at
  `.context.index/vectors.json`.
- **Tool**: `search_project(query, k?)` returns the top-k chunks with file
  path, line range and score.

Retrieval is **tool-gated, not auto-prepended** — the model calls
`search_project` when it needs to, keeping the context window small and under
its control.

## 8. MCP bridge

ARO already ships an MCP server (`aro mcp`) that exposes tools, resources and
prompts over stdio. `aro lm` bridges it — and any additional MCP servers
listed in `.context` under `mcp_servers:` — into the same `ToolRegistry` used
by the built-ins.

- On startup, each configured MCP server is spawned as a subprocess.
- The bridge performs the `initialize` → `initialized` handshake, then calls
  `tools/list` and translates every tool descriptor into an
  `LMToolDescriptor` whose name is prefixed with the bridge label (e.g.
  `aro_aro_check`).
- When the model calls a bridged tool, the bridge forwards the invocation as
  a `tools/call` JSON-RPC request and returns the textual response.

This gives `aro lm` access to every current and future tool the ARO runtime
exposes via MCP, without duplicating logic in AROLM.

## 9. Out of scope (follow-up issues)

- **Pure-Swift inference**: vendoring `llama.cpp` as a C target, or adopting
  `mlx-swift` directly, so there is no subprocess runner.
- **Multi-model registry**: switch between multiple models in a single
  session without restarting.
- **Real embedding backend**: swap `HashingEmbedder` for an ML embedder once a
  small GGUF/MLX embedding model is bundled.
- **Streaming tool-call execution**: execute tool calls as partial deltas
  arrive rather than at the end of a turn.
- **Incremental index invalidation**: re-embed only files whose mtime or
  content hash changed since the last `/index`.

## 10. File layout

```
Sources/AROLM/
├── LMCommand.swift          # ArgumentParser entry point + slash commands
├── LMSession.swift          # Session lifecycle, chat loop, slash helpers
├── ContextStore.swift       # .context YAML load/save
├── JSONValue.swift          # Sendable JSON tree
├── ModelManager.swift       # Hugging Face download + cache
├── Backend/
│   ├── LMBackend.swift      # Protocol + request/response types
│   ├── OpenAIClient.swift   # Shared chat-completions HTTP client
│   ├── ProcessRunner.swift  # Subprocess helpers
│   ├── LlamaCppBackend.swift
│   ├── MLXBackend.swift
│   ├── RemoteBackend.swift
│   └── BackendFactory.swift
├── Tools/
│   ├── LMTool.swift
│   ├── ToolRegistry.swift
│   ├── PathGuard.swift
│   ├── FileTools.swift
│   ├── ShellTool.swift
│   ├── AROTools.swift
│   └── ProposalTools.swift
├── Retrieval/
│   ├── Embedder.swift
│   ├── VectorStore.swift
│   ├── ProjectIndexer.swift
│   └── SearchTool.swift
├── MCP/
│   └── MCPClientBridge.swift
└── Resources/
    └── model-manifest.json
```
