// ============================================================
// DiffRenderer.swift
// SOLARO — render .diff / .patch files in the editor pane (#233 §1)
// ============================================================
//
// Read-only viewer for unified diffs. Recognises the standard
// `git diff` output: `diff --git`, file headers, `@@` hunk
// markers, and `+` / `-` / ` ` line prefixes. The renderer
// strips the prefix character and tints the row background
// instead, so the actual code reads as code.

import SwiftUI
import Foundation

enum DiffLineKind: Equatable {
    case added       // "+"
    case removed     // "-"
    case context     // " "
    case hunk        // "@@ -10,5 +10,7 @@"
    case fileHeader  // "diff --git", "+++ b/…", "--- a/…", "index …"
    case noNewline   // "\ No newline at end of file"
    case blank       // empty line in the diff stream
}

struct DiffLine: Equatable {
    let kind: DiffLineKind
    /// The line content with the prefix character (+/-/space) already removed.
    let body: String
}

enum DiffParser {
    /// Parse a unified diff into structured rows. Forgiving — any
    /// line we don't recognise lands as `.context` so the user
    /// still sees their text.
    static func parse(_ source: String) -> [DiffLine] {
        var rows: [DiffLine] = []
        for raw in source.components(separatedBy: "\n") {
            rows.append(classify(raw))
        }
        return rows
    }

    private static func classify(_ raw: String) -> DiffLine {
        if raw.isEmpty {
            return DiffLine(kind: .blank, body: "")
        }
        if raw.hasPrefix("diff --git") || raw.hasPrefix("index ")
            || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ")
            || raw.hasPrefix("new file mode") || raw.hasPrefix("deleted file mode")
            || raw.hasPrefix("rename from") || raw.hasPrefix("rename to")
            || raw.hasPrefix("similarity index")
        {
            return DiffLine(kind: .fileHeader, body: raw)
        }
        if raw.hasPrefix("@@") {
            return DiffLine(kind: .hunk, body: raw)
        }
        if raw.hasPrefix("\\") {
            return DiffLine(kind: .noNewline, body: String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        if raw.hasPrefix("+") {
            return DiffLine(kind: .added, body: String(raw.dropFirst()))
        }
        if raw.hasPrefix("-") {
            return DiffLine(kind: .removed, body: String(raw.dropFirst()))
        }
        if raw.hasPrefix(" ") {
            return DiffLine(kind: .context, body: String(raw.dropFirst()))
        }
        return DiffLine(kind: .context, body: raw)
    }
}

struct DiffRendererView: View {
    let source: String

    @AppStorage(SolaroPrefs.diffStyle.rawValue)
    private var styleRaw: String = DiffStyle.unified.rawValue

    private var style: DiffStyle {
        DiffStyle(rawValue: styleRaw) ?? .unified
    }

    private var lines: [DiffLine] { DiffParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            switch style {
            case .unified:     unifiedBody
            case .sideBySide:  sideBySideBody
            }
        }
        .background(SolaroColor.backdrop)
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Picker("", selection: $styleRaw) {
                Text("Unified").tag(DiffStyle.unified.rawValue)
                Text("Side-by-side").tag(DiffStyle.sideBySide.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()
            Spacer()
            let stats = DiffStats.compute(lines: lines)
            Text("+\(stats.added)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.stateOK)
            Text("−\(stats.removed)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.stateError)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private var unifiedBody: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, SolaroSpace.s)
        }
    }

    private var sideBySideBody: some View {
        let pairs = DiffPairer.pair(lines)
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    sideBySideRow(pair)
                }
            }
            .padding(.vertical, SolaroSpace.s)
        }
    }

    /// One row of the side-by-side view. Hunk + file-header rows
    /// span the full width; line pairs split 50/50 with an empty
    /// half for adds / removes that don't pair with anything.
    @ViewBuilder
    private func sideBySideRow(_ pair: DiffPair) -> some View {
        if pair.isFullWidth {
            row(pair.left ?? pair.right!)
        } else {
            HStack(spacing: 0) {
                halfRow(pair.left,  side: .left)
                Rectangle()
                    .fill(SolaroColor.divider)
                    .frame(width: 1)
                halfRow(pair.right, side: .right)
            }
        }
    }

    private enum Side { case left, right }

    private func halfRow(_ line: DiffLine?, side: Side) -> some View {
        let kind: DiffLineKind = line?.kind ?? .blank
        let body: String = {
            guard let line else { return "" }
            return line.body.isEmpty ? " " : line.body
        }()
        return HStack(alignment: .top, spacing: 0) {
            Text(prefix(forSide: side, kind: kind))
                .font(SolaroFont.mono)
                .foregroundStyle(prefixColor(for: kind))
                .frame(width: 22, alignment: .center)
            Text(body)
                .font(SolaroFont.mono)
                .foregroundStyle(bodyColor(for: kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SolaroSpace.s)
        .background(background(for: kind))
        .frame(maxWidth: .infinity)
    }

    private func prefix(forSide side: Side, kind: DiffLineKind) -> String {
        switch (side, kind) {
        case (.left, .removed): return "−"
        case (.right, .added):  return "+"
        case (_, .context):     return " "
        default:                return " "
        }
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(prefix(for: line.kind))
                .font(SolaroFont.mono)
                .foregroundStyle(prefixColor(for: line.kind))
                .frame(width: 22, alignment: .center)
            Text(line.body.isEmpty ? " " : line.body)
                .font(SolaroFont.mono)
                .foregroundStyle(bodyColor(for: line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SolaroSpace.s)
        .background(background(for: line.kind))
    }

    private func prefix(for kind: DiffLineKind) -> String {
        switch kind {
        case .added:      return "+"
        case .removed:    return "−"   // unicode minus for visual weight
        case .hunk:       return "›"
        case .fileHeader: return ""
        case .noNewline:  return "\\"
        case .context, .blank: return " "
        }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added:      return SolaroColor.stateOK.opacity(0.14)
        case .removed:    return SolaroColor.stateError.opacity(0.14)
        case .hunk:       return SolaroColor.accent.opacity(0.10)
        case .fileHeader: return SolaroColor.textTertiary.opacity(0.10)
        default:          return Color.clear
        }
    }

    private func prefixColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added:      return SolaroColor.stateOK
        case .removed:    return SolaroColor.stateError
        case .hunk:       return SolaroColor.accent
        case .fileHeader: return SolaroColor.textTertiary
        default:          return SolaroColor.textTertiary
        }
    }

    private func bodyColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .fileHeader: return SolaroColor.textSecondary
        case .hunk:       return SolaroColor.textSecondary
        case .noNewline:  return SolaroColor.textTertiary
        default:          return SolaroColor.textPrimary
        }
    }
}

