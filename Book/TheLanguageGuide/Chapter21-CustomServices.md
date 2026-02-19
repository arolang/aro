# Chapter 21: Custom Services

*"When you need to talk to the outside world."*

---

## 21.1 Actions vs Services: The Key Distinction

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

## 21.2 The Service Protocol

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

## 21.3 Implementing a Service

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

## 21.4 Using Your Service in ARO

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

## 21.5 Service Registration

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

For plugin-based services (covered in Chapter 18), registration happens automatically when the plugin loads.

---

## 21.6 Error Handling in Services

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

## 21.7 Complete Example: Redis Service

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
        key: "user:" + <user-id>,
        value: <user>
    }.

    (* Set expiration to 1 hour *)
    Call the <expire-result> from the <redis: expire> with {
        key: "user:" + <user-id>,
        seconds: 3600
    }.

    Return an <OK: status> for the <cache>.
}

(Get Cached User: Caching) {
    Extract the <user-id> from the <request: id>.

    Call the <cached> from the <redis: get> with {
        key: "user:" + <user-id>
    }.

    Return an <OK: status> with <cached>.
}
```

---

## 21.8 Best Practices

**Name services clearly.** The service name appears in ARO code, so it should be short and recognizable. Use "postgres" not "postgresqlDatabaseService".

**Keep methods focused.** Each method should do one thing. "query" runs a query. "execute" runs a statement without results. "insert" inserts and returns the ID. Do not combine operations.

**Document methods.** Users of your service need to know what methods are available, what arguments each expects, and what it returns. Consider adding a "help" method that returns documentation.

**Handle connection lifecycle.** Services often maintain connections to external systems. Initialize connections in `init()`, reuse them across calls, and close them in `shutdown()`.

**Use environment variables for configuration.** Host, port, credentials, and other settings should come from environment variables, not hardcoded values. This allows the same code to work in development and production.

**Provide meaningful errors.** When a method fails, the error message should explain what went wrong and ideally suggest a fix. "Connection refused to localhost:5432" is better than "Connection error".

---

## 21.9 Services vs Built-in Actions

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

*Next: Chapter 21 — Plugins*
