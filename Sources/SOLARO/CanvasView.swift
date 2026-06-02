// ============================================================
// CanvasView.swift
// SOLARO — Canvas action-graph rendering (Phases 8 / 9 + drag fix)
// ============================================================
//
// Wireframe target: note 8467 figure 1 (canvas center pane).
//
// The canvas:
//   * Dot-grid backdrop on the workspace dark surface.
//   * Pan (drag empty area) and zoom (magnify gesture / HUD).
//   * Rounded action cards per statement with a left role-color
//     stripe, verb + role-tinted label, and the AROStatement's
//     full description on a second line.
//   * Cubic Bézier wires colored by the receiver's preposition,
//     with a soft glow underlay and a small dot at the receiver.
//   * Drag-to-move nodes; positions persist to the .aro.layout.json
//     sidecar through the supplied `persistPosition` callback.

import SwiftUI
import AROParser

struct CanvasView: View {
    let graph: CanvasGraph
    /// Persist a single node's position to the file's layout
    /// sidecar. Called on drag-end.
    let persistPosition: (CanvasNode.ID, CGPoint) -> Void
    /// Two-way binding to the controller's `currentLine`. The
    /// matching-line node gets an accent border; tapping a node
    /// pushes its line back into this binding.
    @Binding var currentLine: Int?
    /// 1-indexed line where the debugger is currently paused. The
    /// node whose `lineHint` matches gets a warm-tinted "paused"
    /// outline distinct from the cursor-selection accent.
    let pausedLine: Int?
    /// Live symbol bag for hover tooltips on nodes that reference
    /// one of these identifiers.
    let pauseSymbols: [String: ConsoleProcess.SymbolValue]
    /// 1-indexed lines that carry a breakpoint. Nodes on those
    /// lines render a red dot in the top-left corner so the
    /// canvas mirrors the editor gutter.
    let breakpointLines: Set<Int>

    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0

    /// Live per-node position overlay. Initialised from the graph's
    /// laid-out positions on first appearance; mutated by drags.
    @State private var liveNodes: [CanvasNode.ID: CGPoint] = [:]