// MARK: - Side-by-side pairing

enum DiffStyle: String { case unified, sideBySide }

/// One row of the side-by-side view. Either both halves point at
/// the same `DiffLine` (full-width — used for hunk + file-header
/// rows) or each side holds an independent line / nil.
struct DiffPair {
    let left: DiffLine?
    let right: DiffLine?
    let isFullWidth: Bool
}

/// Walks a unified diff and groups consecutive `-` / `+` runs into
/// left / right pairs. Context lines mirror on both sides; hunk
/// markers and file headers stay full-width.
enum DiffPairer {
    static func pair(_ lines: [DiffLine]) -> [DiffPair] {
        var pairs: [DiffPair] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .hunk, .fileHeader, .noNewline:
                pairs.append(DiffPair(left: line, right: line, isFullWidth: true))
                i += 1
            case .context, .blank:
                pairs.append(DiffPair(left: line, right: line, isFullWidth: false))
                i += 1
            case .removed:
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while i < lines.count, lines[i].kind == .removed {
                    removed.append(lines[i])
                    i += 1
                }
                while i < lines.count, lines[i].kind == .added {
                    added.append(lines[i])
                    i += 1
                }
                let count = max(removed.count, added.count)
                for k in 0..<count {
                    pairs.append(DiffPair(
                        left:  k < removed.count ? removed[k] : nil,
                        right: k < added.count   ? added[k]   : nil,
                        isFullWidth: false
                    ))
                }
            case .added:
                pairs.append(DiffPair(left: nil, right: line, isFullWidth: false))
                i += 1
            }
        }
        return pairs
    }
}

/// Quick counter for the header chip — number of `+` and `-`
/// lines in the whole diff, excluding file headers.
struct DiffStats {
    let added: Int
    let removed: Int

    static func compute(lines: [DiffLine]) -> DiffStats {
        var a = 0, r = 0
        for line in lines {
            switch line.kind {
            case .added:   a += 1
            case .removed: r += 1
            default: break
            }
        }
        return DiffStats(added: a, removed: r)
    }
}
