// ============================================================
// FileTabBar.swift
// SOLARO — center-pane tab strip (#238)
// ============================================================
//
// Horizontal scrollable strip of file tabs above the center pane.
// Sidebar selection adds + activates a tab; ⌘W closes the active
// tab; ⌘⇧[ and ⌘⇧] cycle between tabs.

import SwiftUI

struct FileTabBar: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(controller.openTabs, id: \.path) { url in
                    FileTab(
                        url: url,
                        isActive: controller.currentFile == url,
                        displayName: displayName(of: url),
                        onActivate: { controller.openFile(url) },
                        onClose: { controller.closeTab(url) }
                    )
                    Divider()
                        .frame(height: 18)
                        .background(SolaroColor.divider)
                }
            }
        }
        .background(SolaroColor.surface)
    }

    private func displayName(of url: URL) -> String {
        guard let model = controller.model else { return url.lastPathComponent }
        let rootPath = model.root.rootPath.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            // Show only the basename when it's unique among open
            // tabs; otherwise include the parent directory so two
            // tabs named "main.aro" don't look identical.
            let basename = url.lastPathComponent
            let dupes = controller.openTabs
                .filter { $0.lastPathComponent == basename }
                .count
            if dupes > 1 {
                return relative
            }
            return basename
        }
        return url.lastPathComponent
    }
}

private struct FileTab: View {
    let url: URL
    let isActive: Bool
    let displayName: String
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 11))
                .foregroundStyle(SolaroColor.accent.opacity(isActive ? 1 : 0.6))
            Text(displayName)
                .font(SolaroFont.caption)
                .foregroundStyle(isActive
                                 ? SolaroColor.textPrimary
                                 : SolaroColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SolaroColor.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 6)
        .background(
            isActive
                ? SolaroColor.surfaceRaised
                : (hovering ? SolaroColor.surfaceRaised.opacity(0.5) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? SolaroColor.accent : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        .onHover { hovering = $0 }
        .help(url.path)
    }

    private var glyph: String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".aro")   { return "doc.text.fill" }
        if name.hasSuffix(".yaml") || name.hasSuffix(".yml") {
            return "rectangle.connected.to.line.below"
        }
        if name.hasSuffix(".store") { return "tray.full" }
        return "doc"
    }
}
