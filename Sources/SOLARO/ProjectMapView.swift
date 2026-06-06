// ============================================================
// ProjectMapView.swift
// SOLARO — Map mode: project-level graph (Phase 10)
// ============================================================
//
// Wireframe target: note 8519 (Project Map).
//
// One column per domain (business activity), with feature-set
// cards stacked inside. Wires cross between cards to show events
// (dashed) and Application.<Name> calls (solid). Pan + zoom
// inherited from the same gesture pattern as CanvasView.

import SwiftUI
import AROParser

struct ProjectMapView: View {
    let map: ProjectMap
    /// Most recent `aro test` outcome per feature-set name. Read
    /// by each node card to paint a small PASS / FAIL chip on the
    /// trailing edge so the project-level map mirrors the per-FS
    /// canvas containers' test badge.
    let testResults: [String: TestNodeResult]
    let onSelect: (ProjectMapNode) -> Void

    @State private var pan: CGSize = .zero
    @State private var zoom: Double = 1.0
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var magnify: Double = 1.0

    // Layout constants
    private let domainWidth: CGFloat = 240
    private let domainSpacing: CGFloat = 32
    private let nodeHeight: CGFloat = 52
    private let nodeSpacing: CGFloat = 8
    private let domainPadding: CGFloat = 12
    private let domainHeaderHeight: CGFloat = 28
    private let mapPadding: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let layout = laidOut(in: geo.size)
            ZStack {
                SolaroColor.backdrop
                dotGrid(in: geo.size)

                ZStack(alignment: .topLeading) {
                    // Domain containers behind everything else.
                    ForEach(layout.domains, id: \.domain) { d in
                        DomainContainer(
                            name: d.domain,
                            color: SolaroColor.roleColor(forVerb: d.domain.lowercased())
                                .opacity(0.6)
                        )
                        .frame(width: d.frame.width, height: d.frame.height)
                        .offset(x: d.frame.minX, y: d.frame.minY)
                    }
                    // Wires next.
                    MapWiresLayer(
                        edges: map.edges,
                        positions: layout.nodePositions,
                        cardSize: CGSize(width: domainWidth - 2 * domainPadding,
                                         height: nodeHeight)
                    )
                    // Then the node cards on top.
                    ForEach(map.nodes) { node in
                        if let pos = layout.nodePositions[node.id] {
                            ProjectMapNodeCard(
                                node: node,
                                testResult: testResults[node.featureSetName]
                            )
                                .frame(width: domainWidth - 2 * domainPadding,
                                       height: nodeHeight)
                                .offset(x: pos.x, y: pos.y)
                                .onTapGesture(count: 2) {
                                    onSelect(node)
                                }
                        }
                    }
                }
                .offset(x: pan.width + dragOffset.width,
                        y: pan.height + dragOffset.height)
                .scaleEffect(zoom * magnify, anchor: .topLeading)
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
            .overlay(alignment: .topLeading) {
                if map.nodes.isEmpty {
                    EmptyMapNotice()
                        .padding(SolaroSpace.l)
                }
            }
        }
    }

    // MARK: - Layout

    private struct LaidOutDomain {
        let domain: String
        let frame: CGRect
        let nodes: [ProjectMapNode]
    }

    private struct LayoutResult {
        let domains: [LaidOutDomain]
        let nodePositions: [String: CGPoint]
    }

    /// One column per domain. Empty domains aren't included.
    private func laidOut(in canvasSize: CGSize) -> LayoutResult {
        let domains = map.domains.filter { d in
            map.nodes.contains(where: { $0.businessActivity == d })
        }
        var laidOut: [LaidOutDomain] = []
        var positions: [String: CGPoint] = [:]

        var x = mapPadding
        for domain in domains {
            let nodesInDomain = map.nodes.filter { $0.businessActivity == domain }
            let totalNodeHeight = CGFloat(nodesInDomain.count) * nodeHeight
                + CGFloat(max(nodesInDomain.count - 1, 0)) * nodeSpacing
            let domainHeight = domainHeaderHeight + 2 * domainPadding + totalNodeHeight
            let frame = CGRect(
                x: x, y: mapPadding,
                width: domainWidth, height: domainHeight
            )
            laidOut.append(.init(domain: domain, frame: frame, nodes: nodesInDomain))

            var ny = frame.minY + domainHeaderHeight + domainPadding
            for n in nodesInDomain {
                positions[n.id] = CGPoint(
                    x: frame.minX + domainPadding,
                    y: ny
                )
                ny += nodeHeight + nodeSpacing
            }
            x += domainWidth + domainSpacing
        }
        return LayoutResult(domains: laidOut, nodePositions: positions)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func dotGrid(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            let spacing: CGFloat = 24
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            let color = GraphicsContext.Shading.color(
                SolaroColor.textTertiary.opacity(0.12)
            )
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = CGFloat(col) * spacing
                    let y = CGFloat(row) * spacing
                    let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: rect), with: color)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Domain container

