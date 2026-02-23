# Chapter 19: System Objects

*"Every program needs to interact with its environment."*

---

## 19.1 What Are System Objects?

System objects are special objects in ARO that represent external sources and sinks of data. Unlike regular variables that you create and bind within your feature sets, system objects are provided by the runtime and represent I/O streams, HTTP requests, files, environment variables, and other external resources.

ARO defines a consistent interaction pattern for system objects based on data flow direction:

| Pattern | Direction | Description |
|---------|-----------|-------------|
| **Source** | External → Internal | Read data FROM the system object |
| **Sink** | Internal → External | Write data TO the system object |
| **Bidirectional** | Both | Read from and write to the system object |

This pattern aligns with ARO's action roles: REQUEST actions read from sources, EXPORT actions write to sinks.

### The Source/Sink Flow

The following diagram illustrates how data flows between your ARO feature sets and system objects:

<svg width="800" height="400" xmlns="http://www.w3.org/2000/svg">
  <!-- Background -->
  <rect width="800" height="400" fill="#f8f9fa"/>
  <!-- Title -->
  <text x="400" y="30" font-family="monospace" font-size="18" font-weight="bold" text-anchor="middle" fill="#2c3e50">
    System Objects: Source/Sink Pattern
  </text>
  <!-- Feature Set (center) -->
  <rect x="300" y="150" width="200" height="100" fill="#3498db" stroke="#2980b9" stroke-width="2" rx="5"/>
  <text x="400" y="185" font-family="monospace" font-size="14" font-weight="bold" text-anchor="middle" fill="white">
    ARO Feature Set
  </text>
  <text x="400" y="210" font-family="monospace" font-size="12" text-anchor="middle" fill="white">
    Business Logic
  </text>
  <text x="400" y="230" font-family="monospace" font-size="12" text-anchor="middle" fill="white">
    Variables &amp; Computations
  </text>
  <!-- SOURCE Objects (left side) -->
  <g id="sources">
    <!-- stdin -->
    <rect x="20" y="60" width="120" height="40" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
    <text x="80" y="85" font-family="monospace" font-size="12" text-anchor="middle" fill="white">stdin (Source)</text>
    <!-- env -->
    <rect x="20" y="120" width="120" height="40" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
    <text x="80" y="145" font-family="monospace" font-size="12" text-anchor="middle" fill="white">env (Source)</text>
    <!-- request -->
    <rect x="20" y="180" width="120" height="40" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
    <text x="80" y="205" font-family="monospace" font-size="12" text-anchor="middle" fill="white">request (Source)</text>
    <!-- event -->
    <rect x="20" y="240" width="120" height="40" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
    <text x="80" y="265" font-family="monospace" font-size="12" text-anchor="middle" fill="white">event (Source)</text>
    <!-- packet -->
    <rect x="20" y="300" width="120" height="40" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
    <text x="80" y="325" font-family="monospace" font-size="12" text-anchor="middle" fill="white">packet (Source)</text>
  </g>
  <!-- SINK Objects (right side) -->
  <g id="sinks">
    <!-- console -->
    <rect x="660" y="90" width="120" height="40" fill="#e74c3c" stroke="#c0392b" stroke-width="2" rx="3"/>
    <text x="720" y="115" font-family="monospace" font-size="12" text-anchor="middle" fill="white">console (Sink)</text>
    <!-- stderr -->
    <rect x="660" y="150" width="120" height="40" fill="#e74c3c" stroke="#c0392b" stroke-width="2" rx="3"/>
    <text x="720" y="175" font-family="monospace" font-size="12" text-anchor="middle" fill="white">stderr (Sink)</text>
  </g>
  <!-- BIDIRECTIONAL Objects (bottom) -->
  <g id="bidirectional">
    <!-- file -->
    <rect x="260" y="330" width="120" height="40" fill="#9b59b6" stroke="#8e44ad" stroke-width="2" rx="3"/>
    <text x="320" y="355" font-family="monospace" font-size="11" text-anchor="middle" fill="white">file (Bidirectional)</text>
    <!-- connection -->
    <rect x="420" y="330" width="120" height="40" fill="#9b59b6" stroke="#8e44ad" stroke-width="2" rx="3"/>
    <text x="480" y="355" font-family="monospace" font-size="11" text-anchor="middle" fill="white">connection (Bidirectional)</text>
  </g>
  <!-- Arrows: Sources → Feature Set -->
  <defs>
    <marker id="arrowhead" markerWidth="10" markerHeight="10" refX="10" refY="3" orient="auto" viewBox="0 0 10 6">
      <polygon points="0,0 10,3 0,6" fill="#2c3e50"/>
    </marker>
  </defs>
  <!-- REQUEST arrows (Sources to Feature Set) -->
  <path d="M 140 80 L 300 170" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="220" y="120" font-family="monospace" font-size="10" fill="#27ae60">&lt;Extract&gt;</text>
  <path d="M 140 140 L 300 180" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="220" y="155" font-family="monospace" font-size="10" fill="#27ae60">&lt;Read&gt;</text>
  <path d="M 140 200 L 300 200" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="220" y="195" font-family="monospace" font-size="10" fill="#27ae60">&lt;Request&gt;</text>
  <path d="M 140 260 L 300 220" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <path d="M 140 320 L 300 230" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <!-- EXPORT arrows (Feature Set to Sinks) -->
  <path d="M 500 180 L 660 110" stroke="#e74c3c" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="580" y="140" font-family="monospace" font-size="10" fill="#e74c3c">&lt;Log&gt;</text>
  <path d="M 500 210 L 660 170" stroke="#e74c3c" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="580" y="185" font-family="monospace" font-size="10" fill="#e74c3c">&lt;Print&gt;</text>
  <!-- Bidirectional arrows -->
  <path d="M 320 250 L 320 330" stroke="#9b59b6" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <path d="M 340 330 L 340 250" stroke="#9b59b6" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="360" y="290" font-family="monospace" font-size="10" fill="#9b59b6">&lt;Read&gt;/&lt;Write&gt;</text>
  <path d="M 460 250 L 480 330" stroke="#9b59b6" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <path d="M 500 330 L 480 250" stroke="#9b59b6" stroke-width="2" fill="none" marker-end="url(#arrowhead)"/>
  <text x="510" y="290" font-family="monospace" font-size="10" fill="#9b59b6">&lt;Extract&gt;/&lt;Send&gt;</text>
  <!-- Legend -->
  <rect x="20" y="360" width="760" height="30" fill="white" stroke="#bdc3c7" stroke-width="1" rx="3"/>
  <rect x="30" y="368" width="15" height="12" fill="#27ae60"/>
  <text x="50" y="378" font-family="monospace" font-size="10" fill="#2c3e50">Source (Read Only)</text>
  <rect x="200" y="368" width="15" height="12" fill="#e74c3c"/>
  <text x="220" y="378" font-family="monospace" font-size="10" fill="#2c3e50">Sink (Write Only)</text>
  <rect x="370" y="368" width="15" height="12" fill="#9b59b6"/>
  <text x="390" y="378" font-family="monospace" font-size="10" fill="#2c3e50">Bidirectional (Read &amp; Write)</text>
  <rect x="590" y="368" width="15" height="12" fill="#3498db"/>
  <text x="610" y="378" font-family="monospace" font-size="10" fill="#2c3e50">Feature Set (Your Code)</text>
