// ============================================================
// OpenAPIGraphView.swift
// SOLARO — graphical OpenAPI editor in the canvas pane
// ============================================================
//
// Shown in the canvas slot when the selected file is openapi.yaml.
// Lays out:
//
//   ROUTES        INLINE NODES          COMPONENT SCHEMAS
//   ──────        ────────────          ─────────────────
//   GET /users  ─ ─ inline req  ─ ─ ─→  User
//   POST /users ─────────────────────→  CreateUserRequest
//                                       UserList
//                                          │
//                                          └─→ User
//
// Solid coloured wires for $ref edges, gray dotted wires for
// inline-component links. Pan + zoom via the same gesture pattern
// as the ARO statement canvas.

import SwiftUI
import AppKit

struct OpenAPIGraphView: View {
    let yaml: String
    /// Lint warnings the workspace already computed; nodes that
    /// match any warning ID render a small badge.
    let warnings: [OpenAPILintWarning]
    /// Callback invoked when the user selects a node. The
    /// workspace's inspector uses this to render an editable
    /// form for the selected route or schema.
    let onSelect: (OpenAPINode?) -> Void
    /// Callback invoked when the user clicks "Add Route" /
    /// "Add Schema". The workspace mutates the document and
    /// re-renders (yaml is re-read on the next render).
    let onAddRoute: (() -> Void)?
    let onAddSchema: (() -> Void)?
    /// Invoked on double-click of a node — the workspace uses
    /// this to jump the YAML editor to the route/schema definition.
    let onJumpToCode: ((OpenAPINode) -> Void)?

    private var warningsByNode: [String: [OpenAPILintWarning]] {
        Dictionary(grouping: warnings, by: { $0.nodeID })
    }

    @State private var selectedID: String?
    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0

    private let routeNodeWidth: CGFloat = 280
    private let schemaNodeMinWidth: CGFloat = 240
    private let columnGap: CGFloat = 160
    private let rowPitch: CGFloat = 110

    var body: some View {
        let graph = laidOut()
        let contentSize = contentBounds(graph: graph)
        return ZStack {
            SolaroColor.backdrop
            // Inline `Canvas` (replaces the old `dotGrid(in:)`
            // helper) — its drawing closure already receives the
            // rendering rect's size, so we don't need a wrapping
            // `GeometryReader` to read `geo.size`. The
            // `GeometryReader` here was the macOS 26 crash
            // trigger: combined with the inner `.frame(width:
            // height:)` and `.scaleEffect()`, it cycled sizes back
            // through `NSHostingView.SizeConstraints` →
            // `SplitViewChildController` until AppKit's
            // constraint-loop guard fired.
            Canvas { ctx, size in
                let spacing: CGFloat = 24
                let cols = Int(size.width / spacing) + 2
                let rows = Int(size.height / spacing) + 2
                let color = GraphicsContext.Shading.color(
                    SolaroColor.textTertiary.opacity(0.18)
                )
                for row in 0..<rows {
                    for col in 0..<cols {
                        let x = CGFloat(col) * spacing
                        let y = CGFloat(row) * spacing
                        let rect = CGRect(
                            x: x - 0.8, y: y - 0.8,
                            width: 1.6, height: 1.6
                        )
                        ctx.fill(
                            Path(ellipseIn: rect), with: color
                        )
                    }
                }
            }
            .allowsHitTesting(false)

            // The wires/nodes layer needs an explicit
            // `width × height == contentSize` so wires can be
            // drawn at absolute coordinates and the scale/offset
            // transforms behave. But that explicit frame is the
            // SwiftUI tree's ideal size — and NSHostingView feeds
            // the ideal size into its SizeConstraints, which is
            // what `SplitViewChildController` reads. On macOS 26
            // the resulting min/max-size update re-enqueues a
            // layout pass per render, eventually tripping AppKit's
            // "more update-constraints passes than views" guard
            // and aborting the app.
            //
            // Hosting the explicit-size content in
            // `Color.clear.overlay { ... }` keeps the inner frame
            // for rendering but breaks the size-propagation pipe:
            // `Color.clear` is the layout-defining child and has a
            // flexible ideal size, so the outer ZStack's ideal
            // size stays "fill available," NSHostingView's min/max
            // doesn't churn, and SplitViewChildController stops
            // re-entering.
            Color.clear.overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    OpenAPIWiresLayer(graph: graph)
                    OpenAPINodesLayer(
                        graph: graph,
                        selectedID: selectedID,
                        warningsByNode: warningsByNode,
                        onTap: { node in
                            selectedID = node.id
                            onSelect(node)
                        },
                        onDoubleTap: { node in
                            onJumpToCode?(node)
                        }
                    )
                }
                .frame(width: contentSize.width, height: contentSize.height,
                       alignment: .topLeading)
                .offset(x: pan.width + dragOffset.width,
                        y: pan.height + dragOffset.height)
                .scaleEffect(zoom * magnify, anchor: .topLeading)
                .animation(.easeOut(duration: 0.15), value: zoom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(panGesture)
        .gesture(magnifyGesture)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                titleBar(graph: graph)
                addToolbar
            }
            .padding(SolaroSpace.l)
        }
        .overlay(alignment: .topTrailing) {
            if !graph.refs.isEmpty {
                legend.padding(SolaroSpace.l)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            zoomControls.padding(SolaroSpace.m)
        }
        .overlay(alignment: .center) {
            if graph.nodes.isEmpty {
                EmptyOpenAPINotice().padding(SolaroSpace.l)
            }
        }
    }

