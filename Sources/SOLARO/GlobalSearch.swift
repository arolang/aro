// ============================================================
// GlobalSearch.swift
// SOLARO — toolbar search field + jump-to results panel
// ============================================================
//
// The toolbar's "Search" field is the primary jump-to UX in
// SOLARO. The user types a few characters and a results panel
// drops down directly under the field showing:
//
//   * Files        — every project source file whose name
//                    matches.
//   * Feature sets — every `(name: business activity)` header
//                    whose name or activity matches.
//   * Content      — line-level matches across *every* `.aro`
//                    file in the project (case-insensitive
//                    substring) annotated with the enclosing
//                    feature set name when one can be resolved.
//
// Selecting a result (Return or click/tap) opens the file,
// jumps to the right line, and dismisses the panel. Up / Down
// move the highlight; Escape closes the panel. The popover is
// borderless so it reads as a panel anchored to the field
// rather than a callout.

import SwiftUI
import AROParser

/// One hit shown in the search panel.
struct GlobalSearchHit: Identifiable, Hashable {
    let id: String
    let kind: Kind
    let url: URL
    let line: Int?

    /// Primary line of the row — the snippet for content hits,
    /// the file name for file hits, the FS name for FS hits.
    let headline: String

    /// The portion of `headline` that matched the query, used
    /// to bold the match in the rendered row. Both ends are
    /// inclusive offsets into `headline`.
    let highlightRange: Range<String.Index>?

    /// Breadcrumb under the headline: `file.aro:42 · FeatureSet`.
    let breadcrumb: String

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
    /// turn the panel into a wall of text.
    static let maxContentHitsPerFile = 8

    /// Across-the-project content match cap. Same idea, just
    /// at the project level.
    static let maxTotalContentHits = 80

    static func search(query: String,
                       controller: WorkspaceController) -> [GlobalSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        guard let model = controller.model else { return [] }
        var out: [GlobalSearchHit] = []
        let rootPath = model.root.rootPath.path

        // Files.
        for url in model.sourceFiles {
            let name = url.lastPathComponent
            if let range = name.lowercased().range(of: needle) {
                let mappedRange = mapRange(range, from: name.lowercased(),
                                            into: name)
                out.append(GlobalSearchHit(
                    id: "file:\(url.path)",
                    kind: .file,
                    url: url,
                    line: nil,
                    headline: name,
                    highlightRange: mappedRange,
                    breadcrumb: relativePath(url, root: rootPath)
                ))
            }
        }

        // Feature set names + business activities. Only files
        // whose programs have parsed are considered here — an
        // unparsed file can't surface FS headers anyway.
        for url in model.sourceFiles {
            guard let program = controller.programs[url] else { continue }
            for fs in program.featureSets {
                let nameMatch = fs.name.lowercased().range(of: needle)
                let actMatch = fs.businessActivity.lowercased().range(of: needle)
                guard nameMatch != nil || actMatch != nil else { continue }
                let lowerName = fs.name.lowercased()
                let mapped = nameMatch.map {
                    mapRange($0, from: lowerName, into: fs.name)
                }
                out.append(GlobalSearchHit(
                    id: "fs:\(url.path):\(fs.name)",
                    kind: .featureSet,
                    url: url,
                    line: fs.span.start.line,
                    headline: fs.name,
                    highlightRange: mapped,
                    breadcrumb: "\(fs.businessActivity)  ·  "
                        + "\(url.lastPathComponent):\(fs.span.start.line)"
                ))
            }
        }

        // Content — every file, not just cached ones.
        var contentHits = 0
        contentLoop: for url in model.sourceFiles {
            guard contentHits < maxTotalContentHits else { break }
            guard let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let program = controller.programs[url]
            var perFile = 0
            let lines = text.split(separator: "\n",
                                   omittingEmptySubsequences: false)
            for (idx, rawLine) in lines.enumerated() {
                guard perFile < maxContentHitsPerFile else { break }
                let line = String(rawLine)
                let lower = line.lowercased()
                guard let range = lower.range(of: needle) else { continue }
                let lineNumber = idx + 1
                let (snippet, snippetRange) =
                    snippet(line: line, lowerLine: lower, around: range)
                let fsName = program
                    .flatMap { enclosingFeatureSet(line: lineNumber, in: $0) }?
                    .name
                let breadcrumb: String
                if let fsName {
                    breadcrumb = "\(url.lastPathComponent):\(lineNumber)  ·  "
                        + fsName
                } else {
                    breadcrumb = "\(url.lastPathComponent):\(lineNumber)"
                }
                out.append(GlobalSearchHit(
                    id: "content:\(url.path):\(lineNumber)",
                    kind: .content,
                    url: url,
                    line: lineNumber,
                    headline: snippet,
                    highlightRange: snippetRange,
                    breadcrumb: breadcrumb
                ))
                perFile += 1
                contentHits += 1
                if contentHits >= maxTotalContentHits {
                    break contentLoop
                }
            }
        }

        return out
    }

