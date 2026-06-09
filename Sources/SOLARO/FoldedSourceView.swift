// ============================================================
// FoldedSourceView.swift
// SOLARO — outline-style folded view of an ARO source file (#246)
// ============================================================
//
// Read-only browser for an ARO file with each feature-set body
// collapsed. The header line for every feature set is shown
// verbatim; the body is replaced with `{ … N statements }`. The
// user can click a header to expand just that feature set, or
// click again to collapse. Useful for getting a bird's-eye view
// of a large file before drilling into a specific block.

import SwiftUI
import AROParser

struct FoldedSourceView: View {
    let source: String
    let program: Program
    let onJumpToLine: (Int) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(program.featureSets, id: \.name) { fs in
                    featureSetBlock(fs)
                }
                if program.featureSets.isEmpty {
                    Text("(no feature sets parsed in this file)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .padding(SolaroSpace.m)
                }
            }
            .padding(SolaroSpace.s)
        }
        .background(SolaroColor.backdrop)
    }

    @ViewBuilder
    private func featureSetBlock(_ fs: FeatureSet) -> some View {
        let isOpen = expanded.contains(fs.name)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(fs.name)
            } label: {
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: isOpen
                          ? "chevron.down"
                          : "chevron.right")
                        .foregroundStyle(SolaroColor.accent)
                        .frame(width: 14)
                    Text("(\(fs.name): \(fs.businessActivity))")
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.textPrimary)
                    Text(" { … \(fs.statements.count) statement\(fs.statements.count == 1 ? "" : "s") }")
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.textTertiary)
                    Spacer()
                    Button {
                        onJumpToLine(fs.span.start.line)
                    } label: {
                        Image(systemName: "text.cursor")
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Open this feature set in the editor")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, SolaroSpace.s)
            }
            .buttonStyle(.plain)
            if isOpen {
                expandedBody(fs)
            }
            Divider().background(SolaroColor.divider)
        }
    }

    private func expandedBody(_ fs: FeatureSet) -> some View {
        let lines = source.components(separatedBy: "\n")
        let start = fs.span.start.line       // 1-based
        let end = min(lines.count, fs.span.end.line)
        let body = (start...end)
            .compactMap { lines.indices.contains($0 - 1) ? lines[$0 - 1] : nil }
            .joined(separator: "\n")
        return Text(body)
            .font(SolaroFont.mono)
            .foregroundStyle(SolaroColor.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, SolaroSpace.xs)
            .background(SolaroColor.surface.opacity(0.4))
    }

    private func toggle(_ name: String) {
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
        }
    }
}
