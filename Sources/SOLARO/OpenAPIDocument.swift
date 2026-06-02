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

    init(root: [String: Any], url: URL) {
        self.root = root
        self.url = url
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
