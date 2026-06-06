// ============================================================
// GlobalSearch.swift
// SOLARO — toolbar search field with files / symbols / hits
// ============================================================
//
// The toolbar's "Search" field is the primary jump-to UX in
// SOLARO. The user types a few characters and gets a popover
// with three sections:
//
//   * Files        — every project source file whose name
//                    matches.
//   * Feature sets — every `(name: business activity)` header
//                    whose name or activity matches.
//   * Content      — line-level matches across all `.aro`
//                    files in the project (case-insensitive
//                    substring; rendered with the hit
//                    surrounded by `…`).
//
// Selecting a result opens the file, jumps to the right line,
// and dismisses the popover. The search itself runs
// synchronously on the controller's cached `programs` dict so
// no IO happens per keystroke for the file / symbol passes;
// the content pass reads files lazily (only the ones whose
// programs are loaded) and caps total hits per file at a
// small number so a giant CSV-laden project doesn't choke
// the popover.

import SwiftUI
import AROParser

/// One hit shown in the search popover.
struct GlobalSearchHit: Identifiable, Hashable {
    let id: String
    let kind: Kind
    let label: String
    let detail: String
    let url: URL
    let line: Int?

    enum Kind: String, CaseIterable {
        case file = "Files"
        case featureSet = "Feature sets"
        case content = "Content"

        var symbol: String {
            switch self {
            case .file:       return "doc.text"
            case .featureSet: return "square.grid.2x2"
            case .content:    return "text.magnifyingglass"
            }
        }
    }
}

/// Walks the project and produces hits for a given query.
/// Pure value-level work — keeps the SwiftUI view side
/// rendering-only.
@MainActor
enum GlobalSearchEngine {

    /// Per-file content match cap. Without this a query like
    /// "the" on a project with thousands of statements would
    /// turn the popover into a wall of text.
    static let maxContentHitsPerFile = 5

    /// Across-the-project content match cap. Same idea, just at
    /// the project level so we don't render hundreds of rows.
    static let maxTotalContentHits = 30

    static func search(query: String,
                       controller: WorkspaceController) -> [GlobalSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        guard let model = controller.model else { return [] }
        var out: [GlobalSearchHit] = []

        // Files
        for url in model.sourceFiles {
            let name = url.lastPathComponent
            if name.lowercased().contains(needle) {
                out.append(GlobalSearchHit(
                    id: "file:\(url.path)",
                    kind: .file,
                    label: name,
                    detail: relativePath(url, root: model.root.rootPath),
                    url: url,
                    line: nil
                ))
            }
        }

        // Feature set names + business activities.
        for url in model.sourceFiles {
            guard let program = controller.programs[url] else { continue }
            for fs in program.featureSets {
                if fs.name.lowercased().contains(needle)
                    || fs.businessActivity.lowercased().contains(needle) {
                    out.append(GlobalSearchHit(
                        id: "fs:\(url.path):\(fs.name)",
                        kind: .featureSet,
                        label: fs.name,
                        detail: "\(fs.businessActivity) · \(url.lastPathComponent)",
                        url: url,
                        line: fs.span.start.line
                    ))
                }
            }
        }

        // Content matches. We only walk files whose programs are
        // already cached — keeps the per-keystroke cost bounded.
        var contentHits = 0
        contentLoop: for url in model.sourceFiles {
            guard contentHits < maxTotalContentHits else { break }
            guard controller.programs[url] != nil else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            var perFile = 0
            for (idx, rawLine) in text.split(separator: "\n",
                                             omittingEmptySubsequences: false)
                .enumerated() {
                guard perFile < maxContentHitsPerFile else { break }
                let line = String(rawLine)
                if line.lowercased().contains(needle) {
                    out.append(GlobalSearchHit(
                        id: "content:\(url.path):\(idx + 1)",
                        kind: .content,
                        label: snippet(line, around: needle),
                        detail: "\(url.lastPathComponent):\(idx + 1)",
                        url: url,
                        line: idx + 1
                    ))
                    perFile += 1
                    contentHits += 1
                    if contentHits >= maxTotalContentHits {
                        break contentLoop
                    }
                }
            }
        }

        return out
    }

