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

Plugins can be either single Swift files or Swift packages with dependencies:

**Simple Plugin (single file):**
```
MyApp/
├── main.aro
├── openapi.yaml
└── plugins/
    └── MyService.swift
```

**Package Plugin (with dependencies):**
```
MyApp/
├── main.aro
├── openapi.yaml
└── plugins/
    └── MyPlugin/
        ├── Package.swift
        └── Sources/MyPlugin/
            └── MyService.swift
```

### Writing a Plugin

Plugins use a C-compatible JSON interface:

```swift
// plugins/GreetingService.swift
import Foundation

/// Plugin initialization - returns service metadata as JSON
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "greeting", "symbol": "greeting_call"}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

/// Service entry point - C-callable interface
@_cdecl("greeting_call")
public func greetingCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse arguments
    var args: [String: Any] = [:]
    if let data = argsJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    // Execute method
    let name = args["name"] as? String ?? "World"
    let result: String

    switch method.lowercased() {
    case "hello":
        result = "Hello, \(name)!"
    case "goodbye":
        result = "Goodbye, \(name)!"
    default:
        let errorJSON = "{\"error\": \"Unknown method: \(method)\"}"
        resultPtr.pointee = strdup(errorJSON)
        return 1
    }

    // Return result as JSON
    let resultJSON = "{\"result\": \"\(result)\"}"
    resultPtr.pointee = strdup(resultJSON)
    return 0
}
```

### Package Plugin with Dependencies

For plugins that need external libraries, use a Swift package:

```swift
// plugins/ZipPlugin/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZipPlugin", type: .dynamic, targets: ["ZipPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.0")
    ],
    targets: [
        .target(name: "ZipPlugin", dependencies: ["Zip"])
    ]
)
```

### How Plugins Work

1. ARO scans `./plugins/` directory
2. For `.swift` files: compiles to `.dylib` using `swiftc`
3. For directories with `Package.swift`: builds using `swift build`
4. Loads dynamic library via `dlopen`
5. Calls `aro_plugin_init` to get service metadata (JSON)
6. Registers each service with the symbol from metadata

Compiled plugins are cached in `.aro-cache/` and only recompiled when source changes.

### Plugin Metadata Format

The `aro_plugin_init` function returns JSON:

```json
{
  "services": [
    {"name": "greeting", "symbol": "greeting_call"}
  ]
}
```

- `name`: Service name used in ARO code (`<greeting: hello>`)
- `symbol`: C function symbol to call

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
