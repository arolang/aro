// ============================================================
// FileTreePane.swift
// SOLARO — left rail: file tree + feature-set summary
// ============================================================
//
// Phase 1 lists the project's `.aro` files in source-path order
// with a click affordance. The feature-set summary (a row per
// feature set under each file) follows from the parsed AST and
// shows up under each file as a nested list. Tabs (Files /
// Features / Plugins) from the wireframes are flattened here
// — Phase 2 splits them back out.

import Foundation
import SwiftCrossUI

struct FileTreePane: View {
    let model: ProjectModel?
    let currentFile: SourceFileState?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files").font(.system(.headline))
            if let model {
                if model.sourceFiles.isEmpty {
                    Text("No .aro files in this project.")
                        .foregroundColor(.gray)
                } else {
                    ForEach(model.sourceFiles, id: \.path) { url in
                        Button(displayName(of: url, root: model.root.rootPath)) {
                            onSelect(url)
                        }
                    }
                }
                if let spec = model.openAPISpec {
                    Text("openapi.yaml — \(spec.lastPathComponent)")
                        .foregroundColor(.gray)
                }
                if !model.storeFiles.isEmpty {
                    Text("Stores")
                        .font(.system(.headline))
                        .padding(.top, 8)
                    ForEach(model.storeFiles, id: \.path) { url in
                        Text(url.lastPathComponent).foregroundColor(.gray)
                    }
                }
            } else {
                Text("Loading…").foregroundColor(.gray)
            }
        }
        .padding(8)
        .frame(width: 240)
    }

    /// Display path relative to the project root. Returns the bare
    /// filename for files in the root, otherwise `subdir/name.aro`.
    private func displayName(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