</svg>

---

## 19.2 Sink Syntax

For sink operations, ARO provides a clean, intuitive syntax where the value comes directly after the verb:

```aro
(* Sink syntax - direct value to system object *)
Log "Hello, World!" to the <console>.
Log <data> to the <console>.
Log { status: "ok", count: 42 } to the <console>.
```

Sink verbs that support this syntax include:
- `log`, `print`, `output`, `debug` — Console output
- `write` — File writing
- `send`, `dispatch` — Socket/network sending

---

## 19.2 Built-in System Objects

### Console Objects

ARO provides three console-related system objects:

| Object | Type | Description |
|--------|------|-------------|
| `console` | Sink | Standard output stream (supports qualifiers for stdout/stderr routing) |
| `stderr` | Sink | Standard error stream (direct access) |
| `stdin` | Source | Standard input stream |

```aro
(* Write to console (stdout) *)
Log "Starting server..." to the <console>.

(* Write to console stdout (explicit) *)
Log "Processing data..." to the <console: output>.

(* Write to console stderr *)
Log "Warning: config missing" to the <console: error>.

(* Write to stderr object (alternative syntax) *)
Log "Error message" to the <stderr>.

(* Read from stdin *)
Read the <input> from the <stdin>.
```

**Console Output Streams:**

The `console` system object supports qualifier-based stream selection:

