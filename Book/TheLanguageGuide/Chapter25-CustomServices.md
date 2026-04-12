# Chapter 25: Custom Services

*"When you need to talk to the outside world."*

> **Deprecation notice:** The `AROService` protocol and `ServiceRegistry` described in this chapter are deprecated as of ARO-0073. Services are now declared in `aro_plugin_info` and routed through `aro_plugin_execute("service:<method>", input_json)`. The old pattern still works but will be removed before the 1.0 release. See Section 25.10 for the new approach and Chapter 26 for the full plugin ABI.

---

## 25.1 Actions vs Services: The Key Distinction

Before diving into custom services, it is essential to understand how they differ from custom actions. This distinction shapes how you design extensions to ARO.

**Custom Actions** add new verbs to the language. When you create a custom action, you define a new way of expressing intent. The Geocode action lets you write `Geocode the <coordinates> from the <address>`. The verb "Geocode" becomes part of your ARO vocabulary.

**Custom Services** are external integrations invoked through the `<Call>` action. Services do not add new verbs—they add new capabilities accessible through the existing Call verb. You write `Call the <result> from the <postgres: query>` to invoke the postgres service's query method.

The pattern reveals the distinction:

```aro
(* Custom Action - new verb *)
Geocode the <coordinates> from the <address>.

(* Custom Service - Call verb with service:method *)
Call the <users> from the <postgres: query> with { sql: "SELECT * FROM users" }.
```

### When to Use Each

| Use Case | Choose | Why |
|----------|--------|-----|
| Domain-specific operation that feels like a language feature | Action | Reads naturally: `Validate the <order>` |
| External system integration (database, queue, API) | Service | Uniform pattern: `Call from <service: method>` |
| Reusable across many projects | Service | Services are more portable |
| Single, focused operation | Action | Cleaner syntax for one thing |
| Multiple related operations | Service | One service, many methods |

### The Design Philosophy

Actions extend the language. Services extend the runtime.

When you add an action, you are saying "this operation is so fundamental to my domain that it deserves its own verb." A payment system might have `<Charge>`, `<Refund>`, and `<Authorize>` as actions because these are core operations that should read as naturally as built-in actions.

When you add a service, you are saying "this external system provides capabilities my application needs." A database driver, message queue client, or cloud storage integration are services because they wrap external systems with multiple operations.

---

## 25.2 The Service Protocol (Legacy)

> **Note:** This section describes the legacy `AROService` protocol, which is deprecated. For new plugins, declare services in `aro_plugin_info` instead. See Section 25.10 for the current approach.

Services implement the `AROService` protocol. This protocol defines the contract between your service and the ARO runtime.

```swift
public protocol AROService: Sendable {
    /// Service name used in ARO code (e.g., "postgres", "redis")
    static var name: String { get }

    /// Initialize the service
    init() throws

    /// Execute a method call
    func call(
        _ method: String,
        args: [String: any Sendable]
    ) async throws -> any Sendable

    /// Cleanup resources (optional)
    func shutdown() async
}
```

The protocol is simpler than ActionImplementation because services have a uniform invocation pattern. All service calls go through the `call` method; the method parameter distinguishes different operations.

---

