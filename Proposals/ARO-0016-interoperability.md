# ARO-0016: Interoperability

* Proposal: ARO-0016
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal defines how ARO interoperates with external libraries and services. ARO uses a **Swift Package-based Service** architecture where external functionality is wrapped in services and invoked via the `<Call>` action.

## Motivation

Real-world applications require integration with:

1. **HTTP APIs**: REST, GraphQL endpoints
2. **Databases**: PostgreSQL, MongoDB, Redis
3. **Media Processing**: FFmpeg, ImageMagick
4. **System Libraries**: Encryption, compression

ARO provides a simple, unified approach: **external libraries become Services**.

---

## Design Principle

> **One Action, Many Services**

All external integrations use the same pattern:

```aro
Call the <result> from the <service: method> with { args }.
```

---

## The Call Action

### Syntax

```aro
Call the <result> from the <service: method> with { key: value, ... }.
```

### Components

| Component | Description |
|-----------|-------------|
| `result` | Variable to store the result |
| `service` | Service name (e.g., `http`, `postgres`, `ffmpeg`) |
| `method` | Method to invoke (e.g., `get`, `query`, `transcode`) |
| `args` | Key-value arguments |

### Examples

```aro
(* HTTP GET request *)
Call the <response> from the <http: get> with {
    url: "https://api.example.com/users"
}.

(* Database query *)
Call the <users> from the <postgres: query> with {
    sql: "SELECT * FROM users WHERE active = true"
}.

(* Media transcoding *)
Call the <result> from the <ffmpeg: transcode> with {
    input: "/path/to/video.mov",
    output: "/path/to/video.mp4",
    format: "mp4"
}.
```

---

## Built-in Services

### HTTP Client

The `http` service is built-in and provides HTTP request capabilities.

```aro
(* GET request *)
Call the <response> from the <http: get> with {
    url: "https://api.example.com/data",
    headers: { "Authorization": "Bearer token123" }
}.

(* POST request *)
Call the <response> from the <http: post> with {
    url: "https://api.example.com/users",
    body: { name: "Alice", email: "alice@example.com" },
    headers: { "Content-Type": "application/json" }
}.

(* Other methods: put, patch, delete *)
Call the <response> from the <http: delete> with {
    url: "https://api.example.com/users/123"
}.
```

**Response format:**

```json
{
    "status": 200,
    "headers": { "Content-Type": "application/json" },
    "body": { ... }
}
```

---

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

---

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

### Plugin Interface

Plugins use a C-compatible JSON interface for maximum portability:

```swift
// plugins/GreetingService.swift
import Foundation

/// Plugin initialization - returns service metadata as JSON
/// Tells ARO what services and symbols this plugin provides
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "greeting", "symbol": "greeting_call"}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

/// Service entry point - C-callable interface
/// - Parameters:
///   - methodPtr: Method name (C string)
///   - argsPtr: Arguments as JSON (C string)
///   - resultPtr: Output - result as JSON (caller must free)
/// - Returns: 0 for success, non-zero for error
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

The `aro_plugin_init` function returns JSON describing available services:

```json
{
  "services": [
    {"name": "greeting", "symbol": "greeting_call"},
    {"name": "translator", "symbol": "translator_call"}
  ]
}
```

Each service entry specifies:
- `name`: Service name used in ARO code (`<greeting: hello>`)
- `symbol`: C function symbol to call (`greeting_call`)

---

## Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Weather Service
  version: 1.0.0

paths: {}

components:
  schemas:
    WeatherData:
      type: object
      properties:
        temperature:
          type: number
        conditions:
          type: string
        location:
          type: string
```

### main.aro

```aro
(Application-Start: Weather Service) {
    Log the <message> for the <console> with "Weather Service starting...".

    (* Fetch weather from external API *)
    Call the <response> from the <http: get> with {
        url: "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true"
    }.

    Extract the <weather> from the <response: body>.

    Log the <message> for the <console> with "Current weather:".
    Log the <message> for the <console> with <weather>.

    Return an <OK: status> for the <startup>.
}

(Application-End: Success) {
    Log the <message> for the <console> with "Weather Service shutting down...".
    Return an <OK: status> for the <shutdown>.
}
```

---

## Service Method Reference

### HTTP Service (`http`)

| Method | Arguments | Description |
|--------|-----------|-------------|
| `get` | `url`, `headers?` | HTTP GET request |
| `post` | `url`, `body`, `headers?` | HTTP POST request |
| `put` | `url`, `body`, `headers?` | HTTP PUT request |
| `patch` | `url`, `body`, `headers?` | HTTP PATCH request |
| `delete` | `url`, `headers?` | HTTP DELETE request |

---

## Implementation Notes

### Interpreter Mode

1. Application loads, discovers `aro.yaml`
2. Swift Package Manager loads service packages
3. Services register with `ServiceRegistry`
4. `<Call>` action looks up service and invokes method

### Compiled Mode

1. `aro build` reads `aro.yaml`, includes service packages in link
2. LLVM IR calls `aro_action_call` → Swift runtime
3. Swift runtime looks up service in `ServiceRegistry`
4. Service method executes

---

## Summary

ARO's interoperability is built on a simple principle:

| Concept | Implementation |
|---------|---------------|
| External libraries | Swift Package Services |
| Invocation | `<Call>` action |
| Custom services | Plugin system |
| Configuration | `aro.yaml` |

This approach provides:
- **Simplicity**: One action for all external calls
- **Extensibility**: Easy to add new services
- **Portability**: Works in interpreter and compiler modes
- **Swift Integration**: Leverages Swift ecosystem

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2024-12 | Simplified to Service-based architecture |
| 1.0 | 2024-01 | Initial specification with complex syntax |
