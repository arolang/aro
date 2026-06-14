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
    /// Current rows held by each repository — drives the inline
    /// table inside `RepoCard` (#284 step 3).
    let repositoryRecords: [String: [[String: String]]]
    let onDrag: (String, CGPoint) -> Void
    let onDragEnd: (String, CGPoint) -> Void
    /// Snapshot point — same role as `NodesLayer.onDragStart`.
    let onDragStart: (String) -> Void
    /// Click on the body of a repository card → push it into the
    /// controller's selection so the inspector renders its editor.
    let onSelect: (RepositoryNode) -> Void
    /// Trash-icon tap → ask the controller to drop every record
    /// the UI is holding for this repo.
    let onClear: (RepositoryNode) -> Void
    /// The currently-selected repo name, for accent-stroke styling.
    let selectedRepositoryName: String?

    @State private var dragOrigins: [String: CGPoint] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(repositories) { repo in
                let p = positions[repo.id] ?? CGPoint(x: repo.x, y: repo.y)
                RepoCard(
                    repo: repo,
                    width: repoWidth,
                    collapsedHeight: repoHeight,
                    liveValue: repositoryValues[repo.name],
                    history: repositoryHistory[repo.name] ?? [],
                    records: repositoryRecords[repo.name],
                    isSelected: selectedRepositoryName == repo.name,
                    onSelect: { onSelect(repo) },
                    onClear: { onClear(repo) }
                )
                    // Place by top-left so the card grows downward
                    // when it has records. The wires layer always
                    // anchors to the top edge of the card, so a
                    // taller card doesn't move the connection point.
                    .offset(x: p.x, y: p.y)
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
    /// Height of the always-visible header row. The card grows
    /// taller than this when it has `records` to render as a table.
    let collapsedHeight: CGFloat
    /// Most recent value seen on this repository during the current
    /// recorded run, or `nil` if nothing has flowed through yet.
    let liveValue: ConsoleProcess.SymbolValue?
    /// Rolling history (newest first) — shown in the hover popover
    /// so the user can see the recent write sequence.
    let history: [ConsoleProcess.SymbolValue]
    /// Current rows held by the repository, projected to flat
    /// `[field: rendered]` dictionaries. `nil` means the runtime
    /// hasn't reported on this repo yet (so we render the empty
    /// capsule). An empty array means "the repo is currently empty"
    /// and we render a single "(no entries)" hint.
    let records: [[String: String]]?
    /// True when this card matches `controller.selectedRepository`
    /// — the overlay stroke thickens + tints accent so the user
    /// has a visual handle on the inspector ↔ canvas link.
    let isSelected: Bool
    /// Header / body tap → select this repo in the inspector.
    let onSelect: () -> Void
    /// Trash icon → drop every observed record for this repo.
    let onClear: () -> Void

    @State private var hovering = false
    @State private var showHistory = false
    /// Set by clicking the "+N more" footer. Toggles the table
    /// between the compact preview (`visibleRowLimit` rows) and the
    /// full list of records held by the repository.
    @State private var expanded = false

    /// Cap the visible row count when the card is collapsed. The
    /// footer row turns into a button that expands the table to all
    /// rows when the repository holds more than this.
    private static let visibleRowLimit = 4

    /// Cap how wide the card may grow when records push it open.
    /// Long URL / hash payloads otherwise produce a card that
    /// stretches across the whole canvas. 480pt fits ~80 chars of
    /// monospaced text — wider values wrap to a second line.
    private static let expandedMaxWidth: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(maxWidth: .infinity,
                       minHeight: collapsedHeight,
                       alignment: .leading)
            if let records, !records.isEmpty {
                Divider()
                    .background(SolaroColor.divider)
                recordsTable(records)
                    .padding(.horizontal, SolaroSpace.s)
                    .padding(.vertical, SolaroSpace.xs)
            }
        }
        // Collapsed card keeps the historical fixed width; once
        // there are rows, it may grow up to `expandedMaxWidth` to
        // give cells room to render long values without
        // truncation (#284 step 3).
        .frame(minWidth: width,
               maxWidth: (records?.isEmpty == false) ? Self.expandedMaxWidth : width,
               alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .fill(SolaroColor.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(
                    SolaroColor.accent
                        .opacity(isSelected ? 1.0 : 0.55),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .onHover { isHovering in
            hovering = isHovering
            showHistory = isHovering && !history.isEmpty && !isSelected
        }
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            RepoHistoryPopover(repo: repo, history: history)
        }
        // Plain tap to select; long-press drag handled by the
        // outer DragGesture on RepoNodesLayer. SwiftUI gives the
        // tap priority when both fire on the same press, so the
        // user can still click-and-drag without selecting
        // accidentally — the drag wins as soon as a translation is
        // reported.
        .onTapGesture(perform: onSelect)
        .help(helpText)
    }

    private var header: some View {
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
            // Trash icon clears every observed record for this
            // repo. Hidden until the user hovers / has selected
            // the card so the canvas reads quiet at rest. Empty
            // repos hide it entirely — there's nothing to clear.
            if (hovering || isSelected),
               let records, !records.isEmpty
            {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear every entry in this repository (UI only — next run repopulates)")
            }
        }
        .padding(.horizontal, SolaroSpace.m)
    }

    @ViewBuilder
    private func recordsTable(_ records: [[String: String]]) -> some View {
        let columns = Self.columnOrder(for: records)
        let visible = expanded
            ? records
            : Array(records.prefix(Self.visibleRowLimit))
        let overflow = records.count - visible.count
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SolaroSpace.s) {
                ForEach(columns, id: \.self) { col in
                    Text(col)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: SolaroSpace.s) {
                    ForEach(columns, id: \.self) { col in
                        // No `lineLimit`/`truncationMode` — long
                        // payloads (URLs, hashes) wrap to multiple
                        // lines so the card always shows the full
                        // string. `fixedSize(vertical:)` lets the
                        // row's height match its tallest cell;
                        // `textSelection(.enabled)` lets the user
                        // copy the value with ⌘C.
                        Text(row[col] ?? "—")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            if overflow > 0 {
                // Clickable footer: tap to expand the table to the
                // full row set. PlainButtonStyle keeps the chrome
                // borderless so it visually reads as a link, not a
                // button-with-shadow.
                Button {
                    expanded = true
                } label: {
                    Text("+\(overflow) more")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.accent)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Show all \(records.count) rows")
            } else if expanded, records.count > Self.visibleRowLimit {
                Button {
                    expanded = false
                } label: {
                    Text("Show fewer")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.accent)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Collapse the table to the most recent \(Self.visibleRowLimit) rows")
            }
        }
    }

    /// Column ordering preserves the first row's key order and then
    /// appends any new keys discovered in later rows. Keeps the
    /// rendering stable across redraws without an explicit schema.
    private static func columnOrder(for records: [[String: String]]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in records {
            for key in row.keys where !seen.contains(key) {
                seen.insert(key)
                out.append(key)
            }
        }
        // Sort within the first row to keep the order deterministic
        // (Swift dictionaries don't promise insertion order). Stable
        // alphabetical is good enough — the user already gets the
        // raw record under hover.
        return out.sorted()
    }

    private var helpText: String {
        var msg = "Repository: \(repo.name) — \(usageLabel(repo.usage))"
        if let live = liveValue {
            msg += "\nCurrent value: \(live.value)"
        }
        if let records {
            msg += "\nRows: \(records.count)"
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
