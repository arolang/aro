// ============================================================
// CanvasRepos.swift
// SOLARO — repository nodes + their hover-history popover
// ============================================================
//
// Extracted from CanvasView.swift (#284 step 3). Owns
// `RepoNodesLayer`, `RepoCard`, and `RepoHistoryPopover` — the
// blue capsules behind the canvas that mirror live repository
// payloads and their rolling history.

import SwiftUI

// MARK: - Repositories

/// Draws each repository entity as a draggable card, positioned via
/// the shared `positions` map so the wires layer connects to the
/// exact same point.
struct RepoNodesLayer: View {
    let repositories: [RepositoryNode]
    let positions: [CanvasNode.ID: CGPoint]
    let repoWidth: CGFloat
    let repoHeight: CGFloat
    /// Latest value the runtime saw flowing through each repository,
    /// keyed by repo object name. Empty when no recorded run has
    /// produced a value yet.
    let repositoryValues: [String: ConsoleProcess.SymbolValue]
    /// Rolling history of recent payloads, newest first.
    let repositoryHistory: [String: [ConsoleProcess.SymbolValue]]
    let onDrag: (String, CGPoint) -> Void
    let onDragEnd: (String, CGPoint) -> Void
    /// Snapshot point — same role as `NodesLayer.onDragStart`.
    let onDragStart: (String) -> Void

    @State private var dragOrigins: [String: CGPoint] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(repositories) { repo in
                let p = positions[repo.id] ?? CGPoint(x: repo.x, y: repo.y)
                RepoCard(
                    repo: repo,
                    width: repoWidth,
                    height: repoHeight,
                    liveValue: repositoryValues[repo.name],
                    history: repositoryHistory[repo.name] ?? []
                )
                    .position(x: p.x + repoWidth / 2,
                              y: p.y + repoHeight / 2)
                    .gesture(dragGesture(id: repo.id, livePosition: p))
            }
        }
    }

    private func dragGesture(id: String, livePosition: CGPoint) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let origin = dragOrigins[id] ?? livePosition
                if dragOrigins[id] == nil {
                    dragOrigins[id] = origin
                    onDragStart(id)
                }
                let next = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                onDrag(id, next)
            }
            .onEnded { value in
                let origin = dragOrigins[id] ?? livePosition
                let final = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                dragOrigins.removeValue(forKey: id)
                onDragEnd(id, final)
            }
    }
}

struct RepoCard: View {
    let repo: RepositoryNode
    let width: CGFloat
    let height: CGFloat
    /// Most recent value seen on this repository during the current
    /// recorded run, or `nil` if nothing has flowed through yet.
    let liveValue: ConsoleProcess.SymbolValue?
    /// Rolling history (newest first) — shown in the hover popover
    /// so the user can see the recent write sequence.
    let history: [ConsoleProcess.SymbolValue]

    @State private var hovering = false
    @State private var showHistory = false

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SolaroColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                if let live = liveValue {
                    // Replace the usage badge with the live payload
                    // once we have one — surfaces the actual data
                    // alongside the wires.
                    Text(live.value)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(usageLabel(repo.usage))
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SolaroSpace.m)
        .frame(width: width, height: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(SolaroColor.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(SolaroColor.accent.opacity(0.55), lineWidth: 1)
        )
        .onHover { isHovering in
            hovering = isHovering
            showHistory = isHovering && !history.isEmpty
        }
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            RepoHistoryPopover(repo: repo, history: history)
        }
        .help(helpText)
    }

    private var helpText: String {
        var msg = "Repository: \(repo.name) — \(usageLabel(repo.usage))"
        if let live = liveValue {
            msg += "\nCurrent value: \(live.value)"
        }
        return msg
    }

    private func usageLabel(_ u: RepositoryNode.Usage) -> String {
        var parts: [String] = []
        if u.contains(.read)  { parts.append("read") }
        if u.contains(.write) { parts.append("write") }
        if u.contains(.watch) { parts.append("watch") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Hover popover for the repository card — lists the recent
/// payloads the runtime saw flowing through this repo (newest
/// first) so the user can trace the write sequence without
/// running a separate tool.
struct RepoHistoryPopover: View {
    let repo: RepositoryNode
    let history: [ConsoleProcess.SymbolValue]

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .foregroundStyle(SolaroColor.accent)
                    .font(.system(size: 11))
                Text(repo.name)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer()
            }
            Divider().background(SolaroColor.divider)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(history.enumerated()), id: \.offset) { idx, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(idx == 0 ? "now" : "−\(idx)")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Text(value.value)
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(SolaroSpace.m)
        .frame(minWidth: 260, maxWidth: 520, alignment: .topLeading)
    }
}
