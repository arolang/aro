// ============================================================
// AROCatalog.swift
// ARO Runtime - Shared discovery surface for actions and qualifiers
// (Issue #225)
// ============================================================

import Foundation

// MARK: - Origin

/// Where a catalog entry came from. Lets consumers filter built-ins from
/// plugin-provided contributions and identify the source plugin.
public enum CatalogOrigin: Sendable, Equatable {
    case builtin
    case plugin(name: String, handle: String?)
}

// MARK: - Action Entry

/// Structured description of a single action verb. This is the type LSP and
/// MCP consume — both built-ins and plugin actions reduce to the same shape.
public struct CatalogActionEntry: Sendable, Equatable {
    /// Display name (e.g. "Extract"). For plugin actions this is the action's
    /// canonical name, not the namespaced form.
    public let verb: String
    /// Semantic role (request/own/response/export/server)
    public let role: ActionRole
    /// Valid prepositions for this action (e.g. ["from", "with"])
    public let prepositions: [String]
    /// Human-readable description, when known
    public let description: String?
    /// Origin (built-in or plugin)
    public let origin: CatalogOrigin
    /// Version when this action was introduced (plugin actions only)
    public let since: String?

    public init(
        verb: String,
        role: ActionRole,
        prepositions: [String] = [],
        description: String? = nil,
        origin: CatalogOrigin = .builtin,
        since: String? = nil
    ) {
        self.verb = verb
        self.role = role
        self.prepositions = prepositions
        self.description = description
        self.origin = origin
        self.since = since
    }
}

// MARK: - Qualifier Entry

/// Structured description of a qualifier. Built-in qualifiers have an empty
/// `namespace`; plugin qualifiers carry the handle declared in `plugin.yaml`
/// (e.g. `collections.reverse`).
public struct CatalogQualifierEntry: Sendable, Equatable {
    /// Namespace (e.g. "collections"); empty string for built-ins
    public let namespace: String
    /// Plain qualifier name (e.g. "reverse", "uppercase")
    public let qualifier: String
    /// Accepted input types
    public let inputTypes: [String]
    /// Whether the qualifier accepts parameters via a `with` clause
    public let acceptsParameters: Bool
    /// Human-readable description, when known
    public let description: String?
    /// Origin (built-in or plugin)
    public let origin: CatalogOrigin

    public init(
        namespace: String,
        qualifier: String,
        inputTypes: [String] = [],
        acceptsParameters: Bool = false,
        description: String? = nil,
        origin: CatalogOrigin = .builtin
    ) {
        self.namespace = namespace
        self.qualifier = qualifier
        self.inputTypes = inputTypes
        self.acceptsParameters = acceptsParameters
        self.description = description
        self.origin = origin
    }

    /// Display form: `qualifier` for built-ins, `namespace.qualifier` otherwise.
    public var fullName: String {
        namespace.isEmpty || namespace == "_builtin" ? qualifier : "\(namespace).\(qualifier)"
    }
}

// MARK: - Catalog