    /// Trim a long source line down to ~80 chars centred on the
    /// match so the popover row stays compact.
    private static func snippet(_ line: String,
                                around needle: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let target: Int = 80
        guard trimmed.count > target else { return trimmed }
        let lower = trimmed.lowercased()
        guard let range = lower.range(of: needle) else {
            return String(trimmed.prefix(target)) + "…"
        }
        let matchStart = trimmed.distance(from: trimmed.startIndex,
                                          to: range.lowerBound)
        let halfWindow = target / 2
        let startOffset = max(0, matchStart - halfWindow)
        let endOffset = min(trimmed.count, startOffset + target)
        let start = trimmed.index(trimmed.startIndex,
                                  offsetBy: startOffset)
        let end = trimmed.index(trimmed.startIndex,
                                offsetBy: endOffset)
        var s = String(trimmed[start..<end])
        if startOffset > 0 { s = "…" + s }
        if endOffset < trimmed.count { s += "…" }
        return s
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let absolute = url.path
        let rootPath = root.path
        if absolute.hasPrefix(rootPath) {
            var rel = String(absolute.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel.isEmpty ? "(root)" : rel
        }
        return url.lastPathComponent
    }
}

/// Toolbar search field + result popover. Owned by
/// `WorkspaceView` so the popover state lives next to the
/// other toolbar state and a single ⌘F lands focus + opens the
/// popover.
struct GlobalSearchField: View {
    @Bindable var controller: WorkspaceController
    let onOpenHit: (GlobalSearchHit) -> Void

    @State private var hits: [GlobalSearchHit] = []
    @State private var showPopover: Bool = false
    @State private var selectedIndex: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Search", text: $controller.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .focused($focused)
            .onChange(of: controller.searchText) { _, _ in
                refresh()
            }
            .onSubmit {
                guard !hits.isEmpty else { return }
                let idx = max(0, min(selectedIndex, hits.count - 1))
                deliver(hits[idx])
            }
            .onKeyPress(.escape) {
                showPopover = false
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !hits.isEmpty else { return .ignored }
                selectedIndex = min(selectedIndex + 1, hits.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !hits.isEmpty else { return .ignored }
                selectedIndex = max(selectedIndex - 1, 0)
                return .handled
            }
            .popover(isPresented: $showPopover,
                     attachmentAnchor: .point(.bottom),
                     arrowEdge: .top) {
                resultsPopover
                    .frame(minWidth: 460, idealWidth: 520,
                           minHeight: 60, idealHeight: 360)
            }
    }

    private func refresh() {
        hits = GlobalSearchEngine.search(
            query: controller.searchText,
            controller: controller
        )
        showPopover = !hits.isEmpty
        selectedIndex = 0
    }

    private var resultsPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GlobalSearchHit.Kind.allCases, id: \.self) { kind in
                let bucket = hits.filter { $0.kind == kind }
                if !bucket.isEmpty {
                    section(title: kind.rawValue,
                            symbol: kind.symbol,
                            hits: bucket)
                }
            }
            if hits.isEmpty {
                Text("No matches.")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .padding(SolaroSpace.m)
            }
        }
        .padding(.vertical, SolaroSpace.xs)
        .background(SolaroColor.surface)
    }

    private func section(title: String,
                         symbol: String,
                         hits: [GlobalSearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(SolaroColor.textTertiary)
                Text(title.uppercased())
                    .font(SolaroFont.caption)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .padding(.horizontal, SolaroSpace.m)
            .padding(.top, SolaroSpace.s)
            .padding(.bottom, SolaroSpace.xs)
            ForEach(hits) { hit in
                row(hit)
            }
        }
    }

    private func row(_ hit: GlobalSearchHit) -> some View {
        let globalIdx = hits.firstIndex(of: hit) ?? -1
        let isSelected = globalIdx == selectedIndex
        return Button {
            deliver(hit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.label)
                    .font(SolaroFont.body)
                    .foregroundStyle(isSelected
                                     ? Color.white
                                     : SolaroColor.textPrimary)
                    .lineLimit(1)
                Text(hit.detail)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(isSelected
                                     ? Color.white.opacity(0.8)
                                     : SolaroColor.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? SolaroColor.accent
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    private func deliver(_ hit: GlobalSearchHit) {
        showPopover = false
        focused = false
        onOpenHit(hit)
    }
}