    // MARK: - Helpers

    /// Trim a long source line down to ~90 chars centred on the
    /// match so the row stays compact, and return the range of
    /// the match inside the trimmed string for rendering.
    private static func snippet(
        line: String,
        lowerLine: String,
        around match: Range<String.Index>
    ) -> (String, Range<String.Index>?) {
        let trimmedLeading = line.drop(while: { $0.isWhitespace })
        let leadingDrop = line.distance(from: line.startIndex,
                                         to: trimmedLeading.startIndex)
        let trimmed = String(trimmedLeading)
        let target = 90
        let lower = lowerLine.dropFirst(leadingDrop)
        let matchStart = line.distance(from: line.startIndex,
                                        to: match.lowerBound) - leadingDrop
        let matchLen = line.distance(from: match.lowerBound,
                                      to: match.upperBound)
        guard matchStart >= 0 else {
            return (trimmed, nil)
        }
        if trimmed.count <= target {
            let start = trimmed.index(trimmed.startIndex,
                                      offsetBy: matchStart,
                                      limitedBy: trimmed.endIndex)
                ?? trimmed.endIndex
            let end = trimmed.index(start, offsetBy: matchLen,
                                    limitedBy: trimmed.endIndex)
                ?? trimmed.endIndex
            return (trimmed, start..<end)
        }
        let halfWindow = target / 2
        let startOffset = max(0, matchStart - halfWindow)
        let endOffset = min(trimmed.count, startOffset + target)
        let startIdx = trimmed.index(trimmed.startIndex,
                                      offsetBy: startOffset)
        let endIdx = trimmed.index(trimmed.startIndex, offsetBy: endOffset)
        var s = String(trimmed[startIdx..<endIdx])
        var leftEllipsis = false
        var rightEllipsis = false
        if startOffset > 0 {
            s = "…" + s
            leftEllipsis = true
        }
        if endOffset < trimmed.count {
            s += "…"
            rightEllipsis = true
        }
        _ = rightEllipsis
        let snippetMatchStart = matchStart - startOffset
            + (leftEllipsis ? 1 : 0)
        let snippetMatchEnd = snippetMatchStart + matchLen
        guard snippetMatchStart >= 0,
              snippetMatchEnd <= s.count
        else { return (s, nil) }
        let start = s.index(s.startIndex, offsetBy: snippetMatchStart)
        let end = s.index(s.startIndex, offsetBy: snippetMatchEnd)
        _ = lower
        return (s, start..<end)
    }

    /// Walk the feature sets of a program and return the one
    /// whose span contains the given source line.
    private static func enclosingFeatureSet(
        line: Int,
        in program: Program
    ) -> FeatureSet? {
        for fs in program.featureSets {
            if line >= fs.span.start.line && line <= fs.span.end.line {
                return fs
            }
        }
        return nil
    }

    /// Map a range inside the lowercased version of a string
    /// back onto the original-case string. Offsets are the same
    /// because `lowercased()` is character-by-character.
    private static func mapRange(
        _ r: Range<String.Index>,
        from lower: String,
        into original: String
    ) -> Range<String.Index> {
        let start = lower.distance(from: lower.startIndex,
                                    to: r.lowerBound)
        let end = lower.distance(from: lower.startIndex,
                                  to: r.upperBound)
        let s = original.index(original.startIndex, offsetBy: start)
        let e = original.index(original.startIndex, offsetBy: end)
        return s..<e
    }

