// ============================================================
// Breadcrumb.swift
// SOLARO — editor breadcrumb showing the current source location
// ============================================================

import SwiftUI
import AROParser

struct BreadcrumbView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Text(segment.label)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(segment.isCurrent
                                     ? SolaroColor.textPrimary
                                     : SolaroColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, 4)
        .background(SolaroColor.surface)
    }

    private struct Segment {
        let label: String
        let isCurrent: Bool
    }

    /// Build the segments: project > file > feature-set > line N.
    private var segments: [Segment] {
        var out: [Segment] = []
        guard let url = controller.currentFile,
              let model = controller.model else {
            return [Segment(label: controller.project.displayName, isCurrent: true)]
        }
        out.append(Segment(label: model.root.displayName, isCurrent: false))
        out.append(Segment(label: url.lastPathComponent, isCurrent: false))
        if let line = controller.currentLine,
           let fsName = enclosingFeatureSetName(for: line, in: url) {
            out.append(Segment(label: fsName, isCurrent: false))
            out.append(Segment(label: "line \(line)", isCurrent: true))
        }
        return out
    }

    /// Find the feature set whose source range covers `line`.
    private func enclosingFeatureSetName(for line: Int, in url: URL) -> String? {
        guard let program = controller.programs[url] else { return nil }
        for fs in program.featureSets {
            if fs.span.start.line <= line && line <= fs.span.end.line {
                return fs.name
            }
        }
        return nil
    }
}
