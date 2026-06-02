// ============================================================
// OpenAPIDocument.swift
// SOLARO — mutable wrapper around an OpenAPI YAML file
// ============================================================
//
// The OpenAPI canvas (read-only) reads the YAML on every render.
// The inspector form lets the user edit fields graphically — this
// needs a persistent, mutable representation that can:
//   * load the YAML once on file open,
//   * mutate specific fields by path,
//   * re-serialise back to YAML on save.
//
// We hold the document as a nested `[String: Any]` (the natural
// Yams shape) and patch keys in place. Comments and original
// formatting are not preserved by Yams round-trip — that's a
// known trade-off for Phase 2.

import Foundation
import Yams

@MainActor
@Observable
final class OpenAPIDocument {
    /// Raw OpenAPI dictionary loaded from the YAML.
    var root: [String: Any]
    /// The file the document was read from.
    let url: URL
    /// `true` when the document has unsaved changes.
    private(set) var isDirty: Bool = false
    /// Last error from a save attempt, surfaced in the inspector.
    private(set) var lastError: String?

    /// File-system source that fires whenever the YAML file on
    /// disk is rewritten — e.g. an external editor saved over it.
    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1

    init(root: [String: Any], url: URL) {
        self.root = root
        self.url = url
        installFileWatcher()
    }

    /// Tear the file watcher down. Called explicitly because the
    /// MainActor-isolated stored properties aren't reachable from
    /// a nonisolated deinit.
    func tearDownWatcher() {
        watcher?.cancel()
        if watcherFD >= 0 {
            Darwin.close(watcherFD)
            watcherFD = -1
        }
        watcher = nil
    }

