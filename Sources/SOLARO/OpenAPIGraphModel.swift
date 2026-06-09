// ============================================================
// OpenAPIGraphModel.swift
// SOLARO — graph extraction from openapi.yaml for the canvas
// ============================================================
//
// Parses a project's `openapi.yaml` into a graph the SwiftUI
// canvas can render: HTTP routes in one column, component
// schemas in another, $ref edges connecting them.
//
// This is the data layer only — no UI here. `OpenAPIGraphView`
// lives next door and consumes this graph.

import Foundation
import Yams

/// One node in the OpenAPI graph. Either a route or a schema —
/// both share an id, display label, and position so the canvas
/// renderer can treat them uniformly when drawing wires.
struct OpenAPINode: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case route(method: String, path: String, summary: String?, operationId: String?)
        case schema(typeName: String, properties: [Property])
    }

    let id: String
    let kind: Kind
    var x: Double = 0
    var y: Double = 0

    struct Property: Equatable, Hashable {
        let name: String
        let typeLabel: String      // "string", "integer", "User" (when $ref), …
        let refTarget: String?     // schema id when this property is a $ref, else nil
    }

    /// Display label shown at the top of the node card. For routes
    /// the verb + path; for schemas the type name.
    var displayName: String {
        switch kind {
        case .route(let method, let path, _, _):
            return "\(method) \(path)"
        case .schema(let name, _):
            return name
        }
    }
}

/// A reference edge from one node to another. Used to draw wires.
struct OpenAPIRef: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case requestBody      // route → schema ($ref, solid colored)
        case response         // route → schema ($ref, solid colored)
        case schemaProperty   // schema → schema ($ref, solid colored)
        case schemaArrayItem  // schema → schema ($ref, solid colored)
        case inlineLink       // route/schema → inline node (gray dotted)
    }

    let id: String
    let fromID: String
    let toID: String
    let kind: Kind
    /// Pretty label, e.g. "201 / application/json", "user" for a
    /// schema-property edge, etc.
    let label: String
}

/// The full parsed graph.
struct OpenAPIGraph: Equatable {
    var nodes: [OpenAPINode]
    var refs: [OpenAPIRef]
    /// Top-level metadata extracted from the YAML (`info` block).
    let title: String
    let version: String
}

enum OpenAPIGraphBuilder {

