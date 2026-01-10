# ARO-0043: System Objects Protocol

- **Status**: Draft
- **Author**: Claude (and the aro developer team)
- **Created**: 2025-12-31

## Summary

This proposal introduces a formal `SystemObject` protocol for ARO's "magic" built-in objects (console, request, etc.), providing:

1. A unified protocol defining what system objects are
2. Source/Sink semantics for reading from and writing to objects
3. Plugin extensibility for custom system objects

## Motivation

ARO currently has many implicit "magic" objects that are available without declaration:

- `console` - Standard output
- `request`, `pathParameters`, `queryParameters`, `headers`, `body` - HTTP context
- `connection`, `packet` - Socket context
- `event` - Event payload
- `shutdown` - Shutdown context

However, these objects:
1. Have no formal protocol defining their behavior
2. Are handled inconsistently across different actions
3. Cannot be extended by plugins
4. Have awkward syntax for output operations

### Current Problem: Awkward Sink Syntax

```aro
(* Current - forces throwaway variable *)
<Log> "Scanning template directory..." to the <console>.

(* The user must invent <start> even though they don't care about it *)
```

### Proposed Solution: Source/Sink Pattern

```aro
(* SOURCE: read FROM objects - result is bound variable *)
<Read> the <config> from the <file: "./config.yaml">.
<Extract> the <id> from the <request: pathParameters.id>.

(* SINK: write TO objects - result IS the data *)
<Log> "Starting server..." to the <console>.
<Write> <data> to the <file: "./output.json">.
```

## Design

### SystemObject Protocol

```swift
/// Protocol for system objects - sources (read from) and sinks (write to)
public protocol SystemObject: Sendable {
    /// Unique identifier used in ARO code (e.g., "console", "request")
    static var identifier: String { get }

    /// Human-readable description
    static var description: String { get }

    /// What operations this object supports
    var capabilities: SystemObjectCapabilities { get }

    /// Read from this object (for sources)
    /// - Parameter property: Optional property path (e.g., "body", "headers.authorization")
    func read(property: String?) async throws -> any Sendable

    /// Write to this object (for sinks)
    /// - Parameter value: The value to write
    func write(_ value: any Sendable) async throws
}
```

### Capabilities

```swift
public struct SystemObjectCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public static let readable  = SystemObjectCapabilities(rawValue: 1 << 0)
    public static let writable  = SystemObjectCapabilities(rawValue: 1 << 1)

    // Convenience aliases
    public static let source: SystemObjectCapabilities = [.readable]
    public static let sink: SystemObjectCapabilities = [.writable]
    public static let bidirectional: SystemObjectCapabilities = [.readable, .writable]
}
```

### Registry

```swift
public final class SystemObjectRegistry: @unchecked Sendable {
    public static let shared = SystemObjectRegistry()

    private var factories: [String: (ExecutionContext) -> any SystemObject] = [:]
    private var lock = NSLock()

    /// Register a static system object (e.g., console)
    public func register<T: SystemObject>(_ type: T.Type) where T: Instantiable {
        register(T.identifier) { _ in T() }
    }

    /// Register a context-dependent system object (e.g., request)
    public func register(_ identifier: String,
                         factory: @escaping (ExecutionContext) -> any SystemObject) {
        lock.withLock { factories[identifier] = factory }
    }

    /// Get a system object by identifier
    public func get(_ identifier: String, context: ExecutionContext) -> (any SystemObject)? {
        lock.withLock { factories[identifier]?(context) }
    }

    /// All registered identifiers (for documentation/discovery)
    public var identifiers: [String] {
        lock.withLock { Array(factories.keys).sorted() }
    }
}
```

## Built-in System Objects

| Identifier | Type | Capabilities | Description |
|------------|------|--------------|-------------|
| `console` | Static | Sink | Standard output stream |
| `stderr` | Static | Sink | Standard error stream |
| `stdin` | Static | Source | Standard input stream |
| `env` | Static | Source | Environment variables |
| `request` | Context | Source | HTTP request (in HTTP handlers) |
| `pathParameters` | Context | Source | URL path parameters |
| `queryParameters` | Context | Source | URL query parameters |
| `headers` | Context | Source | HTTP headers |
| `body` | Context | Source | Request body |
| `connection` | Context | Both | Socket connection |
| `event` | Context | Source | Event payload |
| `shutdown` | Context | Source | Shutdown context |
| `file` | Dynamic | Both | File I/O (path in qualifier) |

### Object Categories

1. **Static Objects**: Always available, no context needed
   - `console`, `stderr`, `stdin`, `env`

2. **Context Objects**: Auto-bound based on execution context
   - HTTP handlers: `request`, `pathParameters`, `queryParameters`, `headers`, `body`
   - Socket handlers: `connection`
   - Event handlers: `event`
   - Shutdown handlers: `shutdown`

