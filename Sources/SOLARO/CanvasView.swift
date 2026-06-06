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
    /// Multi-select (#266) — applies to every member of
    /// `controller.selectedNodeIDs` instead of the clicked node.
    case copyAsAROSelection
    case deleteSelection
}

struct CanvasView: View {
    /// Workspace state. Used directly for `liveNodes` (so drag
    /// positions live on a class an UndoManager handler can mutate)
    /// rather than going through callbacks for every coordinate.
    @Bindable var controller: WorkspaceController
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
    /// Asks the parent (CenterPane) to open the "Create new
    /// Feature Set" sheet. Wired into the canvas's blank-area
    /// context menu next to Auto Layout (#?). Optional so canvases
    /// that don't back a source file (Project Map, OpenAPI graph)
    /// can omit it.
    let requestCreateFeatureSet: (() -> Void)?
    /// Persist a node's new statement source back to the .aro
    /// file. Called on the editor's Apply. The caller (CenterPane)
    /// reads the current file, finds the statement, replaces its
    /// span, and writes the result. Optional so non-source-backed
    /// canvases (OpenAPI graph, Project Map) can omit it.
    let applyNodeEdit: ((CanvasNode.ID, String) -> Void)?

    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0
    /// Honour System Settings → Accessibility → Display → Reduce
    /// Motion (#278). When set, the canvas drops its smooth zoom
    /// + scroll-to-node animations and snaps to the target value
    /// instantly so the user isn't subjected to a transition
    /// they've explicitly opted out of.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Convenience accessor for the controller-owned live drag
    /// positions. Reads and writes proxy through the controller so
    /// undo handlers (defined later in this file) can mutate the
    /// same source of truth.
    private var liveNodes: [CanvasNode.ID: CGPoint] {
        get { controller.liveNodes }
        nonmutating set { controller.liveNodes = newValue }
    }
    /// Node ID currently being edited via the inline editor (the
    /// expanded card). nil when no node is in edit mode.
    @State private var editingNodeID: CanvasNode.ID? = nil

    /// Workspace-scoped UndoManager. Used so every canvas
    /// mutation (drag, FS drag, auto-layout reset) can register an
    /// undo operation. macOS automatically wires this to the
    /// standard Edit menu's Undo / Redo items.
    @Environment(\.solaroUndoManager) private var undoManager

