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

/// Right-click context-menu choices on a canvas node card.
enum CanvasNodeContextAction {
    case revealInEditor
    case duplicate
    case delete
    case extractAsAction
    case explainWithAsk
}

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
    /// 1-indexed source lines → wall-clock time each line was most
    /// recently observed executing (from the live JSONL stream).
    /// Drives the per-card "executing now" pulse. Empty when no run
    /// has happened yet — the cards then just render normally.
    let lastExecutedAt: [Int: Date]
    /// Feature-set name → most recent time any statement in that FS
    /// fired. Drives the container's outline glow so concurrent
    /// runs of multiple feature sets read as visually distinct.
    let lastExecutedAtPerFeatureSet: [String: Date]
    /// Source line → runtime error message for statements the
    /// runtime failed on. Drives the per-card red border + tooltip.
    let errorLines: [Int: String]
    /// Latest payload observed flowing through each repository,
    /// keyed by repo object name (e.g. `"user-repository"`).
    let repositoryValues: [String: ConsoleProcess.SymbolValue]
    /// Rolling history (newest first) of the last few payloads per
    /// repo. Used by `RepoCard`'s hover popover.
    let repositoryHistory: [String: [ConsoleProcess.SymbolValue]]
    /// 1-indexed lines that carry a breakpoint. Nodes on those
    /// lines render a red dot in the top-left corner so the
    /// canvas mirrors the editor gutter.
    let breakpointLines: Set<Int>
    /// Forwarded to the inner drop handler — see the parameter
    /// docs on the duplicate property below for context. SwiftUI
    /// macros don't let us shadow, so the actual storage lives on
    /// the canvas struct (this field) and we just pass it down.
    let onActionDrop: ((String, CGPoint) -> Void)?
    /// Right-click context-menu actions on a node card.
    let onNodeContextAction: ((CanvasNodeContextAction, CanvasNode) -> Void)?
    /// Wipe the layout sidecar's stored positions so the next
    /// graph build falls back to `StackLayout`'s defaults. Used by
    /// the canvas's "Auto Layout" right-click menu — the caller
    /// (CenterPane) owns the sidecar file and persists the empty
    /// state. Optional so screens that don't need a reset action
    /// (Project Map, OpenAPI canvas) can omit it.
    let resetLayout: (() -> Void)?

    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0

    /// Live per-node position overlay. Initialised from the graph's
    /// laid-out positions on first appearance; mutated by drags.
    @State private var liveNodes: [CanvasNode.ID: CGPoint] = [:]
    /// Snapshot of every node's position when a feature-set header
    /// drag begins, keyed by FS name → {node id → origin}. Cleared
    /// on drag-end. Same anti-cumulative trick as `dragOrigins` in
    /// the per-node drag — `DragGesture` reports cumulative
    /// translations, so without a fixed origin every onChanged
    /// would double-apply the delta.
    @State private var fsDragOrigins: [String: [CanvasNode.ID: CGPoint]] = [:]

    private let nodeWidth: CGFloat = 240
    private let nodeHeight: CGFloat = 64
    private let repoWidth: CGFloat = 200
    private let repoHeight: CGFloat = 72

    var body: some View {
        GeometryReader { geo in
            let contentSize = contentBounds()
            ZStack {
                SolaroColor.backdrop
                dotGrid(in: geo.size)

                canvasLayers(contentSize: contentSize)
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
    /// Read the dropped action template (NSString payload from
    /// ActionsListView's .onDrag) and forward it + the drop point
    /// to the dispatcher closure. The dispatcher mutates the
    /// source file textually — see CenterPane for the insertion
    /// logic.
    private func handleActionDrop(
        providers: [NSItemProvider],
        location: CGPoint,
        deliver: @MainActor @escaping (String, CGPoint) -> Void
    ) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let nsstr = obj as? NSString else { return }
            let payload = nsstr as String
            Task { @MainActor in
                deliver(payload, location)
            }
        }
        return true
    }

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

    /// Layered ZStack with feature-set boxes, wires, repos, and
    /// statement nodes. Pulled out of `body` because the type-checker
    /// timed out once the layer list grew past four entries.
    @ViewBuilder
    private func canvasLayers(contentSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            FeatureSetContainersLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                lastExecutedAtPerFeatureSet: lastExecutedAtPerFeatureSet,
                onHeaderDrag: { name, delta in
                    moveFeatureSet(name, by: delta, persist: false)
                },
                onHeaderDragEnd: { name, delta in
                    moveFeatureSet(name, by: delta, persist: true)
                }
            )
            .frame(width: contentSize.width, height: contentSize.height,
                   alignment: .topLeading)
            LoopContainersLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight
            )
            .frame(width: contentSize.width, height: contentSize.height,
                   alignment: .topLeading)
            WiresLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                repoWidth: repoWidth, repoHeight: repoHeight
            )
            .frame(width: contentSize.width, height: contentSize.height,
                   alignment: .topLeading)
            RepoNodesLayer(
                repositories: graph.repositories,
                positions: nodePositions,
                repoWidth: repoWidth,
                repoHeight: repoHeight,
                repositoryValues: repositoryValues,
                repositoryHistory: repositoryHistory,
                onDrag: { id, newPos in liveNodes[id] = newPos },
                onDragEnd: { id, finalPos in
                    liveNodes[id] = finalPos
                    persistPosition(id, finalPos)
                }
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
                lastExecutedAt: lastExecutedAt,
                errorLines: errorLines,
                breakpointLines: breakpointLines,
                onContextAction: onNodeContextAction,
                onDrag: { id, newPos in liveNodes[id] = newPos },
                onDragEnd: { id, finalPos in
                    liveNodes[id] = finalPos
                    persistPosition(id, finalPos)
                },
                onSelect: { lineHint in
                    if currentLine != lineHint {
                        currentLine = lineHint
                    }
                }
            )
            .frame(width: contentSize.width, height: contentSize.height,
                   alignment: .topLeading)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
            guard let onActionDrop else { return false }
            return handleActionDrop(
                providers: providers,
                location: location,
                deliver: onActionDrop
            )
        }
        // Right-click on blank canvas space → "Auto Layout".
        // Individual node cards declare their own `.contextMenu`,
        // and SwiftUI picks the innermost menu for right-clicks
        // that land on a node, so this catches only clicks that
        // miss every card / wire.
        .contextMenu {
            if resetLayout != nil {
                Button {
                    triggerAutoLayout()
                } label: {
                    Label("Auto Layout", systemImage: "rectangle.3.group")
                }
                .help("Reset every user-dragged position and re-flow the graph")
            }
        }
    }

    /// Wipe live drag positions + persisted sidecar entries so the
    /// next graph build seeds purely from `StackLayout.place()`.
    /// Called from the canvas's "Auto Layout" context-menu item.
    private func triggerAutoLayout() {
        resetLayout?()
        liveNodes.removeAll()
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
        for repo in graph.repositories {
            if let live = liveNodes[repo.id] {
                out[repo.id] = live
            } else {
                out[repo.id] = CGPoint(x: repo.x, y: repo.y)
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
        for repo in graph.repositories {
            let p = liveNodes[repo.id] ?? CGPoint(x: repo.x, y: repo.y)
            maxX = max(maxX, p.x + repoWidth)
            maxY = max(maxY, p.y + repoHeight)
        }
        return CGSize(width: maxX + 200, height: maxY + 200)
    }

    /// Translate every statement node in `featureSet` by `delta`,
    /// using the positions snapshot captured at drag-start so
    /// cumulative DragGesture translations don't multiply.
    /// `persist=false` while dragging (live update only); `=true` on
    /// drag-end (writes the final positions to the layout sidecar).
    private func moveFeatureSet(
        _ featureSet: String,
        by delta: CGSize,
        persist: Bool
    ) {
        // Capture origins on first onChanged.
        if fsDragOrigins[featureSet] == nil {
            var snapshot: [CanvasNode.ID: CGPoint] = [:]
            for node in graph.nodes where node.featureSetName == featureSet {
                snapshot[node.id] = liveNodes[node.id]
                    ?? CGPoint(x: node.x, y: node.y)
            }
            fsDragOrigins[featureSet] = snapshot
        }
        guard let origins = fsDragOrigins[featureSet] else { return }
        for (id, origin) in origins {
            let next = CGPoint(
                x: origin.x + delta.width,
                y: origin.y + delta.height
            )
            liveNodes[id] = next
            if persist { persistPosition(id, next) }
        }
        if persist { fsDragOrigins.removeValue(forKey: featureSet) }
    }

    private func seedPositionsIfNeeded() {
        // Only seed nodes we don't already track. Lets the layout
        // sidecar / default stack drive the first frame while
        // preserving any drags the user already made this session.
        for node in graph.nodes where liveNodes[node.id] == nil {
            liveNodes[node.id] = CGPoint(x: node.x, y: node.y)
        }
        for repo in graph.repositories where liveNodes[repo.id] == nil {
            liveNodes[repo.id] = CGPoint(x: repo.x, y: repo.y)
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

// MARK: - Feature-set containers

/// Draws one colored rounded rectangle per feature set in the
/// graph, with the feature-set name labelled at the top. Sits
/// behind wires + nodes so the boxes read as background regions
/// rather than overlays.
private struct FeatureSetContainersLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    /// Feature-set name → wall-clock time of the most recent event
    /// observed for that FS. Drives the container's outline glow.
    let lastExecutedAtPerFeatureSet: [String: Date]
    /// Drag callback fired continuously while the user drags the
    /// container's header strip. The receiver translates every
    /// statement node belonging to the named feature set by the
    /// running delta.
    let onHeaderDrag: (String, CGSize) -> Void
    /// Called once the header drag ends — the receiver should
    /// persist the new positions to the layout sidecar.
    let onHeaderDragEnd: (String, CGSize) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(groupedFeatureSets(), id: \.name) { group in
                FeatureSetContainer(
                    name: group.name,
                    tint: color(for: group.name),
                    rect: group.rect,
                    lastExecutedAt: lastExecutedAtPerFeatureSet[group.name],
                    onHeaderDrag: { delta in onHeaderDrag(group.name, delta) },
                    onHeaderDragEnd: { delta in onHeaderDragEnd(group.name, delta) }
                )
                .position(x: group.rect.midX, y: group.rect.midY)
                .frame(width: group.rect.width, height: group.rect.height)
            }
        }
    }

    private struct FSGroup {
        let name: String
        let rect: CGRect
    }

    private func groupedFeatureSets() -> [FSGroup] {
        // Compute bounding rects per feature set in source order.
        var order: [String] = []
        var bounds: [String: CGRect] = [:]
        for node in graph.nodes {
            let p = positions[node.id] ?? CGPoint(x: node.x, y: node.y)
            let nodeRect = CGRect(x: p.x, y: p.y,
                                  width: nodeWidth, height: nodeHeight)
            if let existing = bounds[node.featureSetName] {
                bounds[node.featureSetName] = existing.union(nodeRect)
            } else {
                bounds[node.featureSetName] = nodeRect
                order.append(node.featureSetName)
            }
        }
        let inset: CGFloat = 14
        let headerExtra: CGFloat = 28
        return order.map { name in
            let core = bounds[name] ?? .zero
            let r = CGRect(
                x: core.minX - inset,
                y: core.minY - inset - headerExtra,
                width: core.width + inset * 2,
                height: core.height + inset * 2 + headerExtra
            )
            return FSGroup(name: name, rect: r)
        }
    }

    /// Stable color per feature-set name. Cycles through a small
    /// palette of role tints so each feature set reads as a distinct
    /// region.
    private func color(for name: String) -> Color {
        let palette: [Color] = [
            SolaroColor.roleRequest,
            SolaroColor.roleOwn,
            SolaroColor.roleExport,
            SolaroColor.roleResponse,
            SolaroColor.accent,
            SolaroColor.stateWarn,
        ]
        var hash = 5381
        for byte in name.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return palette[abs(hash) % palette.count]
    }
}

/// Paints a rounded "meta pill" around the body nodes of each
/// `LoopGroup` in the graph, with the loop header (`for each
/// <entry> in <entries>`) rendered as a small chip above the
/// bracket. The pill is purely decorative — body statement nodes
/// keep their normal drag / click behaviour.
private struct LoopContainersLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(loopRects(), id: \.id) { rect in
                LoopBracket(label: rect.label, tint: SolaroColor.textTertiary)
                    .position(x: rect.rect.midX, y: rect.rect.midY)
                    .frame(width: rect.rect.width, height: rect.rect.height)
            }
        }
    }

    private struct LoopRect {
        let id: String
        let label: String
        let rect: CGRect
    }

    private func loopRects() -> [LoopRect] {
        let inset: CGFloat = 8
        let headerExtra: CGFloat = 22
        return graph.loops.compactMap { loop in
            var bounds: CGRect? = nil
            for id in loop.bodyNodeIDs {
                guard let p = positions[id] else { continue }
                let nodeRect = CGRect(x: p.x, y: p.y,
                                      width: nodeWidth, height: nodeHeight)
                bounds = bounds?.union(nodeRect) ?? nodeRect
            }
            guard let core = bounds else { return nil }
            let r = CGRect(
                x: core.minX - inset,
                y: core.minY - inset - headerExtra,
                width: core.width + inset * 2,
                height: core.height + inset * 2 + headerExtra
            )
            return LoopRect(id: loop.id, label: loop.label, rect: r)
        }
    }
}

