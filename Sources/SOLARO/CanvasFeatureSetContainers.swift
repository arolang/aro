// ============================================================
// CanvasFeatureSetContainers.swift
// SOLARO — colored rectangles + headers grouping FS statements
// ============================================================
//
// Extracted from CanvasView.swift (#284 step 2). Owns
// `FeatureSetContainersLayer`, `FeatureSetContainer`,
// `LoopContainersLayer`, and `LoopBracket` — the layer behind
// every node card that groups statements by feature set and
// shows the FS title + test PASS/FAIL chip.

import SwiftUI

// MARK: - Feature-set containers

/// Draws one colored rounded rectangle per feature set in the
/// graph, with the feature-set name labelled at the top. Sits
/// behind wires + nodes so the boxes read as background regions
/// rather than overlays.
struct FeatureSetContainersLayer: View {
    let graph: CanvasGraph
    let positions: [CanvasNode.ID: CGPoint]
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    /// Feature-set name → wall-clock time of the most recent event
    /// observed for that FS. Drives the container's outline glow.
    let lastExecutedAtPerFeatureSet: [String: Date]
    /// Feature-set name → most recent `aro test` outcome. Drives
    /// the PASS/FAIL chip in the header.
    let testResults: [String: TestNodeResult]
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
                    testResult: testResults[group.name],
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
struct LoopContainersLayer: View {
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
struct LoopBracket: View {
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

struct FeatureSetContainer: View {
    let name: String
    let tint: Color
    let rect: CGRect
    /// Most recent time any statement in this FS fired, or `nil` if
    /// it hasn't run yet this session. Drives the container's
    /// brighter glow during the pulse window.
    let lastExecutedAt: Date?
    /// Outcome of the most recent `aro test` invocation for this
    /// feature set, if it's a test FS. Drives the pass/fail badge
    /// next to the header title.
    let testResult: TestNodeResult?
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

    /// PASS/FAIL chip on the FS container header. Bumped up in
    /// size (#?) so the test result is the most obvious thing on
    /// the container, matching the editor gutter's chip vocabulary.
    @ViewBuilder
    private var testBadge: some View {
        switch testResult {
        case .passed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("PASS")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
            }
            .foregroundStyle(SolaroColor.stateOK)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SolaroColor.stateOK.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(SolaroColor.stateOK.opacity(0.5), lineWidth: 1)
            )
            .help("Last test run: passed")
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("FAIL")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
            }
            .foregroundStyle(SolaroColor.stateError)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SolaroColor.stateError.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(SolaroColor.stateError.opacity(0.5), lineWidth: 1)
            )
            .help("Last test run: \(message)")
        case .none:
            EmptyView()
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
                // PASS / FAIL chip on the right side of the
                // header strip (#?). Anchoring it past the Spacer
                // means it never overlaps the FS name even when
                // the container is narrow.
                testBadge
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