    private let nodeWidth: CGFloat = 240
    private let nodeHeight: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let contentSize = contentBounds()
            ZStack {
                SolaroColor.backdrop
                dotGrid(in: geo.size)

                ZStack(alignment: .topLeading) {
                    WiresLayer(
                        graph: graph,
                        positions: nodePositions,
                        nodeWidth: nodeWidth, nodeHeight: nodeHeight
                    )
                    .frame(width: contentSize.width, height: contentSize.height,
                           alignment: .topLeading)
                    NodesLayer(
                        graph: graph,
                        positions: nodePositions,
                        nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                        selectedLine: currentLine,
                        pausedLine: pausedLine,
                        pauseSymbols: pauseSymbols,
                        breakpointLines: breakpointLines,
                        onDrag: { id, newPos in
                            liveNodes[id] = newPos
                        },
                        onDragEnd: { id, finalPos in
                            liveNodes[id] = finalPos
                            persistPosition(id, finalPos)
                        },
                        onSelect: { lineHint in
                            // Push the node's source line back so
                            // the editor moves its caret to match.
                            if currentLine != lineHint {
                                currentLine = lineHint
                            }
                        }
                    )
                    .frame(width: contentSize.width, height: contentSize.height,
                           alignment: .topLeading)
                }
                .frame(width: contentSize.width, height: contentSize.height,
                       alignment: .topLeading)
                .offset(x: pan.width + dragOffset.width,
                        y: pan.height + dragOffset.height)
                .scaleEffect(zoom * magnify, anchor: .topLeading)
                .animation(.easeOut(duration: 0.15), value: zoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnifyGesture)
            .overlay(alignment: .bottomTrailing) {
                zoomControls.padding(SolaroSpace.m)
            }
            .overlay(alignment: .topTrailing) {
                if graph.nodes.isEmpty {
                    EmptyCanvasNotice().padding(SolaroSpace.l)
                } else if !legendPrepositions.isEmpty {
                    WireLegend(prepositions: legendPrepositions)
                        .padding(SolaroSpace.l)
                }
            }
            .onAppear(perform: seedPositionsIfNeeded)
            .onChange(of: graph.nodes.map(\.id)) { _, _ in
                seedPositionsIfNeeded()
            }
            .onChange(of: currentLine) { _, newLine in
                guard let newLine else { return }
                centerOnNode(forLine: newLine, in: geo.size)
            }
        }
    }

    /// Ease-in-out the canvas's pan offset so the node matching
    /// `line` lands at the viewport center. Called whenever
    /// `currentLine` changes — both editor-driven (cursor moved
    /// in source) and canvas-driven (node tap) flows trigger this,
    /// but the latter usually only nudges by a small amount.
    private func centerOnNode(forLine line: Int, in viewportSize: CGSize) {
        guard let target = graph.nodes.first(where: { $0.lineHint == line }) else {
            return
        }
        let pos = liveNodes[target.id] ?? CGPoint(x: target.x, y: target.y)
        let nodeCenter = CGPoint(
            x: pos.x + nodeWidth / 2,
            y: pos.y + nodeHeight / 2
        )
        // Modifier order in body: scaleEffect (inner) → offset
        // (outer). Visual position of a point P inside content:
        //     screen = P * zoom + pan
        // Solve for pan that places the node center at the viewport
        // center.
        let newPan = CGSize(
            width: viewportSize.width / 2 - nodeCenter.x * zoom,
            height: viewportSize.height / 2 - nodeCenter.y * zoom
        )
        withAnimation(.easeInOut(duration: 0.35)) {
            pan = newPan
        }
    }

    // MARK: - Position bookkeeping

    /// Effective position per node — drag overrides the laid-out
    /// position from the graph (which itself came from the sidecar
    /// or the default stack layout).
    private var nodePositions: [CanvasNode.ID: CGPoint] {
        var out: [CanvasNode.ID: CGPoint] = [:]
        for node in graph.nodes {
            if let live = liveNodes[node.id] {
                out[node.id] = live
            } else {
                out[node.id] = CGPoint(x: node.x, y: node.y)
            }
        }
        return out
    }

    /// Bounding box (in canvas coordinates) of all currently-placed
    /// nodes, with generous padding so the wires/nodes container has
    /// a consistent frame for both layers and pan reaches everything.
    private func contentBounds() -> CGSize {
        var maxX: CGFloat = 800
        var maxY: CGFloat = 600
        for node in graph.nodes {
            let p = liveNodes[node.id] ?? CGPoint(x: node.x, y: node.y)
            maxX = max(maxX, p.x + nodeWidth)
            maxY = max(maxY, p.y + nodeHeight)
        }
        return CGSize(width: maxX + 200, height: maxY + 200)
    }

    private func seedPositionsIfNeeded() {
        // Only seed nodes we don't already track. Lets the layout
        // sidecar / default stack drive the first frame while
        // preserving any drags the user already made this session.
        for node in graph.nodes where liveNodes[node.id] == nil {
            liveNodes[node.id] = CGPoint(x: node.x, y: node.y)
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnify) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoom = max(0.3, min(3.0, zoom * value))
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

    // MARK: - Legend

    private var legendPrepositions: [String] {
        let canonical = ["from", "to", "with", "into", "against",
                         "for", "at", "by", "via", "on"]
        let present = Set(
            graph.edges
                .filter { $0.kind == .dataFlow }
                .compactMap { $0.preposition?.lowercased() }
        )
        return canonical.filter(present.contains)
    }
}

// MARK: - Wires layer