3. **Dynamic Objects**: Created with qualifier parameter
   - `file` with path: `<file: "./config.yaml">`

## ARO Syntax Changes

### Sink Actions (write TO)

New syntax allows expression/literal directly as the data to write:

```aro
(* Log to console *)
<Log> "Starting server..." to the <console>.
<Log> <error-message> to the <stderr>.

(* Write to file *)
<Write> <data> to the <file: "./output.json">.
<Write> { name: "Alice", age: 30 } to the <file: "./user.yaml">.

(* Send to socket *)
<Send> <message> to the <connection>.
<Send> "PONG" to the <connection>.
```

### Source Actions (read FROM)

Unchanged - result is the bound variable:

```aro
(* Read from file *)
<Read> the <config> from the <file: "./config.yaml">.

(* Extract from request *)
<Extract> the <id> from the <request: pathParameters.id>.
<Extract> the <data> from the <body>.

(* Get from environment *)
<Get> the <api-key> from the <env: "API_KEY">.
```

## Implementation: Built-in Objects

### ConsoleObject

```swift
public struct ConsoleObject: SystemObject {
    public static let identifier = "console"
    public static let description = "Standard output stream"
    public var capabilities: SystemObjectCapabilities { .sink }

    public func write(_ value: any Sendable) async throws {
        let message = ResponseFormatter.formatValue(value, mode: .developer)
        print(message)
    }

    public func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notReadable(Self.identifier)
    }
}
```

### RequestObject

```swift
public struct RequestObject: SystemObject {
    public static let identifier = "request"
    public static let description = "HTTP request context"
    public var capabilities: SystemObjectCapabilities { .source }

    private let request: HTTPRequest

    init(from context: ExecutionContext) {
        self.request = context.httpRequest!
    }

    public func read(property: String?) async throws -> any Sendable {
        switch property {
        case nil:            return request
        case "body":         return request.body
        case "headers":      return request.headers
        case "method":       return request.method
        case "path":         return request.path
        case "url":          return request.url
        default:
            // Support nested paths: "headers.authorization"
            return try request.valueAtPath(property!)
        }
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}
```

### FileObject

```swift
public struct FileObject: SystemObject {
    public static let identifier = "file"
    public static let description = "File system I/O"
    public var capabilities: SystemObjectCapabilities { .bidirectional }

    private let path: String
    private let fileService: FileSystemService

    init(path: String, fileService: FileSystemService) {
        self.path = path
        self.fileService = fileService
    }

    public func read(property: String?) async throws -> any Sendable {
        let content = try await fileService.read(path: path)
        let format = FileFormat.detect(from: path)
        return FormatDeserializer.deserialize(content, format: format)
    }

    public func write(_ value: any Sendable) async throws {
        let format = FileFormat.detect(from: path)
        let content = FormatSerializer.serialize(value, format: format)
        try await fileService.write(path: path, content: content)
    }
}
```

### EnvironmentObject

```swift
public struct EnvironmentObject: SystemObject {
    public static let identifier = "env"
    public static let description = "Environment variables"
    public var capabilities: SystemObjectCapabilities { .source }

    public func read(property: String?) async throws -> any Sendable {
        guard let key = property else {
            // Return all environment variables
            return ProcessInfo.processInfo.environment
        }
        guard let value = ProcessInfo.processInfo.environment[key] else {
            throw SystemObjectError.propertyNotFound(key, in: Self.identifier)
        }
        return value
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}
```

## Plugin Extensibility

Plugins can provide custom system objects via the existing plugin architecture.

### Plugin Metadata

```json
{
  "services": [...],
  "systemObjects": [
    {
      "identifier": "redis",
      "description": "Redis key-value store",
      "capabilities": ["readable", "writable"],
      "readSymbol": "redis_read",
      "writeSymbol": "redis_write"
    }
  ]
}
```

### Plugin Implementation

```swift
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "services": [],
        "systemObjects": [
            {
                "identifier": "redis",
                "description": "Redis key-value store",
                "capabilities": ["readable", "writable"],
                "readSymbol": "redis_read",
                "writeSymbol": "redis_write"
            }
        ]
    }
    """
    return UnsafePointer(strdup(metadata)!)
}

@_cdecl("redis_read")
public func redisRead(
    _ propertyPtr: UnsafePointer<CChar>?,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let key = propertyPtr.map { String(cString: $0) } ?? ""
    guard let value = redis.get(key) else {
        return 1 // Not found
    }
    resultPtr.pointee = strdup(value)
    return 0
}

@_cdecl("redis_write")
public func redisWrite(
    _ valuePtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let value = String(cString: valuePtr)
    redis.set(value)
    return 0
}
```

### Usage in ARO

```aro
(* Plugin-provided system object *)
<Get> the <session> from the <redis: "session:123">.
<Set> <userData> to the <redis: "user:456">.
```