    /// Watch the file for external writes; when something else
    /// touches it (vim, Xcode, git checkout, …) reload the
    /// document — but only if the user has no unsaved changes,
    /// since otherwise we'd silently nuke their work.
    private func installFileWatcher() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadFromDiskIfClean()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watcherFD, fd >= 0 {
                Darwin.close(fd)
                self?.watcherFD = -1
            }
        }
        source.resume()
        watcher = source
    }

    private func reloadFromDiskIfClean() {
        guard !isDirty else { return }
        guard
            let text = try? String(contentsOf: url, encoding: .utf8),
            let parsed = try? Yams.load(yaml: text) as? [String: Any]
        else { return }
        root = parsed
    }

    /// Mark the document as having unsaved changes. Called when
    /// the YAML editor parses a text edit back into `root` — the
    /// inspector's Save button + the modified-badge respond to
    /// this flag.
    func markDirty() {
        isDirty = true
    }

    static func load(from url: URL) -> OpenAPIDocument? {
        guard
            let text = try? String(contentsOf: url, encoding: .utf8),
            let parsed = try? Yams.load(yaml: text) as? [String: Any]
        else { return nil }
        return OpenAPIDocument(root: parsed, url: url)
    }

    /// Round-trip the document through Yams.dump and write to disk.
    func save() {
        do {
            let yaml = try Yams.dump(object: root, sortKeys: false)
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Route mutations

    /// Find the operation dictionary at `paths.<path>.<method>` and
    /// hand it to `mutate`. The closure returns the new dict; nil
    /// means "no change". On non-nil return, the document becomes
    /// dirty.
    func mutateRoute(path: String, method: String,
                     _ mutate: (inout [String: Any]) -> Void) {
        var paths = root["paths"] as? [String: Any] ?? [:]
        var pathObj = paths[path] as? [String: Any] ?? [:]
        var operation = pathObj[method.lowercased()] as? [String: Any] ?? [:]
        let before = NSDictionary(dictionary: operation)
        mutate(&operation)
        let after = NSDictionary(dictionary: operation)
        if before == after { return }
        pathObj[method.lowercased()] = operation
        paths[path] = pathObj
        root["paths"] = paths
        isDirty = true
    }

    /// Convenience: read the current operation dictionary.
    func operation(path: String, method: String) -> [String: Any]? {
        guard
            let paths = root["paths"] as? [String: Any],
            let pathObj = paths[path] as? [String: Any],
            let operation = pathObj[method.lowercased()] as? [String: Any]
        else { return nil }
        return operation
    }

    // MARK: - Schema mutations

    /// Find a schema at `components.schemas.<name>` and pass its
    /// dictionary to `mutate`.
    func mutateSchema(name: String,
                      _ mutate: (inout [String: Any]) -> Void) {
        var components = root["components"] as? [String: Any] ?? [:]
        var schemas = components["schemas"] as? [String: Any] ?? [:]
        var schema = schemas[name] as? [String: Any] ?? [:]
        let before = NSDictionary(dictionary: schema)
        mutate(&schema)
        let after = NSDictionary(dictionary: schema)
        if before == after { return }
        schemas[name] = schema
        components["schemas"] = schemas
        root["components"] = components
        isDirty = true
    }

    func schema(name: String) -> [String: Any]? {
        guard
            let components = root["components"] as? [String: Any],
            let schemas = components["schemas"] as? [String: Any]
        else { return nil }
        return schemas[name] as? [String: Any]
    }

    // MARK: - Add / remove

    /// Insert a new route under `paths`. Picks a non-colliding path
    /// like `/newRoute`, `/newRoute2`, …; returns the chosen path
    /// + method so the caller can select the new node.
    @discardableResult
    func addRoute() -> (path: String, method: String) {
        var paths = root["paths"] as? [String: Any] ?? [:]
        var pathName = "/newRoute"
        var counter = 2
        while paths[pathName] != nil {
            pathName = "/newRoute\(counter)"
            counter += 1
        }
        paths[pathName] = [
            "get": [
                "operationId": "todoRename",
                "summary": "Describe what this route does",
                "responses": [
                    "200": [
                        "description": "ok",
                    ],
                ],
            ],
        ] as [String: Any]
        root["paths"] = paths
        isDirty = true
        return (pathName, "GET")
    }

    /// Insert a new component schema. Returns the chosen name so
    /// the caller can select it.
    @discardableResult
    func addSchema() -> String {
        var components = root["components"] as? [String: Any] ?? [:]
        var schemas = components["schemas"] as? [String: Any] ?? [:]
        var name = "NewType"
        var counter = 2
        while schemas[name] != nil {
            name = "NewType\(counter)"
            counter += 1
        }
        schemas[name] = [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
            ],
        ] as [String: Any]
        components["schemas"] = schemas
        root["components"] = components
        isDirty = true
        return name
    }

    /// Remove a route (`paths.<path>.<method>`) and, if that was
    /// the only verb on that path, the path entry itself.
    func removeRoute(path: String, method: String) {
        var paths = root["paths"] as? [String: Any] ?? [:]
        var pathObj = paths[path] as? [String: Any] ?? [:]
        if pathObj.removeValue(forKey: method.lowercased()) == nil { return }
        if pathObj.isEmpty {
            paths.removeValue(forKey: path)
        } else {
            paths[path] = pathObj
        }
        root["paths"] = paths
        isDirty = true
    }

    /// Remove a component schema.
    func removeSchema(name: String) {
        var components = root["components"] as? [String: Any] ?? [:]
        var schemas = components["schemas"] as? [String: Any] ?? [:]
        if schemas.removeValue(forKey: name) == nil { return }
        components["schemas"] = schemas
        root["components"] = components
        isDirty = true
    }

    /// Rename a component schema. Updates every `$ref` pointing
    /// at the old name so the graph stays consistent. No-op when
    /// the target name already exists or the names are identical.
    @discardableResult
    func renameSchema(from oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return false }
        var components = root["components"] as? [String: Any] ?? [:]
        var schemas = components["schemas"] as? [String: Any] ?? [:]
        guard let value = schemas[oldName], schemas[trimmed] == nil else {
            return false
        }
        schemas.removeValue(forKey: oldName)
        schemas[trimmed] = value
        components["schemas"] = schemas
        root["components"] = components
        rewriteRefs(from: "#/components/schemas/\(oldName)",
                    to: "#/components/schemas/\(trimmed)")
        isDirty = true
        return true
    }

    /// Walk the entire root tree replacing any `$ref` string equal
    /// to `from` with `to`. Used to keep cross-references valid
    /// when a schema is renamed.
    private func rewriteRefs(from: String, to: String) {
        root = (Self.rewriteRefs(in: root, from: from, to: to) as? [String: Any]) ?? root
    }

    private static func rewriteRefs(in value: Any, from: String, to: String) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if k == "$ref", let s = v as? String, s == from {
                    out[k] = to
                } else {
                    out[k] = rewriteRefs(in: v, from: from, to: to)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { rewriteRefs(in: $0, from: from, to: to) }
        }
        return value
    }

    /// Toggle membership in the schema's `required` array.
    func setPropertyRequired(in schemaName: String, propertyName: String, required: Bool) {
        mutateSchema(name: schemaName) { schema in
            var arr = (schema["required"] as? [Any])?.compactMap { $0 as? String } ?? []
            if required {
                if !arr.contains(propertyName) { arr.append(propertyName) }
            } else {
                arr.removeAll { $0 == propertyName }
            }
            if arr.isEmpty {
                schema.removeValue(forKey: "required")
            } else {
                schema["required"] = arr
            }
        }
    }

    /// Set the property's type — accepts primitives or a schema
    /// name (which becomes a `$ref` to the component). Mutually
    /// exclusive with each other: a $ref drops the `type` key,
    /// a primitive drops `$ref`.
    func setPropertyType(
        in schemaName: String,
        propertyName: String,
        kind: PropertyTypeChoice
    ) {
        mutateSchema(name: schemaName) { schema in
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            var p = (props[propertyName] as? [String: Any]) ?? [:]
            // Wipe both first, then set whichever the user picked.
            p.removeValue(forKey: "type")
            p.removeValue(forKey: "$ref")
            p.removeValue(forKey: "items")
            switch kind {
            case .primitive(let name):
                p["type"] = name
            case .array(let inner):
                p["type"] = "array"
                switch inner {
                case .primitive(let n):
                    p["items"] = ["type": n] as [String: Any]
                case .schemaRef(let s):
                    p["items"] = ["$ref": "#/components/schemas/\(s)"] as [String: Any]
                }
            case .schemaRef(let target):
                p["$ref"] = "#/components/schemas/\(target)"
            }
            props[propertyName] = p
            schema["properties"] = props
        }
    }

    enum PropertyTypeChoice: Equatable, Hashable {
        case primitive(String)            // "string", "integer", etc
        case schemaRef(String)            // schema name → $ref
        case array(InnerType)             // array of …

        enum InnerType: Equatable, Hashable {
            case primitive(String)
            case schemaRef(String)
        }
    }

    /// Set the property's description ("" clears it).
    func setPropertyDescription(
        in schemaName: String,
        propertyName: String,
        description: String
    ) {
        mutateSchema(name: schemaName) { schema in
            var props = (schema["properties"] as? [String: Any]) ?? [:]
            var p = (props[propertyName] as? [String: Any]) ?? [:]
            if description.isEmpty {
                p.removeValue(forKey: "description")
            } else {
                p["description"] = description
            }
            props[propertyName] = p
            schema["properties"] = props
        }
    }

    /// Every component schema name — used by the inspector's
    /// type picker to offer "→ existing schema" choices.
    var schemaNames: [String] {
        guard
            let components = root["components"] as? [String: Any],
            let schemas = components["schemas"] as? [String: Any]
        else { return [] }
        return schemas.keys.sorted()
    }
}