<div style="text-align: center; margin: 2em 0;">
<svg xmlns="http://www.w3.org/2000/svg" width="560" height="155" font-family="sans-serif">
  <!-- Feature Set (indigo, left) -->
  <rect x="10" y="30" width="155" height="70" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="87" y="52" text-anchor="middle" font-size="10" fill="#4338ca" font-weight="bold">Feature Set</text>
  <text x="87" y="69" text-anchor="middle" font-size="8" fill="#4338ca">Call the &lt;result&gt;</text>
  <text x="87" y="82" text-anchor="middle" font-size="8" fill="#4338ca">from the &lt;external-api&gt;.</text>

  <!-- Arrow: internal call → -->
  <line x1="165" y1="65" x2="200" y2="65" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="200,65 191,60 191,70" fill="#9ca3af"/>
  <text x="182" y="57" text-anchor="middle" font-size="8" fill="#6b7280">internal</text>
  <text x="182" y="67" text-anchor="middle" font-size="8" fill="#6b7280">call</text>

  <!-- Call Action (amber, center) -->
  <rect x="200" y="30" width="155" height="70" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="277" y="56" text-anchor="middle" font-size="11" fill="#92400e" font-weight="bold">Call Action</text>
  <text x="277" y="74" text-anchor="middle" font-size="9" fill="#92400e">HTTP / TCP request</text>

  <!-- Arrow: network request → -->
  <line x1="355" y1="55" x2="390" y2="45" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="390,45 381,45 384,54" fill="#9ca3af"/>
  <text x="372" y="38" text-anchor="middle" font-size="8" fill="#6b7280">network</text>
  <text x="372" y="48" text-anchor="middle" font-size="8" fill="#6b7280">request</text>

  <!-- Arrow: response ← -->
  <line x1="390" y1="85" x2="355" y2="75" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="355,75 364,70 364,80" fill="#9ca3af"/>
  <text x="372" y="88" text-anchor="middle" font-size="8" fill="#6b7280">response</text>

  <!-- External Service (light gray dashed, right) -->
  <rect x="390" y="20" width="155" height="90" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="2" stroke-dasharray="4,2"/>
  <text x="467" y="58" text-anchor="middle" font-size="11" fill="#374151" font-weight="bold">External Service</text>
  <text x="467" y="75" text-anchor="middle" font-size="9" fill="#374151">API / Database / TCP</text>

  <!-- Arrow: bound result ← -->
  <line x1="200" y1="75" x2="165" y2="75" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="165,75 174,70 174,80" fill="#9ca3af"/>
  <text x="182" y="88" text-anchor="middle" font-size="8" fill="#6b7280">bound</text>
  <text x="182" y="98" text-anchor="middle" font-size="8" fill="#6b7280">result</text>
</svg>
</div>

## 25.3 Implementing a Service (Legacy)

> **Note:** This section shows the legacy implementation pattern. For new code, see Section 25.10.

Let us build a PostgreSQL service to illustrate the implementation pattern.

### Step 1: Define the Service Structure

```swift
import PostgresNIO

public struct PostgresService: AROService {
    public static let name = "postgres"

    private let pool: PostgresConnectionPool

    public init() throws {
        // Load configuration from environment
        let config = PostgresConnection.Configuration(
            host: ProcessInfo.processInfo.environment["DB_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["DB_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["DB_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["DB_PASSWORD"] ?? "",
            database: ProcessInfo.processInfo.environment["DB_NAME"] ?? "app"
        )

        self.pool = try PostgresConnectionPool(configuration: config)
    }
```

### Step 2: Implement the Call Method

The call method dispatches to different operations based on the method parameter:

```swift
    public func call(
        _ method: String,
        args: [String: any Sendable]
    ) async throws -> any Sendable {
        switch method.lowercased() {
        case "query":
            return try await executeQuery(args)
        case "execute":
            return try await executeStatement(args)
        case "insert":
            return try await executeInsert(args)
        default:
            throw ServiceError.unknownMethod(method, service: Self.name)
        }
    }

    private func executeQuery(_ args: [String: any Sendable]) async throws -> [[String: Any]] {
        guard let sql = args["sql"] as? String else {
            throw ServiceError.missingArgument("sql")
        }

        let rows = try await pool.query(sql)
        return rows.map { row in
            // Convert PostgreSQL row to dictionary
            var dict: [String: Any] = [:]
            for (column, value) in row {
                dict[column] = value
            }
            return dict
        }
    }

    private func executeStatement(_ args: [String: any Sendable]) async throws -> [String: Any] {
        guard let sql = args["sql"] as? String else {
            throw ServiceError.missingArgument("sql")
        }

        try await pool.execute(sql)
        return ["success": true]
    }

    private func executeInsert(_ args: [String: any Sendable]) async throws -> [String: Any] {
        guard let table = args["table"] as? String,
              let data = args["data"] as? [String: Any] else {
            throw ServiceError.missingArgument("table or data")
        }

        let columns = data.keys.sorted().joined(separator: ", ")
        let placeholders = (1...data.count).map { "$\($0)" }.joined(separator: ", ")
        let sql = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders)) RETURNING id"

        let result = try await pool.query(sql, values: data.values.map { $0 })
        return ["id": result.first?["id"] ?? 0]
    }
```

### Step 3: Implement Shutdown

```swift
    public func shutdown() async {
        await pool.close()
    }
}
```

---

## 25.4 Using Your Service in ARO

Once registered, your service is available through the Call action:

