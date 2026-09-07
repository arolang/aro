// ============================================================
// GraphDiffView.swift
// SOLARO — side-by-side feature-graph diff (#443)
// ============================================================
//
// The textual diff (DiffRenderer) answers "which lines changed".
// This answers the question a reviewer actually has: which feature
// sets changed, what happened inside them, and which wires between
// them moved — a deleted `Emit` line is one line of text and a
// whole handler that no longer runs.
//
// Two columns per feature set — the base revision on the left, the
// working tree on the right — with nodes bordered by what happened
// to them. A statement that only moved because something was
// inserted above it renders unchanged on both sides, which is the
// entire point of diffing the parsed graph rather than the bytes.
//
// The comparison itself is `FeatureGraphDiff` in AROParser, the
// same core `aro diff --graph` prints, so the IDE and the CLI
// cannot drift apart.
//
// Node-anchored inline comments and per-node conflict resolution
// are the far end of #443 and are not in this pass: selection here
// establishes the anchor (`SelectedDiffNode`) they would hang off.

import SwiftUI
import AROParser

struct GraphDiffView: View {
    let diff: FeatureGraphDiff

    @State private var showUnchanged = false
    @State private var selected: SelectedDiffNode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if visibleNodes.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SolaroSpace.l) {
                        if !changedWires.isEmpty { wireSection }
                        ForEach(visibleNodes) { node in
                            featureSetRow(node)
                        }
                    }
                    .padding(SolaroSpace.m)
                }
            }
        }
        .background(SolaroColor.backdrop)
    }

    private var visibleNodes: [FeatureGraphDiff.NodeDiff] {
        showUnchanged ? diff.nodes : diff.touchedNodes
    }

    private var changedWires: [FeatureGraphDiff.EdgeDiff] {
        diff.edges.filter { $0.change != .unchanged }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(SolaroColor.accent)
            Text("\(diff.beforeLabel) → \(diff.afterLabel)")
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
            Text("The revisions differ only in formatting, or not at all.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Wires

    /// Events, `Application.<Name>` calls and repository observers
    /// that appeared or vanished. Listed above the feature sets
    /// because a wire is the change a line diff cannot show.
    private var wireSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WIRES")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(1.5)
            ForEach(changedWires, id: \.self) { entry in
                HStack(spacing: SolaroSpace.xs) {
                    Text(entry.change == .added ? "+" : "−")
                        .foregroundStyle(borderColor(entry.change))
                    Text(entry.edge.from)
                        .foregroundStyle(SolaroColor.textPrimary)
                    Text("\(entry.edge.kind.rawValue)(\(entry.edge.label))")
                        .foregroundStyle(SolaroColor.textTertiary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(SolaroColor.textTertiary)
                    Text(entry.edge.to)
                        .foregroundStyle(SolaroColor.textPrimary)
                }
                .font(SolaroFont.monoCaption)
            }
        }
        .padding(SolaroSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SolaroColor.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }

    // MARK: - Feature sets

    private func featureSetRow(_ node: FeatureGraphDiff.NodeDiff) -> some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.xs) {
                changeBadge(node.change)
                Text(node.name)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(node.businessActivity)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(node.kind.label)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
                counts(node)
            }
            location(node)
            HStack(alignment: .top, spacing: SolaroSpace.m) {
                column(node, side: .before, label: diff.beforeLabel)
                column(node, side: .after, label: diff.afterLabel)
            }
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
    }

    /// Where the feature set lives — and, when it moved, that the
    /// move is all that happened to it.
    @ViewBuilder
    private func location(_ node: FeatureGraphDiff.NodeDiff) -> some View {
        if node.movedFile {
            Text("moved: \(node.beforeFile ?? "?") → \(node.afterFile ?? "?")")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        } else {
            Text(node.file)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
    }

    private func counts(_ node: FeatureGraphDiff.NodeDiff) -> some View {
        HStack(spacing: SolaroSpace.xs) {
            if node.count(of: .added) > 0 {
                Text("+\(node.count(of: .added))")
                    .foregroundStyle(SolaroColor.roleOwn)
            }
            if node.count(of: .removed) > 0 {
                Text("−\(node.count(of: .removed))")
                    .foregroundStyle(SolaroColor.stateError)
            }
            if node.count(of: .modified) > 0 {
                Text("~\(node.count(of: .modified))")
                    .foregroundStyle(SolaroColor.roleExport)
            }
        }
        .font(SolaroFont.monoCaption)
    }

    private enum Side { case before, after }

    private func column(_ node: FeatureGraphDiff.NodeDiff,
                        side: Side,
                        label: String) -> some View
    {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(1.5)
            ForEach(Array(node.statements.enumerated()), id: \.offset) { index, statement in
                if let text = text(of: statement, side: side) {
                    nodeCard(statement, text: text,
                             id: SelectedDiffNode(set: node.name, index: index))
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
                          id: SelectedDiffNode) -> some View {
        // A modified statement is one node on each side, bordered
        // amber — not a delete facing an add. That's what keeps a
        // comment anchored to it from being orphaned by an edit.
        let color = borderColor(statement.change)
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

    private func borderColor(_ change: GraphChange) -> Color {
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
            .background(borderColor(change).opacity(0.3))
            .clipShape(Capsule())
    }
}

/// Identity of a node in the diff. Feature-set name plus index
/// within that set's statement list — stable while the user is
/// looking at one comparison, and the anchor a node-level comment
/// or a per-node conflict resolution would hang off.
struct SelectedDiffNode: Hashable {
    let set: String
    let index: Int
}

// MARK: - Sheet

/// The Git menu's "Compare Feature Graph…" — pick a revision, see
/// the graph the working tree changed.
struct GraphDiffSheet: View {
    let project: Project
    var onClose: () -> Void

    @State private var model = GraphDiffModel()
    @FocusState private var revisionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(SolaroColor.divider)
            content
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(SolaroColor.backdrop)
        .task { await model.load(project: project) }
    }

    private var toolbar: some View {
        HStack(spacing: SolaroSpace.s) {
            Text("COMPARE FEATURE GRAPH")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textTertiary)
                .tracking(1.5)
            TextField("Revision", text: $model.baseRevision)
                .textFieldStyle(.roundedBorder)
                .font(SolaroFont.monoCaption)
                .frame(width: 200)
                .focused($revisionFocused)
                .onSubmit { Task { await model.load(project: project) } }
            Button("Compare") {
                Task { await model.load(project: project) }
            }
            .disabled(model.isLoading)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(SolaroSpace.m)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            VStack(spacing: SolaroSpace.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(SolaroColor.stateError)
                Text(error)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SolaroSpace.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = model.diff {
            GraphDiffView(diff: diff)
        } else {
            Color.clear
        }
    }
}
