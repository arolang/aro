// ============================================================
// GraphDiffView.swift
// SOLARO — side-by-side feature-set graph diff (#443)
// ============================================================
//
// The textual diff (DiffRenderer) answers "which lines changed".
// This answers the question a reviewer actually has: which feature
// sets changed, and what happened inside them.
//
// Two columns — the base revision on the left, the branch on the
// right — with nodes bordered by what happened to them. A
// statement that only moved because something was inserted above
// it renders unchanged on both sides, which is the entire point of
// diffing the parsed graph rather than the bytes.
//
// Node-anchored comments live in the inspector rail on the right
// and are keyed to the statement, so they survive the statement
// moving. Per-node conflict resolution builds on the same anchor
// and is not in this pass — see the MR description.

import SwiftUI
import AROParser

struct GraphDiffView: View {
    let path: String
    let diff: AROGraphDiff
    /// Base and branch labels for the column headers.
    let beforeLabel: String
    let afterLabel: String

    @State private var showUnchanged = false
    @State private var selected: SelectedDiffNode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if visibleSets.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SolaroSpace.l) {
                        ForEach(visibleSets, id: \.name) { set in
                            featureSetRow(set)
                        }
                    }
                    .padding(SolaroSpace.m)
                }
            }
        }
        .background(SolaroColor.backdrop)
    }

    private var visibleSets: [FeatureSetDiff] {
        showUnchanged ? diff.featureSets : diff.featureSets.filter { !$0.isUntouched }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(SolaroColor.accent)
            Text(path)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
            Text(diff.summaryLine)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Toggle("Unchanged", isOn: $showUnchanged)
                .toggleStyle(.checkbox)
                .font(SolaroFont.caption)
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private var empty: some View {
        VStack(spacing: SolaroSpace.s) {
            Image(systemName: "equal.circle")
                .font(.system(size: 26))
                .foregroundStyle(SolaroColor.textTertiary)
            Text("No feature-set changes.")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("The files differ only in formatting, or not at all.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureSetRow(_ set: FeatureSetDiff) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.xs) {
                changeBadge(set.change)
                Text(set.name)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(set.businessActivity)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                counts(set)
            }
            HStack(alignment: .top, spacing: SolaroSpace.m) {
                column(set, side: .before, label: beforeLabel)
                column(set, side: .after, label: afterLabel)
            }
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }

    private func counts(_ set: FeatureSetDiff) -> some View {
        HStack(spacing: SolaroSpace.xs) {
            if set.count(of: .added) > 0 {
                Text("+\(set.count(of: .added))")
                    .foregroundStyle(SolaroColor.roleOwn)
            }
            if set.count(of: .removed) > 0 {
                Text("−\(set.count(of: .removed))")
                    .foregroundStyle(SolaroColor.stateError)
            }
            if set.count(of: .modified) > 0 {
                Text("~\(set.count(of: .modified))")
                    .foregroundStyle(SolaroColor.roleExport)
            }
        }
        .font(SolaroFont.monoCaption)
    }

    private enum Side { case before, after }

    private func column(_ set: FeatureSetDiff, side: Side, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(1.5)
            ForEach(Array(set.statements.enumerated()), id: \.offset) { index, statement in
                if let text = text(of: statement, side: side) {
                    nodeCard(statement, text: text, side: side,
                             id: SelectedDiffNode(set: set.name, index: index))
                } else {
                    // A gap keeps the two columns aligned so the eye
                    // can track a statement straight across.
                    Color.clear.frame(height: 22)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(of statement: StatementDiff, side: Side) -> String? {
        switch side {
        case .before: return statement.before
        case .after:  return statement.after
        }
    }

    private func nodeCard(_ statement: StatementDiff,
                          text: String,
                          side: Side,
                          id: SelectedDiffNode) -> some View {
        // A modified statement is one node on each side, bordered
        // amber — not a delete facing an add. That's what keeps a
        // comment anchored to it from being orphaned by an edit.
        let color = borderColor(statement.change, side: side)
        return Text(text)
            .font(SolaroFont.monoCaption)
            .foregroundStyle(statement.change == .unchanged
                             ? SolaroColor.textTertiary
                             : SolaroColor.textPrimary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(selected == id ? 0.25 : 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .stroke(color, lineWidth: selected == id ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
            .contentShape(Rectangle())
            .onTapGesture { selected = (selected == id) ? nil : id }
    }

    private func borderColor(_ change: GraphChange, side: Side) -> Color {
        switch change {
        case .added:     return SolaroColor.roleOwn
        case .removed:   return SolaroColor.stateError
        case .modified:  return SolaroColor.roleExport
        case .unchanged: return SolaroColor.divider
        }
    }

    private func changeBadge(_ change: GraphChange) -> some View {
        Text(change.rawValue.uppercased())
            .font(SolaroFont.caption)
            .foregroundStyle(SolaroColor.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeColor(change).opacity(0.3))
            .clipShape(Capsule())
    }

    private func badgeColor(_ change: GraphChange) -> Color {
        switch change {
        case .added:     return SolaroColor.roleOwn
        case .removed:   return SolaroColor.stateError
        case .modified:  return SolaroColor.roleExport
        case .unchanged: return SolaroColor.divider
        }
    }
}

/// Identity of a node in the diff. Feature-set name plus index
/// within that set's statement list — stable while the user is
/// looking at one comparison, and the anchor a node-level comment
/// would hang off.
struct SelectedDiffNode: Hashable {
    let set: String
    let index: Int
}