/// Single source of truth for the LSP and MCP layers when answering "what
/// actions/qualifiers are available?"
///
/// Wraps `ActionRegistry` and `QualifierRegistry` so consumers don't need to
/// reach into either, and tracks plugin loads done on behalf of editors and
/// tools (which run outside the normal `aro run` flow).
public actor AROCatalog {
    /// Shared instance. Use this for the LSP server's process-wide state.
    public static let shared = AROCatalog()

    /// Plugin directories that have been loaded into the registries.
    /// Avoids reloading the same workspace twice.
    private var loadedWorkspaces: Set<URL> = []

    public init() {}

    // MARK: - Plugin Loading

    /// Discover and load all plugins from `<workspaceRoot>/Plugins/` into the
    /// shared `ActionRegistry` and `QualifierRegistry`.
    ///
    /// Safe to call multiple times — duplicate loads are skipped. Errors during
    /// individual plugin loads are logged but do not throw, mirroring the
    /// runtime's behaviour.
    /// - Parameter workspaceRoot: The user's project directory (the parent of
    ///   `Plugins/`, not the `Plugins/` directory itself).
    /// - Returns: True if at least one plugin was discovered, false otherwise.
    @discardableResult
    public func loadPluginsFromWorkspace(_ workspaceRoot: URL) -> Bool {
        let resolved = workspaceRoot.standardizedFileURL
        guard !loadedWorkspaces.contains(resolved) else { return true }

        let pluginsDir = resolved.appendingPathComponent("Plugins")
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            return false
        }

        do {
            try UnifiedPluginLoader.shared.loadPlugins(from: resolved)
            loadedWorkspaces.insert(resolved)
            return true
        } catch {
            AROLogger.warning("AROCatalog: plugin load failed for \(resolved.path): \(error)", subsystem: "catalog")
            return false
        }
    }

    /// Returns true if the catalog has loaded the given workspace.
    public func hasLoaded(_ workspaceRoot: URL) -> Bool {
        loadedWorkspaces.contains(workspaceRoot.standardizedFileURL)
    }

    /// Forget all workspace tracking (useful for tests). Does NOT unload
    /// plugins from the registries — call `UnifiedPluginLoader.shared.unloadAll()`
    /// for that.
    public func resetTrackingForTesting() {
        loadedWorkspaces.removeAll()
    }

    // MARK: - Actions

    /// All known actions, optionally filtered by role.
    /// Built-ins come first, plugin actions follow, both sorted by name.
    ///
    /// `nonisolated` so sync callers (LSP handlers, snapshot helpers) can
    /// invoke this without spawning a Task and blocking on a semaphore — the
    /// pattern that previously deadlocked the cooperative thread pool under
    /// `swift test --parallel`. The underlying registries are themselves
    /// thread-safe (`ActionRegistry` exposes a lock-protected mirror;
    /// `QualifierRegistry` is a sync class), so we don't need actor isolation
    /// here.
    public nonisolated func actions(role: ActionRole? = nil) -> [CatalogActionEntry] {
        var entries: [CatalogActionEntry] = []

        // Built-ins from ActionRegistry, decorated with descriptions
        let builtIns = ActionRegistry.snapshotBuiltInActionInfos
        for info in builtIns {
            // Each unique action type may register multiple verbs. Surface every
            // verb so completion can suggest "Retrieve" and "Fetch" separately
            // even though they share an implementation.
            for verb in info.verbs {
                let entry = CatalogActionEntry(
                    verb: Self.displayCase(verb),
                    role: info.role,
                    prepositions: info.prepositions,
                    description: AROCatalogDescriptions.action(named: verb),
                    origin: .builtin,
                    since: nil
                )
                if role == nil || entry.role == role { entries.append(entry) }
            }
        }

        // Plugin actions from ActionRegistry
        let pluginInfos = ActionRegistry.snapshotPluginActionInfos
        for info in pluginInfos {
            // Skip namespaced duplicates ("hash.hash") — keep only the plain verb
            // since the catalog already records the handle separately.
            if info.verb.contains(".") { continue }

            let metadata = info.metadata
            let pluginRole = metadata?.role ?? .own
            let entry = CatalogActionEntry(
                verb: Self.displayCase(info.verb),
                role: pluginRole,
                prepositions: metadata?.prepositions ?? [],
                description: metadata?.description,
                origin: .plugin(name: info.pluginName ?? "", handle: metadata?.handle),
                since: metadata?.since
            )
            if role == nil || entry.role == role { entries.append(entry) }
        }

        return entries.sorted { $0.verb < $1.verb }
    }

    // MARK: - Qualifiers

    /// All known qualifiers, optionally filtered by namespace.
    /// `namespace == nil` returns everything; pass `""` for built-ins only.
    ///
    /// `nonisolated` for the same reason as `actions(role:)`: only reads from
    /// the thread-safe `QualifierRegistry`, so no actor hop is required.
    public nonisolated func qualifiers(namespace: String? = nil) -> [CatalogQualifierEntry] {
        var entries: [CatalogQualifierEntry] = []

        // QualifierRegistry already knows about both built-ins (registered as
        // `_builtin.<name>`) and plugin qualifiers.
        for reg in QualifierRegistry.shared.allRegistrations() {
            let isBuiltIn = reg.namespace == "_builtin"
            let entry = CatalogQualifierEntry(
                namespace: isBuiltIn ? "" : reg.namespace,
                qualifier: reg.qualifier,
                inputTypes: reg.inputTypes.map { $0.rawValue }.sorted(),
                acceptsParameters: reg.acceptsParameters,
                description: reg.description,
                origin: isBuiltIn ? .builtin : .plugin(name: reg.pluginName, handle: reg.namespace)
            )

            if let filter = namespace {
                if entry.namespace == filter { entries.append(entry) }
            } else {
                entries.append(entry)
            }
        }

        // Add specifier-only qualifiers (status/body/data/etc.) that are not in
        // QualifierRegistry but are documented for completion.
        if namespace == nil || namespace == "" {
            for spec in AROCatalogDescriptions.specifierQualifiers {
                entries.append(CatalogQualifierEntry(
                    namespace: "",
                    qualifier: spec.name,
                    inputTypes: [],
                    acceptsParameters: false,
                    description: spec.description,
                    origin: .builtin
                ))
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.namespace == rhs.namespace { return lhs.qualifier < rhs.qualifier }
            return lhs.namespace < rhs.namespace
        }
    }

    // MARK: - Synchronous Snapshots
    //
    // Direct nonisolated reads. The previous implementation spun a Task and
    // blocked the caller on a `DispatchSemaphore` — under `swift test
    // --parallel`, that pattern starved the cooperative thread pool and
    // deadlocked the entire test run. Now that `actions()` / `qualifiers()`
    // are themselves `nonisolated`, snapshots are plain function calls.

    /// Synchronous snapshot of `actions(role:)`.
    public nonisolated static func actionsSnapshot(role: ActionRole? = nil) -> [CatalogActionEntry] {
        AROCatalog.shared.actions(role: role)
    }

    /// Synchronous snapshot of `qualifiers(namespace:)`.
    public nonisolated static func qualifiersSnapshot(namespace: String? = nil) -> [CatalogQualifierEntry] {
        AROCatalog.shared.qualifiers(namespace: namespace)
    }

    // MARK: - Helpers

    /// Capitalise the first character of a verb for display ("extract" → "Extract").
    /// Plugin verbs are already lowercased when normalised; built-in verbs are
    /// stored lowercased; LSP/MCP consumers expect title-case.
    private static func displayCase(_ verb: String) -> String {
        guard let first = verb.first else { return verb }
        return first.uppercased() + verb.dropFirst()
    }
}