struct WiresLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            // Draw sequence (program-flow) edges first so the
            // data-flow Béziers sit on top of them.
            for edge in graph.edges where edge.kind == .sequence {
                drawSequence(edge, ctx: ctx)
            }
            for edge in graph.edges where edge.kind == .dataFlow {
                drawDataFlow(edge, ctx: ctx)
            }
        }
    }

    private func drawSequence(_ edge: CanvasEdge,
                              ctx: GraphicsContext) {
        guard
            let from = positions[edge.fromNodeID],
            let to = positions[edge.toNodeID]
        else { return }
        // Bottom-center of source → top-center of receiver. The
        // user sees execution flowing top-down through the stack
        // layout.
        let start = CGPoint(x: from.x + nodeWidth / 2,
                            y: from.y + nodeHeight)
        let end   = CGPoint(x: to.x + nodeWidth / 2,
                            y: to.y)
        let dy = abs(end.y - start.y)
        let curve = max(dy * 0.4, 18)
        let c1 = CGPoint(x: start.x, y: start.y + curve)
        let c2 = CGPoint(x: end.x,   y: end.y - curve)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        ctx.stroke(
            path,
            with: .color(SolaroColor.textTertiary.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4])
        )
    }

    private func drawDataFlow(_ edge: CanvasEdge,
                              ctx: GraphicsContext) {
        guard
            let from = positions[edge.fromNodeID],
            let to = positions[edge.toNodeID]
        else { return }
        let start = CGPoint(x: from.x + nodeWidth,
                            y: from.y + nodeHeight / 2)
        let end = CGPoint(x: to.x,
                          y: to.y + nodeHeight / 2)
        let dx = abs(end.x - start.x)
        let curveOffset = max(dx * 0.5, 36)
        let c1 = CGPoint(x: start.x + curveOffset, y: start.y)
        let c2 = CGPoint(x: end.x - curveOffset, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        let color = SolaroColor.wireColor(forPreposition: edge.preposition)
        ctx.stroke(path,
                   with: .color(color.opacity(0.20)),
                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
        ctx.stroke(path,
                   with: .color(color.opacity(0.92)),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        let dotRect = CGRect(x: end.x - 3, y: end.y - 3,
                             width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
    }
}

// MARK: - Nodes layer (drag-aware)

struct NodesLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    /// Currently-highlighted source line (from the editor caret).
    /// The node with `lineHint == selectedLine` gets an accent border.
    let selectedLine: Int?
    /// Debugger-paused line — the matching node gets a warm
    /// "paused here" outline.
    let pausedLine: Int?
    /// Live symbols for hover tooltips.
    let pauseSymbols: [String: ConsoleProcess.SymbolValue]
    /// Lines that carry a breakpoint — each matching node renders
    /// the red gutter dot in its corner.
    let breakpointLines: Set<Int>
    let onDrag: (CanvasNode.ID, CGPoint) -> Void
    let onDragEnd: (CanvasNode.ID, CGPoint) -> Void
    let onSelect: (Int) -> Void

    /// Position of each node at the moment its drag began. Captured
    /// once on the first `onChanged` event, cleared on `onEnded`.
    /// Without this, every drag event adds the cumulative translation
    /// to the *just-updated* live position, so the node sprints away
    /// at 2× mouse speed (the user-reported regression).
    @State private var dragOrigins: [CanvasNode.ID: CGPoint] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible spacer so the ZStack reports a non-zero size
            // even when all real children are placed via .position
            // (which doesn't contribute to layout).
            Color.clear
            ForEach(graph.nodes) { node in
                let p = positions[node.id] ?? CGPoint(x: node.x, y: node.y)
                CanvasNodeCard(
                    node: node,
                    width: nodeWidth, height: nodeHeight,
                    isSelected: selectedLine == node.lineHint,
                    isPaused: pausedLine == node.lineHint,
                    hasBreakpoint: breakpointLines.contains(node.lineHint),
                    symbols: relevantSymbols(for: node)
                )
                // `.position` is absolute placement that puts the
                // view's center at the given point in the parent's
                // coordinate space — unlike `.offset`, it counts as
                // layout. The +width/2, +height/2 converts from the
                // (top-left) node origin we store on disk to the
                // (center) point .position expects.
                .position(x: p.x + nodeWidth / 2,
                          y: p.y + nodeHeight / 2)
                .onTapGesture { onSelect(node.lineHint) }
                .gesture(dragGesture(id: node.id, livePosition: p))
            }
        }
    }

    /// Filter the global symbol bag down to identifiers this node
    /// produces or reads. Drives the per-node hover tooltip.
    private func relevantSymbols(for node: CanvasNode)
        -> [ConsoleProcess.SymbolValue]
    {
        var names: Set<String> = Set(node.referencedIdentifiers)
        if let r = node.resultName, !r.hasPrefix("_") {
            names.insert(r)
        }
        return names.compactMap { pauseSymbols[$0] }
            .sorted { $0.name < $1.name }
    }

    private func dragGesture(id: CanvasNode.ID,
                             livePosition: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // Capture the origin once at the start of the drag —
                // not on every onChanged. Subsequent events use the
                // captured value so `translation` (which is cumulative
                // from the gesture start) lands at the correct spot.
                if dragOrigins[id] == nil {
                    dragOrigins[id] = livePosition
                }
                let origin = dragOrigins[id] ?? livePosition
                onDrag(id,
                       CGPoint(x: origin.x + value.translation.width,
                               y: origin.y + value.translation.height))
            }
            .onEnded { value in
                let origin = dragOrigins[id] ?? livePosition
                let final = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                onDragEnd(id, final)
                dragOrigins.removeValue(forKey: id)
            }
    }
}