    // MARK: - Layout

    /// Re-parse + lay out the graph. Routes go in column 0, inline
    /// nodes in column 1, component schemas in column 2. Each
    /// column tracks its own Y cursor so tall schema cards don't
    /// overlap their neighbours.
    private func laidOut() -> OpenAPIGraph {
        var graph = OpenAPIGraphBuilder.build(yaml: yaml)
        let topPadding: Double = 80
        let leftPadding: Double = 40
        let verticalGap: Double = 24

        let routeX = leftPadding
        let inlineX = leftPadding + Double(routeNodeWidth) + Double(columnGap)
        let schemaX = inlineX + Double(schemaNodeMinWidth) + Double(columnGap)

        var routeY = topPadding
        var inlineY = topPadding
        var schemaY = topPadding

        for i in graph.nodes.indices {
            let h = approxNodeHeight(graph.nodes[i])
            switch graph.nodes[i].kind {
            case .route:
                graph.nodes[i].x = routeX
                graph.nodes[i].y = routeY
                routeY += Double(h) + verticalGap
            case .schema:
                if graph.nodes[i].id.hasPrefix("inline:") {
                    graph.nodes[i].x = inlineX
                    graph.nodes[i].y = inlineY
                    inlineY += Double(h) + verticalGap
                } else {
                    graph.nodes[i].x = schemaX
                    graph.nodes[i].y = schemaY
                    schemaY += Double(h) + verticalGap
                }
            }
        }
        return graph
    }

    private func approxNodeHeight(_ node: OpenAPINode) -> CGFloat {
        switch node.kind {
        case .route: return 84
        case .schema(_, let props):
            return CGFloat(40 + 20 * max(props.count, 1))
        }
    }

    private func contentBounds(graph: OpenAPIGraph) -> CGSize {
        var maxX: CGFloat = 1000
        var maxY: CGFloat = 600
        for node in graph.nodes {
            let approxWidth = node.id.hasPrefix("schema:") || node.id.hasPrefix("inline:")
                ? schemaNodeMinWidth + 40
                : routeNodeWidth
            maxX = max(maxX, CGFloat(node.x) + approxWidth)
            maxY = max(maxY, CGFloat(node.y) + 200)
        }
        return CGSize(width: maxX + 200, height: maxY + 200)
    }

    // MARK: - Title + legend + zoom HUD

    private func titleBar(graph: OpenAPIGraph) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(SolaroColor.accent)
                Text(graph.title.isEmpty ? "OpenAPI" : graph.title)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                if !graph.version.isEmpty {
                    Text("v\(graph.version)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
            }
            Text(summaryString(graph: graph))
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surfaceRaised.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }

    private func summaryString(graph: OpenAPIGraph) -> String {
        let routes = graph.nodes.filter { if case .route = $0.kind { return true } else { return false } }.count
        let schemas = graph.nodes.filter {
            guard case .schema = $0.kind else { return false }
            return !$0.id.hasPrefix("inline:")
        }.count
        let inlines = graph.nodes.filter { $0.id.hasPrefix("inline:") }.count
        var parts: [String] = []
        parts.append("\(routes) route\(routes == 1 ? "" : "s")")
        parts.append("\(schemas) schema\(schemas == 1 ? "" : "s")")
        if inlines > 0 { parts.append("\(inlines) inline") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var addToolbar: some View {
        HStack(spacing: SolaroSpace.s) {
            if let onAddRoute {
                Button {
                    onAddRoute()
                } label: {
                    Label("Add route", systemImage: "plus.rectangle.on.rectangle")
                }
            }
            if let onAddSchema {
                Button {
                    onAddSchema()
                } label: {
                    Label("Add schema", systemImage: "plus.square.on.square")
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONNECTIONS")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(2)
            legendRow(color: SolaroColor.roleRequest, dashed: false, label: "request body")
            legendRow(color: SolaroColor.roleResponse, dashed: false, label: "response")
            legendRow(color: SolaroColor.roleOwn, dashed: false, label: "schema $ref")
            legendRow(color: SolaroColor.textTertiary, dashed: true, label: "inline component")
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surfaceRaised.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(SolaroColor.divider, lineWidth: 1)
        )
    }

    private func legendRow(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            if dashed {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 18, height: 2)
                    .overlay(
                        Rectangle()
                            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.4,
                                                                   dash: [2, 3]))
                    )
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 18, height: 2)
            }
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
        }
    }

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
}

// MARK: - Wires

private struct OpenAPIWiresLayer: View {
    let graph: OpenAPIGraph

    var body: some View {
        Canvas { ctx, _ in
            let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
            for ref in graph.refs {
                guard let from = byID[ref.fromID], let to = byID[ref.toID] else { continue }
                drawWire(from: from, to: to, kind: ref.kind, ctx: ctx)
            }
        }
    }

    private func drawWire(from: OpenAPINode, to: OpenAPINode,
                          kind: OpenAPIRef.Kind, ctx: GraphicsContext) {
        let nodeApproxHeight: CGFloat = 80
        let nodeApproxWidth: CGFloat = 260
        let start = CGPoint(x: CGFloat(from.x) + nodeApproxWidth,
                            y: CGFloat(from.y) + nodeApproxHeight / 2)
        let end = CGPoint(x: CGFloat(to.x),
                          y: CGFloat(to.y) + nodeApproxHeight / 2)
        let dx = abs(end.x - start.x)
        let curve = max(dx * 0.5, 36)
        let c1 = CGPoint(x: start.x + curve, y: start.y)
        let c2 = CGPoint(x: end.x - curve, y: end.y)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)

        let (color, dashed) = style(for: kind)
        let solid = StrokeStyle(lineWidth: 1.6, lineCap: .round)
        let dotted = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4])
        ctx.stroke(path,
                   with: .color(color.opacity(0.15)),
                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
        ctx.stroke(path,
                   with: .color(color),
                   style: dashed ? dotted : solid)
        // Receiver-end dot.
        let dotRect = CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
    }

    private func style(for kind: OpenAPIRef.Kind) -> (Color, Bool) {
        switch kind {
        case .requestBody:     return (SolaroColor.roleRequest, false)
        case .response:        return (SolaroColor.roleResponse, false)
        case .schemaProperty:  return (SolaroColor.roleOwn, false)
        case .schemaArrayItem: return (SolaroColor.roleOwn, false)
        case .inlineLink:      return (SolaroColor.textTertiary, true)
        }
    }
}

// MARK: - Nodes

