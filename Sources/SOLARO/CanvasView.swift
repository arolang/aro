// ============================================================
// CanvasView.swift
// SOLARO — Canvas action-graph rendering (Phase 8)
// ============================================================
//
// Wireframe target: note 8467 figure 1 (canvas center pane).
//
// Phase 8 ships:
//   * Dot-grid backdrop on the workspace dark surface.
//   * Pan (drag) and zoom (magnify gesture / scroll-wheel).
//   * Rounded action cards per statement with a left role-color
//     stripe, verb label, and `<result>` + preposition + `<object>`
//     pin text.
//   * Straight wires between connected statements colored by the
//     receiving statement's preposition. Phase 9 swaps these for
//     cubic Béziers.

import SwiftUI
import AROParser

struct CanvasView: View {
    let graph: CanvasGraph
    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0

    private let nodeWidth: CGFloat = 220
    private let nodeHeight: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            ZStack {
                SolaroColor.backdrop
                dotGrid(in: geo.size)

                ZStack {
                    // Wires first so nodes sit on top.
                    WiresLayer(graph: graph,
                               nodeWidth: nodeWidth, nodeHeight: nodeHeight)
                    NodesLayer(graph: graph,
                               nodeWidth: nodeWidth, nodeHeight: nodeHeight)
                }
                .offset(x: pan.width + dragOffset.width,
                        y: pan.height + dragOffset.height)
                .scaleEffect(zoom * magnify, anchor: .topLeading)
                .animation(.easeOut(duration: 0.15), value: zoom)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    }
            )
            .gesture(
                MagnificationGesture()
                    .updating($magnify) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        zoom = max(0.3, min(3.0, zoom * value))
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                zoomControls
                    .padding(SolaroSpace.m)
            }
            .overlay(alignment: .topTrailing) {
                if graph.nodes.isEmpty {
                    EmptyCanvasNotice()
                        .padding(SolaroSpace.l)
                }
            }
        }
    }

    // MARK: - Backdrop dot grid

    @ViewBuilder
    private func dotGrid(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            let spacing: CGFloat = 24
            let dotRadius: CGFloat = 0.8
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            let color = GraphicsContext.Shading.color(
                SolaroColor.textTertiary.opacity(0.18)
            )
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * spacing
                    let y = CGFloat(row) * spacing
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2)
                    ctx.fill(Path(ellipseIn: rect), with: color)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: - Zoom HUD

    private var zoomControls: some View {
        HStack(spacing: SolaroSpace.s) {
            Button { zoom = max(0.3, zoom - 0.1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Text("\(Int(zoom * 100))%")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .frame(minWidth: 40)
            Button { zoom = min(3.0, zoom + 0.1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button {
                pan = .zero
                zoom = 1.0
            } label: {
                Image(systemName: "scope")
            }
            .help("Reset pan and zoom")
        }
        .buttonStyle(.borderless)
        .padding(SolaroSpace.s)
        .background(SolaroColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }
}

// MARK: - Wires layer (Phase 8 — straight lines; Phase 9 swaps to Béziers)

struct WiresLayer: View {
    let graph: CanvasGraph
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
            for edge in graph.edges {
                guard
                    let from = nodesByID[edge.fromNodeID],
                    let to = nodesByID[edge.toNodeID]
                else { continue }
                let startPoint = CGPoint(
                    x: from.x + Double(nodeWidth),       // right edge of source
                    y: from.y + Double(nodeHeight) / 2
                )
                let endPoint = CGPoint(
                    x: to.x,                              // left edge of receiver
                    y: to.y + Double(nodeHeight) / 2
                )
                var path = Path()
                path.move(to: startPoint)
                path.addLine(to: endPoint)
                let color = SolaroColor.wireColor(forPreposition: edge.preposition)
                ctx.stroke(path,
                           with: .color(color.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5))
            }
        }
    }
}

// MARK: - Nodes layer

struct NodesLayer: View {
    let graph: CanvasGraph
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(graph.nodes) { node in
                CanvasNodeCard(
                    node: node,
                    width: nodeWidth, height: nodeHeight
                )
                .offset(x: node.x, y: node.y)
            }
        }
    }
}

private struct CanvasNodeCard: View {
    let node: CanvasNode
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SolaroColor.roleColor(forVerb: node.verb))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.verb)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(SolaroColor.roleColor(forVerb: node.verb))
                    if let r = node.resultName {
                        Text("<\(r)>")
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                }
                if let prep = node.objectPreposition,
                   let obj = node.objectName,
                   obj.first != "_" {
                    Text("\(prep) <\(obj)>")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.wireColor(forPreposition: prep))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, SolaroSpace.xs)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(SolaroColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
        .help("Line \(node.lineHint): \(node.summary)")
    }
}

private struct EmptyCanvasNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            Text("No statements in this feature set.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("Add a statement to see it appear here as a node.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.m)
        .background(SolaroColor.surfaceRaised.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }
}
