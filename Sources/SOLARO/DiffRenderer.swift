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

    private var lines: [DiffLine] { DiffParser.parse(source) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, SolaroSpace.s)
        }
        .background(SolaroColor.backdrop)
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
