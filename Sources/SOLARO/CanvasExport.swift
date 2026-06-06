// ============================================================
// CanvasExport.swift
// SOLARO — PNG export of the current canvas (#267)
// ============================================================
//
// Renders the active canvas's content at 2× scale onto a PNG
// the user picks with `NSSavePanel`. The renderer forces
// `colorScheme = .light` regardless of the user's in-app theme
// so the exported PNG lands cleanly in READMEs, slide decks,
// and printed pages — dark-on-dark surfaces would tank
// legibility on paper.

import SwiftUI
import AppKit

/// Builds + writes the PNG. Used from the command palette and
/// (eventually) a right-click "Export selection as PNG" on the
/// canvas blank area. `graph` is whatever the canvas would draw
/// right now — the caller resolves it from the controller's
/// programs the same way `CenterPane.canvasGraph` does.
@MainActor
enum CanvasExporter {

    static func exportPNG(graph: CanvasGraph,
                          project: Project) {
        let panel = NSSavePanel()
        panel.title = "Export Canvas as PNG"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue =
            "\(project.displayName)-canvas.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let view = CanvasExportView(graph: graph)
            // Force printable light palette regardless of the
            // user's theme preference (#267).
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: contentWidth(for: graph),
                                                  height: contentHeight(for: graph))

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else {
            NSSound.beep()
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            NSSound.beep()
        }
    }

    private static let nodeWidth: CGFloat = 280
    private static let nodeHeight: CGFloat = 88
    private static let horizontalSpacing: CGFloat = 96
    private static let topPadding: CGFloat = 72
    private static let edgePadding: CGFloat = 32

    private static func contentWidth(for graph: CanvasGraph) -> CGFloat {
        guard !graph.nodes.isEmpty else { return 800 }
        let maxX = graph.nodes.map(\.x).max() ?? 0
        return max(maxX + nodeWidth + edgePadding * 2, 800)
    }

    private static func contentHeight(for graph: CanvasGraph) -> CGFloat {
        guard !graph.nodes.isEmpty else { return 600 }
        let maxY = graph.nodes.map(\.y).max() ?? 0
        return max(maxY + nodeHeight + edgePadding * 2, 600)
    }
}

/// Stripped-down canvas — no pulses, no hover, no selection
/// chrome. Pure node + wire rendering used by the exporter to
/// produce a clean snapshot.
struct CanvasExportView: View {
    let graph: CanvasGraph

    private let nodeWidth: CGFloat = 280
    private let nodeHeight: CGFloat = 88

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            // Feature-set tinted backgrounds, reused from the
            // live canvas so the export looks like the IDE.
            FeatureSetContainersLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                lastExecutedAtPerFeatureSet: [:],
                testResults: [:],
                onHeaderDrag: { _, _ in },
                onHeaderDragEnd: { _, _ in }
            )
            WiresLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                repoWidth: 220, repoHeight: 72
            )
            ForEach(graph.nodes) { node in
                exportCard(for: node)
                    .position(x: node.x + nodeWidth / 2,
                              y: node.y + nodeHeight / 2)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var nodePositions: [CanvasNode.ID: CGPoint] {
        Dictionary(uniqueKeysWithValues:
            graph.nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) }
        )
    }

    /// Static, no-state version of `CanvasNodeCard` — same role
    /// rail + summary text but without the pulse / popover /
    /// breakpoint / error overlays so the PNG stays neutral.
    private func exportCard(for node: CanvasNode) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SolaroColor.roleColor(forVerb: node.verb))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.verb)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(node.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .frame(width: nodeWidth, height: nodeHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }
}