    /// Parse `yaml` into a graph. Empty / unparseable input yields
    /// an empty graph with default metadata — callers handle the
    /// honest empty case in the view.
    static func build(yaml: String) -> OpenAPIGraph {
        guard
            !yaml.isEmpty,
            let parsed = try? Yams.load(yaml: yaml) as? [String: Any]
        else {
            return OpenAPIGraph(nodes: [], refs: [], title: "", version: "")
        }

        let info = parsed["info"] as? [String: Any]
        let title = info?["title"] as? String ?? ""
        let version = info?["version"] as? String ?? ""

        var nodes: [OpenAPINode] = []
        var refs: [OpenAPIRef] = []

        // Schemas first so route refs can resolve cleanly.
        if let components = parsed["components"] as? [String: Any],
           let schemas = components["schemas"] as? [String: Any]
        {
            // Sort by name so layout is stable.
            for (name, schemaObj) in schemas.sorted(by: { $0.key < $1.key }) {
                let id = "schema:\(name)"
                guard let schema = schemaObj as? [String: Any] else {
                    nodes.append(OpenAPINode(id: id,
                                             kind: .schema(typeName: name, properties: [])))
                    continue
                }

                var props: [OpenAPINode.Property] = []
                if let propsDict = schema["properties"] as? [String: Any] {
                    for (propName, propValue) in propsDict.sorted(by: { $0.key < $1.key }) {
                        let p = describeProperty(propName: propName,
                                                 propValue: propValue,
                                                 ownerSchemaId: id,
                                                 refs: &refs)
                        props.append(p)
                    }
                }
                // Array schema whose items are a $ref — draw an edge.
                if let typeStr = schema["type"] as? String, typeStr == "array",
                   let items = schema["items"] as? [String: Any],
                   let target = schemaIdFromRef(items["$ref"])
                {
                    refs.append(OpenAPIRef(
                        id: "\(id)→\(target)→items",
                        fromID: id, toID: target,
                        kind: .schemaArrayItem,
                        label: "items"
                    ))
                }

                nodes.append(OpenAPINode(
                    id: id,
                    kind: .schema(typeName: name, properties: props)
                ))
            }
        }

        // Then routes — operationId, method, summary, refs in / out.
        if let paths = parsed["paths"] as? [String: Any] {
            let knownMethods: Set<String> = [
                "get", "post", "put", "patch", "delete", "options", "head"
            ]
            for (path, pathObj) in paths.sorted(by: { $0.key < $1.key }) {
                guard let methods = pathObj as? [String: Any] else { continue }
                for (verb, opObj) in methods.sorted(by: { $0.key < $1.key }) {
                    guard knownMethods.contains(verb.lowercased()),
                          let operation = opObj as? [String: Any]
                    else { continue }

                    let methodUpper = verb.uppercased()
                    let routeID = "route:\(methodUpper) \(path)"
                    let summary = operation["summary"] as? String
                    let operationId = operation["operationId"] as? String

                    nodes.append(OpenAPINode(
                        id: routeID,
                        kind: .route(method: methodUpper,
                                     path: path,
                                     summary: summary,
                                     operationId: operationId)
                    ))

                    // Request body — either a $ref to a component
                    // (solid colored edge) or an inline object (a
                    // synthetic schema node + dotted edge).
                    if let body = operation["requestBody"] as? [String: Any],
                       let content = body["content"] as? [String: Any]
                    {
                        for (_, mediaObj) in content {
                            guard let media = mediaObj as? [String: Any],
                                  let schema = media["schema"] as? [String: Any]
                            else { continue }
                            if let target = schemaIdFromRef(schema["$ref"]) {
                                refs.append(OpenAPIRef(
                                    id: "\(routeID)→\(target)→req",
                                    fromID: routeID, toID: target,
                                    kind: .requestBody,
                                    label: "request body"
                                ))
                            } else {
                                materializeInline(
                                    schema: schema,
                                    parentID: routeID,
                                    label: "request body",
                                    nodes: &nodes,
                                    refs: &refs
                                )
                            }
                        }
                    }
                    // Responses — same dance per status / media type.
                    if let responses = operation["responses"] as? [String: Any] {
                        for (status, respObj) in responses {
                            guard let resp = respObj as? [String: Any],
                                  let content = resp["content"] as? [String: Any]
                            else { continue }
                            for (_, mediaObj) in content {
                                guard let media = mediaObj as? [String: Any],
                                      let schema = media["schema"] as? [String: Any]
                                else { continue }
                                if let target = schemaIdFromRef(schema["$ref"]) {
                                    refs.append(OpenAPIRef(
                                        id: "\(routeID)→\(target)→resp:\(status)",
                                        fromID: routeID, toID: target,
                                        kind: .response,
                                        label: "response \(status)"
                                    ))
                                } else {
                                    materializeInline(
                                        schema: schema,
                                        parentID: routeID,
                                        label: "response \(status)",
                                        nodes: &nodes,
                                        refs: &refs
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        return OpenAPIGraph(
            nodes: nodes,
            refs: refs,
            title: title,
            version: version
        )
    }

    // MARK: - Helpers

    private static func describeProperty(
        propName: String,
        propValue: Any,
        ownerSchemaId: String,
        refs: inout [OpenAPIRef]
    ) -> OpenAPINode.Property {
        guard let dict = propValue as? [String: Any] else {
            return .init(name: propName, typeLabel: "any", refTarget: nil)
        }
        if let target = schemaIdFromRef(dict["$ref"]) {
            let targetName = (target as String).replacingOccurrences(of: "schema:", with: "")
            refs.append(OpenAPIRef(
                id: "\(ownerSchemaId)→\(target)→prop:\(propName)",
                fromID: ownerSchemaId, toID: target,
                kind: .schemaProperty,
                label: propName
            ))
            return .init(name: propName, typeLabel: targetName, refTarget: target)
        }
        if let arr = dict["type"] as? String, arr == "array",
           let items = dict["items"] as? [String: Any]
        {
            if let target = schemaIdFromRef(items["$ref"]) {
                let targetName = (target as String).replacingOccurrences(of: "schema:", with: "")
                refs.append(OpenAPIRef(
                    id: "\(ownerSchemaId)→\(target)→arr:\(propName)",
                    fromID: ownerSchemaId, toID: target,
                    kind: .schemaArrayItem,
                    label: "\(propName)[]"
                ))
                return .init(name: propName, typeLabel: "[\(targetName)]",
                             refTarget: target)
            }
            let primitive = items["type"] as? String ?? "any"
            return .init(name: propName, typeLabel: "[\(primitive)]", refTarget: nil)
        }
        let typeStr = dict["type"] as? String ?? "any"
        return .init(name: propName, typeLabel: typeStr, refTarget: nil)
    }

    /// Map a `$ref` string like `#/components/schemas/User` to the
    /// node id we use for that schema.
    private static func schemaIdFromRef(_ ref: Any?) -> String? {
        guard let refStr = ref as? String else { return nil }
        let prefix = "#/components/schemas/"
        guard refStr.hasPrefix(prefix) else { return nil }
        let name = String(refStr.dropFirst(prefix.count))
        return "schema:\(name)"
    }

    /// Spawn a synthetic schema node from an inline object schema
    /// hanging off a route's request/response (or another schema's
    /// property). The new node is wired to its parent with the
    /// dotted "inline-link" edge kind.
    private static func materializeInline(
        schema: [String: Any],
        parentID: String,
        label: String,
        nodes: inout [OpenAPINode],
        refs: inout [OpenAPIRef]
    ) {
        // Inline arrays whose `items` are a $ref — treat as a
        // direct ref from the parent to the items schema.
        if let typeStr = schema["type"] as? String, typeStr == "array",
           let items = schema["items"] as? [String: Any],
           let target = schemaIdFromRef(items["$ref"])
        {
            refs.append(OpenAPIRef(
                id: "\(parentID)→\(target)→inline-arr:\(label)",
                fromID: parentID, toID: target,
                kind: .inlineLink,
                label: "\(label) [items]"
            ))
            return
        }

        // Anything else with a properties dictionary becomes an
        // inline node. Primitive types (just `type: string`) we
        // ignore — there's nothing to draw for them.
        guard let properties = schema["properties"] as? [String: Any] else {
            return
        }

        let inlineID = "inline:\(parentID):\(label)"
        var props: [OpenAPINode.Property] = []
        for (propName, propValue) in properties.sorted(by: { $0.key < $1.key }) {
            props.append(describeProperty(
                propName: propName,
                propValue: propValue,
                ownerSchemaId: inlineID,
                refs: &refs
            ))
        }
        let display = "inline · \(label)"
        nodes.append(OpenAPINode(
            id: inlineID,
            kind: .schema(typeName: display, properties: props)
        ))
        refs.append(OpenAPIRef(
            id: "\(parentID)→\(inlineID)→inline:\(label)",
            fromID: parentID, toID: inlineID,
            kind: .inlineLink,
            label: label
        ))
    }
}
