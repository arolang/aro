# Environment Variables

Every variable the ARO runtime, compiler, CLI or assistant reads, with the
default that applies when it is unset. Compiled from the reads in `Sources/`;
each row names the file that reads it, so a stale row is checkable.

Reading an *arbitrary* variable from ARO code is a different thing and always
available:

```aro
Get the <api-key> from the <env: "API_KEY">.
```

`<env: NAME>` answers `""` for a variable that is not set.

---

## Execution

| Variable | Default | What it does |
|---|---|---|
| `ARO_NO_DEFER` | unset | Any value disables ARO-0088 deferred execution: every action runs at its own statement. The fastest way to find out whether a bug is an ordering bug. `LazyActionPolicy.swift:104` |
| `ARO_FORCE_WARN_SECONDS` | `5.0` | Seconds before a blocked `force()` prints a slow-wait warning to stderr. `0`, `off`, `false`, `no` disable it — **and so does any unparseable value**. `AROFuture.swift:266` |
| `ARO_STREAM_PREFETCH` | `2` | How many elements a stream producer may run ahead of its consumer. `RuntimeConfig.swift:44` |
| `ARO_MAX_CALL_DEPTH` | `50000` | Live user-action frames before a runaway recursion is stopped with a named call chain. `0` disables the check. `RuntimeConfig.swift:62` |
| `ARO_DEBUG` | unset | Any value turns on assorted stderr diagnostics: plugin registration and loading, date-range resolution traces. |

## HTTP and request bodies

| Variable | Default | What it does |
|---|---|---|
| `ARO_MAX_BODY` | `1MB` | Default limit on a request body that becomes a value, for routes with no `x-aro-max-body`. Accepts `1MB`, `512KB`, `2MiB` or a byte count. The route's own declaration still wins. `RuntimeConfig.swift:123` |
| `ARO_BODY_CHUNK_SIZE` | `64KB` | Chunk size for streamed request bodies and streamed file writes. `RuntimeConfig.swift:132` |
| `ARO_HTTP_PORT` | unset | Overrides the HTTP bind port — beats the `with` clause, the specifier, a literal and the OpenAPI contract. Also overrides `<contract: port>`. `ServerActions.swift:125` |
| `ARO_SOCKET_PORT` | unset | Same, for the socket server. `ExecutionContext.swift:639` |
| `ARO_HTTP_CONCURRENCY` | `8` | Process-wide cap on concurrent outgoing HTTP fetches. `HTTPClient.swift:57` |
| `ARO_OPENAPI_SERVER` | first entry | Which root `servers[]` entry to bind when the spec declares several: a zero-based index, or a server `description`. `OpenAPILoader.swift:132` |

## Repository observers

| Variable | Default | What it does |
|---|---|---|
| `ARO_ASYNC_OBSERVERS` | off | `1`, `true` or `yes` routes repository observers through the bounded pool. **Changes ordering**: `Store` then returns before its observers finish. `RuntimeConfig.swift:81` |
| `ARO_OBSERVER_WORKERS` | `max(4, cores × 2)` | Workers draining the observer queue when the above is on. `RuntimeConfig.swift:91` |
| `ARO_OBSERVER_QUEUE_CAPACITY` | `4096` | Queued-but-undispatched observer work items; producers suspend when full. `RuntimeConfig.swift:101` |

## Building and linking

| Variable | Default | What it does |
|---|---|---|
| `ARO_LIB_PATH` | discovery | Absolute path to `libARORuntime.a`, checked first when linking. `CompilationStrategy.swift:311` |
| `ARO_BIN` | discovery | The `aro` binary. In the CLI its *directory* is searched for the runtime archive; in `aro ask` it selects which `aro` the assistant shells out to. |
| `SWIFT`, `SWIFTC` | toolchain discovery | The `swift` driver and `swiftc` used to build Swift plugins. |
| `ARO_SWIFTC_PATH` | — | A further `swiftc` override, consulted after `SWIFTC` and `PATH`. |
| `ARO_CC_PATH`, `ARO_CXX_PATH`, `ARO_CARGO_PATH`, `CARGO` | discovery | Explicit `clang`, `clang++` and `cargo` for rebuilding C, C++ and Rust plugins. |
| `SWIFT_PATH`, `SWIFT_LIB_PATH` | discovery | Swift binary and Swift runtime dylib directory for the plugin host and the linker. |
| `SDKROOT` | discovery | Windows linking: where to find Swift import libraries and `swiftrt.obj`. |

`DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH` and `DYLD_INSERT_LIBRARIES`
are read only to be **removed** from the environment handed to `cargo`,
`rustc` and `swift build`, so they do not load ARO's own `libLLVM`.

## REPL, kernel and tools

| Variable | Default | What it does |
|---|---|---|
| `ARO_REPL_PLUGINS_DIR` | `~/.aro/repl-plugins` | Where an interactive session keeps its plugins. |
| `ARO_REPL_ALLOW_BLOCKING` | unset | Exactly `"1"` lets a REPL or notebook cell run a blocking verb — starting a server and waiting — instead of being rejected. |
| `ARO_BASE_PATH` | discovery | ARO installation root for `aro mcp`; accepted only if `<path>/Proposals` exists. |
| `JUPYTER_DATA_DIR`, `XDG_DATA_HOME` | platform default | Where `aro kernel install` writes the kernelspec. |

## `aro ask`

| Variable | Default | What it does |
|---|---|---|
| `ARO_ASK_ENDPOINT` (alias `ARO_LM_ENDPOINT`) | unset | An OpenAI-compatible endpoint; when set it wins over the local backends. |
| `ARO_ASK_API_KEY` (alias `ARO_LM_API_KEY`) | none | Bearer key for that endpoint. |
| `ARO_ASK_VERBOSE` | unset | Any value un-silences the backend subprocess and dumps raw model output. `--verbose` sets it. |
| `ARO_SYSTEM_PROMPT_FILE` | built-in prompt | A file whose contents replace the assistant's system prompt. |
| `HF_HOME`, `HF_TOKEN` | `~/.cache/…`, anonymous | HuggingFace cache root and token for model downloads. |

## Terminal capabilities

`TERM`, `COLORTERM`, `TERM_PROGRAM`, `LINES`, `COLUMNS`, `LANG`, `LC_ALL` are
read with their conventional meanings for colour, size and encoding detection.
On Windows, `WT_SESSION` and `PROMPT` stand in for a TTY check.

**There is no `NO_COLOR` support.** Colour is decided by `isatty()` plus `TERM`
and `COLORTERM`. Commands that produce colour accept `--no-color`.

`ARO_METRICS_SOCKET` is set by Solaro but read by nothing; it is not a
supported knob.
