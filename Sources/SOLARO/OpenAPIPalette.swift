// ============================================================
// OpenAPIPalette.swift
// SOLARO — OpenAPI endpoint palette (Phase 3)
// ============================================================
//
// Reads the project's `openapi.yaml` and surfaces each endpoint
// as a draggable chip (wireframe note 8467 figure 10). Phase 3
// ships the data-driven list; drag-to-canvas comes when the
// canvas gains drop targets (Phase 2 follow-up #232).

import Foundation
import SwiftCrossUI
import Yams

/// One HTTP endpoint discovered in `openapi.yaml`.
struct OpenAPIEndpoint: Identifiable, Equatable {
    let id: String                  // "GET /users"
    let method: String              // "GET", "POST", …
    let path: String                // "/users"
    let operationId: String?        // matches the ARO feature-set name
    let summary: String?
    /// Whether a matching feature set already exists in the project.
    var used: Bool = false
}

enum OpenAPIPalette {

    /// Discover endpoints in a project's `openapi.yaml`. Returns
    /// an empty list when the file is missing — the UI handles
    /// that case honestly.
    ///
    /// Used-feature-set marking is determined by checking each
    /// `operationId` against the list of feature-set names in the
    /// program(s).
    static func endpoints(in projectModel: ProjectModel, programs: [Program]) -> [OpenAPIEndpoint] {
        guard let spec = projectModel.openAPISpec else { return [] }
        guard
            let text = try? String(contentsOf: spec, encoding: .utf8),
            let parsed = try? Yams.load(yaml: text) as? [String: Any],
            let paths = parsed["paths"] as? [String: Any]
        else { return [] }

        let existingNames: Set<String> = Set(
            programs.flatMap { $0.featureSets.map(\.name) }
        )

        var out: [OpenAPIEndpoint] = []
        for (path, pathObj) in paths {
            guard let methods = pathObj as? [String: Any] else { continue }
            for (verb, opObj) in methods {
                guard
                    ["get", "post", "put", "patch", "delete", "options", "head"]
                        .contains(verb.lowercased())
                else { continue }
                let methodUpper = verb.uppercased()
                let operationDict = opObj as? [String: Any]
                let operationId = operationDict?["operationId"] as? String
                let summary = operationDict?["summary"] as? String

                out.append(OpenAPIEndpoint(
                    id: "\(methodUpper) \(path)",
                    method: methodUpper,
                    path: path,
                    operationId: operationId,
                    summary: summary,
                    used: operationId.map { existingNames.contains($0) } ?? false
                ))
            }
        }
        return out.sorted { $0.id < $1.id }
    }
}

import AROParser

struct OpenAPIPaletteView: View {
    let endpoints: [OpenAPIEndpoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAPI palette").font(.system(.headline))
            if endpoints.isEmpty {
                Text("No openapi.yaml in this project — drop one at the project root to populate this palette.")
                    .foregroundColor(.gray)
            } else {
                Text("\(endpoints.count) endpoint(s)").foregroundColor(.gray)
                ForEach(endpoints, id: \.id) { ep in
                    HStack {
                        Text(ep.method)
                            .foregroundColor(methodColor(ep.method))
                        Text(ep.path)
                        Spacer()
                        if let opId = ep.operationId {
                            Text(opId).foregroundColor(.gray)
                        }
                        if ep.used {
                            Text("⇆ used").foregroundColor(.gray)
                        } else {
                            Text("+ stub").foregroundColor(.gray)
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET":    return .blue
        case "POST":   return .green
        case "PUT", "PATCH":   return .yellow
        case "DELETE": return .red
        default:       return .gray
        }
    }
}
