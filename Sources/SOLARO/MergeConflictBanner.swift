// ============================================================
// MergeConflictBanner.swift
// SOLARO — surface + resolve git merge conflicts (#262)
// ============================================================
//
// Detects `<<<<<<<` / `=======` / `>>>>>>>` markers in the file's
// source, shows a banner above the editor with the conflict
// count, and provides a sheet where each block can be resolved
// per-hunk: keep HEAD, keep incoming, or keep both.

import SwiftUI
import Foundation

struct MergeConflict: Identifiable, Equatable {
    let id = UUID()
    /// Raw source line where `<<<<<<<` lives (1-based).
    let startLine: Int
    let endLine: Int       // line where `>>>>>>>` lives
    let headLabel: String  // text after `<<<<<<<` (e.g. "HEAD")
    let incomingLabel: String  // text after `>>>>>>>`
    let headLines: [String]
    let incomingLines: [String]
}

enum MergeConflictScanner {
    /// Walk the source for git conflict markers and return a
    /// structured list. Returns `[]` when the file is clean.
    static func scan(_ source: String) -> [MergeConflict] {
        var conflicts: [MergeConflict] = []
        let lines = source.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("<<<<<<<") {
                let headLabel = String(line.dropFirst(7))
                    .trimmingCharacters(in: .whitespaces)
                var head: [String] = []
                var incoming: [String] = []
                var inIncoming = false
                var incomingLabel = ""
                var endLine = -1
                var j = i + 1
                while j < lines.count {
                    let inner = lines[j]
                    if inner.hasPrefix("=======") {
                        inIncoming = true
                    } else if inner.hasPrefix(">>>>>>>") {
                        incomingLabel = String(inner.dropFirst(7))
                            .trimmingCharacters(in: .whitespaces)
                        endLine = j
                        break
                    } else if inIncoming {
                        incoming.append(inner)
                    } else {
                        head.append(inner)
                    }
                    j += 1
                }
                guard endLine > 0 else {
                    // Unterminated marker — bail and stop scanning.
                    break
                }
                conflicts.append(
                    MergeConflict(
                        startLine: i + 1,
                        endLine: endLine + 1,
                        headLabel: headLabel.isEmpty ? "HEAD" : headLabel,
                        incomingLabel: incomingLabel.isEmpty ? "incoming" : incomingLabel,
                        headLines: head,
                        incomingLines: incoming
                    )
                )
                i = endLine + 1
                continue
            }
            i += 1
        }
        return conflicts
    }

    /// Apply a `resolution` for a single conflict block by
    /// replacing the block's lines in `source`. The resolution is
    /// one of: keepHead, keepIncoming, keepBoth. Returns the new
    /// source string.
    enum Resolution { case keepHead, keepIncoming, keepBoth }

    static func apply(
        resolution: Resolution,
        to conflict: MergeConflict,
        in source: String
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        let from = conflict.startLine - 1
        let to = conflict.endLine - 1
        guard from < lines.count, to < lines.count, from <= to else {
            return source
        }
        let kept: [String] = {
            switch resolution {
            case .keepHead:     return conflict.headLines
            case .keepIncoming: return conflict.incomingLines
            case .keepBoth:     return conflict.headLines + conflict.incomingLines
            }
        }()
        lines.removeSubrange(from...to)
        lines.insert(contentsOf: kept, at: from)
        return lines.joined(separator: "\n")
    }
}

struct MergeConflictBanner: View {
    let count: Int
    let onResolve: () -> Void

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SolaroColor.stateError)
            Text("\(count) unresolved merge conflict\(count == 1 ? "" : "s")")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Spacer()
            Button("Resolve conflicts…", action: onResolve)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .background(SolaroColor.stateError.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SolaroColor.stateError.opacity(0.5))
                .frame(height: 1)
        }
    }
}

struct MergeConflictResolverSheet: View {
    let fileURL: URL
    @State private var conflicts: [MergeConflict] = []
    @State private var source: String = ""
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(SolaroColor.accent)
                Text("Resolve conflicts in \(fileURL.lastPathComponent)")
                    .font(SolaroFont.toolbarTitle)
                Spacer()
                Button("Done", action: onComplete)
                    .buttonStyle(.borderedProminent)
            }
            if conflicts.isEmpty {
                Text("All conflicts resolved. Stage the file and continue your merge.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateOK)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SolaroSpace.m) {
                        ForEach(conflicts) { conflict in
                            block(conflict)
                        }
                    }
                }
            }
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 720, minHeight: 520)
        .background(SolaroColor.surface)
        .task { reload() }
    }

    @ViewBuilder
    private func block(_ conflict: MergeConflict) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("Lines \(conflict.startLine)–\(conflict.endLine)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                halfPane(label: conflict.headLabel,
                         color: SolaroColor.stateOK,
                         lines: conflict.headLines)
                halfPane(label: conflict.incomingLabel,
                         color: SolaroColor.accent,
                         lines: conflict.incomingLines)
            }
            HStack {
                Button("Use \(conflict.headLabel)") {
                    apply(.keepHead, to: conflict)
                }
                Button("Use \(conflict.incomingLabel)") {
                    apply(.keepIncoming, to: conflict)
                }
                Button("Keep both") {
                    apply(.keepBoth, to: conflict)
                }
                Spacer()
            }
            Divider()
        }
    }

    private func halfPane(label: String, color: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(color)
            Text(lines.joined(separator: "\n"))
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SolaroSpace.s)
                .background(color.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        source = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        conflicts = MergeConflictScanner.scan(source)
    }

    private func apply(_ resolution: MergeConflictScanner.Resolution,
                       to conflict: MergeConflict)
    {
        source = MergeConflictScanner.apply(
            resolution: resolution,
            to: conflict,
            in: source
        )
        try? source.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }
}