| Syntax | Stream | Use Case |
|--------|--------|----------|
| `<console>` | stdout | Default output (no qualifier) |
| `<console: output>` | stdout | Explicit standard output |
| `<console: error>` | stderr | Errors and diagnostics |

For backward compatibility, the `stderr` object remains available:
- `<stderr>` - Direct access to standard error stream

**When to use stderr:**
- Error messages and warnings
- Diagnostic output that shouldn't mix with data
- Progress indicators in data processing pipelines
- Debug logs in production

### Console Stream Routing

The following diagram shows how the Log action routes output based on qualifiers:

<svg width="600" height="350" xmlns="http://www.w3.org/2000/svg">
  <!-- Title -->
  <text x="300" y="25" font-family="monospace" font-size="16" font-weight="bold" text-anchor="middle">
    Log Action: Console Stream Routing
  </text>
  <!-- ARO Code box -->
  <rect x="50" y="60" width="200" height="200" fill="#ecf0f1" stroke="#34495e" stroke-width="2" rx="5"/>
  <text x="150" y="85" font-family="monospace" font-size="12" font-weight="bold" text-anchor="middle">
    ARO Feature Set
  </text>
  <!-- Example 1: Default -->
  <text x="60" y="110" font-family="monospace" font-size="10" fill="#2c3e50">
    &lt;Log&gt; "msg" to
  </text>
  <text x="60" y="125" font-family="monospace" font-size="10" fill="#27ae60">
    &lt;console&gt;.
  </text>
  <!-- Example 2: Explicit output -->
  <text x="60" y="155" font-family="monospace" font-size="10" fill="#2c3e50">
    &lt;Log&gt; "msg" to
  </text>
  <text x="60" y="170" font-family="monospace" font-size="10" fill="#3498db">
    &lt;console: output&gt;.
  </text>
  <!-- Example 3: Error -->
  <text x="60" y="200" font-family="monospace" font-size="10" fill="#2c3e50">
    &lt;Log&gt; "err" to
  </text>
  <text x="60" y="215" font-family="monospace" font-size="10" fill="#e74c3c">
    &lt;console: error&gt;.
  </text>
  <!-- Log Action box -->
  <rect x="300" y="120" width="100" height="80" fill="#3498db" stroke="#2980b9" stroke-width="2" rx="5"/>
  <text x="350" y="145" font-family="monospace" font-size="12" font-weight="bold" text-anchor="middle" fill="white">
    Log
  </text>
  <text x="350" y="165" font-family="monospace" font-size="11" text-anchor="middle" fill="white">
    Action
  </text>
  <text x="350" y="185" font-family="monospace" font-size="9" text-anchor="middle" fill="#ecf0f1">
    Qualifier Check
  </text>
  <!-- stdout box -->
  <rect x="450" y="80" width="100" height="50" fill="#27ae60" stroke="#229954" stroke-width="2" rx="3"/>
  <text x="500" y="100" font-family="monospace" font-size="11" font-weight="bold" text-anchor="middle" fill="white">
    stdout
  </text>
  <text x="500" y="118" font-family="monospace" font-size="9" text-anchor="middle" fill="white">
    (standard out)
  </text>
  <!-- stderr box -->
  <rect x="450" y="170" width="100" height="50" fill="#e74c3c" stroke="#c0392b" stroke-width="2" rx="3"/>
  <text x="500" y="190" font-family="monospace" font-size="11" font-weight="bold" text-anchor="middle" fill="white">
    stderr
  </text>
  <text x="500" y="208" font-family="monospace" font-size="9" text-anchor="middle" fill="white">
    (standard error)
  </text>
  <!-- Arrows -->
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="10" refX="10" refY="3" orient="auto">
      <polygon points="0,0 10,3 0,6" fill="#2c3e50"/>
    </marker>
  </defs>
  <!-- Connections -->
  <path d="M 250 117 L 300 140" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <path d="M 250 162 L 300 155" stroke="#3498db" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <path d="M 250 207 L 300 180" stroke="#e74c3c" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <path d="M 400 140 L 450 105" stroke="#27ae60" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <path d="M 400 150 L 450 105" stroke="#3498db" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <path d="M 400 180 L 450 195" stroke="#e74c3c" stroke-width="2" fill="none" marker-end="url(#arrow)"/>
  <!-- Labels -->
  <text x="330" y="125" font-family="monospace" font-size="8" fill="#27ae60">
    (default)
  </text>
  <text x="330" y="148" font-family="monospace" font-size="8" fill="#3498db">
    (output)
  </text>
  <text x="330" y="192" font-family="monospace" font-size="8" fill="#e74c3c">
    (error)
  </text>
  <!-- Terminal output box -->
  <rect x="50" y="280" width="500" height="50" fill="#2c3e50" stroke="#1a252f" stroke-width="2" rx="3"/>
  <text x="60" y="300" font-family="monospace" font-size="10" fill="#27ae60">
    $ aro run ./App 2&gt; errors.log 1&gt; output.log
  </text>
  <text x="60" y="318" font-family="monospace" font-size="9" fill="#ecf0f1">
    # Separate streams: stdout to output.log, stderr to errors.log
  </text>