/// The dotted-bracket pill itself. Slimmer than the feature-set
/// container and drawn in the neutral text-tertiary tint so it
/// reads as syntactic structure rather than a colored region.
private struct LoopBracket: View {
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(label)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.top, 4)
            .padding(.bottom, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(tint.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(
                    tint.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
        )
        .allowsHitTesting(false)
    }
}

private struct FeatureSetContainer: View {
    let name: String
    let tint: Color
    let rect: CGRect
    /// Most recent time any statement in this FS fired, or `nil` if
    /// it hasn't run yet this session. Drives the container's
    /// brighter glow during the pulse window.
    let lastExecutedAt: Date?
    let onHeaderDrag: (CGSize) -> Void
    let onHeaderDragEnd: (CGSize) -> Void

    // Same hold-then-fade shape as `CanvasNodeCard`'s rail pulse, a
    // touch longer because the FS container is bigger and reads as
    // ambient context rather than a focal element.
    private let pulseHold: TimeInterval = 0.45
    private let pulseFade: TimeInterval = 0.85
    private var pulseDuration: TimeInterval { pulseHold + pulseFade }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !isPulseLive)) { context in
            content(intensity: intensity(at: context.date))
        }
    }

    @ViewBuilder
    private func content(intensity: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(name)
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(tint)
                    .tracking(2)
                if intensity > 0 {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(tint.opacity(0.6 + 0.4 * intensity))
                }
                Spacer()
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.top, SolaroSpace.xs)
            .padding(.bottom, 2)
            // Limit the drag-grab area to the header strip so the
            // user can still click into the body to interact with
            // individual node cards.
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in onHeaderDrag(value.translation) }
                    .onEnded { value in onHeaderDragEnd(value.translation) }
            )
            .help("Drag the header to move the whole feature set")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.l, style: .continuous)
                .fill(tint.opacity(0.06 + 0.05 * intensity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.l, style: .continuous)
                .stroke(
                    tint.opacity(0.45 + 0.45 * intensity),
                    style: StrokeStyle(
                        lineWidth: 1.2 + 1.2 * intensity,
                        dash: intensity > 0 ? [] : [4, 3]
                    )
                )
        )
    }

    private func intensity(at now: Date) -> Double {
        guard let last = lastExecutedAt else { return 0 }
        let dt = now.timeIntervalSince(last)
        if dt < 0 { return 1 }
        if dt < pulseHold { return 1 }
        let fadeDt = dt - pulseHold
        if fadeDt >= pulseFade { return 0 }
        return 1 - fadeDt / pulseFade
    }

    private var isPulseLive: Bool {
        guard let last = lastExecutedAt else { return false }
        return Date().timeIntervalSince(last) < pulseDuration
    }
}

