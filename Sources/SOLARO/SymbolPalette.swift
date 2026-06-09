// ============================================================
// SymbolPalette.swift
// SOLARO — ⌘⇧O symbol picker (#240, go-to-definition)
// ============================================================

import SwiftUI

enum SymbolPaletteBuilder {

    /// One PaletteItem per defined identifier. Subtitle shows the
    /// project-relative path of its first definition + reference
    /// count. Selecting jumps to the definition.
    @MainActor
    static func items(
        controller: WorkspaceController,
        onJump: @escaping (URL, Int) -> Void
    ) -> [PaletteItem] {
        let index = SymbolIndex.build(from: controller.programs)
        guard let model = controller.model else { return [] }
        let rootPath = model.root.rootPath.standardizedFileURL.path
        return index.allDefinedNames.compactMap { name in
            guard let firstDef = index.definitions[name]?.first else { return nil }
            let refCount = index.references[name]?.count ?? 0
            let filePath = firstDef.file.standardizedFileURL.path
            let relative: String = filePath.hasPrefix(rootPath + "/")
                ? String(filePath.dropFirst(rootPath.count + 1))
                : firstDef.file.lastPathComponent
            return PaletteItem(
                id: "def:\(name)",
                title: name,
                subtitle: "\(relative):\(firstDef.line)  ·  \(firstDef.verb)",
                category: "DEF",
                trailing: refCount == 0 ? "" : "\(refCount) ref\(refCount == 1 ? "" : "s")",
                symbol: "circle.fill",
                action: { onJump(firstDef.file, firstDef.line) }
            )
        }
    }
}

/// Sheet listing every reference to a given identifier. Opened
/// either from the symbol palette's trailing badge or from the
/// command palette.
struct FindReferencesSheet: View {
    let controller: WorkspaceController
    let symbolName: String
    let onClose: () -> Void
    let onJump: (URL, Int) -> Void

    private var refs: [SymbolHit] {
        let index = SymbolIndex.build(from: controller.programs)
        let defs = index.definitions[symbolName] ?? []
        let uses = index.references[symbolName] ?? []
        return (defs + uses).sorted { lhs, rhs in
            if lhs.file.path != rhs.file.path {
                return lhs.file.path < rhs.file.path
            }
            return lhs.line < rhs.line
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SolaroSpace.s) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .foregroundStyle(SolaroColor.accent)
                Text("REFERENCES · \(symbolName)")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                Spacer()
                Text("\(refs.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Button("Close") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, SolaroSpace.s)
            Divider().background(SolaroColor.divider)
            if refs.isEmpty {
                Spacer()
                Text("No references found.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(refs) { hit in
                            Button {
                                onJump(hit.file, hit.line)
                            } label: {
                                HStack(spacing: SolaroSpace.s) {
                                    Image(systemName: hit.isDefinition
                                          ? "arrow.right.circle.fill"
                                          : "arrow.down.left.circle")
                                        .foregroundStyle(hit.isDefinition
                                                         ? SolaroColor.accent
                                                         : SolaroColor.textSecondary)
                                    Text(relativePath(of: hit.file))
                                        .font(SolaroFont.body)
                                        .foregroundStyle(SolaroColor.textPrimary)
                                    Text(":\(hit.line)")
                                        .font(SolaroFont.monoCaption)
                                        .foregroundStyle(SolaroColor.textTertiary)
                                    Spacer()
                                    Text(hit.verb)
                                        .font(SolaroFont.monoCaption)
                                        .foregroundStyle(SolaroColor.roleColor(forVerb: hit.verb))
                                }
                                .padding(.horizontal, SolaroSpace.m)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 540, height: 460)
        .background(SolaroColor.surface)
    }

    private func relativePath(of url: URL) -> String {
        guard let model = controller.model else { return url.lastPathComponent }
        let rootPath = model.root.rootPath.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