    /// Snapshot of where each in-flight node drag started — needed
    /// so the `onDragEnd` handler can register an undo step that
    /// restores the *pre-drag* position rather than whatever the
    /// drag's own `onChanged` last wrote.
    @State private var dragStartPositions: [CanvasNode.ID: CGPoint] = [:]

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
                .animation(reduceMotion ? nil
                                        : .easeOut(duration: 0.15),
                           value: zoom)
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
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
                testResults: controller.testResults,
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
                    let oldPos = dragStartPositions[id]
                        ?? graph.repositories.first(where: { $0.id == id })
                            .map { CGPoint(x: $0.x, y: $0.y) }
                        ?? .zero
                    liveNodes[id] = finalPos
                    persistPosition(id, finalPos)
                    registerNodeMoveUndo(id: id,
                                         from: oldPos, to: finalPos)
                    dragStartPositions.removeValue(forKey: id)
                },
                onDragStart: { id in
                    if dragStartPositions[id] == nil {
                        dragStartPositions[id] = liveNodes[id]
                            ?? graph.repositories.first(where: { $0.id == id })
                                .map { CGPoint(x: $0.x, y: $0.y) }
                            ?? .zero
                    }
                }
            )
            .frame(width: contentSize.width, height: contentSize.height,
                   alignment: .topLeading)
            NodesLayer(
                graph: graph,
                positions: nodePositions,
                nodeWidth: nodeWidth, nodeHeight: nodeHeight,
                rawSourceText: { rawSourceText(for: $0) },
                selectedLine: currentLine,
                selectedNodeIDs: controller.selectedNodeIDs,
                pausedLine: pausedLine,
                pauseSymbols: pauseSymbols,
                lastExecutedAt: lastExecutedAt,
                errorLines: errorLines,
                breakpointLines: breakpointLines,
                onContextAction: onNodeContextAction,
                onDrag: { id, newPos in liveNodes[id] = newPos },
                onDragEnd: { id, finalPos in
                    let oldPos = dragStartPositions[id]
                        ?? CGPoint(x: graph.nodes.first(where: { $0.id == id })?.x ?? 0,
                                   y: graph.nodes.first(where: { $0.id == id })?.y ?? 0)
                    liveNodes[id] = finalPos
                    persistPosition(id, finalPos)
                    registerNodeMoveUndo(id: id,
                                         from: oldPos, to: finalPos)
                    dragStartPositions.removeValue(forKey: id)
                },
                onDragStart: { id in
                    if dragStartPositions[id] == nil {
                        dragStartPositions[id] = liveNodes[id]
                            ?? graph.nodes.first(where: { $0.id == id })
                                .map { CGPoint(x: $0.x, y: $0.y) }
                            ?? .zero
                    }
                },
                onSelect: { lineHint in
                    if currentLine != lineHint {
                        currentLine = lineHint
                    }
                },
                onSelectNode: { node in
                    // Mirror the node into the controller so the
                    // Inspector can render the same fields the
                    // double-click expansion shows.
                    controller.selectedNode = node
                    controller.selectedNodeSource = rawSourceText(for: node)
                    // Multi-select (#266): ⌘-click toggles
                    // membership, a plain click replaces the set.
                    if NSEvent.modifierFlags.contains(.command) {
                        if controller.selectedNodeIDs.contains(node.id) {
                            controller.selectedNodeIDs.remove(node.id)
                        } else {
                            controller.selectedNodeIDs.insert(node.id)
                        }
                    } else {
                        controller.selectedNodeIDs = [node.id]
                    }
                },
                editingNodeID: editingNodeID,
                onDoubleTap: { id in editingNodeID = id },
                onApplyEdit: { id, newText in
                    applyNodeEdit?(id, newText)
                    editingNodeID = nil
                },
                onCancelEdit: { editingNodeID = nil }
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
            if let requestCreateFeatureSet {
                Button {
                    requestCreateFeatureSet()
                } label: {
                    Label("Create new Feature Set…",
                          systemImage: "rectangle.badge.plus")
                }
                .help("Append a new empty feature set to the current file")
            }
        }
    }

    /// Wipe live drag positions + persisted sidecar entries so the
    /// next graph build seeds purely from `StackLayout.place()`.
    /// Called from the canvas's "Auto Layout" context-menu item.
    private func triggerAutoLayout() {
        let snapshot = controller.liveNodes
        resetLayout?()
        liveNodes.removeAll()
        registerAutoLayoutUndo(snapshot: snapshot)
    }

    // MARK: - Undo registration

    /// Register an undo step for a per-node drag — restoring both
    /// the live-position dict (visible immediately) and the layout
    /// sidecar (persists across reloads).
    private func registerNodeMoveUndo(
        id: CanvasNode.ID,
        from oldPos: CGPoint,
        to newPos: CGPoint
    ) {
        guard let mgr = undoManager else { return }
        let controllerRef = controller
        let persist = persistPosition
        mgr.setActionName("Move Node")
        mgr.registerUndo(withTarget: controllerRef) { _ in
            controllerRef.liveNodes[id] = oldPos
            persist(id, oldPos)
            // Re-register the inverse so ⇧⌘Z (redo) round-trips.
            registerNodeMoveUndo(id: id, from: newPos, to: oldPos)
        }
        WorkspaceUndoRegistry.shared.noteUndoChange()
    }

    /// Register an undo step for a feature-set header drag — the
    /// whole snapshot of body-node positions captured at drag start
    /// gets restored at once.
    private func registerFeatureSetMoveUndo(
        featureSet: String,
        origins: [CanvasNode.ID: CGPoint],
        endPositions: [CanvasNode.ID: CGPoint]
    ) {
        guard let mgr = undoManager else { return }
        let controllerRef = controller
        let persist = persistPosition
        mgr.setActionName("Move Feature Set")
        mgr.registerUndo(withTarget: controllerRef) { _ in
            for (id, pos) in origins {
                controllerRef.liveNodes[id] = pos
                persist(id, pos)
            }
            registerFeatureSetMoveUndo(
                featureSet: featureSet,
                origins: endPositions,
                endPositions: origins
            )
        }
        WorkspaceUndoRegistry.shared.noteUndoChange()
    }

    /// Register an undo step for the Auto Layout reset — the
    /// pre-reset `liveNodes` snapshot is restored verbatim, and
    /// each persisted position is written back to the sidecar.
    private func registerAutoLayoutUndo(
        snapshot: [CanvasNode.ID: CGPoint]
    ) {
        guard let mgr = undoManager, !snapshot.isEmpty else { return }
        let controllerRef = controller
        let persist = persistPosition
        mgr.setActionName("Auto Layout")
        mgr.registerUndo(withTarget: controllerRef) { _ in
            controllerRef.liveNodes = snapshot
            for (id, pos) in snapshot {
                persist(id, pos)
            }
            registerAutoLayoutUndo(snapshot: [:])
            // Note: redoing an Auto Layout just re-triggers the
            // user-visible button; the undo handler intentionally
            // doesn't try to re-clear positions, because the user
            // is expected to hit the menu item again to "redo"
            // the reset.
        }
        WorkspaceUndoRegistry.shared.noteUndoChange()
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
    /// Read the raw source-span text for `node` from the current
    /// file. Used by the inline editor to prefill with the actual
    /// literal the user typed (e.g. `"/tmp"`) rather than the AST
    /// description's pretty-printed `<_expression_>` placeholder.
    private func rawSourceText(for node: CanvasNode) -> String? {
        guard let url = controller.currentFile,
              let program = controller.programs[url] else { return nil }
        let parts = node.id.split(separator: ":")
        guard let lastSlice = parts.last,
              let startOffset = Int(String(lastSlice)) else { return nil }
        var found: SourceSpan? = nil
        for fs in program.featureSets {
            if let span = locateStatementSpan(
                in: fs.statements, offset: startOffset
            ) {
                found = span
                break
            }
        }
        guard let span = found,
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let utf8 = source.utf8
        let length = utf8.count
        let lo = max(0, min(span.start.offset, length))
        let hi = max(lo, min(span.end.offset, length))
        return String(decoding: utf8.dropFirst(lo).prefix(hi - lo),
                      as: UTF8.self)
    }

    private func locateStatementSpan(
        in statements: [Statement],
        offset: Int
    ) -> SourceSpan? {
        for statement in statements {
            if let aro = statement as? AROStatement,
               aro.span.start.offset == offset {
                return aro.span
            }
            if let loop = statement as? ForEachLoop,
               let nested = locateStatementSpan(
                in: loop.body, offset: offset
               ) {
                return nested
            }
            if let loop = statement as? RangeLoop,
               let nested = locateStatementSpan(
                in: loop.body, offset: offset
               ) {
                return nested
            }
        }
        return nil
    }

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
        var endPositions: [CanvasNode.ID: CGPoint] = [:]
        for (id, origin) in origins {
            let next = CGPoint(
                x: origin.x + delta.width,
                y: origin.y + delta.height
            )
            liveNodes[id] = next
            endPositions[id] = next
            if persist { persistPosition(id, next) }
        }
        if persist {
            registerFeatureSetMoveUndo(
                featureSet: featureSet,
                origins: origins,
                endPositions: endPositions
            )
            fsDragOrigins.removeValue(forKey: featureSet)
        }
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
        // Dot grid is purely decorative — hide from VoiceOver so a
        // user navigating with assistive tech doesn't hear "image,
        // image, image, …" on every focus shift (#278).
        .accessibilityHidden(true)
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
    /// Resolve a node's raw source-span text. Used by the inline
    /// editor so its fields prefill with the user-meaningful
    /// literal (e.g. `"/tmp"`) rather than the AST description's
    /// `<_expression_>` placeholder.
    let rawSourceText: (CanvasNode) -> String?
    /// Currently-highlighted source line (from the editor caret).
    /// The node with `lineHint == selectedLine` gets an accent border.
    let selectedLine: Int?
    /// Multi-select (#266) — any node whose `id` is in this set
    /// renders the same accent border. Plain selection (single
    /// click) replaces the set with the clicked node's ID;
    /// ⌘-click toggles. The CanvasView wires this from
    /// `controller.selectedNodeIDs`.
    let selectedNodeIDs: Set<String>
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
    /// Fires once at the start of each drag so the caller can
    /// snapshot the pre-drag position for undo registration. The
    /// drag gesture's own origin bookkeeping is kept inside
    /// `NodesLayer`; we just signal "this drag started".
    let onDragStart: (CanvasNode.ID) -> Void
    let onSelect: (Int) -> Void
    /// Mirrors the just-selected node into the controller so the
    /// Inspector can show the same fields the inline editor would.
    /// Fires alongside `onSelect`.
    let onSelectNode: (CanvasNode) -> Void
    /// Node currently in inline-edit mode. The matching card
    /// expands into `NodeEditorView` instead of its normal compact
    /// form.
    let editingNodeID: CanvasNode.ID?
    let onDoubleTap: (CanvasNode.ID) -> Void
    let onApplyEdit: (CanvasNode.ID, String) -> Void
    let onCancelEdit: () -> Void

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
                Group {
                    if editingNodeID == node.id {
                        NodeEditorView(
                            schema: NodeEditingSchemaFactory.infer(
                                node: node,
                                statementSource: rawSourceText(node)
                                    ?? node.summary,
                                availableIdentifiers: scopeFor(node: node)
                            ),
                            onApply: { newText in
                                onApplyEdit(node.id, newText)
                            },
                            onCancel: { onCancelEdit() }
                        )
                    } else {
                        CanvasNodeCard(
                            node: node,
                            width: nodeWidth, height: nodeHeight,
                            isSelected: selectedLine == node.lineHint
                                || selectedNodeIDs.contains(node.id),
                            isPaused: pausedLine == node.lineHint,
                            hasBreakpoint: breakpointLines.contains(node.lineHint),
                            symbols: relevantSymbols(for: node),
                            lastExecutedAt: lastExecutedAt[node.lineHint],
                            errorMessage: errorLines[node.lineHint]
                        )
                    }
                }
                .position(x: p.x + nodeWidth / 2,
                          y: p.y + nodeHeight / 2)
                // Float the inline editor above every other node
                // card. Without an explicit z-index, ForEach uses
                // source order, so cards positioned later (further
                // down the canvas) end up drawn on top of the
                // editor when its rect overlaps theirs.
                .zIndex(editingNodeID == node.id ? 1000 : 0)
                .onTapGesture(count: 2) { onDoubleTap(node.id) }
                .onTapGesture {
                    onSelect(node.lineHint)
                    onSelectNode(node)
                }
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
                        // Multi-selection (#266) — only show the
                        // bulk actions when more than the clicked
                        // node is selected so the single-node menu
                        // stays uncluttered for the common case.
                        if selectedNodeIDs.count > 1,
                           selectedNodeIDs.contains(node.id) {
                            Divider()
                            Button {
                                onContextAction(.copyAsAROSelection, node)
                            } label: {
                                Label("Copy \(selectedNodeIDs.count) statements as ARO",
                                      systemImage: "doc.on.doc")
                            }
                            Button(role: .destructive) {
                                onContextAction(.deleteSelection, node)
                            } label: {
                                Label("Delete \(selectedNodeIDs.count) statements",
                                      systemImage: "trash.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Filter the global symbol bag down to identifiers this node
    /// produces or reads. Drives the per-node hover tooltip.
    /// In-scope identifiers the user can pick from in the editor's
    /// variable dropdown. Defined as the set of result names from
    /// every statement that appears earlier in the same feature
    /// set (source order), so a later Compute can pick the result
    /// of an earlier Extract.
    private func scopeFor(node: CanvasNode) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for other in graph.nodes {
            if other.id == node.id { break }
            if other.featureSetName != node.featureSetName { continue }
            if let name = other.resultName,
               !name.hasPrefix("_"),
               !seen.contains(name) {
                seen.insert(name)
                out.append(name)
            }
        }
        return out
    }

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
                    onDragStart(id)
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