```aro
(List Active Users: User Management) {
    Call the <users> from the <postgres: query> with {
        sql: "SELECT * FROM users WHERE active = true"
    }.

    Return an <OK: status> with <users>.
}

(Create User: User Management) {
    Extract the <data> from the <request: body>.

    Call the <result> from the <postgres: insert> with {
        table: "users",
        data: <data>
    }.

    Extract the <id> from the <result: id>.
    Return a <Created: status> with { id: <id> }.
}

(Update User Status: User Management) {
    Extract the <id> from the <pathParameters: id>.
    Extract the <status> from the <request: status>.

    Call the <result> from the <postgres: execute> with {
        sql: "UPDATE users SET status = $1 WHERE id = $2",
        params: [<status>, <id>]
    }.

    Return an <OK: status> for the <update>.
}
```

---

## 25.5 Service Registration (Legacy)

> **Note:** The `ServiceRegistry` pattern below is deprecated. For new plugins, declare services in `aro_plugin_info` and they are registered automatically when the plugin loads. See Section 25.10.

Services must be registered before use. Registration happens during application initialization:

```swift
// In your Swift application startup
import ARORuntime

func initializeServices() throws {
    // Register custom services
    try ServiceRegistry.shared.register(PostgresService())
    try ServiceRegistry.shared.register(RedisService())
    try ServiceRegistry.shared.register(RabbitMQService())
}
```

---

## 25.6 Error Handling in Services

Services report errors by throwing Swift exceptions. The runtime converts these to ARO error messages:

```swift
public enum ServiceError: Error, CustomStringConvertible {
    case unknownMethod(String, service: String)
    case missingArgument(String)
    case connectionFailed(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .unknownMethod(let method, let service):
            return "Unknown method '\(method)' for service '\(service)'"
        case .missingArgument(let arg):
            return "Missing required argument: \(arg)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .queryFailed(let reason):
            return "Query failed: \(reason)"
        }
    }
}
```

When a service throws, the ARO runtime produces an error like:

```
Cannot call postgres:query - Connection failed: Connection refused to localhost:5432
```

---

## 25.7 Complete Example: Redis Service

Here is a complete service implementation for Redis:

```swift
import RediStack

public struct RedisService: AROService {
    public static let name = "redis"

    private let connection: RedisConnection

    public init() throws {
        let host = ProcessInfo.processInfo.environment["REDIS_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["REDIS_PORT"] ?? "6379") ?? 6379

        self.connection = try RedisConnection.make(
            configuration: .init(hostname: host, port: port)
        ).wait()
    }

    public func call(
        _ method: String,
        args: [String: any Sendable]
    ) async throws -> any Sendable {
        switch method.lowercased() {
        case "get":
            guard let key = args["key"] as? String else {
                throw ServiceError.missingArgument("key")
            }
            let value = try await connection.get(RedisKey(key)).get()
            return value.string ?? ""

        case "set":
            guard let key = args["key"] as? String,
                  let value = args["value"] else {
                throw ServiceError.missingArgument("key or value")
            }
            let stringValue = String(describing: value)
            try await connection.set(RedisKey(key), to: stringValue).get()
            return ["success": true]

        case "del", "delete":
            guard let key = args["key"] as? String else {
                throw ServiceError.missingArgument("key")
            }
            let count = try await connection.delete(RedisKey(key)).get()
            return ["deleted": count]

        case "incr":
            guard let key = args["key"] as? String else {
                throw ServiceError.missingArgument("key")
            }
            let newValue = try await connection.increment(RedisKey(key)).get()
            return ["value": newValue]

        case "expire":
            guard let key = args["key"] as? String,
                  let seconds = args["seconds"] as? Int else {
                throw ServiceError.missingArgument("key or seconds")
            }
            try await connection.expire(RedisKey(key), after: .seconds(Int64(seconds))).get()
            return ["success": true]

        default:
            throw ServiceError.unknownMethod(method, service: Self.name)
        }
    }

    public func shutdown() async {
        try? await connection.close().get()
    }
}
```

**Usage in ARO:**

```aro
(Cache User: Caching) {
    Extract the <user-id> from the <user: id>.

    Call the <result> from the <redis: set> with {
        key: "user:" ++ <user-id>,
        value: <user>
    }.

    (* Set expiration to 1 hour *)
    Call the <expire-result> from the <redis: expire> with {
        key: "user:" ++ <user-id>,
        seconds: 3600
    }.

    Return an <OK: status> for the <cache>.
}

(Get Cached User: Caching) {
    Extract the <user-id> from the <request: id>.

    Call the <cached> from the <redis: get> with {
        key: "user:" ++ <user-id>
    }.

    Return an <OK: status> with <cached>.
}
```