// MARK: - Built-in Description Tables

/// Static descriptions for built-in actions and "specifier" qualifiers
/// (status/body/data/etc.) — pulled out of CompletionHandler and MCPToolProvider
/// so the catalog is the single source of truth.
public enum AROCatalogDescriptions {

    /// Description for a built-in action verb (case-insensitive lookup).
    public static func action(named verb: String) -> String? {
        actionDescriptions[verb.lowercased()]
    }

    /// Specifiers that appear after `:` but aren't real qualifiers (HTTP statuses,
    /// extraction shortcuts, ParseHtml output forms, …). Surfaced for completion.
    public static let specifierQualifiers: [(name: String, description: String)] = [
        ("status", "HTTP-style status qualifier (OK, Created, NotFound, …)"),
        ("body", "Request/response body"),
        ("id", "Identifier"),
        ("data", "Data payload"),
        ("message", "Message content"),
        ("error", "Error information"),
        ("result", "Operation result"),
        ("config", "Configuration"),
        ("first", "First element of a list"),
        ("last", "Last element of a list"),
        ("hidden", "Mask input (password entry)"),
        ("markdown", "Convert HTML to Markdown"),
        ("links", "Extract all hyperlinks"),
        ("title", "Extract page title"),
    ]

    /// Descriptions for all built-in action verbs. Keys are lowercased verbs.
    /// Migrated from the inline arrays in `CompletionHandler.actionCompletions()`
    /// and `MCPToolProvider.executeActions()`.
    private static let actionDescriptions: [String: String] = [
        // REQUEST
        "extract": "Extract data from events, requests, parameters, or path parameters",
        "parse": "Parse structured data (JSON, HTML, XML, CSV)",
        "parsehtml": "Parse HTML into structured data",
        "parselinkheader": "Parse HTTP Link header for pagination",
        "retrieve": "Retrieve from a repository (supports `where field = value` and `default`)",
        "fetch": "Make HTTP GET requests to external services",
        "receive": "Receive data from a socket connection or event stream",
        "accept": "Accept input or accept a state transition",
        "read": "Read content from a file",
        "request": "Make an HTTP request (GET, POST, PUT, DELETE)",
        "probe": "Check whether a target is reachable — never halts on DNS/connect failure",
        "list": "List directory contents",
        "stat": "Get file metadata (size, dates, permissions)",
        "exists": "Check if a path exists",
        "prompt": "Prompt the user for terminal input",
        "select": "Present a terminal selection menu",

        // OWN
        "create": "Create new objects or collections",
        "compute": "Calculate values (arithmetic, length, uppercase, lowercase, trim, hash, …)",
        "validate": "Validate data against rules or schemas",
        "compare": "Compare two values; result is a boolean",
        "transform": "Convert data between types (int/float/string/bool)",
        "update": "Update fields on an existing object",
        "sort": "Sort a collection by field",
        "set": "Set a value",
        "merge": "Merge two collections or objects",
        "delete": "Remove data from a collection",
        "filter": "Filter a collection by predicate",
        "match": "Match against a pattern",
        "split": "Split a string by delimiter or regex",
        "join": "Join list elements into a string",
        "map": "Transform each element of a collection",
        "reduce": "Reduce a collection to a single value",
        "group": "Group a collection by field value",
        "copy": "Copy a file to a destination",
        "move": "Move or rename a file",
        "append": "Append to a file or collection",
        "execute": "Execute a system shell command",
        "call": "Call an external service or plugin action",
        "clear": "Clear the terminal screen",
        "render": "Render a Mustache-style template",

        // RESPONSE
        "return": "Return success with optional data",
        "throw": "Return an error response",
        "broadcast": "Broadcast to all connected clients",

        // EXPORT
        "send": "Send an HTTP request or message to a service/socket",
        "log": "Write to console / logs",
        "store": "Save to a repository (auto-generates `id`)",
        "write": "Write content to a file",
        "emit": "Emit a domain event to the event bus",
        "publish": "Make a variable globally visible across feature sets",
        "notify": "Send a notification to one or more recipients",
        "stream": "Stream data lazily to an output or pipe",

        // SERVER
        "start": "Start a server or service (http-server, file-monitor, socket-server)",
        "stop": "Stop a running service",
        "keepalive": "Keep the application running to process events (blocks until SIGINT)",
        "waitforevents": "Wait until all pending events are processed",
        "schedule": "Schedule a repeating timer event every N seconds",
        "sleep": "Pause execution for N seconds",
        "listen": "Listen for incoming connections on a port",
        "connect": "Connect to a TCP server",
        "close": "Close a connection",
        "make": "Create a directory",
        "watch": "Watch for file system changes",
        "configure": "Configure runtime settings (timeout, retry, …)",

        // TEST
        "given": "Set up test context",
        "when": "Execute the action under test",
        "then": "Assert expected outcomes",
        "assert": "Make a specific assertion",

        // GIT (ARO-0080)
        "stage": "Stage files into the git index",
        "commit": "Commit staged changes to the repository",
        "pull": "Pull from the configured remote",
        "push": "Push to the configured remote",
        "clone": "Clone a remote repository",
        "checkout": "Checkout a branch",
        "tag": "Tag a commit",
    ]
}
