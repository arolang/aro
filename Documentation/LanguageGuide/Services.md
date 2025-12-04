# External Services

ARO integrates with external libraries through **Services**. Services wrap external functionality (HTTP clients, databases, media processors, etc.) and expose them through the `<Call>` action.

## The Call Action

All external service invocations use the same pattern:

```aro
<Call> the <result> from the <service: method> with { key: value, ... }.
```

| Component | Description |
|-----------|-------------|
| `result` | Variable to store the result |
| `service` | Service name (e.g., `http`, `postgres`, `ffmpeg`) |
| `method` | Method to invoke (e.g., `get`, `query`, `transcode`) |
| `args` | Key-value arguments |

## Built-in Services

### HTTP Client

The `http` service provides HTTP request capabilities.

**GET Request:**
```aro
<Call> the <response> from the <http: get> with {
    url: "https://api.example.com/users"
}.
```

**GET with Headers:**
```aro
<Call> the <response> from the <http: get> with {
    url: "https://api.example.com/protected",
    headers: { "Authorization": "Bearer token123" }
}.
```

**POST Request:**
```aro
<Call> the <response> from the <http: post> with {
    url: "https://api.example.com/users",
    body: { name: "Alice", email: "alice@example.com" },
    headers: { "Content-Type": "application/json" }
}.
```

**Other Methods:**
```aro
(* PUT request *)
<Call> the <response> from the <http: put> with {
    url: "https://api.example.com/users/123",
    body: { name: "Alice Updated" }
}.

(* PATCH request *)
<Call> the <response> from the <http: patch> with {
    url: "https://api.example.com/users/123",
    body: { status: "active" }
}.

(* DELETE request *)
<Call> the <response> from the <http: delete> with {
    url: "https://api.example.com/users/123"
}.
```

**Response Format:**
```json
{
    "status": 200,
    "headers": { "Content-Type": "application/json" },
    "body": { ... }
}
```

### HTTP Method Reference

| Method | Arguments | Description |
|--------|-----------|-------------|
| `get` | `url`, `headers?` | HTTP GET request |
| `post` | `url`, `body`, `headers?` | HTTP POST request |
| `put` | `url`, `body`, `headers?` | HTTP PUT request |
| `patch` | `url`, `body`, `headers?` | HTTP PATCH request |
| `delete` | `url`, `headers?` | HTTP DELETE request |

## Creating Custom Services

Services are Swift types that implement the `AROService` protocol.

### Service Protocol

```swift
public protocol AROService: Sendable {
    /// Service name (e.g., "postgres", "redis")
    static var name: String { get }

    /// Initialize the service
    init() throws

    /// Call a method
    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable

    /// Shutdown (optional)
    func shutdown() async
}
```

### Example: PostgreSQL Service

```swift
import PostgresNIO

public struct PostgresService: AROService {
    public static let name = "postgres"

    private let pool: PostgresConnectionPool

    public init() throws {
        let config = PostgresConnection.Configuration(...)
        pool = try PostgresConnectionPool(configuration: config)
    }

    public func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        switch method {
        case "query":
            let sql = args["sql"] as! String
            let rows = try await pool.query(sql)
            return rows.map { row in
                // Convert to dictionary
            }

        case "execute":
            let sql = args["sql"] as! String
            try await pool.execute(sql)
            return ["success": true]

        default:
            throw ServiceError.unknownMethod(method, service: Self.name)
        }
    }

    public func shutdown() async {
        await pool.close()
    }
}
```

### Registration

Services are registered with the `ServiceRegistry`:

```swift
try ServiceRegistry.shared.register(PostgresService())
```

### Usage in ARO

```aro
(* Database query *)
<Call> the <users> from the <postgres: query> with {
    sql: "SELECT * FROM users WHERE active = true"
}.

(* Database execute *)
<Call> the <result> from the <postgres: execute> with {
    sql: "UPDATE users SET status = 'active' WHERE id = 123"
}.
```

## Plugin System

When ARO is distributed as a pre-compiled binary, users can add custom services via **plugins**.

### Plugin Structure

```
MyApp/
├── main.aro
├── openapi.yaml
├── plugins/                    # Custom services
│   └── MyService.swift
└── aro.yaml
```

### Writing a Plugin

```swift
// plugins/MyService.swift
import Foundation

@_cdecl("aro_plugin_register")
public func register(_ registry: UnsafeMutableRawPointer) {
    let reg = AROPluginRegistry(registry)
    reg.registerService("myservice", MyService())
}

struct MyService: AROPluginService {
    func call(_ method: String, args: [String: Any]) throws -> Any {
        switch method {
        case "greet":
            let name = args["name"] as? String ?? "World"
            return "Hello, \(name)!"
        default:
            throw NSError(domain: "Plugin", code: 1)
        }
    }
}
```

### Plugin Configuration

```yaml
# aro.yaml
plugins:
  - source: plugins/MyService.swift
  - source: plugins/CacheService.swift

  # Pre-compiled plugins
  - library: /path/to/CustomPlugin.dylib
```

### How Plugins Work

1. ARO scans `./plugins/` directory
2. Compiles `.swift` files to `.dylib` using `swiftc`
3. Loads via `dlopen`
4. Calls `aro_plugin_register` entry point

Compiled plugins are cached in `.aro-cache/` and only recompiled when source changes.

### Using Plugin Services

```aro
(Application-Start: Plugin Demo) {
    <Call> the <greeting> from the <myservice: greet> with {
        name: "ARO Developer"
    }.

    <Log> the <message> for the <console> with <greeting>.

    <Return> an <OK: status> for the <startup>.
}
```

## Common Service Examples

### HTTP API Client

```aro
(Fetch Weather: External API) {
    <Call> the <response> from the <http: get> with {
        url: "https://api.weather.com/current",
        headers: { "Authorization": "Bearer ${API_KEY}" }
    }.

    <Extract> the <weather> from the <response: body>.
    <Return> an <OK: status> with <weather>.
}
```

### Database Query

```aro
(List Users: User Management) {
    <Call> the <users> from the <postgres: query> with {
        sql: "SELECT * FROM users WHERE active = true"
    }.

    <Return> an <OK: status> with <users>.
}
```

### Media Processing

```aro
(Generate Thumbnail: Media) {
    <Extract> the <video-path> from the <request: path>.

    <Call> the <thumbnail> from the <ffmpeg: extractFrame> with {
        input: <video-path>,
        time: "00:00:05",
        output: "/tmp/thumb.jpg"
    }.

    <Return> an <OK: status> with <thumbnail>.
}
```

## Design Philosophy

1. **One Action, Many Services**: All external calls use `<Call>`
2. **Swift-First**: Services are Swift types, leveraging the Swift ecosystem
3. **Package-Based**: Services are Swift Packages, easy to create and share
4. **Works Everywhere**: Same approach for interpreter and compiler modes

## Next Steps

- [Actions](actions.html) - All built-in actions
- [HTTP Services](httpservices.html) - Built-in HTTP server
- [Events](events.html) - Event-driven patterns