---

## 25.8 Best Practices

**Name services clearly.** The service name appears in ARO code, so it should be short and recognizable. Use "postgres" not "postgresqlDatabaseService".

**Keep methods focused.** Each method should do one thing. "query" runs a query. "execute" runs a statement without results. "insert" inserts and returns the ID. Do not combine operations.

**Document methods.** Users of your service need to know what methods are available, what arguments each expects, and what it returns. Consider adding a "help" method that returns documentation.

**Handle connection lifecycle.** Services often maintain connections to external systems. Initialize connections in `init()`, reuse them across calls, and close them in `shutdown()`.

**Use environment variables for configuration.** Host, port, credentials, and other settings should come from environment variables, not hardcoded values. This allows the same code to work in development and production.

**Provide meaningful errors.** When a method fails, the error message should explain what went wrong and ideally suggest a fix. "Connection refused to localhost:5432" is better than "Connection error".

---

## 25.9 Services vs Built-in Actions

Some capabilities in ARO are implemented as built-in actions rather than services. HTTP requests use the `Request` action, not a service:

```aro
(* Built-in Request action - NOT a service *)
Request the <weather> from "https://api.weather.com/current".

(* Service call pattern - for external integrations *)
Call the <users> from the <postgres: query> with { sql: "..." }.
```

The distinction: built-in actions are part of the ARO language and have dedicated syntax. Services are external integrations that share the uniform Call pattern.

| Capability | Implementation | Syntax |
|------------|----------------|--------|
| HTTP requests | Built-in action | `Request the <data> from <url>.` |
| File operations | Built-in action | `Read the <data> from <path>.` |
| Database queries | Custom service | `Call from <postgres: query>` |
| Message queues | Custom service | `Call from <rabbitmq: publish>` |
| Cloud storage | Custom service | `Call from <s3: upload>` |

---

## 25.10 The New Service Pattern (ARO-0073)

As of ARO-0073, services are declared in `aro_plugin_info` alongside actions and qualifiers. The runtime routes `Call the <result> from the <postgres: query>` to `aro_plugin_execute("service:query", input_json)`. No separate `AROService` protocol, no `ServiceRegistry`, no `aro_plugin_init` returning service metadata.

### Declaring a Service in plugin.yaml and aro_plugin_info

**plugin.yaml:**

```yaml
name: plugin-postgres
version: 1.0.0
handle: Postgres
provides:
  - type: swift-plugin
    path: Sources/
```

**aro_plugin_info JSON (returned as a string from the C export):**

```json
{
  "name": "plugin-postgres",
  "version": "1.0.0",
  "services": [
    {
      "name": "postgres",
      "methods": ["query", "execute", "insert"],
      "description": "PostgreSQL database service"
    }
  ]
}
```

### Routing Service Calls Through aro_plugin_execute

All service method calls arrive at `aro_plugin_execute` with the action name formatted as `"service:<method>"`:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    if (strncmp(action, "service:", 8) == 0) {
        const char* method = action + 8;   // "query", "execute", "insert"
        return dispatch_service_method(method, input_json);
    }
    // ... handle regular actions ...
}
```

The `input_json` contains the same rich payload as any action call, with `_with` carrying the arguments from the ARO `with { }` clause:

```json
{
  "data": null,
  "_with": {
    "sql": "SELECT * FROM users WHERE active = true"
  }
}
```

### Using the Service in ARO (unchanged)

The ARO syntax for invoking services is identical whether using the old or new pattern:

```aro
(List Active Users: User Management) {
    Call the <users> from the <postgres: query> with {
        sql: "SELECT * FROM users WHERE active = true"
    }.

    Return an <OK: status> with <users>.
}
```

### Lifecycle Hooks

Stateful services that need to initialize connections or clean up resources use the new lifecycle hooks:

```c
void aro_plugin_init(void) {
    // Open connection pool, load credentials, etc.
    postgres_pool = pg_connect(getenv("DB_URL"));
}

void aro_plugin_shutdown(void) {
    // Close connections, flush write buffers, etc.
    pg_close(postgres_pool);
}
```

`aro_plugin_init` is called once after the plugin loads. `aro_plugin_shutdown` is called before the plugin unloads. Both are optional — only implement them if your service needs stateful setup or teardown.

---

*Next: Chapter 26 — Plugins*