// MARK: - Wires layer

struct WiresLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    let repoWidth: CGFloat
    let repoHeight: CGFloat

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
            // Repo wires sit on top so the user can trace a write or
            // a watch back to its repository without losing the line
            // under a data-flow curve.
            for edge in graph.edges {
                if case .repoAccess(let op) = edge.kind {
                    drawRepoAccess(edge, op: op, ctx: ctx)
                }
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

    /// Draw a wire from a statement node (left side) to a repository
    /// box (right column). Color + stroke style read by operation:
    ///   read  → blue solid
    ///   write → amber solid + filled arrow at the repo end
    ///   watch → purple dashed
    private func drawRepoAccess(
        _ edge: CanvasEdge,
        op: CanvasEdge.RepoOperation,
        ctx: GraphicsContext
    ) {
        guard
            let from = positions[edge.fromNodeID],
            let to = positions[edge.toNodeID]
        else { return }
        // Statement node origin (top-left): exits its right edge.
        let start = CGPoint(x: from.x + nodeWidth,
                            y: from.y + nodeHeight / 2)
        // Repo node origin (top-left): enters its left edge.
        let end = CGPoint(x: to.x,
                          y: to.y + repoHeight / 2)
        let dx = abs(end.x - start.x)
        let curveOffset = max(dx * 0.5, 36)
        let c1 = CGPoint(x: start.x + curveOffset, y: start.y)
        let c2 = CGPoint(x: end.x - curveOffset, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)

        let (color, dash, drawArrow): (Color, [CGFloat], Bool) = {
            switch op {
            case .read:  return (SolaroColor.accent,     [],     false)
            case .write: return (SolaroColor.stateWarn,  [],     true)
            case .watch: return (SolaroColor.stateError, [5, 4], false)
            }
        }()
        let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dash)
        ctx.stroke(path, with: .color(color.opacity(0.22)),
                   style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: dash))
        ctx.stroke(path, with: .color(color.opacity(0.92)), style: style)
        if drawArrow {
            // Filled triangle pointing into the repo's left edge.
            var arrow = Path()
            let size: CGFloat = 7
            arrow.move(to: CGPoint(x: end.x, y: end.y))
            arrow.addLine(to: CGPoint(x: end.x - size, y: end.y - size * 0.6))
            arrow.addLine(to: CGPoint(x: end.x - size, y: end.y + size * 0.6))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(color))
        } else {
            let dotRect = CGRect(x: end.x - 3, y: end.y - 3,
                                 width: 6, height: 6)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
        }
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
    /// Per-line execution timestamps from the live event stream.
    let lastExecutedAt: [Int: Date]
    /// Source line → runtime error message; matching nodes get a
    /// red border and a tooltip with the message.
    let errorLines: [Int: String]
    /// Lines that carry a breakpoint — each matching node renders
    /// the red gutter dot in its corner.
    let breakpointLines: Set<Int>
    /// Right-click context menu on each node card.
    let onContextAction: ((CanvasNodeContextAction, CanvasNode) -> Void)?
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
                    symbols: relevantSymbols(for: node),
                    lastExecutedAt: lastExecutedAt[node.lineHint],
                    errorMessage: errorLines[node.lineHint]
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
                .contextMenu {
                    if let onContextAction {
                        Button {
                            onContextAction(.revealInEditor, node)
                        } label: {
                            Label("Reveal in editor", systemImage: "text.cursor")
                        }
                        Button {
                            onContextAction(.duplicate, node)
                        } label: {
                            Label("Duplicate statement",
                                  systemImage: "plus.square.on.square")
                        }
                        Button {
                            onContextAction(.extractAsAction, node)
                        } label: {
                            Label("Extract as Action…",
                                  systemImage: "function")
                        }
                        Button {
                            onContextAction(.explainWithAsk, node)
                        } label: {
                            Label("Explain with aro ask…",
                                  systemImage: "sparkles")
                        }
                        Divider()
                        Button(role: .destructive) {
                            onContextAction(.delete, node)
                        } label: {
                            Label("Delete statement", systemImage: "trash")
                        }
                    }
                }
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
    /// Wall-clock time this node's source line was last seen
    /// executing (from the JSONL stream). nil if it hasn't run yet
    /// during this session. Drives the colored left-border pulse.
    let lastExecutedAt: Date?
    /// Runtime error message attributed to this node's source line,
    /// or nil if the statement ran cleanly. Drives the red border
    /// + tooltip + error icon.
    let errorMessage: String?

    @State private var hovering = false
    @State private var showPopover = false

    /// Per-pulse hold-then-fade timings. A fresh event lands with a
    /// short `pulseHold` at full brightness — long enough for the
    /// eye to catch even when a program executes in single-digit
    /// milliseconds — followed by `pulseFade` ramping back down to
    /// zero. Every new event resets to T=0 of the hold so two
    /// rapid-fire pulses on the same line don't visually collapse
    /// into one.
    private let pulseHold: TimeInterval = 0.35
    private let pulseFade: TimeInterval = 0.65
    private var pulseDuration: TimeInterval { pulseHold + pulseFade }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !isPulseLive)) { context in
            cardContent(at: context.date)
        }
    }

    @ViewBuilder
    private func cardContent(at now: Date) -> some View {
        let pulse = pulseIntensity(at: now)
        HStack(spacing: 0) {
            // Left role rail — always exactly 3 pt in layout so the
            // verb/value text never shifts. The pulse animation
            // lives on top of the card as an `.overlay(alignment:
            // .leading)` (see the modifier near the bottom of this
            // body), where it can paint a wider, brighter, glowing
            // bar without affecting any other view's frame.
            let role = SolaroColor.roleColor(forVerb: node.verb)
            Rectangle()
                .fill(role)
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
                if liveValues.isEmpty {
                    Text(summaryDisplay)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Show live runtime values inline so the canvas
                    // reads like a wire diagram with the actual
                    // payload visible — no hover required.
                    ForEach(liveValues, id: \.name) { s in
                        HStack(spacing: 4) {
                            Text("<\(s.name)>")
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textTertiary)
                            Text("=")
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textTertiary)
                            Text(s.value)
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
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
        // Pulse bar overlay — paints a wider, brighter version of
        // the role rail on top of the 3 pt layout slot when the
        // line is firing. Because it's an overlay on the whole card
        // (not a sibling in the HStack), it never shifts the text.
        .overlay(alignment: .leading) {
            if pulse > 0 {
                let role = SolaroColor.roleColor(forVerb: node.verb)
                Rectangle()
                    .fill(Color.white.opacity(0.85 * pulse))
                    .frame(width: 3 + 5 * pulse)
                    .shadow(
                        color: role.opacity(0.85 * pulse),
                        radius: 6 * pulse,
                        x: 0, y: 0
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(
                    borderColor,
                    lineWidth: (errorMessage != nil || isPaused || isSelected) ? 2 : 1
                )
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
                Image(systemName: "circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(SolaroColor.stateError)
                    .frame(width: 10, height: 10)
                    .offset(x: -5, y: -5)
                    .accessibilityLabel("breakpoint")
            }
        }
        .onHover { isHovering in
            hovering = isHovering
            // Only show the styled popover when there's actually
            // something interesting to display — i.e. live debugger
            // values captured for symbols this statement touches.
            showPopover = isHovering && !symbols.isEmpty
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            CanvasNodeHoverPopover(node: node, symbols: symbols)
        }
        // Keep the system tooltip as a fallback for nodes that
        // have no captured symbols — at least the line + summary
        // are still readable.
        .help(tooltipText)
    }

    /// Multi-line tooltip combining the statement's source location,
    /// raw text, and any live symbol values the debugger has
    /// captured for identifiers this statement reads or produces.
    private var tooltipText: String {
        var lines = ["Line \(node.lineHint): \(node.summary)"]
        if let error = errorMessage {
            lines.append("")
            lines.append("Runtime error: \(error)")
        }
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
        if errorMessage != nil { return SolaroColor.stateError }
        if isPaused   { return SolaroColor.stateWarn }
        if isSelected { return SolaroColor.accent }
        if hovering   { return SolaroColor.accent.opacity(0.6) }
        return SolaroColor.divider
    }

    /// 0...1 brightness for the role rail at `now`. Each event
    /// guarantees a `pulseHold` window of full brightness so even
    /// programs that finish in a handful of milliseconds register
    /// visually, followed by a `pulseFade` ramp down to zero. A
    /// fresh event resets the clock back to T=0 of the hold.
    private func pulseIntensity(at now: Date) -> Double {
        guard let last = lastExecutedAt else { return 0 }
        let dt = now.timeIntervalSince(last)
        if dt < 0 { return 1 }
        if dt < pulseHold { return 1 }
        let fadeDt = dt - pulseHold
        if fadeDt >= pulseFade { return 0 }
        return 1 - fadeDt / pulseFade
    }

    /// True until the most recent execution fades out — keeps the
    /// TimelineView ticking only while there's something to animate
    /// so static cards don't waste frames.
    private var isPulseLive: Bool {
        guard let last = lastExecutedAt else { return false }
        return Date().timeIntervalSince(last) < pulseDuration
    }

    /// Symbols to render inline on the card — prefer the statement's
    /// result, then any object/value-source identifiers it touches.
    /// Capped at 2 so the 64-pt card stays readable.
    private var liveValues: [ConsoleProcess.SymbolValue] {
        guard !symbols.isEmpty else { return [] }
        var picked: [ConsoleProcess.SymbolValue] = []
        var seen = Set<String>()
        if let r = node.resultName,
           let s = symbols.first(where: { $0.name == r })
        {
            picked.append(s); seen.insert(s.name)
        }
        for s in symbols where !seen.contains(s.name) {
            picked.append(s)
            seen.insert(s.name)
            if picked.count == 2 { break }
        }
        return picked
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

/// Styled balloon popover for canvas nodes — mirrors the editor's
/// HoverValuePopover but renders the full list of symbols the
/// statement is touching, with the statement source as the header.
private struct CanvasNodeHoverPopover: View {
    let node: CanvasNode
    let symbols: [ConsoleProcess.SymbolValue]

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(SolaroColor.stateWarn)
                    .font(.system(size: 11))
                Text("Line \(node.lineHint)")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .tracking(2)
                Spacer()
            }
            Text(node.summary)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Divider().background(SolaroColor.divider)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(symbols, id: \.name) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(s.name)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.accent)
                        Text(":")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                        Text(s.typeName)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textSecondary)
                        Text("=")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                        Text(s.value)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text("captured at the current pause")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
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

// MARK: - Repositories

/// Draws each repository entity as a draggable card, positioned via
/// the shared `positions` map so the wires layer connects to the
/// exact same point.
private struct RepoNodesLayer: View {
    let repositories: [RepositoryNode]
    let positions: [CanvasNode.ID: CGPoint]
    let repoWidth: CGFloat
    let repoHeight: CGFloat
    /// Latest value the runtime saw flowing through each repository,
    /// keyed by repo object name. Empty when no recorded run has
    /// produced a value yet.
    let repositoryValues: [String: ConsoleProcess.SymbolValue]
    /// Rolling history of recent payloads, newest first.
    let repositoryHistory: [String: [ConsoleProcess.SymbolValue]]
    let onDrag: (String, CGPoint) -> Void
    let onDragEnd: (String, CGPoint) -> Void

    @State private var dragOrigins: [String: CGPoint] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(repositories) { repo in
                let p = positions[repo.id] ?? CGPoint(x: repo.x, y: repo.y)
                RepoCard(
                    repo: repo,
                    width: repoWidth,
                    height: repoHeight,
                    liveValue: repositoryValues[repo.name],
                    history: repositoryHistory[repo.name] ?? []
                )
                    .position(x: p.x + repoWidth / 2,
                              y: p.y + repoHeight / 2)
                    .gesture(dragGesture(id: repo.id, livePosition: p))
            }
        }
    }

    private func dragGesture(id: String, livePosition: CGPoint) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = dragOrigins[id] ?? livePosition
                if dragOrigins[id] == nil { dragOrigins[id] = origin }
                let next = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                onDrag(id, next)
            }
            .onEnded { value in
                let origin = dragOrigins[id] ?? livePosition
                let final = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                dragOrigins.removeValue(forKey: id)
                onDragEnd(id, final)
            }
    }
}

