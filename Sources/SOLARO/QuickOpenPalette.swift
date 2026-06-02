// ============================================================
// QuickOpenPalette.swift
// SOLARO — ⌘P fuzzy file picker (#236)
// ============================================================

import SwiftUI

enum QuickOpenBuilder {

    /// Build a PaletteItem per file in the project. Display name
    /// is the path relative to the project root so duplicate
    /// basenames stay distinguishable.
    @MainActor
    static func items(
        controller: WorkspaceController,
        onOpen: @escaping (URL) -> Void
    ) -> [PaletteItem] {
        guard let model = controller.model else { return [] }
        var files: [(URL, FileTreeNode.Kind)] = []
        for url in model.sourceFiles { files.append((url, .aroSource)) }
        for url in model.storeFiles  { files.append((url, .storeFile)) }
        if let spec = model.openAPISpec { files.append((spec, .openapi)) }

        let rootPath = model.root.rootPath.standardizedFileURL.path
        return files.map { (url, kind) in
            let filePath = url.standardizedFileURL.path
            let relative: String = filePath.hasPrefix(rootPath + "/")
                ? String(filePath.dropFirst(rootPath.count + 1))
                : url.lastPathComponent
            return PaletteItem(
                id: filePath,
                title: url.lastPathComponent,
                subtitle: relative,
                category: nil,
                trailing: nil,
                symbol: symbol(for: kind),
                action: { onOpen(url) }
            )
        }
    }

    private static func symbol(for kind: FileTreeNode.Kind) -> String {
        switch kind {
        case .aroSource: return "doc.text.fill"
        case .storeFile: return "tray.full"
        case .openapi:   return "rectangle.connected.to.line.below"
        case .directory: return "folder.fill"
        case .other:     return "doc"
        }
    }
}