private struct CanvasNodeCard: View {
    let node: CanvasNode
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isPaused: Bool
    let hasBreakpoint: Bool
    let symbols: [ConsoleProcess.SymbolValue]

    @State private var hovering = false

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
                    if let r = node.resultName, !r.hasPrefix("_") {
                        Text("<\(r)>")
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                    }
                    Spacer(minLength: 0)
                    Text(":\(node.lineHint)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Text(summaryDisplay)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, SolaroSpace.xs)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            isSelected
                ? SolaroColor.surfaceRaised.opacity(1.0)
                : SolaroColor.surfaceRaised
        )
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(borderColor, lineWidth: isPaused || isSelected ? 2 : 1)
        )
        .shadow(
            color: Color.black.opacity(
                isPaused ? 0.55 :
                isSelected ? 0.45 :
                (hovering ? 0.35 : 0.12)
            ),
            radius: isPaused ? 12 : (isSelected ? 10 : (hovering ? 8 : 3)),
            x: 0,
            y: isPaused ? 6 : (isSelected ? 5 : (hovering ? 4 : 2))
        )
        .overlay(alignment: .topLeading) {
            if hasBreakpoint {
                Circle()
                    .fill(SolaroColor.stateError)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .offset(x: -4, y: -4)
            }
        }
        .onHover { hovering = $0 }
        .help(tooltipText)
    }

    /// Multi-line tooltip combining the statement's source location,
    /// raw text, and any live symbol values the debugger has
    /// captured for identifiers this statement reads or produces.
    private var tooltipText: String {
        var lines = ["Line \(node.lineHint): \(node.summary)"]
        if !symbols.isEmpty {
            lines.append("")
            lines.append("Current values:")
            for s in symbols {
                lines.append("  \(s.name): \(s.typeName) = \(s.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var borderColor: Color {
        if isPaused   { return SolaroColor.stateWarn }
        if isSelected { return SolaroColor.accent }
        if hovering   { return SolaroColor.accent.opacity(0.6) }
        return SolaroColor.divider
    }

    /// Human-readable line shown under the verb. Falls back to the
    /// statement's raw description, but trims the verb prefix +
    /// terminal period so the card doesn't visually echo itself.
    private var summaryDisplay: String {
        let raw = node.summary
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutDot = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        let prefix = node.verb + " "
        if withoutDot.hasPrefix(prefix) {
            return String(withoutDot.dropFirst(prefix.count))
        }
        return withoutDot
    }
}

private struct WireLegend: View {
    let prepositions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONNECTIONS")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(2)
            ForEach(prepositions, id: \.self) { p in
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(SolaroColor.wireColor(forPreposition: p))
                        .frame(width: 18, height: 2)
                    Text(p)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                }
            }
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surfaceRaised.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
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
