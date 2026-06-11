// ============================================================
// CanvasNodeCard.swift
// SOLARO — single-statement card on the canvas
// ============================================================
//
// Extracted from CanvasView.swift to keep that file under
// control (#284 step 1). The card owns: the role rail's pulse
// animation, the live-symbol popover, the breakpoint corner
// dot, the runtime-error overlay, and the selection chrome.

import SwiftUI

struct CanvasNodeCard: View {
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
                    Text(node.lineLabel)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                if liveValues.isEmpty {
                    Text(node.summaryDisplay)
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

}

/// Styled balloon popover for canvas nodes — mirrors the editor's
/// HoverValuePopover but renders the full list of symbols the
/// statement is touching, with the statement source as the header.
struct CanvasNodeHoverPopover: View {
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
                // Let the source wrap rather than truncate — the
                // popover sits on top of the canvas backdrop, so a
                // taller balloon is fine and the user actually
                // needs to *read* what the statement does.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Divider().background(SolaroColor.divider)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(symbols, id: \.name) { s in
                    // Stacked `name : type` row on top, then the
                    // value on its own line so long strings can
                    // wrap freely instead of being clipped at the
                    // popover's right edge. Solves the "messages
                    // longer than the popover get cut off" gripe.
                    VStack(alignment: .leading, spacing: 2) {
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
                        }
                        Text(s.value)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("captured at the current pause")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        // Wider envelope so common payloads — JSON object previews,
        // multi-segment error messages — fit without forcing a
        // wrap. `fixedSize(vertical:)` on the rows lets the balloon
        // grow downward when content exceeds this width.
        .frame(minWidth: 280, maxWidth: 520, alignment: .leading)
    }
}