private struct OpenAPINodesLayer: View {
    let graph: OpenAPIGraph
    let selectedID: String?
    let warningsByNode: [String: [OpenAPILintWarning]]
    let onTap: (OpenAPINode) -> Void
    let onDoubleTap: (OpenAPINode) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(graph.nodes) { node in
                nodeView(for: node)
                    .overlay(alignment: .topTrailing) {
                        warningBadge(for: node)
                    }
                    .position(x: CGFloat(node.x) + nodeWidth(for: node) / 2,
                              y: CGFloat(node.y) + nodeHeight(for: node) / 2)
                    // Double-tap first: SwiftUI prefers higher-count
                    // gestures when both are attached, so single-tap
                    // selection still fires when the user clicks once.
                    .onTapGesture(count: 2) { onDoubleTap(node) }
                    .onTapGesture { onTap(node) }
            }
        }
    }

    @ViewBuilder
    private func warningBadge(for node: OpenAPINode) -> some View {
        let entries = warningsByNode[node.id] ?? []
        if !entries.isEmpty {
            let hasError = entries.contains { $0.severity == .error }
            HStack(spacing: 2) {
                Image(systemName: hasError
                      ? "exclamationmark.octagon.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(hasError
                                     ? SolaroColor.stateError
                                     : SolaroColor.stateWarn)
                Text("\(entries.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(hasError
                                     ? SolaroColor.stateError
                                     : SolaroColor.stateWarn)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(SolaroColor.surface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    hasError ? SolaroColor.stateError : SolaroColor.stateWarn,
                    lineWidth: 1
                )
            )
            .offset(x: 4, y: -4)
            .help(entries.map(\.message).joined(separator: "\n"))
        }
    }

    private func nodeWidth(for node: OpenAPINode) -> CGFloat {
        switch node.kind {
        case .route: return 280
        case .schema: return 260
        }
    }

    private func nodeHeight(for node: OpenAPINode) -> CGFloat {
        switch node.kind {
        case .route: return 84
        case .schema(_, let props):
            return CGFloat(40 + 20 * max(props.count, 1))
        }
    }

    @ViewBuilder
    private func nodeView(for node: OpenAPINode) -> some View {
        switch node.kind {
        case .route(let method, let path, let summary, let opId):
            RouteNodeCard(
                method: method, path: path,
                summary: summary, operationId: opId,
                isSelected: selectedID == node.id
            )
            .frame(width: nodeWidth(for: node))
        case .schema(let name, let props):
            SchemaNodeCard(
                name: name,
                properties: props,
                isInline: node.id.hasPrefix("inline:"),
                isSelected: selectedID == node.id
            )
            .frame(width: nodeWidth(for: node))
        }
    }
}

private struct RouteNodeCard: View {
    let method: String
    let path: String
    let summary: String?
    let operationId: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.xs) {
                Text(method)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(methodColor)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(methodColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(path)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let operationId {
                Text(operationId)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SolaroColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(isSelected ? SolaroColor.accent : SolaroColor.divider,
                        lineWidth: isSelected ? 2 : 1)
        )
    }

    private var methodColor: Color {
        switch method {
        case "GET":    return SolaroColor.roleRequest
        case "POST":   return SolaroColor.roleResponse
        case "PUT", "PATCH": return SolaroColor.roleExport
        case "DELETE": return SolaroColor.stateError
        default: return SolaroColor.textSecondary
        }
    }
}

private struct SchemaNodeCard: View {
    let name: String
    let properties: [OpenAPINode.Property]
    let isInline: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: isInline ? "curlybraces" : "shippingbox.fill")
                    .foregroundStyle(isInline
                                     ? SolaroColor.textTertiary
                                     : SolaroColor.roleOwn)
                Text(name)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(isInline
                                     ? SolaroColor.textSecondary
                                     : SolaroColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if properties.isEmpty {
                Text("(no properties)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                Divider().background(SolaroColor.divider).padding(.vertical, 2)
                ForEach(Array(properties.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 4) {
                        Text(p.name)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                        Text(":")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                        Text(p.typeLabel)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(p.refTarget == nil
                                             ? SolaroColor.textSecondary
                                             : SolaroColor.accent)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isInline ? SolaroColor.surfaceRaised.opacity(0.6) : SolaroColor.surfaceRaised
        )
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .strokeBorder(
                    isSelected ? SolaroColor.accent : SolaroColor.divider,
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2 : 1,
                        dash: isInline ? [4, 3] : []
                    )
                )
        )
    }
}

private struct EmptyOpenAPINotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            Text("Empty OpenAPI document.")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("Add a path under `paths:` and a schema under")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Text("`components.schemas:` to see them graphed here.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.m)
        .background(SolaroColor.surfaceRaised.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }
}
