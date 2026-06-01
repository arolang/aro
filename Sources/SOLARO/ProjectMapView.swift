// ============================================================
// ProjectMapView.swift
// SOLARO — Project Map render (note 8519, Phase 3)
// ============================================================
//
// Visual layout matches the wireframe at the data level: domains
// as groups, feature sets listed under each, edges enumerated as
// "from → to (kind)" rows. The colored containing rectangles and
// Bézier wires from the wireframe land in the same #232 follow-
// up as the canvas's wires.

import Foundation
import SwiftCrossUI

struct ProjectMapView: View {
    let map: ProjectMap
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project Map").font(.system(.headline))
                Spacer()
                Text("\(map.nodes.count) feature sets · \(map.domains.count) domains · \(map.edges.count) edges")
                    .foregroundColor(.gray)
            }

            if map.nodes.isEmpty {
                Text("No feature sets in this project yet.").foregroundColor(.gray)
            } else {
                ForEach(map.domains, id: \.self) { domain in
                    domainSection(domain)
                }
                if !map.edges.isEmpty {
                    Text("Connections").font(.system(.headline)).padding(.top, 8)
                    ForEach(map.edges, id: \.id) { edge in
                        edgeRow(edge)
                    }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func domainSection(_ domain: String) -> some View {
        let displayName = domain.isEmpty ? "(unscoped)" : domain
        VStack(alignment: .leading, spacing: 4) {
            Text("◉ \(displayName)").font(.system(.subheadline))
            ForEach(featureSetsIn(domain: domain), id: \.id) { node in
                Button(featureSetLabel(node)) {
                    onSelect(node.id)
                }
            }
        }
    }

    @ViewBuilder
    private func edgeRow(_ edge: ProjectMapEdge) -> some View {
        switch edge.kind {
        case .eventEmitSubscribe(let name):
            HStack {
                Text(edge.from)
                Text("- - emit \(name) - ->").foregroundColor(.gray)
                Text(edge.to)
            }
        case .applicationCall(let action):
            HStack {
                Text(edge.from)
                Text("─ calls Application.\(action) →").foregroundColor(.gray)
                Text(edge.to)
            }
        }
    }

    private func featureSetsIn(domain: String) -> [ProjectMapNode] {
        map.nodes.filter { $0.businessActivity == domain }
    }

    private func featureSetLabel(_ node: ProjectMapNode) -> String {
        let trig: String
        switch node.trigger {
        case .applicationStart:                return "lifecycle"
        case .applicationEnd:                  return "lifecycle"
        case .http(let op):                    return "HTTP · \(op)"
        case .eventHandler(let n):             return "handler · \(n)"
        case .repositoryObserver(let repo):    return "observer · \(repo)"
        case .userAction:                      return "Application.\(node.featureSetName)"
        case .unknown:                         return "unscoped"
        }
        _ = trig
        return "\(node.featureSetName)  ·  \(node.statementCount) stmts"
    }
}