private struct DomainContainer: View {
    let name: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name.isEmpty ? "—" : name)
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(color)
                .tracking(2)
                .padding(.horizontal, SolaroSpace.s)
                .padding(.vertical, SolaroSpace.xs)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.l)
                .fill(color.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.l)
                .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
    }
}

// MARK: - Node card

private struct ProjectMapNodeCard: View {
    let node: ProjectMapNode
    /// PASS / FAIL chip painted on the trailing edge when this
    /// feature set is a test FS and the runner has produced an
    /// outcome for it. nil for production FSes.
    let testResult: TestNodeResult?

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.featureSetName)
                    .font(SolaroFont.body)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                Text(triggerLabel)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            testBadge
            Text("\(node.statementCount)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(borderTint, lineWidth: 1)
        )
        .help("\(node.featureSetName) · \(node.statementCount) statements")
    }

    /// Test-status chip — green check for PASS, red X for FAIL.
    /// Renders nothing when the FS isn't a test or hasn't been run
    /// yet so production rows stay visually quiet.
    @ViewBuilder
    private var testBadge: some View {
        switch testResult {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SolaroColor.stateOK)
                .help("Last test run: passed")
        case .failed(let message):
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SolaroColor.stateError)
                .help("Last test run: \(message)")
        case .none:
            EmptyView()
        }
    }

    /// Border tint follows the test result so a glance picks out
    /// failures even when the chip is off-screen during a zoom-out
    /// — falls back to the trigger tint for production rows and
    /// untested test feature sets.
    private var borderTint: Color {
        switch testResult {
        case .passed: return SolaroColor.stateOK.opacity(0.55)
        case .failed: return SolaroColor.stateError.opacity(0.65)
        case .none:   return tint.opacity(0.5)
        }
    }

    private var symbol: String {
        switch node.trigger {
        case .applicationStart: return "play.fill"
        case .applicationEnd: return "stop.fill"
        case .http: return "rectangle.connected.to.line.below"
        case .eventHandler: return "antenna.radiowaves.left.and.right"
        case .repositoryObserver: return "eye.fill"
        case .userAction: return "function"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch node.trigger {
        case .applicationStart: return SolaroColor.stateOK
        case .applicationEnd: return SolaroColor.stateWarn
        case .http: return SolaroColor.roleRequest
        case .eventHandler: return SolaroColor.roleExport
        case .repositoryObserver: return SolaroColor.roleResponse
        case .userAction: return SolaroColor.roleOwn
        case .unknown: return SolaroColor.textTertiary
        }
    }

    private var triggerLabel: String {
        switch node.trigger {
        case .applicationStart: return "entry"
        case .applicationEnd: return "exit"
        case .http(let op): return "GET \(op)"
        case .eventHandler(let evt): return "on \(evt)"
        case .repositoryObserver(let repo): return "watches \(repo)"
        case .userAction: return "callable"
        case .unknown: return ""
        }
    }
}

// MARK: - Wires layer

private struct MapWiresLayer: View {
    let edges: [ProjectMapEdge]
    let positions: [String: CGPoint]
    let cardSize: CGSize

    var body: some View {
        Canvas { ctx, _ in
            for edge in edges {
                guard
                    let from = positions[edge.from],
                    let to = positions[edge.to]
                else { continue }

                let start = CGPoint(x: from.x + cardSize.width,
                                    y: from.y + cardSize.height / 2)
                let end = CGPoint(x: to.x,
                                  y: to.y + cardSize.height / 2)
                let dx = abs(end.x - start.x)
                let curve = max(dx * 0.5, 40)
                let c1 = CGPoint(x: start.x + curve, y: start.y)
                let c2 = CGPoint(x: end.x - curve, y: end.y)

                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: c1, control2: c2)

                let (color, style) = strokeStyle(for: edge.kind)
                ctx.stroke(path,
                           with: .color(color.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round))
                ctx.stroke(path, with: .color(color), style: style)
            }
        }
    }

    private func strokeStyle(for kind: ProjectMapEdge.Kind) -> (Color, StrokeStyle) {
        switch kind {
        case .eventEmitSubscribe:
            return (SolaroColor.roleExport,
                    StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 4]))
        case .applicationCall:
            return (SolaroColor.roleOwn,
                    StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }
}

private struct EmptyMapNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            Text("No feature sets to map yet.")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("Add an .aro file with a feature set; the map populates automatically.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.m)
        .background(SolaroColor.surfaceRaised.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }
}
