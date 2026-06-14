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
// move the highlight; Escape closes the panel. Hits, the
// highlight index, and the visibility flag all live on
// `WorkspaceController` so the toolbar TextField and the
// body-level results panel can share state without going
// through bindings or PreferenceKeys.
//
// Why not a popover? SwiftUI popovers anchored to a SwiftUI
// view that lives inside a macOS `ToolbarItem` don't reliably
// display — the toolbar item hosts the field in a separate
// NSView tree that strips popover attachments. So the panel
// is rendered as a body overlay in `WorkspaceView` instead.

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
    /// to bold the match in the rendered row. nil when we
    /// couldn't compute it (e.g. the match got trimmed out of
    /// the snippet window).
    let highlightRange: Range<String.Index>?

    /// Breadcrumb under the headline: `file.aro:42 · FeatureSet`.
    let breadcrumb: String

    /// Set when this hit points into a book chapter instead of a
    /// project source file. The dispatch site checks this first
    /// and opens the BookWindow + jumps to the chapter when it's
    /// non-nil; otherwise it falls back to the normal file-open
    /// path.
    let bookContext: BookContext?

    /// Identifies which book + chapter (and the matched line in
    /// that chapter) a `Kind.book` hit refers to.
    struct BookContext: Hashable {
        let bookID: String
        let chapterID: String
        /// 1-indexed line number inside the chapter's markdown.
        /// Best-effort; the viewer doesn't currently scroll to
        /// it, but the field is recorded so a later viewer with
        /// in-chapter highlighting can use it without a search
        /// rebuild.
        let chapterLine: Int?
    }

    enum Kind: String, CaseIterable {
        case file = "Files"
        case featureSet = "Feature sets"
        case content = "Content"
        case book = "Books"

        var symbol: String {
            switch self {
            case .file:       return "doc.text"
            case .featureSet: return "square.grid.2x2"
            case .content:    return "text.magnifyingglass"
            case .book:       return "book"
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
                    breadcrumb: relativePath(url, root: rootPath),
                    bookContext: nil
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
                        + "\(url.lastPathComponent):\(fs.span.start.line)",
                    bookContext: nil
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
                    breadcrumb: breadcrumb,
                    bookContext: nil
                ))
                perFile += 1
                contentHits += 1
                if contentHits >= maxTotalContentHits {
                    break contentLoop
                }
            }
        }

        // Books — walk every known book's cached chapters. We
        // only see books the user has already downloaded; an
        // un-downloaded book has no `chapters`, so it
        // self-skips. Capped per-book + total the same way file
        // content hits are capped.
        out.append(contentsOf: searchBooks(needle: needle))

        return out
    }

    /// Per-book chapter-line cap. Mirrors `maxContentHitsPerFile`
    /// so a query like "the" doesn't drown the panel in a single
    /// long appendix.
    static let maxBookHitsPerChapter = 6
    static let maxTotalBookHits = 60

    static func searchBooks(needle: String) -> [GlobalSearchHit] {
        var out: [GlobalSearchHit] = []
        var total = 0
        bookLoop: for book in Book.all {
            let store = BookStoreRegistry.store(for: book)
            for chapter in store.chapters {
                if total >= maxTotalBookHits { break bookLoop }
                // Cheap title match first — surfaces "Appendix
                // A" when the user types "appendix" without
                // dragging the whole body through the matcher.
                if let titleRange = chapter.title
                    .lowercased().range(of: needle)
                {
                    let mapped = mapRange(
                        titleRange,
                        from: chapter.title.lowercased(),
                        into: chapter.title)
                    out.append(GlobalSearchHit(
                        id: "book:\(book.id):\(chapter.id):title",
                        kind: .book,
                        url: URL(fileURLWithPath: "/"),
                        line: nil,
                        headline: chapter.title,
                        highlightRange: mapped,
                        breadcrumb: book.title,
                        bookContext: GlobalSearchHit.BookContext(
                            bookID: book.id,
                            chapterID: chapter.id,
                            chapterLine: nil)
                    ))
                    total += 1
                    if total >= maxTotalBookHits { break bookLoop }
                }
                // Body lines.
                let lines = chapter.markdown.split(
                    separator: "\n",
                    omittingEmptySubsequences: false)
                var perChapter = 0
                for (idx, rawLine) in lines.enumerated() {
                    if perChapter >= maxBookHitsPerChapter { break }
                    let line = String(rawLine)
                    let lower = line.lowercased()
                    guard let range = lower.range(of: needle)
                    else { continue }
                    let (snippet, snippetRange) =
                        snippet(line: line, lowerLine: lower, around: range)
                    let lineNumber = idx + 1
                    out.append(GlobalSearchHit(
                        id: "book:\(book.id):\(chapter.id):\(lineNumber)",
                        kind: .book,
                        url: URL(fileURLWithPath: "/"),
                        line: lineNumber,
                        headline: snippet,
                        highlightRange: snippetRange,
                        breadcrumb: "\(book.title)  ·  \(chapter.title)",
                        bookContext: GlobalSearchHit.BookContext(
                            bookID: book.id,
                            chapterID: chapter.id,
                            chapterLine: lineNumber)
                    ))
                    perChapter += 1
                    total += 1
                    if total >= maxTotalBookHits { break bookLoop }
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
        if startOffset > 0 {
            s = "…" + s
            leftEllipsis = true
        }
        if endOffset < trimmed.count { s += "…" }
        let snippetMatchStart = matchStart - startOffset
            + (leftEllipsis ? 1 : 0)
        let snippetMatchEnd = snippetMatchStart + matchLen
        guard snippetMatchStart >= 0,
              snippetMatchEnd <= s.count
        else { return (s, nil) }
        let start = s.index(s.startIndex, offsetBy: snippetMatchStart)
        let end = s.index(s.startIndex, offsetBy: snippetMatchEnd)
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

// MARK: - Toolbar TextField

/// Toolbar TextField — owns no panel UI; just updates the
/// controller's search state. The actual results panel is
/// rendered as a body overlay in `WorkspaceView`.
struct GlobalSearchField: View {
    @Bindable var controller: WorkspaceController
    let onOpenHit: (GlobalSearchHit) -> Void

    var body: some View {
        TextField("Search", text: $controller.searchText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 260)
            .onChange(of: controller.searchText) { _, _ in
                refresh()
            }
            .onSubmit {
                openSelectedHit()
            }
            .onKeyPress(.escape) {
                if controller.globalSearchPanelVisible {
                    closePanel()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                guard !controller.globalSearchHits.isEmpty
                else { return .ignored }
                controller.globalSearchSelectedIndex = min(
                    controller.globalSearchSelectedIndex + 1,
                    controller.globalSearchHits.count - 1
                )
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !controller.globalSearchHits.isEmpty
                else { return .ignored }
                controller.globalSearchSelectedIndex = max(
                    controller.globalSearchSelectedIndex - 1,
                    0
                )
                return .handled
            }
    }

    private func refresh() {
        controller.globalSearchHits = GlobalSearchEngine.search(
            query: controller.searchText,
            controller: controller
        )
        controller.globalSearchPanelVisible = !controller.searchText.isEmpty
        controller.globalSearchSelectedIndex = 0
    }

    private func openSelectedHit() {
        let hits = controller.globalSearchHits
        guard !hits.isEmpty else { return }
        let idx = max(0, min(controller.globalSearchSelectedIndex,
                              hits.count - 1))
        deliver(hits[idx])
    }

    private func closePanel() {
        controller.globalSearchPanelVisible = false
    }

    private func deliver(_ hit: GlobalSearchHit) {
        controller.globalSearchPanelVisible = false
        onOpenHit(hit)
    }
}

// MARK: - Body overlay panel

/// Results panel rendered as a top-trailing overlay on the
/// workspace body. Visible whenever
/// `controller.globalSearchPanelVisible` is true; otherwise
/// the caller should branch on the same flag and not render
/// us at all.
struct GlobalSearchPanel: View {
    @Bindable var controller: WorkspaceController
    let onOpenHit: (GlobalSearchHit) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0,
                               pinnedViews: [.sectionHeaders]) {
                        let hits = controller.globalSearchHits
                        if hits.isEmpty {
                            emptyState
                        } else {
                            ForEach(GlobalSearchHit.Kind.allCases,
                                    id: \.self) { kind in
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
                .onChange(of: controller.globalSearchSelectedIndex) { _, idx in
                    let hits = controller.globalSearchHits
                    guard hits.indices.contains(idx) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(hits[idx].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SolaroColor.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SolaroColor.textTertiary.opacity(0.3))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
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
        let hits = controller.globalSearchHits
        let globalIdx = hits.firstIndex(of: hit) ?? -1
        let isSelected = globalIdx == controller.globalSearchSelectedIndex
        return Button {
            controller.globalSearchPanelVisible = false
            onOpenHit(hit)
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
            if hovering, let idx = controller.globalSearchHits.firstIndex(of: hit) {
                controller.globalSearchSelectedIndex = idx
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
            let highlightFG: Color = isSelected
                ? Color.white
                : SolaroColor.textPrimary
            (Text(prefix).foregroundStyle(primaryColor)
                + Text(match)
                    .foregroundStyle(highlightFG)
                    .fontWeight(.bold)
                + Text(suffix).foregroundStyle(primaryColor))
                .font(SolaroFont.body)
        } else {
            Text(hit.headline)
                .font(SolaroFont.body)
                .foregroundStyle(primaryColor)
        }
    }
}
