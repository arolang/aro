# ARO Fact Sheet

Facts about ARO as of `main` (2026-09-20, installed toolchain 0.12.x). One line per fact
where possible. Where documentation layers disagree, the implemented behaviour is stated
and the disagreement is tracked in `MISSING.md` and GitLab. No tutorials, no examples.

Source-of-truth order: `Proposals/` > `Sources/` > Wiki/`OVERVIEW.md` > `Website/` > `Book/`.

---

## 1. Identity

- ARO = Action-Result-Object. A declarative, event-driven DSL for business features; every statement is `Action [article] <Result[: qualifier]> preposition [article] <Object[: qualifier]>.`
- Reference implementation: Swift 6.3 package (`Package.swift`, platform `.macOS(.v15)`), MIT licence, GitLab `git.ausdertechnik.de/arolang/aro` (canonical, `origin`), GitHub mirror `github.com/arolang/aro` (wiki, releases, website `arolang.github.io/aro`).
- Modules: `AROParser` (lexer, parser, AST, semantic analysis), `ARORuntime` (interpreter + C-callable bridge), `AROCompiler` (LLVM code generation, linker), `AROCLI`, `AROLSP`, `AROPackageManager`, `AROAsk`, `AROVersion`, `SOLARO` + `SOLAROLauncher` + `AROXPCService/Protocol` (macOS IDE), `LineNoise` (vendored), C shims `Clibgit2`, `CZeroMQ`, `AROCDebugInfo`.
- Size: `Sources/` ≈ 186 k lines Swift; `ARORuntime` 208 files / 80 k lines; `SOLARO` 137 files / 51 k lines.
- Language specified by 67 numbered proposals in `Proposals/` (`ARO-0001` … `ARO-0091`, sparse). `Scripts/check-proposals.py` (CI) enforces unique IDs, front-matter = filename, and that every `ARO-NNNN` reference resolves — which is why this sheet names no "next free" number: writing one down is itself a reference to a proposal that does not exist.
- Issue citations are written `GitLab #<n>`; `ARO-` is reserved for proposals.
- Documentation: 45-page GitHub wiki, 12 books under `Book/` (Language Guide 55 chapters; Plugin Guide; Essential Primer; Short Studies; Construction Studies; Debugging Guide; Interactive Dialog; ARO By Example; ARO for Data Engineers; ARO by Hallucination; Solaro; Reference), `Website/`, `OVERVIEW.md`, `CLAUDE.md`. `README.md` was emptied by commit 0d881385 and is restored in !583 (GitLab #680).
- `Examples/`: 109 directories, 102 carry a `test.hint` (`mode: both|interpreter|compiled|test`). CLAUDE.md says 110 and lists 57 of them.
- Tests: `Tests/AROParserTests`, `Tests/AROuntimeTests` (sic), `AROCompilerTests`, `AROCLITests`, `AROLSPTests`, `AROAskTests`, `AROPackageManagerTests`, `SOLAROTests`, `IntegrationTestsRunner` (Perl harness `run-tests.pl` over `Examples/*/test.hint`). Last recorded full run: 2518 tests.
- CI: `.gitlab-ci.yml` (Linux x86_64 build/test/integration/release, macOS via GitHub `build.yml` incl. signing + notarisation on tags, Windows `swift build` job, Docker `ghcr.io/arolang/aro-buildsystem` and `aro-runtime` for amd64+arm64).
- Distribution: Homebrew tap `arolang/aro` (macOS), `aro-linux-amd64.tar.gz` (binary + `libARORuntime.a`), `aro-macos-arm64.tar.gz`, `aro-windows-amd64.zip` (CI artifact), Solaro `.dmg`, Language Guide PDF on the latest release.

## 2. Toolchain and CLI

- Binary `aro`; `aro --version`; `aro help <sub>`; no-argument invocation with piped stdin evaluates the source as a script (`echo '…' | aro`, no banner, no `[fs]` prefix).
- Subcommands (20): `run` (default), `debug`, `build`, `compile`, `check`, `diff`, `test`, `repl`, `new`, `add`, `remove`, `plugins`, `actions`, `ui`, `lsp`, `mcp`, `ask`, `kernel`, plus `help`.
- `aro run <path> [app-args…]`: `-e/--entry-point`, `-v`, `--keep-alive`, `--debug` (developer output context), `--record <json>`, `--replay <json>`, `--debug-record <jsonl>` (per-statement events for Solaro). Everything after the path reaches the program as `<parameter: …>`. `aro run` does not `chdir` into the application directory.
- `aro build <path>`: `-o`, `--optimize` (O2 + thin LTO), `--size` (Os), `--strip`, `--release` (= optimize + size + strip), `--static` (default), `--dynamic`, `-v`, `--keep-intermediate` (`.build/<App>.ll`, `.o`), `--emit-llvm`, `--sign <identity>`, `--hardened-runtime` (macOS). `--static` with `--dynamic` is an error. Output `<App>/<App>` (or `-o`).
- `aro compile <path>`: `-f/--format report|json|ast`, `-v`.
- `aro check <path|->`: `--warnings/--no-warnings`, `--verbose`, `--syntax` (bare snippet); subcommands `source` (default) and `plugins [--directory]`. Reports errors, warnings, unknown qualifiers, unknown `Application.<Name>`, non-terminating recursion, unused variables, circular event chains, orphaned emissions, per-route request-body policy (`streams` / `holds ≤ N`), Sleep unit warnings, `Map … with <expr>` misuse, invalid `Split … with`, unknown Delete predicates, state-enum violations.
- `aro test <path>`: `-v`, `--filter <pattern>`, `--no-color`, `--record <jsonl>`. Output `PASS|FAIL|ERROR name (<ms>)` and totals.
- `aro debug [path] [app-args…]`: `-e`, `--breakpoint <line|Verb>` (repeatable), `--break-condition "LINE=<expr>"`, `--logpoint "LINE=msg {var}"`, `--dap` (stdio), `--dap-port <n>` (127.0.0.1, one client), `--dap-log`, `--record <jsonl>`, `--replay <jsonl>`, `--sample <N>`, `-v`.
- `aro repl`: `-l/--load <file>`, `--no-color`, `--json` (line-delimited JSON protocol, ARO-0091).
- `aro kernel`: `--connection-file <path>` (native Jupyter kernel over ZeroMQ, wire protocol 5.3); `aro kernel install [--dir]` writes the kernelspec (absolute path of the installing binary).
- `aro diff <range>`: `--directory`, `--graph`, `--html <file>`, `--all`. Compares feature-graph nodes, statements and wires between two git revisions.
- `aro new plugin <name>`: `--name`, `--lang swift|rust|c|cpp|python|aro` (required), `--handle`, `--actions` (default), `--qualifiers`, `--services`, `--system-objects`, `--events`, `--templates`, `--hybrid`, `-d`.
- `aro add <git-url|github:org/repo>`: `--ref`, `--branch`, `-d`. `aro remove <name>`. `aro plugins [list|update [name] [--ref]|export|restore|check|validate|rebuild <name>|docs <name> [--html] [--output]] [-d] [--verbose]`; `.aro-sources` holds exported Git URLs.
- `aro actions [name-or-verb] [-d] [--qualifiers] [--format text|json]`; verb aliases resolve (`Keepalive` → `WaitForEvents`).
- `aro lsp [--debug]` (stdio JSON-RPC, server name `aro-lsp`); `aro mcp` (Model Context Protocol server over stdio; tools `aro_check`, `aro_run`, `aro_compile`, `aro_examples`, `aro_actions`, `aro_qualifiers`, `aro_parse`, `aro_syntax`; resources and prompts).
- `aro ask [prompt]`: `--model` (default `ARO-Lang/aro-coder-6bit`), `--yes`, `--no-mcp`, `--temperature` (0.2), `-v`, `--no-think`, `--file`. Slash commands: `/help /clean /file /show /tools /model /mcp /index /search /fix /explain /docs /plugin /openapi /quit`. 18 tools (read/write/edit/list/grep/run_shell, parse_aro, aro_check/run/test/build, aro_knowledge, list_actions, list_proposals, read_proposal, create_plugin, write_openapi, generate_docs); 25-round tool loop; `PathGuard` confines paths; `.context` YAML per directory (mode 0600); `.context.index/vectors.json` for retrieval.
- `aro ui [dir]` launches Solaro. `aro lsp`, `aro mcp`, `aro ask`, `aro kernel` are compiled only on macOS and Linux.
- Environment variables read by the toolchain/runtime: `ARO_NO_DEFER`, `ARO_FORCE_WARN_SECONDS` (5), `ARO_ASYNC_OBSERVERS`, `ARO_OBSERVER_WORKERS` (`max(4, cores×2)`), `ARO_OBSERVER_QUEUE_CAPACITY` (4096), `ARO_HTTP_CONCURRENCY` (8), `ARO_STREAM_PREFETCH` (2), `ARO_MAX_CALL_DEPTH` (50 000; 0 = unlimited), `ARO_MAX_BODY`, `ARO_BODY_CHUNK_SIZE`, `ARO_HTTP_PORT`, `ARO_SOCKET_PORT`, `ARO_OPENAPI_SERVER`, `ARO_DEBUG`, `ARO_METRICS_SOCKET`, `ARO_REPL_ALLOW_BLOCKING`, `ARO_REPL_PLUGINS_DIR`, `ARO_LIB_PATH`, `ARO_BIN`, `ARO_SWIFTC_PATH`, `ARO_CARGO_PATH`, `ARO_CC_PATH`, `ARO_CXX_PATH`, `ARO_PLUGIN_SDK_IMPLEMENTATION`, `ARO_ASK_ENDPOINT`, `ARO_ASK_API_KEY`, `ARO_ASK_VERBOSE`, `ARO_LM_ENDPOINT`, `ARO_LM_API_KEY`, `ARO_SYSTEM_PROMPT_FILE`, `ARO_UPDATE_FEED`, `ARO_BASE_PATH`, `ARO_LOG_LEVEL`, `ARO_SHUTDOWN`, `ARO_EMBEDDED_RUNTIME`, `ARO_APPIMAGE`, `ARO_KERNEL_ARO` (Python shim), plus `SWIFT_LIB_PATH`, `LLVM_PATH`, `SDKROOT`, `HF_HOME`, `HF_TOKEN`, `SOLARO_ARO`.

## 3. Application structure

- An application is a directory; every `.aro` file in it and all subdirectories is discovered (a `sources/` subtree is conventional). No imports are needed inside an application; all feature sets are globally visible. An `import <relative-path>` declaration exists in the grammar and the loader resolves import paths (cross-application use, sparsely documented).
- Exactly one `(Application-Start: …)`; at most one `(Application-End: Success)` and one `(Application-End: Error)`. Errors: "No entry point defined", "Multiple entry points found in: …", "Multiple exit handlers found".
- Optional companions: `openapi.yaml|.yml|.json` (HTTP contract, also the only type-definition source), `<name>.store` (YAML-seeded repositories), `Plugins/<name>/plugin.yaml`, `templates/` (Mustache-style templates), `.layout.json` (Solaro canvas sidecar), `test.hint` (integration harness).
- Duplicate feature-set names across files are a compile error; there is no namespacing.
- Lifecycle: discover → parse → analyse → register handlers (socket, WebSocket, domain, plugin, notification, file, repository observer, eviction, watch, state observer, key-press) → publish `ApplicationStarted` → run Application-Start → event loop while services/Keepalive hold it → SIGINT/SIGTERM or error → stop accepting → drain pending events (10 s timeout, stall detection) → `Application-End: Success|Error` → stop services → exit (0 / non-zero).
- Shutdown context: `<shutdown: reason>`, `<shutdown: code>`, `<shutdown: signal>` (Success only), `<shutdown: error>` (Error only). Reading a missing field is a hard error.
- `aro run` exits when Application-Start returns unless `Keepalive the <application> for the <events>.` (verbs `keepalive|wait|block`, role SERVER) or `--keep-alive` holds it; `Emit` inside Application-Start waits for the whole handler cascade, so batch jobs need no Keepalive.
- Every `aro` process exposes a metrics socket `$TMPDIR/aro-metrics-<pid>.sock`.

## 4. Lexical structure

- UTF-8 source, `.aro` extension, whitespace-insensitive, statements end with `.`; no period after a closing `}` of `match`/loops.
- Comments: `(* … *)` (non-nesting) and `// …`.
- Identifiers: letter followed by letters/digits/hyphens; compound names like `user-repository`; case-sensitive; convention lowercase-hyphenated. A hyphen segment may not be a reserved word (`<from-date>`, `<by-status>`, `<content-type>` fail; GitLab #566). `type` is reserved as a segment (quote it: `<event: "type">`).
- Articles `a`, `an`, `the` are optional tokens with no semantics.
- Prepositions (10): `from`, `for`, `against`, `to`, `into`, `via`, `with`, `on`, `at`, `by`. `as` is the Publish/type keyword.
- Reserved words include: `as true false null empty and or not is exists defined contains matches in when match case otherwise default where for each at parallel concurrency while break import require publish takes` and the status names (`OK Success Created Accepted NoContent BadRequest Invalid Unauthorized Forbidden NotFound Conflict Error ServerError`).
- Strings: `"…"` may span lines (GitLab #523); escapes `\n \r \t \\ \" \' \0 \u{…}`; interpolation `${expr}` (`${<var>}`, `${<var: field>}`); `'…'` raw, single line, only `\'` escapes; `"""` triple quotes were removed (dedicated diagnostic, GitLab #524). String concatenation operator `++`.
- Numbers: decimal, `0x` hex, `0b` binary, floats with `.` and `e/E` exponent, `_` separators between digits only (ARO-0082). Integer division truncates in both execution modes.
- Booleans `true`/`false`; `null`; arrays `[…]`; objects `{ key: v, "quoted-key": v }`.
- Regex literals `/pattern/flags`, flags `i s m` (`g` reserved). `/` is division after an identifier, `.`, or when followed by whitespace; otherwise a regex scan is attempted.
- Delimiters: `( ) { } < > [ ] : . , -`. `..`/`..<` range operators are specified (ARO-0089) but not implemented.

## 5. Statements and control flow

- Feature set: `(Name Words: Business Activity) { … }`; optional header guard `(Name: Activity) when <cond> { … }`; the business activity decides how the set is triggered (§12).
- ARO statement: `Verb [article] <result[: qualifier…]> preposition [article] <object[: qualifier…]> [with …] [where …] [by …] [when <cond>].` Verbs are bare identifiers (the `<Verb>` spelling was removed, GitLab #574) and case-insensitive.
- Sink syntax (ARO-0043): an expression in result position, no article, binds nothing: `Log "x" to the <console>.`, `Send <m> to the <c>.`, `Notify the <u> with "…"`.
- Namespaced verbs: `Application.<Name>` (user-defined action) and `<Handle>.<Verb>` (plugin action).
- `Publish as <alias> <variable>.` — alias and original both usable; visible only inside the same business activity; lifetime = the publishing execution (process lifetime when published from Application-Start/End). No trailing `when`.
- Guards: statement suffix `… when <cond>.`; block `when <cond> { … }` (no new scope, no `else`; a `Return` inside ends the feature set).
- `match <noun> { case <pattern> [where <cond>] { … } … otherwise { … } }`; patterns: literal, `<variable>`, `/regex/flags`, `_`; first match wins; any statement allowed inside a case (ARO-0068).
- `for each <item> [at <index>] in <collection|expression> [where <cond>] { … }`; collection evaluated once; noun form may stream in O(1) memory; loop variable immutable per iteration in a child scope.
- `parallel for each <item> in <coll> [with <concurrency: N>] [where <cond>] { … }`; non-deterministic completion; fresh child scope; no writes to outer bindings; default concurrency `min(count, max(4, cores×4))`; `N ≤ 0` clamps to 1 with a diagnostic.
- `for <n> from <a> to <b> { … }` (upper bound exclusive); `while <cond> { … }`; `Break.`.
- Pipeline operator `|>` (ARO-0067) is parsed as `PipelineStatement`; the accepted design is automatic pipeline detection without an operator (ARO-0086).
- Nine writable statement kinds: ARO, Publish, Require, Match, ForEach, RangeLoop, WhileLoop, Break, Pipeline; plus internal `ErrorStatement` for recovery.
- Dead code: statements after an unguarded `Return`/`Throw` warn `unreachable code after Return statement` (ARO-0062).

## 6. Expressions

- Arithmetic `+ - * / %`, string `++`, comparison `== != < > <= >=`, `is`, `is not`, `equals` (deep), `contains`, `matches /re/`, `in` / `not in`, `before` / `after` (dates), logical `and or not`, grouping parentheses, member access `.field`, `[index]`, `["key"]`, `exists`, `is defined`, `is null`, `is empty`, `is not empty`, `is true/false`, `<x> is [a|an] String|Number|Integer|Float|Boolean|List|Map|Date|<Identifier>`.
- Precedence (high → low): postfix `. []` → unary `-` → `* / %` → `+ - ++` → `default` → `< > <= >=` → `== != is contains matches in` → `not` → `and` → `or`. `not <a> == <b>` negates the comparison (GitLab #572). No operand-shape rewriting (GitLab #520).
- `default` operator: `expr default expr`; left wins when present (missing variable, missing field, explicit null are absent; `false`, `0`, `""`, `[]` are present); errors are not swallowed; left-associative; also the query fallback inside `where`. `or` is boolean only; a non-boolean literal under `and`/`or` is an error naming `default` (GitLab #575).
- `contains` dispatches on the left operand (list → element, string → substring, map → key); `in` dispatches on the right operand (list, string, map, date-range).
- A qualified reference `<x: field>` is a valid operand (GitLab #496). `<now>` is a magic variable (UTC ISO-8601); `<metrics>` too; `<today>/<tomorrow>/<yesterday>` are specified (ARO-0041) but not implemented.

## 7. Variables and scope

- Variables are declared implicitly by the result of REQUEST/OWN statements, immutable for the feature set's lifetime; rebinding is a compile error and a runtime refusal (statement fails, process survives; GitLab #495). `_`-prefixed framework variables are exempt; user code must not use the prefix.
- Qualifier-as-name: `<len: length>` binds `len`; legacy `<length>` (base = operation) still works.
- Visibility: internal (feature set), published (same business activity), external (runtime-provided).
- Framework variables: `request`, `body`, `headers` (via `<request: headers…>`), `pathParameters`, `queryParameters`, `event`, `connection`, `packet`, `transition`, `shutdown`, `input` (user actions), `parameter`, `env`, `now`, `metrics`, `terminal`, `template`, `context`; transient statement-scope names `_with_`, `_literal_`, `_expression_`, `_where_value_`, `_to_`, `_against_` … (21 keys in `FrameworkVariables.transientKeys`, cleared per statement in both modes, GitLab #552).
- Each statement gets its own scope for modifiers so deferred actions never read the next statement's `with`.
- Loop iterations and handler executions run in child contexts; feature sets never share locals; sharing goes through repositories, published symbols, and events.

## 8. Types

- Primitives: String, Integer, Float, Boolean (ARO-0003) plus DateTime (ARO-0019); collections `List<T>`, `Map<K,V>`; Bytes/Binary for unknown file formats.
- All complex types come from `openapi.yaml` `components.schemas`; no `type`/`enum` keywords. A contract without `paths` supplies types only.
- Annotations: `<name: String>`, `<items: List<String>>`, `<user: User>`, result `as` clause (`Compute the <n> as Float …`, `Compute … as Money`). `as` is a separate AST slot (GitLab #475).
- Typed extraction (ARO-0046): a PascalCase, letters-and-digits qualifier on the result (`<data: OrderCreated>`) validates against the schema (required properties, types, formats); errors list available schemas.
- Widening Integer → Float is silent; narrowing warns. No optional types: absence fails the statement ("Cannot …") or is handled with `default`/`exists`.
- Value display: console renders Doubles with 15 significant digits; `Write`/HTTP serialise full precision (JSON writer emits up to 17 digits).

## 9. Actions

- Five roles: `request` (external → internal), `own` (internal), `response` (internal → external), `export` (globally visible / emitted), `server` (services). Roles drive preposition validation, data-flow analysis, deferral policy, and `aro actions` grouping.
- 71 built-in actions, ~130 verbs, registered by eleven modules (Request, Own, Response, Server, Socket, File, DataPipeline, Test, Terminal, System, Git — Git is compiled out on Windows). Actions are stateless `Sendable` structs instantiated per execution; `ActionRegistry.shared` maps lowercase verbs to implementations; `ActionRunner.verbMappings` canonicalises synonyms.
- Registered table (name · role · prepositions · verbs):
  Accept own on accept · Append response into,to append · Assert own for,with assert · Broadcast response to,via broadcast · Call own from,to,via,with call,invoke · Clear own for clear · Clone request from,to,with clone · Close server from,with close,disconnect,terminate · Compare own against,from,to,with compare,match · Compute own for,from,with calculate,compute,derive · Connect server to,with connect · Copy server to copy · Create own for,from,to,with build,construct,create · Delete own for,from clear,delete,destroy,remove · Emit export to,with emit · Execute own for,on,with exec,execute,run,shell · Exists request for exists · Extract request from,via extract,get · Filter own from filter · GitCheckout own from,to,with checkout · GitCommit export to,with commit · Given own with given · Group own from group · Include own from embed,include,insert · Join own from join · List request from list · Listen server for,on,to await,listen · Log response for,to,with debug,log,output,print · Make server at,for,to createdirectory,make,mkdir,touch · Map own from,to map · Merge own from,with combine,merge · Move server to move,rename · Notify response for,to,with alert,notify,signal · ParseDispatch request from parse · ParseHtml own from parsehtml · ParseLinkHeader own from (no verb) · Probe request from,with probe · Prompt request from,with ask,prompt · Publish export with export,expose,publish,share · Pull request from pull · Push export to,with push · Read request from read · Receive request from,via receive · Reduce own from,with aggregate,reduce · Render response to render · Repaint response at,to patch,repaint · Request request from,to,via,with http,request · Retrieve request from fetch,find,load,retrieve · Return response for,to,with respond,return · Reverse own for,from,with flip,reverse · Schedule export with schedule · Select request from,with choose,select · Send response to,via,with dispatch,send · Show own for show · Sleep own for,with delay,pause,sleep · Sort own for,from,with arrange,order,sort · Split own from split · Stage own for,to stage · Start server with start · Stat request for stat · Stop server with stop · Store response into,to persist,save,store · Stream request from,with stream,subscribe · Tag export for,with tag · Then own with then · Throw response for fail,raise,throw · Transform own from,into,to convert,map,transform · Update own for,from,into,to,with change,configure,modify,set,update · Validate own against,for,with check,validate,verify · WaitForEvents server for block,keepalive,wait · When own from when · Write response into,to write.
- Verb collisions: `clear` (Clear vs Delete), `map` (Map vs Transform), `wait` (WaitForEvents vs an alias to Listen in `ActionRunner`).
- `Extract`: `from` a framework object or record; result specifiers `first`, `last`, `n` (reverse index: 0 = last), `a-b` (inclusive, clamped), `a,b,c` (pick); out of bounds → nil.
- `Retrieve` (`fetch|find|load`): repository read, all rows or `where` filter; a miss binds an empty list (never throws); `<repo: last|first|0>` single element; also `<git>` status/log/branch.
- `Request` (`http`): `from` = GET, `to` = POST, `via PUT|DELETE|PATCH`, `with { method, headers, body, timeout }` (seconds, default 30); result record `body`, `status`, `headers`; JSON bodies auto-parsed.
- `Read`/`Write`/`Append`: files (format-aware by extension, §16), `<url: …>` (GET/POST), `<stdin>`; `Append` content goes in `with`.
- `Probe`: reachability envelope `{ target, reachable, status?, latency?, reason? }`, default timeout 2 s, never throws on connect failure.
- `Create … with <value|{…}>`; `Compute` (§10); `Transform … from <x> [into|to …]` (type conversion `JSON`, `int`, `double`, `bool`, `string`; template rendering with `<template: path>`); `Merge … from <a> with <b>` (records, arrays, strings); `Update <obj: field> with <v>` / `Update <obj> with {…}` / `Update <patch> into <repo> where …`; `Delete … from <repo> where <one predicate>` (no `where` = clear all) or `from <file|directory: path>`.
- `Validate … for <x> [against /re/|schema] [with …]` binds a fresh result (currently a placeholder that does not validate). `Compare the <r> from <a> against <b>` binds `<r: matches>` (Bool) and `<r: result>` (`equal|less|greater`) (GitLab #469).
- `Sort the <r> for <list> [by <field>|"field"] [descending]` (records need `by`, uniform types), `Reverse`, `Split … by /re/` (never `with`), `Join`, `Group … by "field"`, `Filter … where`, `Map … with <field>` / `Map <r: field>` / schema projection `Map the <r: List<Schema>>`, `Reduce … with sum(<f>)|count()|avg|min|max|first|last`.
- `Return a <Status: status> [with <payload>|for <noun>]`: names `OK|Success` 200, `Created` 201, `Accepted` 202, `NoContent` 204, `BadRequest|Invalid` 400, `Unauthorized` 401, `Forbidden` 403, `NotFound` 404, `Conflict` 409, `Error|ServerError` 500; any other name → 200. `with <record>` = top-level fields; `with <list>` wraps as `{"data": […]}`; scalar → `{"value": …}`. `Throw a <Name: error> for <ctx>` always surfaces as 500.
- `Log <expr> to the <console|console: error|stderr>` (`for … with` form also accepted); `Send <x> to <connection|client-id|websocket-connection>`; `Broadcast <x> to <socket-server|websocket>`; `Notify|Alert|Signal` emit `NotificationSent`.
- `Store the <x> into|to the <name-repository> [with {…}]` (`in` is a parse error); upsert by `id` (UUID generated), else by `name`/`key`; plain values append; arrays flatten to one row each; duplicates are no-ops without observer events; binds `new-entry` (1/0) and `<stored: x>` captures the stored record.
- `Emit a <Name: event> with <payload|{…}>` (also `to`); the emitter waits for every matching handler cascade; payload forced once, memoised.
- `Publish as`, `Schedule … with 30|"2 seconds"` (timers; consumed as `Timer`-style handlers), `Commit|Push|Tag` (§20).
- `Start the <http-server> with <contract>|{ port, websocket }`, `Start the <socket-server> with { port }`, `Start the <file-monitor> with "path"|{ directory }`, `Stop … with <application>|{}`, `Listen the <keyboard> to the <stdin>`, `Connect the <c> to the <host> with { port }`, `Close … with|from`, `Make the <dir> to|at the <path: …>` (mkdir -p; verbs `touch|mkdir|createdirectory`), `Copy|Move the <file|directory: src> to the <destination: dst>`.
- `Execute|Exec|Run|Shell the <r> for the <command: "prog"> with "arg"|[args]|{ command, workingDirectory, environment, timeout (ms, 30000; ≤0 unlimited), shell (/bin/sh), captureStderr }`; result `{ error, message, output, exitCode (-1 on timeout/start failure), command }`; SIGTERM then SIGKILL after 2 s on the process group; never deferred.
- `Sleep the <r> for 500ms|2s|1m|1h|<var> seconds`; a bare number is seconds; `aro check` warns on bare literals > 60.
- `Call the <r> from the <service: method> with {…}` (built-in `http` service: get/post/put/patch/delete → `{ status, headers, body }`; plugin services).
- Terminal: `Prompt the <name> from the <terminal>` (`<pw: hidden>`), `Select the <choice> from <options> from the <terminal>` (`multi-select`), `Clear the <screen|line> for the <terminal>`, `Show`, `Render … to the <console|terminal>`, `Repaint`.
- Testing: `Given the <v> with <value>`, `When the <r> from the <feature-set-name>`, `Then the <v> with <expected>`, `Assert the <v> with|for <expected>`.
- Error philosophy (ARO-0006): happy path only; a failing statement produces `Cannot <verb> the <result> [prep] the <object> [where …]` with resolved values; HTTP maps every uncaught error and every `Throw` to 500 with `{"error": "Runtime Error: …\n Feature: …\n Business Activity: …\n Statement: …"}` (the finer 400/404/422 mapping in ARO-0006 is not implemented). Messages expose values; not for public production APIs.

## 10. Compute qualifiers

- `Compute the <r[: qualifier]> from <x> [with …]`; also arithmetic expressions `Compute the <t> from <a> * <b>`.
- The qualifier namespace is closed (ARO-0019 §3.3, GitLab #486): built-in, plugin `handle.qualifier`, chain `a|b|c` (left to right, `with` shared), or a date offset `-7d|+24h`; anything else is a check-time error naming the closest match. Names live in `ComputeQualifierCatalog` (parser) and `ComputeAction.builtInQualifiers` (runtime); a test keeps them equal; `aro actions --qualifiers` prints the live set.
- 34 built-ins: `average`, `avg`, `base64-decode`, `base64-encode`, `base64url-decode`, `base64url-encode`, `clip` (`with N`), `count`, `date` (parse ISO-8601), `difference`, `distance` (`to <date>`), `fixed` (N places, default 2; stays numeric), `format` (date pattern; the pattern argument is ignored, GitLab #577), `hash` (SHA-256 hex, unsalted), `html-escape`, `identity`, `intersect`, `join` (`with { separator }`), `json-escape`, `length`, `lines`, `lowercase`, `markdown` (Markdown → HTML), `random` (element, or Int below a bound), `replace` (`with { find, replace }`), `sha256`, `sum`, `take` (`with N`), `trim`, `union`, `unique`, `uppercase`, `url-decode`, `url-encode`.
- Set qualifiers: lists are multisets (intersect keeps duplicates up to the minimum count; difference subtracts; union = A then unique B); strings work per character; objects recurse (A wins on union).
- Streaming folds (ARO-0090): `sha256|hash`, `length|count|size` (bytes), `lines` fold a request body chunk-wise; chains fold only if every stage folds.
- Not qualifiers: `sort`, `reverse`, `first` (actions/specifiers), `round|money|currency|precision` (redirect to `fixed`), types (`as`). `date|+1d` as a written chain does not parse.

## 11. Queries, pipelines, streams

- `where` clause: field as `<field>` or bare `field` (GitLab #545); operators `is`, `=`, `==`, `is not`, `!=`, `<`, `<=`, `>`, `>=`, `in [list]`, `not in`, `between lo and hi`, `contains`, `starts with`, `ends with`, `matches /re/`; `and` binds tighter than `or`; parentheses; malformed clauses are check-time errors (GitLab #498). Repository `Retrieve` with a single predicate matches on equality only (GitLab #565). `Delete … where` takes one predicate. `order by`, `limit`, `offset` and window functions (ARO-0018 §6) are specified but not implemented.
- `Filter` over scalar lists matches elements themselves (GitLab #569). `Map` has no per-element binding (`with <expr>` is a check-time error, GitLab #465).
- Streaming (ARO-0051/0086): variable chains form a DAG detected in `SemanticAnalyzer`; linear chains stream in O(1) memory, same-op fan-out fuses aggregations, different-op fan-out uses a stream tee, diamonds materialise. Files ≥ 10 MB and collections ≥ 10 000 elements are treated as streams; 64 KB chunks; producer runs `ARO_STREAM_PREFETCH` elements ahead over a bounded channel; barriers (Sort, Group, `unique`) spill to disk (`ExternalSort`, `SpillableHashMap`). Directory listing is a pull-based lazy stream (issue #198).

## 12. Events and feature-set triggers

- Business-activity matching (in classification order): `" Watch:"` in the name → watch handler; `{field} StateObserver` / `StateObserver<from_to_to>`; `StateTransition Handler<field:value>`; `KeyPress Handler`; `Socket Event Handler`; `WebSocket Event Handler`; `File Event Handler`; `NotificationSent Handler`; `{name}-repository Observer`; `{name}-repository Evicted Handler`; `{EventName} Handler` (with optional state guard); `Action` (user-defined, not an event); `operationId` (HTTP route) or a webhook name; `Application-Start|End`.
- `{EventName} Handler` fires only on `Emit`; `<event>` is the payload, `<event: field>` a field; multiple handlers per event run concurrently in unspecified order, fault-isolated; storing does not raise domain events.
- State guards (ARO-0022): `Handler<field:value>` immediately after `Handler`; `,` = OR, `;` = AND, dotted nested paths; case-insensitive value match; non-matching handlers are skipped silently. Values must be enum members of the contract when the field's schema declares an enum (GitLab #507).
- State transitions: `Accept the <transition: from_to_target> on <object: field>.` (build-time enum check, runtime check of current state); observers `({field} StateObserver)` / `StateObserver<from_to_target>` with `<transition: fieldName|objectName|fromState|toState|entityId|entity>`.
- Repository observers: `({name}-repository Observer)`; `RepositoryChangedEvent { repositoryName, changeType created|updated|deleted, entityId?, newValue?, oldValue?, timestamp }`; one event per stored list element; seeded `.store` rows do not fire; observers are dispatched and awaited on every write unless `ARO_ASYNC_OBSERVERS` is set. Eviction: `Configure the <x-repository: maxSize|ttl> with N` → `RepositoryEvictedEvent` → `({name}-repository Evicted Handler)`.
- File events (`File Event Handler`): the feature-set name must contain `created`, `modified` or `deleted` (case-insensitive) to select the event; a name with none receives all three with `<event: kind>` (GitLab #570/#571); payload `path` (absolute). `FileRenamed` is emitted by Move but has no routing word.
- Socket events (`Socket Event Handler`): name containing `disconnect` (checked first) → `<event: connectionId|reason>`; `connect` → `<connection: id|remoteAddress>`; `data|message|received` → `<packet: buffer|message|connection>`.
- WebSocket events (`WebSocket Event Handler`): name containing `Connect|Message|Disconnect`; payloads `{ connectionId, path, remoteAddress }`, `{ connectionId, message }`, `{ connectionId, reason }`. Requires `Start the <http-server> with { websocket: "/ws" }`.
- Key presses: `(… : KeyPress Handler) where <key> = "down"` after `Listen the <keyboard> to the <stdin>`.
- Notifications: `Notify|Alert|Signal` emit `NotificationSent { message, recipient/target, type, timestamp, … }`.
- Git events: `git.commit|push|pull|checkout|tag|clone` mapped to handler names `GitCommit|GitPush|GitPull|GitCheckout|GitTag|GitClone` (GitLab #588).
- Built-in runtime events: `ApplicationStarted`, `ApplicationStopping`, `FileCreated|Modified|Deleted|Renamed`, `ClientConnected|DataReceived|ClientDisconnected`, `RepositoryChanged`, `RepositoryEvicted`, `StateTransition`, `NotificationSent`, `FeatureSetCompleted`, HTTP request/response, error.
- Circular event chains are a compile error (`Circular event chain detected: A → B → A`); emissions without any handler warn; a feature set no trigger reaches is dead code.
- `CrawlPage` events are de-duplicated by URL (100 000-entry FIFO) as a hard-coded runtime special case (issue #154).
- Dispatch strategies on the `EventBus` actor: `publish` (fire-and-forget), `publishAndTrack` (awaited; default for observers and `Emit`), `publishBackpressured` (worker pool, `ARO_OBSERVER_WORKERS`, `ARO_OBSERVER_QUEUE_CAPACITY`).

## 13. Repositories and store files

- In-memory, application-global, keyed by name only; the name must end in `-repository`; created on first `Store`; actor-isolated (each operation atomic, no multi-statement transactions); insertion order preserved; UUID `id` assigned when absent.
- `.store` files (ARO-0073): `<name>.store` (YAML list) seeds `<singular(name)>-repository` (singular = strip one trailing `s`); read-only unless the POSIX other-write bit is set (`chmod o+w`); writable stores persist `Store|Update|Delete` with a 1 s debounce, atomic temp-file + rename, flush on SIGINT/SIGTERM (SIGKILL loses ≤ 1 s); two files mapping to one repository = compile error; invalid YAML = startup error. Write-back works in `aro run`, the REPL and compiled binaries (store file next to the executable; read-only fallback).
- Durable alternatives: SQLite via plugin (`Call … from the <sqlite: execute|query>`).

## 14. Concurrency model (ARO-0088)

- Feature sets run concurrently (one execution per trigger, own scope). Inside a feature set, statements start in source order and the program waits at the first read of a result ("eager start, lazy join"). Iterations are sequential unless `parallel for each`. Streams pipeline.
- Deferrable verbs (allowlist `LazyActionPolicy.deferrableVerbs`): reads `retrieve fetch read request load find probe receive extract parse get`; transforms `compute calculate derive transform create build construct filter map reduce aggregate split group sort merge combine join concat format`. Everything else is eager and force-at-site; `Sleep`, `Render`, `Repaint`, `Execute` are explicitly eager.
- Force points: field access, `when`, `with`, `for each` collection, any effect reading the value, `Emit` payloads, feature-set exit (outstanding futures are drained so unread failures are still reported, attributed to the causing statement). Reads of a failed result yield an empty value; the error is raised at feature-set exit. Slow forces warn after `ARO_FORCE_WARN_SECONDS`. `ARO_NO_DEFER=1` disables deferral.
- Effects (`Log`, `Store`, `Update`, `Delete`, `Send`, `Write`, `Emit`, `Publish`, `Return`, `Throw`, `Commit`, `Push`, `Tag`, `Notify`, `Start`, `Stop`, …) run at their own statement in source order.
- Futures run on `ActionTaskExecutor` (GCD elastic global queue) as `AROFuture`; results shared via `DispatchGroup`; measured 4.18 s → 2.14 s interpreted (4.2 s → 2.85 s compiled) for two 2 s requests.
- Compiled binaries: global execution gate 4 × CPU; `parallel for each` keeps 2 iterations in flight per loop (`aro_parallel_for_each_execute`).
- No surface syntax for async/await, futures, threads, locks or channels.

## 15. HTTP

- Contract-first: `openapi.yaml|yml|json` in the app root defines routes; feature sets are named after `operationId` (or the webhook name for OpenAPI 3.1 `webhooks`, GitLab #187). No contract → no server; the server binds only on `Start the <http-server> with <contract>|{}` (`{ port: N }` overrides the contract's first `servers:` URL, default 8080; `ARO_HTTP_PORT` overrides both). Missing handlers for declared operations abort startup (`Missing ARO feature set handlers for the following operations: …`). Response bodies are checked against the schema (`[CONTRACT VIOLATION]` log).
- Request objects: `<request: body|method|path|headers.Name>`, `<body>`, `<pathParameters: name>`, `<queryParameters: name>`; no top-level `headers`.
- Request bodies (ARO-0090): moving verbs (`Write` to file, `Send`, `Return … with`, `Emit … with`, `for each`) stream unboundedly; reading (field access, `Compute` unless folding, `Store`, `Log`, `when`) materialises and is bounded by `x-aro-max-body` per operation (`256KB`, `10MB`, `1.5GB`, `1MiB`, bytes; decimal = 1000ⁿ, binary = 1024ⁿ), default 1 MB, global override `Configure the <http-server: max-body> with "1MB"` or `ARO_MAX_BODY`. Over-limit → 413 before reading (from `Content-Length`, incrementally for chunked). A body is consumable once; `Emit`/`Publish`/`Store` anchor it to a refcounted temp file. `BodyMaterializationAnalyzer` computes the policy per route at check time; unknown verbs/plugins count as reading. `aro check` reports `streams`/`holds`; the LSP shows `reads body ≤ N` inlay hints.
- Server implementations: SwiftNIO (`aro run`, macOS/Linux), `NativeHTTPServer` (BSD sockets, thread per connection, compiled binaries; no `Transfer-Encoding: chunked` requests), FlyingFox (Windows; body delivered whole, no streaming, no WebSocket).
- Callbacks: `Operation.callbacks` are parsed and planned (`$url`, `$method`, `$request.query|header|path|body#/ptr`); firing is opt-in via an injected invoker and never happens by default.
- Client: `Request` (§9), `Read/Write the <x> from/to the <url: …>` (GET/POST; content-type sniffing; options `headers`, `timeout`, `encoding`, `follow-redirects`, `max-redirects`), `Probe`, `Stream … from <url>` (SSE), `Call … from the <http: get|post|…>`. Backends: AsyncHTTPClient (NIO) on macOS/Linux, URLSession alternative (Windows).
- WebSocket: upgrade on the HTTP port at the configured path; `Broadcast the <m> to the <websocket>` (JSON-serialised); per-connection `Send … to the <websocket-connection: id>` and `Close` are specified (ARO-0048); binary frames are stringified; known defects: messages arrive masked, Broadcast from inside a WebSocket handler does not reach clients.
- Metrics endpoint pattern: `Return an <OK: status> with <metrics: prometheus>` (`text/plain`).

## 16. Files, formats, directories, monitoring

- Paths use `/` (translated on Windows), relative to the process working directory; `<file: "literal">` or `<file: variable>`; bare string paths accepted for Read/Write/Exists/Delete (bare-path form ignores `with`).
- Format by extension (ARO-0040): `.json` (dict/array), `.jsonl|.ndjson` (array of objects), `.yaml|.yml`, `.toml`, `.xml` (dict; variable name = root), `.csv|.tsv` (array of dicts when headed; options `delimiter`, `header`, `quote`, `encoding`; numeric columns typed), `.md` (String; tables on write), `.html|.htm` (String), `.txt` (key=value dict), `.sql` (INSERT statements on write), `.log` (date-prefixed lines), `.env` (dict), other → Binary. Override with a result qualifier (`<d: json|yaml|csv|tsv|xml|toml|md|html|txt|sql|log|env|binary>`) or `<d: raw>` (legacy `as String`). Nested access `<config: server.port>`. JSON writes sorted keys.
- `List the <r> from the <directory: p> [matching "glob"] [recursively]` (also `<r: "*.aro">`, `<r: recursively>`); glob = POSIX `fnmatch` on the entry name; entries `{ name, path, isFile, isDirectory, size, modified, created }`.
- `Stat` → `{ name, path, size, isFile, isDirectory, created, modified, accessed, permissions, owner, group }`; `Exists` → Bool; `Make` (mkdir -p / touch); `Copy`/`Move` (recursive, overwrite, create parents; result bound as `file`/`directory`); `Delete` (recursive, missing path = error, emits `file.deleted`).
- Streaming writes: `StreamingFileWriter`; reads ≥ 10 MB stream; `Read … : raw` bypasses parsing.
- File monitoring: `Start the <file-monitor> with "path"`; recursive; macOS FSEvents (~0.5 s latency), Linux inotify, otherwise 1 s polling; events routed by handler name (§12).

## 17. Sockets

- TCP server: `Start the <socket-server> with { port }` (or `ARO_SOCKET_PORT`); events per §12; `Send <x> to the <client-id>`, `Broadcast <x> to the <socket-server>` (records → JSON, dates → ISO-8601), `Stop the <socket-server> with {}`.
- TCP client: `Connect the <c> to the <host> with { port }`, `Send` (strings/bytes as-is; convert records with `Transform the <j: JSON> from <rec>` first), `Close`.
- Compiled binaries publish `socket.*` domain events from the NIO server only; the native bridge's socket server lacks connect/disconnect events (ARO-0072 open items). Windows uses polling-based networking.

## 18. Terminal UI and templates

- `TerminalService` (actor) registered when stdout is a TTY (Windows: only under Windows Terminal, `WT_SESSION`): capabilities `rows, columns, supportsColor, supportsTrueColor, supportsUnicode, isTTY, encoding`; `<terminal: rows|columns|width|height|supports_color|supports_true_color|is_tty|encoding>` magic object (defaults 80×24 when not a TTY); truecolor → 256 → 16 → stripped fallback; shadow-buffer double buffering (ARO-0085).
- Templates (ARO-0050): files under `./templates/`; `Transform the <out> from the <template: path> [with <ctx>]`; syntax `{{ statement(s) }}`, shorthand `{{ <var> }}` = `Print <var> to the <template>.`, `{{ for each <i> [at <n>] in <c> { }} … {{ } }}`, guarded `Print … when`, `match` inside blocks, `{{ Include the <part> from the <template: file> [with {…}] }}` (`from` only, GitLab #563), filters `| raw | markdown | length | count | bold | dim | italic | underline | strikethrough | color: "red" | bg: "blue"`. Escaping: `.html|.htm` escape `& < > " '` on interpolation; `.tpl|.txt|.md|.screen` do not; opt-out `<template: raw>` / `| raw`; escaping runs after filters (GitLab #476, #560). Templates are embedded into compiled binaries as LLVM constants with a manifest, filesystem fallback.

## 19. Dates and times

- `<now>` = current UTC ISO-8601 DateTime; properties `iso, year, month, day, hour, minute, second, dayOfWeek, dayOfYear, weekOfYear, timestamp, timezone` (case-insensitive); timezone conversion (`<now: Europe/Berlin>`, `Extract … : timezone with "…"`) is specified but not implemented (always UTC/GMT).
- Parsing `Compute the <d: date> from "2025-06-15T14:00:00Z"` (full ISO, offset, date-only, date-time without zone). Formatting `<f: format> … with "yyyy-MM-dd"` (pattern currently ignored). Distance `<d: distance> from <a> to <b>` (`days|hours|minutes|seconds`).
- Offsets as qualifiers on any date: `<t: +1d>`, `-7d`, `+2h`; units `s m h d w M y` and spelled forms (`M`/`m` casing is fragile). Arithmetic `<date> + 14d`, `<end> - <start>` (duration with `: days|hours`). Comparisons `before`, `after`, `<`, `>`, `in <range>`.
- Ranges: `Create the <r: date-range> from <a> to <b>` → `days|hours|minutes|seconds|start|end`. Recurrence strings `Create the <s: recurrence> with "every monday at 09:00"` → `next|previous|pattern`; consumed by `Schedule`.
- Duration vocabulary shared by `Sleep`, `Schedule`, date offsets: `DurationUnitCatalog`.

## 20. Git (ARO-0080)

- `<git>` discovers the repository upward from the working directory; `<git: "/path">` opens as given. libgit2 (static-link work in MR !450); `Push`/`Pull` shell out to the `git` CLI. Compiled out on Windows.
- `Retrieve the <status|log|branch> from the <git>` (status `{ branch, clean, files }`; log entries `{ short, hash, message, author, email, timestamp }`); `Stage … to the <git> with "."|path|[paths]`; `Commit … to the <git> with "msg"`; `Push … to the <git> [with { remote, branch }]`; `Pull … from the <git>`; `Clone … from the <git> with { url, path, branch?, username?, token? }`; `Checkout … from the <git> with "ref"`; `Tag … for the <git> with "v1"|{ name, message }`.

## 21. Parameters, environment, configuration, metrics, logging, output

- CLI parameters (ARO-0047): `<parameter: name>` / `<parameter>`; `--key value`, `--key=value`, `--flag`, `-abc` booleans; no positional arguments; coercion Int (`^\d+$`), Double, Bool, else String; missing → error. Defaults via `default`.
- Environment: `<env: NAME>` / `<env>`; usable in header guards; an unset variable binds `""`.
- `Configure the <category: key> with <v>` / `Configure the <category> with {…}` (verbs `configure|set` of Update): `validation.timeout`, `http-client.timeout|retries`, `http-server.port|host|max-body`, `batch.size|concurrency`, `<x-repository>.maxSize|ttl`; one qualified Configure per category per feature set (GitLab #564).
- Metrics (ARO-0044): `<metrics>` / `<metrics: short|table|prometheus>`; per feature set `executionCount, successCount, failureCount, total/min/max/averageDurationMs, successRate`; Prometheus names `aro_featureset_executions_total`, `…_success_total`, `…_failures_total`, `aro_featureset_duration_ms_avg|max`, `aro_application_uptime_seconds`; monotonic; also served on the per-process metrics socket (Solaro p95 window of 200).
- Logging: `AROLogger` levels `trace debug info warning error fatal` via `ARO_LOG_LEVEL` (ARO-0059, thinly specified).
- Output contexts (ARO-0031): human (`aro run`: `[FeatureSet] value`, `[OK] user` + flattened `key: value` lines; compiled binaries and piped mode print the value alone), machine (HTTP/events: JSON), developer (`--debug`: typed table). `for the <x>` → reason `x`, keys `x.*`; `with <x>` → top-level fields.

## 22. User-defined actions (ARO-0081)

- `(Name: Action [takes <field[: Type]>]) { … }` is callable application-wide as `Application.Name the <r> with {…}|<obj>` or `from <value>` (only with `takes`). Names unique per application; the `Application` handle is reserved.
- Input via `<input: field>`; framework variables `request`, `response`, `event`, `pathParameters`, `queryParameters` are compile errors inside an action. Output = the returned record flattened one level (`status`, `reason`, payload fields; primitive → `value`); nested shapes survive (GitLab #504).
- Recursion is unbounded in depth; a tail call (final unguarded `Return … with <r>` forwarding the call result) reuses its frame; other recursion uses heap frames; `ARO_MAX_CALL_DEPTH` (50 000) stops runaways naming the call chain; `aro check` warns when every path recurses before a `Return`. Calls are eager (not in the deferrable allowlist).
- Discovery pre-scans all sources (`Compiler.compile(_:declaredUserActions:)`); single-file tools report cross-file calls as out of sight (GitLab #587); REPL-defined actions are callable (GitLab #576).

## 23. Testing (ARO-0015)

- Tests are feature sets whose business activity ends in `Test`/`Tests`, colocated with code; run by `aro test` (interpreter only); stripped from `aro build` output. Vocabulary `Given/When/Then/Assert`; `When … from the <feature-set-name>` executes that feature set with the current bindings. No fixtures, mocking or setup/teardown. Assertion failure text `Expected difference to be -2, but was 2`.
- Integration harness: `Tests/IntegrationTestsRunner/run-tests.pl` runs every example with `test.hint` in interpreter and compiled legs (`mode`, `occurrence-check`, `skip-on-windows`, `skip-compiled-on-linux`); Windows skips the compiled leg. Opt-outs from `both`: FileUpload, MultiService (real parity gaps), EventReplay, RepoBackup.
- Unit tests: `swift test` (XCTest + swift-testing); `_NumericsShims` build flake is environmental (GitLab #295).

## 24. Native compilation (ARO-0009, `aro build`)

- Pipeline: parse + analyse → `LLVMCodeGenerator` (Swifty-LLVM, LLVM 20, `verifyModule`) → `.ll` → object (`clang -c -g -x ir` on macOS, `llc -relocation-model=pic` on Linux) → link with `clang` against `libARORuntime.a` (found via `ARO_LIB_PATH`, `$ARO_BIN`, the `aro` executable's directory, `../lib`, `/opt/homebrew/lib`, `/usr/local/lib`, `/usr/lib`, then `.build/<triple>/release|debug` relative to the CWD — an installed archive wins over a worktree build).
- Host tools required: Swift toolchain (`swiftrt.o`, `lib/swift[_static]`), `clang`, `llc` (Linux), `llvm-objcopy`, `llvm-ar`, `nm`, `strip`, `codesign` (macOS), libgit2 dev files.
- Target triples are the host's: `arm64-apple-macosx14.0.0`, `x86_64-apple-macosx14.0.0`, `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`. No cross-compilation. Windows: link code exists but `aro build` is compiled out ("requires LLVM which is not available on Windows").
- Link modes: `--static` (default) statically links the Swift runtime on Linux from `swift_static/linux` (silent fallback to dynamic if missing) while Foundation and system C libraries (`pthread dl m stdc++ z xml2 git2 curl`) stay dynamic; macOS always links the system Swift dylibs plus Homebrew `libgit2.dylib` (`LinkMode` unused); `--dynamic` on Linux copies 15 hard-coded Swift/Foundation/ICU `.so` names next to the binary with `rpath=$ORIGIN`; every build embeds rpaths to the build machine's library directories. MR !450 (`feat/static-bin`) adds static libgit2, `--target linux-musl` (Swift Static Linux SDK), Windows `/MT` CRT, `check-dynamic-deps.sh` gates and a proposal numbered `ARO-0089` that collides with Ranges.
- Codegen facts: one LLVM function `aro_fs_<mangled>` per feature set; string constants interned; expressions serialised to JSON (`$lit/$var/$binary/$unary/$interpolated`) and evaluated by the bridge except constant-folded literals (ARO-0070 phase 1); `when`/`while` guards via `aro_evaluate_when_guard`; `match` → strcmp chain; loops → phi nodes with child contexts; `parallel for each` outlines bodies; `main` embeds `openapi.yaml`, registers handlers, runs Application-Start, awaits pending events (10 s), prints the response, shuts down. DWARF: `DISubprogram` per feature set, `DILocation` per statement (lldb breakpoints on `.aro` lines; `--keep-intermediate` or `dsymutil` on macOS).
- Bridge: `Sources/ARORuntime/Bridge/*.swift`, 245 `@_cdecl` exports (ActionBridge 68, RuntimeExecutionBridge 37, SocketBridge 26, ServiceBridge 20, …); handles via `Unmanaged`; descriptors as stack structs; `AROFuture` results via `DispatchGroup`; HTTP route dispatch resolves `aro_fs_<opId>` with `dlopen(nil)`+`dlsym` (needs `-rdynamic`).
- Plugins present at build time are compiled, their 12 ABI symbols renamed `aro_static_<plugin>__<symbol>` (`llvm-objcopy --redefine-sym`) and linked in; Python plugins embed `libpython3` with source and wheels extracted to `~/.aro/cache/python-<hash>/`. Plugins installed after the build need `dlopen` (`DynamicLoading.isAvailable`).
- Templates, `openapi.yaml` and read-only `.store` files are embedded; test feature sets are stripped (`Stripped N test feature set(s)`).
- Known compiled-mode gaps: SwiftNIO cannot run inside the binary (native BSD server instead), no chunked request bodies, socket connect/disconnect events and file created/deleted classification differ (ARO-0072), `ManagedAtomic` crashes, `Log` output has no `[FeatureSet]` prefix, concurrency gating differs, tests cannot run against the binary.
- Sizes measured (macOS arm64, MR !450): static 38.9 MB, dynamic 29.8 MB; `-g` on every link; dead-strip only with `--strip`/`--size`.

## 25. Plugins (ARO-0045, ARO-0087)

- Directory `Plugins/<name>/plugin.yaml` (legacy lowercase `plugins/` also scanned); loaded in topological dependency order; `aro add` clones from Git into `Plugins/` and records `source: { git, ref }`; no lockfile; `.aro-sources` for export/restore.
- Manifest keys read: `name` (≤ 50 chars, lowercase-hyphen), `version` (semver), `handle` (PascalCase namespace; root-level canonical, `provides[].handler` legacy with warning), `description`, `author`, `license`, `aro-version` (npm-style ranges), `source`, `provides[] { type, path, handler, build { cargo-target, compiler, flags, output }, python { min-version, requirements }, actions[] { name, verbs (required), role, prepositions, description, since } }`, `dependencies { name: { git, ref } }`, `platforms` (top-level only). Provider types: `swift-plugin`, `rust-plugin`, `c-plugin`, `cpp-plugin`, `python-plugin`, `aro-files`, `aro-templates`. Manifest `actions:` enables lazy loading.
- C ABI (12 symbols): required `char* aro_plugin_info(void)`, `void aro_plugin_free(char*)`; optional `aro_plugin_init`, `aro_plugin_shutdown`, `char* aro_plugin_execute(const char* action, const char* input_json)`, `char* aro_plugin_qualifier(const char* name, const char* input_json)`, `aro_plugin_on_event(type, data)`, `aro_object_read(id, qualifier)`, `aro_object_write(id, qualifier, value_json)`, `aro_object_list(pattern)`, `aro_plugin_register(void)`, `aro_plugin_set_invoke(fn)` (runtime callback to invoke a feature set). Execute never returns NULL; errors are `{"error": …}`; the runtime frees every returned buffer with `aro_plugin_free`.
- Info JSON: `name, version, actions[{name, verbs, role, prepositions, description}], qualifiers[{name, inputTypes, accepts_parameters, description}], services[{name, methods}], system_objects[{identifier|name, capabilities}], events{subscribes, emits}, deprecations[]`.
- Action input JSON: `data` (primary value), `object`, `qualifier`, `preposition`, `result{base, qualifiers, specifiers}`, `source{base, specifiers}`, `_with{…}`, `_context{requestId, featureSet, businessActivity}`; responses may carry `_events[]` which are published. Dispatch key = the verb; services `service:<method>`.
- Qualifiers: input `{ value, type, _with }`; output `{"result": v}` or `{"error": m}` (`{"value": v}` accepted, GitLab #554); registered as `handle.qualifier` only; type validation `Qualifier 'x' expects [List] but received String`; same name + same handle collides (warning, last wins). Native plugins register verbs both bare and namespaced; Python only namespaced.
- Hosts: `UnifiedPluginLoader` → `NativePluginHost` (C/C++/Rust/Swift via `dlopen`; single Swift files compiled with `swiftc`, packages with `swift build` `type: .dynamic`), `PythonPluginHost` (`python3 -c` per call, 30 s timeout, no state between calls), `AROFilePlugin` (`aro-files`, `aro-templates`). Unload/reload at runtime (`dlclose`).
- SDKs: Swift `AROPluginKit` (`@AROExport` on `let plugin = AROPlugin(name:version:handle:)` builder with `.action/.qualifier/.service/.onInit/.onShutdown`, `github.com/arolang/aro-plugin-sdk-swift`), Rust `aro-plugin-sdk` (`#[action]`, `#[qualifier_attr]`, `aro_export!{}`; cdylib, `panic = "abort"`), C/C++ single header `aro_plugin_sdk.h` (`ARO_PLUGIN`, `ARO_HANDLE`, `ARO_ACTION`, `ARO_QUALIFIER`, `ARO_SYSTEM_OBJECT` — broken, GitLab #556), Python `aro_plugin_sdk` (`@plugin`, `@action`, `@qualifier`, `export_abi(globals())`). Capability coverage differs per SDK (events, services, system objects, invoke callback).
- REPL plugins: `:plugin add|list|update|remove` under `~/.aro/repl-plugins/` (`ARO_REPL_PLUGINS_DIR`). LSP and MCP load `Plugins/` on request.
- `Call the <r> from the <service: method> with {…}` reaches plugin services; `<Handle>.<Verb> the <r> from|with …` calls plugin actions; `<x: handle.qualifier>` applies plugin qualifiers.

## 26. REPL, JSON protocol, Jupyter (ARO-0049 draft, ARO-0091)

- `aro repl`: prompt `aro>`; statements run in the implicit feature set `_repl_session_` (activity `Interactive`); bare expressions evaluate (`2 + 2` → `=> 4`); `=> OK`/`=> value`/`Error: …`; continuation prompt `...>` for unclosed brackets/strings only; missing `.` fails immediately; unknown verbs are not diagnosed.
- Meta commands (`:` or `/`): `:help/:h/:?`, `:vars/:v [name]`, `:type/:t`, `:clear/:c/:reset`, `:history/:hist [n]`, `:fs/:featuresets`, `:invoke/:i/:run <name> [json]`, `:set <var> <json>`, `:load <file>`, `:export/:e [file] [--test]`, `:plugin …`, `:widget …` (native kernel only), `:quit/:q/:exit`. Tab completion is LSP-backed; history Up/Down; no Ctrl+R.
- Feature sets typed at the prompt are defined and their domain handlers subscribe; service-bound families (File/Socket/WebSocket/KeyPress) never fire in a session; `Keepalive|Wait|Block` are rejected (`ARO_REPL_ALLOW_BLOCKING=1` overrides); user actions and `<git>` work; `<terminal>` is always bound.
- `aro repl --json`: newline-delimited JSON; `{"type":"ready","version","protocol":1}` once; requests `execute {code, cellId?}`, `is_complete`, `complete {code, cursor}`, `inspect`, `info`, `reset`, `shutdown` with `id`; `stream {id, name, text}` messages precede exactly one `result {id, status ok|error, display (MIME bundle text/plain, application/json, text/html for record lists), durationMs, error{ename, evalue, traceback}}`. One request at a time.
- Cell semantics: units = meta command | feature set | consecutive statements (one unit, so overlap applies); definitions accumulate; `cellId` re-runs release that cell's bindings (GitLab #544); rebinding across cells is refused; the last `own`/`request` value auto-displays; handlers triggered by a cell are awaited (cascades included).
- Jupyter: native `aro kernel` (ZeroMQ, HMAC-SHA256, heartbeat/control/shell/iopub threads; widgets subset; DAP subset `inspectVariables`, `variables`, `evaluate`, `dumpCell`; breakpoints answer `verified: false`); Python shim `Editor/jupyter-aro` (`ipykernel` subclass driving `aro repl --json`; the Windows path). Interrupt kills and replaces the kernel (state lost). Output capture: `ConsoleObject.sink` task-local (all platforms) plus fd 1/2 redirection (POSIX only). `.repl` notebooks (JSON with display bundles) are Solaro's format; `Learning/` ships a 29-notebook course.

## 27. Debugger (`aro debug`, issue #229)

- One statement = one step; pause before execution; commands `s/step`, `n/next`, `f/finish` (all currently advance one statement and follow `Emit` into handlers), `c`, `b <line>|<file>:<line>|:<line>|<Verb>|… if <expr>`, `be <Event>`, `berror`, `bl`, `d <n>`, `w <expr>`, `dw`, `p`, `bt`, `h`, `q`. Breakpoint kinds: location, verb, conditional, logpoint, event (pauses before fan-out), error-any (catches deferred failures at their statement, GitLab #561). Predicates are full ARO expressions; evaluation failure = false.
- DAP: initialize, launch/attach, setBreakpoints (conditions ignored), setFunctionBreakpoints (verbs), threads (one), stackTrace (empty), scopes/variables, continue/next/stepIn/stepOut, disconnect. Not supported: `evaluate`, conditional/hit-count breakpoints, `pause`, detach without quitting, multiple clients. Clients: VS Code extension (`type: "aro"`), IntelliJ plugin ≥ 1.4.3, nvim-dap.
- Record/replay: JSONL of `pause|event|error|end` records with symbol snapshots (truncated previews, no format version); replay navigates without executing. `--sample N` pauses every Nth checkpoint for production attach. Hook cost: one task-local check per statement.
- Compiled binaries: lldb via DWARF only (no bindings, verb/event breakpoints, record/replay).

## 28. LSP and editors (ARO-0034, ARO-0030)

- `aro lsp` (ChimeHQ LanguageServerProtocol): diagnostics on open/save (debounced), completion on `<`, `:`, `.` (actions, variables, qualifiers, members; plugin verbs after loading `Plugins/`), hover, definition, references, document highlight, document/workspace symbols, signature help, formatting, rename, folding, code actions (quickfix/refactor), inlay hints (types, body limits). Semantic tokens disabled (TextMate grammar). Not built on Windows.
- Editors: VS Code `Editor/vscode-aro` (grammar, snippets, LSP client, DAP client), IntelliJ `Editor/intellij-aro` (native LSP API ≥ 2024.2, DAP run configuration), Jupyter shim `Editor/jupyter-aro`. TextMate scopes per ARO-0030.

## 29. Solaro (macOS IDE)

- SwiftUI/AppKit app (`SolaroApp`, launcher `solaro`, `AROXPCService`), macOS only, ships as signed/notarised `.dmg`; needs `aro` on PATH or beside the app (`SOLARO_ARO` override; version-mismatch banner). Dependencies: NIO, MLX, libgit2, STTextView.
- Layout: welcome (open/new/recents), sidebar (tree + search), centre pane modes map | canvas | text | split, inspector (file, selected statement with inline edit, selected repository rows, watches, problems from `aro lsp`, feature sets, OpenAPI form editor), console (Console | Terminal | Tests; JSONL timeline; time-travel scrubber), right rail (Inspector, Actions grouped by role with drag-to-insert, Snippets, Metrics, Ask).
- Canvas: feature set = container, statement = node, dependency = edge; `openapi.yaml` route/schema graph with write-back; positions in `.layout.json`; breakpoints in the gutter also stored there.
- Execution: spawns `aro run|debug|test` (`--debug-record` JSONL per statement drives overlays); runtime backend setting embedded (XPC, code default) | subprocess | external; Test shortcut ⌃⌘U; Run/Debug have no default shortcuts; metrics tab polls the metrics socket (p95 over 200 samples).
- Notebooks: `.repl` files run cell by cell against one `aro repl --json` subprocess; Jupyter-style keyboard model (⇧⏎, ⌥⏎, ⌘⏎, command mode A/B/DD/M/Y…); interrupt restarts the kernel; Learning course auto-installed to `~/Documents/ARO Learning`.
- Ask panel wraps `aro ask` (diff + apply, binary approval gate); Plugins window installs from a GitHub topic search; Books window downloads PDFs; Settings (⌘,) tabs Editor, Backends, Keybindings (`~/.config/solaro/keybindings.json`), Books, Signing, Privacy (no telemetry). Open Solaro issues: #228 (umbrella), #234, #269, #288, #445, #446, #448, #531.

## 30. Platform support (as implemented)

| Capability | macOS | Linux | Windows |
|---|---|---|---|
| `aro run`, `aro check`, `aro compile`, `aro test`, `aro repl`, `aro repl --json` | yes | yes | yes (Swift runtime DLLs required) |
| `aro build` | yes (system Swift dylibs + Homebrew libgit2) | yes (static Swift, dynamic Foundation/C libs) | no (compiled out) |
| `aro lsp`, `aro mcp`, `aro ask`, `aro kernel` | yes | yes | no (Python shim kernel only) |
| HTTP server | SwiftNIO | SwiftNIO | FlyingFox: no body streaming, no WebSocket |
| HTTP client | AsyncHTTPClient | AsyncHTTPClient | URLSession variant |
| Sockets | NIO | NIO | polling |
| File monitor | FSEvents | inotify | 1 s polling |
| Git actions | yes | yes | module compiled out |
| Terminal UI | full | full | Windows Terminal only; hidden prompt echoes |
| REPL output capture (fd level) | yes | yes | no |
| Solaro | yes | no | no |
| `aro ask` model backend | native MLX (Apple Silicon) / llama-server | llama-server (auto-download) | llama-server / endpoint |
| CI coverage | GitHub (build, sign) | GitLab (build, test, integration, release) | GitHub `swift build` only |

## 31. Training pipeline (`Train/`, ARO by Hallucination)

- Product: `ARO-Lang/aro-coder-6bit` (8B dense student, 4-bit, ~4.5 GB, 8 192-token context) distilled from `ARO-Lang/aro-teacher-30b-bf16` (Qwen3-Coder-30B-A3B base); student base `mlx-community/Qwen3-8B-bf16`; used by `aro ask` and Solaro Ask.
- Pipeline: 28 notebooks `Train/script/00_META_PIPELINE.ipynb` … `27_package.ipynb` plus scripts 28–32 (diagnostic repairs, multi-model doc QA, FIM pairs, failure DPO, notebook pairs): corpus collection (examples, proposals, books, wiki, Swift source) → knowledge extraction → seeding from `Train/Material/curated.jsonl` → LLM pair generation validated by `aro check` (2 repair attempts) → warm-start LoRA → actions/REPL-execution/book-QA/function-calling/external-repo/comment datasets → validation and assembly → full LoRA fine-tune → preference SFT (chosen/rejected from `aro check`) → evaluation (syntax pass rate against `aro check`) → iterative loop → distillation → material/thinking/conversation fine-tunes → post-release validation → 4-bit packaging and HF upload. Apple Silicon (MLX, ≥ 16 GB), Python 3.12, `experiments.db` (SQLite) tracks runs; `GEN_TODO.md` lists 21 failed generation prompts.
- Measured (previous session): 82 % syntax-valid output; target corpus ~500–1000 curated examples rather than millions of synthetic ones.
