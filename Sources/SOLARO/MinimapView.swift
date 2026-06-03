// ============================================================
// MinimapView.swift
// SOLARO — scaled-down editor overview gutter (#246)
// ============================================================
//
// Thin column on the right of the text editor showing the whole
// document at micro scale. Each source line is drawn as a 1pt
// horizontal bar whose width tracks the line's character count
// and whose opacity hints at code density (whitespace barely
// shows). Clicking jumps the editor to that line.

import SwiftUI

struct MinimapView: View {
    let text: String
    /// 1-based editor caret line. The minimap highlights a
    /// viewport rectangle centred on this line so the user can
    /// see where they are in a long file.
    let currentLine: Int?
    let onJumpToLine: (Int) -> Void

    /// Vertical lines on screen at typical editor zoom — controls
    /// the size of the highlighted viewport rectangle.
    private let viewportLines: Int = 40

    var body: some View {
        GeometryReader { geo in
            let lines = text.components(separatedBy: "\n")
            let totalCount = max(1, lines.count)
            let perLine = geo.size.height / CGFloat(totalCount)
            // Canvas has no intrinsic size, so without an explicit
            // `.frame(maxWidth:.infinity, maxHeight:.infinity)` it
            // collapses to 0×0 inside the GeometryReader and the
            // minimap appears blank. Filling the proxy size makes
            // the bars render.
            Canvas { ctx, size in
                drawLines(lines: lines,
                          perLine: perLine,
                          size: size,
                          context: ctx)
                drawViewport(currentLine: currentLine,
                             totalCount: totalCount,
                             perLine: perLine,
                             size: size,
                             context: ctx)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        jump(to: value.location.y, perLine: perLine, total: totalCount)
                    }
            )
        }
        .frame(width: 64)
        .background(SolaroColor.surface.opacity(0.6))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(width: 1)
        }
        .help("Minimap — drag to scroll")
    }

    private func drawLines(
        lines: [String],
        perLine: CGFloat,
        size: CGSize,
        context: GraphicsContext
    ) {
        // Bars cap out at 56 characters wide — anything longer
        // pushes off the column edge anyway, and capping keeps
        // the visual contrast usable for short files too.
        let maxChars: CGFloat = 56
        let lineHeight = max(1, perLine)
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let charCount = CGFloat(min(trimmed.count, Int(maxChars)))
            let width = (charCount / maxChars) * (size.width - 8)
            let opacity = 0.30 + min(0.50, Double(trimmed.count) / 100.0)
            let y = CGFloat(i) * perLine
            let rect = CGRect(x: 4, y: y, width: width, height: lineHeight)
            context.fill(
                Path(rect),
                with: .color(SolaroColor.textSecondary.opacity(opacity))
            )
        }
    }

    private func drawViewport(
        currentLine: Int?,
        totalCount: Int,
        perLine: CGFloat,
        size: CGSize,
        context: GraphicsContext
    ) {
        guard let currentLine else { return }
        let viewportHeight = CGFloat(viewportLines) * perLine
        let centre = CGFloat(currentLine - 1) * perLine
        var y = centre - viewportHeight / 2
        if y < 0 { y = 0 }
        if y + viewportHeight > size.height {
            y = max(0, size.height - viewportHeight)
        }
        let rect = CGRect(x: 0, y: y, width: size.width, height: viewportHeight)
        context.fill(
            Path(rect),
            with: .color(SolaroColor.accent.opacity(0.12))
        )
        context.stroke(
            Path(rect),
            with: .color(SolaroColor.accent.opacity(0.45)),
            lineWidth: 1
        )
    }

    private func jump(to y: CGFloat, perLine: CGFloat, total: Int) {
        let line = max(1, min(total, Int(y / max(1, perLine)) + 1))
        onJumpToLine(line)
    }
}