</svg>

### Environment Variables

The `env` system object provides access to environment variables:

```aro
(* Read a specific environment variable *)
Extract the <api-key> from the <env: API_KEY>.

(* Read all environment variables *)
Extract the <all-vars> from the <env>.
```

### Command-Line Parameters

The `parameter` system object provides access to command-line arguments passed to your ARO application:

```aro
(* Read a specific parameter *)
Extract the <url> from the <parameter: url>.
Extract the <count> from the <parameter: count>.

(* Read all parameters as a dictionary *)
Extract the <all-params> from the <parameter>.
```

**Passing Parameters:**

Parameters are passed after the application path:

```bash
# Interpreter mode
aro run ./MyApp --url http://example.com --count 5 --verbose

# Compiled binary
./MyApp --url http://example.com --count 5 --verbose
```

**Supported Syntax:**

| CLI Syntax | ARO Access | Value |
|------------|------------|-------|
| `--url http://example.com` | `<parameter: url>` | `"http://example.com"` |
| `--count 5` | `<parameter: count>` | `5` (auto-converted to Int) |
| `--enabled true` | `<parameter: enabled>` | `true` (auto-converted to Bool) |
| `--verbose` | `<parameter: verbose>` | `true` (boolean flag) |
| `-v` | `<parameter: v>` | `true` (short flag) |
| `-abc` | `<parameter: a>`, `<parameter: b>`, `<parameter: c>` | Each `true` |

**Type Coercion:**

Parameter values are automatically converted to appropriate types:
- Integer patterns (`123`) → `Int`
- Decimal patterns (`3.14`) → `Double`
- `"true"` / `"false"` → `Bool`
- Everything else → `String`

**Example:**

```aro
(Application-Start: Greeter) {
    Extract the <name> from the <parameter: name>.
    Extract the <count> from the <parameter: count>.

    Log "Hello, ${<name>}!" to the <console>.
    Log "Count: ${<count>}" to the <console>.

    Return an <OK: status> with <name>.
}
```

```bash
$ aro run ./Greeter --name "World" --count 3
Hello, World!
Count: 3
```

### File Object

The `file` system object provides bidirectional file I/O with automatic format detection:

```aro
(* Read from a file *)
Read the <config> from the <file: "./config.json">.

(* Write to a file *)
Write <data> to the <file: "./output.json">.
```