// MARK: - Lint warnings

/// One warning attached to a route or schema. Surfaced as a small
/// indicator on the node card + listed in the inspector.
struct OpenAPILintWarning: Identifiable, Equatable, Hashable {
    let id: String
    let nodeID: String
    let severity: Severity
    let message: String

    enum Severity: Equatable, Hashable { case warning, error }
}

enum OpenAPILinter {
    /// Walk the parsed graph + raw OpenAPI dictionary and return any
    /// best-practice warnings (missing summary, no responses, no
    /// operationId, schema with no properties, …).
    @MainActor
    static func lint(graph: OpenAPIGraph, document: OpenAPIDocument) -> [OpenAPILintWarning] {
        var out: [OpenAPILintWarning] = []
        for node in graph.nodes {
            switch node.kind {
            case .route(_, let path, let summary, let operationId):
                if (summary ?? "").isEmpty {
                    out.append(.init(
                        id: "\(node.id)-no-summary",
                        nodeID: node.id, severity: .warning,
                        message: "Missing `summary` — describe what this route does."
                    ))
                }
                if (operationId ?? "").isEmpty {
                    out.append(.init(
                        id: "\(node.id)-no-opId",
                        nodeID: node.id, severity: .warning,
                        message: "Missing `operationId` — ARO matches feature sets by this."
                    ))
                }
                // Check responses presence.
                if let op = node.routeOperationDict(in: document),
                   let responses = op["responses"] as? [String: Any], responses.isEmpty
                {
                    out.append(.init(
                        id: "\(node.id)-no-responses",
                        nodeID: node.id, severity: .error,
                        message: "Empty `responses` — every route needs at least one."
                    ))
                } else if node.routeOperationDict(in: document)?["responses"] == nil {
                    out.append(.init(
                        id: "\(node.id)-no-responses",
                        nodeID: node.id, severity: .error,
                        message: "No `responses` defined — add a 200 / 201 / etc."
                    ))
                }
                _ = path  // currently unused but kept for future rules
            case .schema(_, let props):
                if props.isEmpty, !node.id.hasPrefix("inline:") {
                    out.append(.init(
                        id: "\(node.id)-no-props",
                        nodeID: node.id, severity: .warning,
                        message: "Schema has no `properties` — consider adding fields."
                    ))
                }
            }
        }
        return out
    }
}

private extension OpenAPINode {
    /// Convenience: pull the underlying operation dictionary back
    /// out of the document for lint rules that need to inspect
    /// fields the graph builder didn't capture.
    @MainActor
    func routeOperationDict(in document: OpenAPIDocument) -> [String: Any]? {
        guard case .route(let method, let path, _, _) = kind else { return nil }
        return document.operation(path: path, method: method)
    }
}
