// ============================================================
// InspectorPane.swift
// SOLARO — right rail: AST inspector + deploy/observability
// ============================================================
//
// Phase 1 proves end-to-end parser integration: the AST inspector
// reads the current file's `Program`, lists each feature set
// (business activity + statement count), surfaces parse
// diagnostics. The deploy / observability rail is a Phase 2+
// placeholder.

import Foundation
import SwiftCrossUI
import AROParser

struct InspectorPane: View {
    let file: SourceFileState?
    let runtimeVersion: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector").font(.system(.headline))
            if let file {
                ASTInspector(file: file)
                Spacer().frame(height: 12)
                DeployRail(runtimeVersion: runtimeVersion)
            } else {
                Text("Open a file to inspect.").foregroundColor(.gray)
            }
        }
        .padding(8)
        .frame(width: 320)
    }
}

private struct ASTInspector: View {
    let file: SourceFileState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.url.lastPathComponent).font(.system(.subheadline))

            if file.diagnostics.isEmpty {
                Text("Parse · ok").foregroundColor(.green)
            } else {
                Text("Parse · \(file.diagnostics.count) issue(s)").foregroundColor(.red)
                ForEach(Array(file.diagnostics.prefix(5).enumerated()), id: \.offset) { entry in
                    Text("  • \(entry.element.description)").foregroundColor(.red)
                }
            }

            if let program = file.program {
                Text("Feature sets · \(program.featureSets.count)").padding(.top, 4)
                ForEach(program.featureSets, id: \.name) { fs in
                    HStack {
                        Text("•")
                        Text(fs.name)
                        Text("·")
                            .foregroundColor(.gray)
                        Text(fs.businessActivity.isEmpty ? "<no domain>" : fs.businessActivity)
                            .foregroundColor(.gray)
                        Spacer()
                        Text("\(fs.statements.count) stmt").foregroundColor(.gray)
                    }
                }
            } else {
                Text("AST unavailable — parse failed.").foregroundColor(.red)
            }
        }
    }
}

/// Phase 2+ — observability tile. Phase 1 placeholder shows the
/// runtime version + a "no events yet" honest empty state
/// (ADR-016).
private struct DeployRail: View {
    let runtimeVersion: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Deploy & live").font(.system(.headline))
            Text("runtime \(runtimeVersion)").foregroundColor(.gray)
            Text("no events yet — run something").foregroundColor(.gray)
        }
    }
}