    private static func relativePath(_ url: URL, root: String) -> String {
        let absolute = url.path
        if absolute.hasPrefix(root) {
            var rel = String(absolute.dropFirst(root.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel.isEmpty ? "(root)" : rel
        }
        return url.lastPathComponent
    }
}

/// Toolbar search field + results panel. Owned by
/// `WorkspaceView` so the panel state lives next to the other
/// toolbar state.
struct GlobalSearchField: View {
    @Bindable var controller: WorkspaceController
    let onOpenHit: (GlobalSearchHit) -> Void

    @State private var hits: [GlobalSearchHit] = []
    @State private var showPanel: Bool = false
    @State private var selectedIndex: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Search", text: $controller.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
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
                if showPanel {
                    showPanel = false
                    return .handled
                }
                return .ignored
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
            .popover(isPresented: $showPanel,
                     attachmentAnchor: .point(.bottom),
                     arrowEdge: .top) {
                resultsPanel
                    .frame(minWidth: 520, idealWidth: 600,
                           maxWidth: 720,
                           minHeight: 60, idealHeight: 420,
                           maxHeight: 520)
            }
    }

    private func refresh() {
        hits = GlobalSearchEngine.search(
            query: controller.searchText,
            controller: controller
        )
        showPanel = !controller.searchText.isEmpty
        selectedIndex = 0
    }

    // MARK: - Panel

    @ViewBuilder
    private var resultsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0,
                           pinnedViews: [.sectionHeaders]) {
                    if hits.isEmpty {
                        emptyState
                    } else {
                        ForEach(GlobalSearchHit.Kind.allCases, id: \.self) { kind in
                            let bucket = hits.filter { $0.kind == kind }
                            if !bucket.isEmpty {
                                Section {
                                    ForEach(bucket) { hit in
                                        row(hit)
                                            .id(hit.id)
                                    }
                                } header: {
                                    sectionHeader(title: kind.rawValue,
                                                  symbol: kind.symbol,
                                                  count: bucket.count)
                                }
                            }
                        }
                    }
                }
            }
            .background(SolaroColor.surface)
            .onChange(of: selectedIndex) { _, newValue in
                guard hits.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(hits[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SolaroColor.textTertiary)
            Text("No matches for “\(controller.searchText)”.")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SolaroSpace.m)
    }

    private func sectionHeader(title: String,
                               symbol: String,
                               count: Int) -> some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(title.uppercased())
                .font(SolaroFont.caption)
                .tracking(2)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(SolaroColor.textTertiary.opacity(0.12))
                )
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.top, SolaroSpace.s)
        .padding(.bottom, SolaroSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SolaroColor.surface)
    }

    private func row(_ hit: GlobalSearchHit) -> some View {
        let globalIdx = hits.firstIndex(of: hit) ?? -1
        let isSelected = globalIdx == selectedIndex
        return Button {
            deliver(hit)
        } label: {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                Image(systemName: hit.kind.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected
                                     ? Color.white
                                     : SolaroColor.textSecondary)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    headlineText(hit, isSelected: isSelected)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(hit.breadcrumb)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(isSelected
                                         ? Color.white.opacity(0.85)
                                         : SolaroColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let line = hit.line {
                    Text(":\(line)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(isSelected
                                         ? Color.white.opacity(0.8)
                                         : SolaroColor.textTertiary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SolaroSpace.m)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? SolaroColor.accent
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering, let idx = hits.firstIndex(of: hit) {
                selectedIndex = idx
            }
        }
    }

    @ViewBuilder
    private func headlineText(_ hit: GlobalSearchHit,
                              isSelected: Bool) -> some View {
        let primaryColor: Color = isSelected
            ? Color.white
            : SolaroColor.textPrimary
        if let r = hit.highlightRange,
           r.lowerBound >= hit.headline.startIndex,
           r.upperBound <= hit.headline.endIndex {
            let prefix = String(hit.headline[..<r.lowerBound])
            let match = String(hit.headline[r])
            let suffix = String(hit.headline[r.upperBound...])
            let highlightFill: Color = isSelected
                ? Color.white.opacity(0.22)
                : SolaroColor.accent.opacity(0.22)
            let highlightFG: Color = isSelected
                ? Color.white
                : SolaroColor.textPrimary
            (Text(prefix).foregroundStyle(primaryColor)
                + Text(match)
                    .foregroundStyle(highlightFG)
                    .fontWeight(.semibold)
                + Text(suffix).foregroundStyle(primaryColor))
                .font(SolaroFont.body)
                .background(
                    GeometryReader { _ in
                        Color.clear
                    }
                )
                .padding(.vertical, 0)
                .overlay(alignment: .topLeading) {
                    EmptyView()
                }
                .background(
                    HighlightUnderlay(text: hit.headline,
                                       range: r,
                                       fill: highlightFill)
                )
        } else {
            Text(hit.headline)
                .font(SolaroFont.body)
                .foregroundStyle(primaryColor)
        }
    }

    private func deliver(_ hit: GlobalSearchHit) {
        showPanel = false
        focused = false
        onOpenHit(hit)
    }
}

/// Paints a soft fill behind the matched substring of a row's
/// headline. Sized by measuring the prefix vs. match widths
/// with the same font the headline renders in, so the
/// highlight tracks the actual glyph run even when the row is
/// resized.
private struct HighlightUnderlay: View {
    let text: String
    let range: Range<String.Index>
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            let prefix = String(text[..<range.lowerBound])
            let match = String(text[range])
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let prefixWidth = (prefix as NSString).size(withAttributes: attrs).width
            let matchWidth = (match as NSString).size(withAttributes: attrs).width
            let maxWidth = max(0, geo.size.width - prefixWidth)
            let clipped = min(matchWidth, maxWidth)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(fill)
                .frame(width: clipped, height: geo.size.height)
                .offset(x: prefixWidth, y: 0)
        }
    }
}