The file object automatically detects the format based on file extension and serializes/deserializes accordingly. See Chapter 16B for details on format-aware I/O.

---

## 19.3 HTTP Context Objects

When handling HTTP requests, ARO provides context-specific system objects:

| Object | Type | Description |
|--------|------|-------------|
| `request` | Source | Full HTTP request |
| `pathParameters` | Source | URL path parameters |
| `queryParameters` | Source | URL query parameters |
| `headers` | Source | HTTP headers |
| `body` | Source | Request body |

```aro
(getUser: User API) {
    (* Access path parameters *)
    Extract the <id> from the <pathParameters: id>.

    (* Access query parameters *)
    Extract the <limit> from the <queryParameters: limit>.

    (* Access headers *)
    Extract the <auth> from the <headers: Authorization>.

    (* Access request body *)
    Extract the <data> from the <body>.

    (* Access full request properties *)
    Extract the <method> from the <request: method>.

    Return an <OK: status> with <user>.
}
```

These objects are only available within HTTP request handler feature sets. Attempting to access them outside this context results in an error.

---

## 19.4 Event Context Objects

Event handlers have access to event-specific system objects:

| Object | Type | Description |
|--------|------|-------------|
| `event` | Source | Event payload |
| `shutdown` | Source | Shutdown context |

```aro
(Send Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status> for the <notification>.
}

(Application-End: Success) {
    Extract the <reason> from the <shutdown: reason>.
    Log <reason> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

---

## 19.5 Socket Context Objects

Socket handlers have access to connection-related system objects:

| Object | Type | Description |
|--------|------|-------------|
| `connection` | Bidirectional | Socket connection |
| `packet` | Source | Socket data packet |

```aro
(Echo Server: Socket Event Handler) {
    Extract the <data> from the <packet>.
    Send <data> to the <connection>.
    Return an <OK: status> for the <echo>.
}
```

---

## 19.6 Magic System Objects

Magic system objects are automatically generated by the runtime and are always available without explicit binding. Unlike regular variables that you create, magic objects are synthesized from the execution environment.

### The `Contract` Object

When an ARO application has an `openapi.yaml` file, the `Contract` magic object becomes available. It provides access to the OpenAPI specification metadata at runtime.

**Type:** Source (readable only)

**Properties:**
- `Contract.http-server` — HTTP server configuration
  - `port` — Server port from OpenAPI spec
  - `hostname` — Server hostname (default: "0.0.0.0")
  - `routes` — Array of route paths
  - `routeCount` — Number of routes defined

```aro
(Application-Start: Order Service) {
    (* Start HTTP server using Contract configuration *)
    Start the <http-server> with <Contract>.

    (* Access Contract properties *)
    Log <Contract.http-server.port> to the <console>.
    Log <Contract.http-server.routes> to the <console>.

    (* Shorthand: <http-server> resolves to Contract.http-server *)
    Log <http-server.port> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

The `Contract` object ensures that your application configuration is driven by the OpenAPI specification — the contract is the source of truth.

**Other Magic Objects:**
- `now` — Current UTC timestamp (see Chapter 36: Dates and Times)

---

## 19.7 Plugin System Objects

Plugins can provide custom system objects that integrate seamlessly with ARO's source/sink pattern. This allows third-party services like Redis, databases, or message queues to be accessed with the same familiar syntax.

```aro
(* Plugin-provided Redis system object *)
Get the <session> from the <redis: "session:123">.
Set <userData> to the <redis: "user:456">.
```

See Chapter 18 for details on creating plugins that provide system objects.

---

## 19.8 Summary

System objects provide a unified interface for interacting with external resources. The source/sink pattern creates consistency across all I/O operations:

- **Sources** (readable): `env`, `parameter`, `stdin`, `request`, `event`, `packet`, `Contract`
- **Sinks** (writable): `console`, `stderr`
- **Bidirectional**: `file`, `connection`
- **Magic Objects**: `Contract`, `now`

The sink syntax (`Log "message" to the <console>`) provides a clean, intuitive way to write to system objects.

---

*Next: Chapter 17 — Custom Actions*
