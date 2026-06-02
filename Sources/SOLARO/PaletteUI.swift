// ============================================================
// PaletteUI.swift
// SOLARO — shared widgets for keyboard-driven picker sheets
// ============================================================
//
// Backbone for the command palette (#235), the quick-open file
// picker (#236), and the find-in-project results (#237). Each
// reuses the same row + fuzzy-match logic; the differing parts
// are the data source + the action a row fires.

import SwiftUI

/// One row in a palette. Generic over an opaque "payload" the
/// action closure can capture — usually a command, a file URL,
/// or a search-result reference.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String?
    /// Right-aligned monospaced trailing text — used for shortcut
    /// reminders or hit counts.
    let trailing: String?
    /// SF Symbol shown left of the title; nil hides the icon slot.
    let symbol: String?
    let action: @MainActor () -> Void
}

/// Case-insensitive subsequence match. Returns true when every
/// character of `query` appears in `haystack` in order. Empty
/// query matches everything.
func fuzzyMatches(_ query: String, in haystack: String) -> Bool {
    if query.isEmpty { return true }
    let q = Array(query.lowercased())
    let h = Array(haystack.lowercased())
    var qi = 0
    for ch in h {
        if qi == q.count { break }
        if ch == q[qi] { qi += 1 }
    }
    return qi == q.count
}

/// Rough fuzzy score — higher is better. Rewards consecutive
/// matches + matches at word boundaries. Good enough for ranking
/// command + file lists at SOLARO project sizes.
func fuzzyScore(_ query: String, in haystack: String) -> Int {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let h = Array(haystack.lowercased())
    var score = 0
    var qi = 0
    var lastMatched = -2
    var prevHaystackChar: Character = " "
    for (idx, ch) in h.enumerated() {
        defer { prevHaystackChar = ch }
        if qi == q.count { break }
        if ch == q[qi] {
            qi += 1
            score += 1
            if idx == lastMatched + 1 { score += 5 }       // consecutive
            if prevHaystackChar == " " || prevHaystackChar == "/" { score += 3 }  // word start
            lastMatched = idx
        }
    }
    if qi < q.count { return Int.min }
    return score
}

struct PaletteView: View {
    let title: String
    let placeholder: String
    let items: [PaletteItem]
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    private var filtered: [PaletteItem] {
        let scored: [(PaletteItem, Int)] = items.compactMap { item in
            let haystack = [item.title,
                            item.subtitle ?? "",
                            item.category ?? ""]
                .joined(separator: " ")
            let score = fuzzyScore(query, in: haystack)
            guard score > Int.min else { return nil }
            return (item, score)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            list
        }
        .frame(width: 580, height: 460)
        .background(SolaroColor.surface)
        .onAppear {
            queryFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "command.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(SolaroColor.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .tracking(2)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(SolaroFont.body)
                    .focused($queryFocused)
                    .onSubmit { fireSelected() }
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            VStack {
                Spacer()
                Text("No matches.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { idx, item in
                            PaletteRow(item: item, selected: idx == selectedIndex)
                                .id(idx)
                                .onTapGesture {
                                    selectedIndex = idx
                                    fireSelected()
                                }
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }

    private func fireSelected() {
        guard !filtered.isEmpty,
              filtered.indices.contains(selectedIndex)
        else { return }
        filtered[selectedIndex].action()
        onClose()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(selected
                                     ? SolaroColor.textPrimary
                                     : SolaroColor.textSecondary)
                    .frame(width: 16, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let category = item.category {
                        Text(category)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SolaroColor.divider)
                            .clipShape(Capsule())
                    }
                    Text(item.title)
                        .font(SolaroFont.body)
                        .foregroundStyle(selected
                                         ? SolaroColor.textPrimary
                                         : SolaroColor.textPrimary)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let trailing = item.trailing {
                Text(trailing)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected
                ? SolaroColor.selection.opacity(0.6)
                : Color.clear
        )
    }
}