private struct RepoCard: View {
    let repo: RepositoryNode
    let width: CGFloat
    let height: CGFloat
    /// Most recent value seen on this repository during the current
    /// recorded run, or `nil` if nothing has flowed through yet.
    let liveValue: ConsoleProcess.SymbolValue?
    /// Rolling history (newest first) — shown in the hover popover
    /// so the user can see the recent write sequence.
    let history: [ConsoleProcess.SymbolValue]

    @State private var hovering = false
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SolaroColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                if let live = liveValue {
                    // Replace the usage badge with the live payload
                    // once we have one — surfaces the actual data
                    // alongside the wires.
                    Text(live.value)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(usageLabel(repo.usage))
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SolaroSpace.m)
        .frame(width: width, height: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(SolaroColor.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(SolaroColor.accent.opacity(0.55), lineWidth: 1)
        )
        .onHover { isHovering in
            hovering = isHovering
            showHistory = isHovering && !history.isEmpty
        }
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            RepoHistoryPopover(repo: repo, history: history)
        }
        .help(helpText)
    }

    private var helpText: String {
        var msg = "Repository: \(repo.name) — \(usageLabel(repo.usage))"
        if let live = liveValue {
            msg += "\nCurrent value: \(live.value)"
        }
        return msg
    }

    private func usageLabel(_ u: RepositoryNode.Usage) -> String {
        var parts: [String] = []
        if u.contains(.read)  { parts.append("read") }
        if u.contains(.write) { parts.append("write") }
        if u.contains(.watch) { parts.append("watch") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Hover popover for the repository card — lists the recent
/// payloads the runtime saw flowing through this repo (newest
/// first) so the user can trace the write sequence without
/// running a separate tool.
private struct RepoHistoryPopover: View {
    let repo: RepositoryNode
    let history: [ConsoleProcess.SymbolValue]

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .foregroundStyle(SolaroColor.accent)
                    .font(.system(size: 11))
                Text(repo.name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer()
            }
            Divider().background(SolaroColor.divider)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(history.enumerated()), id: \.offset) { idx, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(idx == 0 ? "now" : "−\(idx)")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Text(value.value)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(SolaroSpace.m)
        .frame(minWidth: 240, maxWidth: 420, alignment: .topLeading)
    }
}