## Parser Changes

### Sink Action Syntax

For sink verbs (Log, Write, Send, etc.), allow expression/literal in result position:

```ebnf
sink_statement = action_verb expression "to" [article] object_noun "."

expression = string_literal
           | variable_reference
           | object_literal
           | array_literal
```

### ResultDescriptor Extension

```swift
public struct ResultDescriptor: Sendable, Equatable {
    public let base: String
    public let qualifier: String?
    public let article: Article
    public let specifiers: [String]

    // NEW: Support for literal values in sink actions
    public let isLiteral: Bool
    public let literalValue: (any Sendable)?
}
```

## Error Handling

```swift
public enum SystemObjectError: Error, CustomStringConvertible {
    case notReadable(String)
    case notWritable(String)
    case notFound(String)
    case propertyNotFound(String, in: String)

    public var description: String {
        switch self {
        case .notReadable(let id):
            return "System object '\(id)' is not readable (sink only)"
        case .notWritable(let id):
            return "System object '\(id)' is not writable (source only)"
        case .notFound(let id):
            return "System object '\(id)' not found"
        case .propertyNotFound(let prop, let id):
            return "Property '\(prop)' not found in system object '\(id)'"
        }
    }
}
```

## Files to Create

| File | Purpose |
|------|---------|
| `Sources/ARORuntime/SystemObjects/SystemObject.swift` | Protocol and capabilities |
| `Sources/ARORuntime/SystemObjects/SystemObjectRegistry.swift` | Registry |
| `Sources/ARORuntime/SystemObjects/SystemObjectError.swift` | Error types |
| `Sources/ARORuntime/SystemObjects/BuiltIn/ConsoleObject.swift` | Console sink |
| `Sources/ARORuntime/SystemObjects/BuiltIn/StdinObject.swift` | Stdin source |
| `Sources/ARORuntime/SystemObjects/BuiltIn/RequestObject.swift` | HTTP request |
| `Sources/ARORuntime/SystemObjects/BuiltIn/ConnectionObject.swift` | Socket connection |
| `Sources/ARORuntime/SystemObjects/BuiltIn/EventObject.swift` | Event payload |
| `Sources/ARORuntime/SystemObjects/BuiltIn/FileObject.swift` | File I/O |
| `Sources/ARORuntime/SystemObjects/BuiltIn/EnvironmentObject.swift` | Env vars |

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/AROParser/Parser.swift` | Sink action syntax |
| `Sources/AROParser/AST.swift` | ResultDescriptor extension |
| `Sources/ARORuntime/Actions/BuiltIn/ResponseActions.swift` | Use SystemObject for Log, Write, Send |
| `Sources/ARORuntime/Actions/BuiltIn/ExtractAction.swift` | Use SystemObject for Read, Extract |
| `Sources/ARORuntime/Services/PluginLoader.swift` | Load plugin system objects |

## Complete Example

```aro
(Application-Start: System Objects Demo) {
    (* I/O Streams - sinks *)
    <Log> "Starting application..." to the <console>.
    <Log> "Debug info" to the <stderr>.

    (* Environment - source *)
    <Get> the <api-key> from the <env: "API_KEY">.
    <Log> <api-key> to the <console>.

    (* File I/O - bidirectional *)
    <Read> the <config> from the <file: "./config.yaml">.
    <Log> <config> to the <console>.

    <Create> the <result> with { processed: true, timestamp: "2025-01-01" }.
    <Write> <result> to the <file: "./output.json">.

    <Return> an <OK: status> for the <demo>.
}

(handleRequest: User API) {
    (* HTTP context - sources *)
    <Extract> the <id> from the <request: pathParameters.id>.
    <Extract> the <auth> from the <headers: Authorization>.
    <Extract> the <data> from the <body>.

    (* Process and respond *)
    <Create> the <response> with { id: <id>, received: <data> }.
    <Return> an <OK: status> with <response>.
}

(Socket Handler: Message Received) {
    (* Socket context - bidirectional *)
    <Extract> the <message> from the <packet: buffer>.
    <Log> <message> to the <console>.

    <Create> the <reply> with "ACK".
    <Send> <reply> to the <connection>.
}
```

## Future Considerations

1. **Additional built-in objects**: `clipboard`, `notification`, `database`
2. **Object composition**: Combine objects like `<file: "/var/log/app.log" | console>`
3. **Streaming**: Support for streaming reads/writes on large data
4. **Typed properties**: Static typing for known properties (`request.body` is always `any Sendable`)

## References

- [ARO-0020](./ARO-0020-runtime-architecture.md) - Runtime architecture
- [ARO-0023](./ARO-0023-file-system.md) - File system operations
- [ARO-0024](./ARO-0024-sockets.md) - Socket operations
- [ARO-0025](./ARO-0025-action-extension-interface.md) - Action extension interface
