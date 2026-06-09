// ============================================================
// Books.swift
// SOLARO — in-app book viewer + on-demand GitHub downloader
// ============================================================
//
// Each book under the upstream repo's `Book/` directory shows up
// here as a `Book` entry. The first time the user opens one of
// them (via the Help menu), SOLARO walks the GitHub Contents API,
// downloads every `*.md` chapter into Application Support, and
// renders them with the same SwiftUI viewer the bundled
// Language Guide used. The Settings panel adds a "Refresh now"
// button that re-downloads on demand so the user can pull in
// edits without restarting.

import SwiftUI
import AppKit
import Foundation

/// One book the Help menu can open. `slug` doubles as the
/// directory name in the upstream repo and the local cache.
struct Book: Identifiable, Hashable {
    let id: String          // slug
    let title: String
    let blurb: String
    /// SF Symbol for the menu / window toolbar.
    let symbol: String

    /// All known books. Source of truth — add an entry here when
    /// a new book lands under `Book/` upstream. The Help menu and
    /// Settings "Books" section both iterate this list.
    static let all: [Book] = [
        .init(id: "TheLanguageGuide",
              title: "The Language Guide",
              blurb: "Long-form reference for every construct in ARO.",
              symbol: "book"),
        .init(id: "TheEssentialPrimer",
              title: "The Essential Primer",
              blurb: "Quick tour of ARO for newcomers.",
              symbol: "book.pages"),
        .init(id: "TheConstructionStudies",
              title: "The Construction Studies",
              blurb: "Building real applications, step by step.",
              symbol: "hammer"),
        .init(id: "TheDebuggingGuide",
              title: "The Debugging Guide",
              blurb: "Reading the canvas, the JSONL recorder, and the LSP.",
              symbol: "ant"),
        .init(id: "TheInteractiveDialog",
              title: "The Interactive Dialog",
              blurb: "Conversational walkthrough of ARO design decisions.",
              symbol: "bubble.left.and.bubble.right"),
        .init(id: "ThePluginGuide",
              title: "The Plugin Guide",
              blurb: "Writing Swift, Rust, C, and Python plugins.",
              symbol: "puzzlepiece.extension"),
        .init(id: "TheShortStudies",
              title: "The Short Studies",
              blurb: "Bite-sized explorations of language corners.",
              symbol: "doc.plaintext"),
        .init(id: "Reference",
              title: "Reference",
              blurb: "Action / verb / preposition tables.",
              symbol: "books.vertical"),
        .init(id: "AROByExample",
              title: "ARO by Example",
              blurb: "Idiomatic ARO patterns paired with examples.",
              symbol: "list.bullet.rectangle"),
        .init(id: "AROByHallucination",
              title: "ARO by Hallucination",
              blurb: "Pairing a local model with ARO's tool calling.",
              symbol: "sparkles"),
    ]
}

/// One chapter inside a book — typically a single `*.md` file.
struct BookChapter: Identifiable, Hashable {
    /// Stable identifier from the filename (without the `.md`
    /// extension) so SwiftUI selection persists across reloads.
    let id: String
    /// Display title — usually the first `# Heading` if present,
    /// otherwise the prettified filename.
    let title: String
    let markdown: String
}

/// On-disk + over-the-network store for one book. Mirrors the
/// upstream repo's `Book/<slug>/*.md` layout under
/// `~/Library/Application Support/SOLARO/books/<slug>/`. Loading
/// is synchronous (it just reads the cached directory); refresh
/// is async and fires through `URLSession`.
@MainActor
@Observable
final class BookStore {
    let book: Book

    /// Loaded chapters, sorted by filename so `Chapter01-…`
    /// reliably comes before `Chapter02-…`.
    private(set) var chapters: [BookChapter] = []
    /// True while a refresh is in flight. The window's toolbar
    /// shows a spinner; trying to start a second refresh while
    /// `isRefreshing` is true is a no-op.
    private(set) var isRefreshing: Bool = false
    /// Last refresh error message — surfaced as a banner in the
    /// viewer so the user knows the local copy might be stale.
    private(set) var lastError: String?
    /// Wall-clock time the cache was last written. `nil` when no
    /// cache exists yet (first-run state).
    private(set) var lastRefreshed: Date?

    init(book: Book) {
        self.book = book
        load()
    }

    /// Re-read chapters from the on-disk cache. Cheap — just a
    /// directory enumeration. Called after `refresh()` succeeds
    /// and at init time.
    func load() {
        let dir = Self.cacheDirectory(for: book)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path)
        else { chapters = []; return }
        var out: [BookChapter] = []
        for name in names.sorted() where name.hasSuffix(".md") {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            out.append(BookChapter(
                id: String(name.dropLast(3)),
                title: Self.title(from: text, fallback: name),
                markdown: text
            ))
        }
        chapters = out
        // Attribute the directory's modification time as "last
        // refreshed" — close enough to what the user expects.
        if let mtime = try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date {
            lastRefreshed = mtime
        }
    }

    /// Pull the latest copy of every chapter from GitHub. Walks
    /// the Contents API to enumerate the book's files (no `git`
    /// dependency), downloads each one, and replaces the local
    /// cache atomically. Errors surface as `lastError`.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let listingURL = URL(string:
            "https://api.github.com/repos/arolang/aro/contents/Book/\(book.id)?ref=main"
        )!
        var listing: [GitHubContentEntry]
        do {
            var request = URLRequest(url: listingURL)
            request.setValue("application/vnd.github+json",
                             forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            listing = try JSONDecoder().decode(
                [GitHubContentEntry].self, from: data
            )
        } catch {
            lastError = "Couldn't list \(book.id) on GitHub: \(error.localizedDescription)"
            return
        }

        // Write to a fresh temp directory first, then atomically
        // swap it for the live cache. Partial-download recovery:
        // if the request fails mid-way, the old cache is intact.
        let fm = FileManager.default
        let cacheDir = Self.cacheDirectory(for: book)
        let stagingDir = cacheDir
            .deletingLastPathComponent()
            .appendingPathComponent(".staging-\(book.id)-\(UUID().uuidString)")
        do {
            try fm.createDirectory(
                at: stagingDir, withIntermediateDirectories: true
            )
        } catch {
            lastError = "Couldn't create staging directory: \(error.localizedDescription)"
            return
        }

        for entry in listing where entry.name.hasSuffix(".md") {
            guard let downloadURL = entry.download_url,
                  let url = URL(string: downloadURL)
            else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let dest = stagingDir.appendingPathComponent(entry.name)
                try data.write(to: dest, options: [.atomic])
            } catch {
                lastError = "Failed to download \(entry.name): \(error.localizedDescription)"
                try? fm.removeItem(at: stagingDir)
                return
            }
        }

        // Atomic swap: move the old cache out of the way, move
        // staging into place, then nuke the backup. Two renames
        // is faster (and safer on quota-strict volumes) than
        // copying every file in.
        let backupDir = cacheDir
            .deletingLastPathComponent()
            .appendingPathComponent(".backup-\(book.id)-\(UUID().uuidString)")
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.moveItem(at: cacheDir, to: backupDir)
        }
        do {
            try fm.createDirectory(
                at: cacheDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.moveItem(at: stagingDir, to: cacheDir)
        } catch {
            // Roll back to the previous cache so the user doesn't
            // see an empty viewer after a failed atomic swap.
            if fm.fileExists(atPath: backupDir.path) {
                try? fm.moveItem(at: backupDir, to: cacheDir)
            }
            lastError = "Couldn't finalise refresh: \(error.localizedDescription)"
            return
        }
        try? fm.removeItem(at: backupDir)

        lastRefreshed = Date()
        load()
    }

    // MARK: - Helpers

    /// Lift the first `# Heading` out of the markdown for the
    /// chapter list label. Falls back to a prettified filename
    /// (`Chapter05-RawStrings.md` → `Chapter05 - Raw Strings`)
    /// so even un-headed files look reasonable.
    private static func title(from markdown: String, fallback: String) -> String {
        for raw in markdown.split(separator: "\n").prefix(8) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return prettify(fallback)
    }

    private static func prettify(_ filename: String) -> String {
        var name = filename
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        // Replace hyphens with " · " so the prefix (Chapter05) and
        // the actual title are visually separated.
        if let dash = name.firstIndex(of: "-") {
            let prefix = name[..<dash]
            let rest = name[name.index(after: dash)...]
            return "\(prefix) · \(rest)"
        }
        return name
    }

    /// Application Support directory for one book's cache.
    static func cacheDirectory(for book: Book) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SOLARO")
            .appendingPathComponent("books")
            .appendingPathComponent(book.id)
    }

    /// Subset of GitHub Contents API entry we care about.
    private struct GitHubContentEntry: Decodable {
        let name: String
        let type: String
        let download_url: String?
    }
}

/// `BookStore` instances are scoped per Book — sharing instances
/// keeps refresh state visible across the menu, settings, and
/// viewer window.
@MainActor
enum BookStoreRegistry {
    private static var stores: [String: BookStore] = [:]

    static func store(for book: Book) -> BookStore {
        if let existing = stores[book.id] { return existing }
        let s = BookStore(book: book)
        stores[book.id] = s
        return s
    }
}

@MainActor
final class BookWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show(_ book: Book) {
        if let existing = windows[book.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let store = BookStoreRegistry.store(for: book)
        let host = NSHostingController(rootView: BookView(store: store))
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 920, height: 640))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = book.title
        w.center()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { _ in BookWindow.windows.removeValue(forKey: book.id) }
        windows[book.id] = w
        w.makeKeyAndOrderFront(nil)
        // First open: if the cache is empty, kick off a download
        // so the window doesn't sit on a "Pick a chapter" empty
        // state. Subsequent opens reuse what's on disk; the user
        // refreshes manually via the toolbar button.
        if store.chapters.isEmpty {
            Task { await store.refresh() }
        }
    }
}

private struct BookView: View {
    @Bindable var store: BookStore
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(store.book.title)
        .onAppear {
            if selection == nil {
                selection = store.chapters.first?.id
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            List(selection: $selection) {
                if store.chapters.isEmpty {
                    Text(store.isRefreshing
                         ? "Downloading…"
                         : "No chapters yet — click Refresh.")
                        .font(SolaroFont.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(store.chapters) { chapter in
                        NavigationLink(value: chapter.id) {
                            Text(chapter.title)
                                .font(SolaroFont.body)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        }
    }

    private var toolbar: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: store.book.symbol)
                .foregroundStyle(SolaroColor.accent)
            Text(store.book.title)
                .font(SolaroFont.sectionTitle)
                .tracking(1)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .help("Re-download from github.com/arolang/aro")
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, SolaroSpace.xs)
    }

    @ViewBuilder
    private var detail: some View {
        if let err = store.lastError {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SolaroColor.stateWarn)
                Text("The viewer is showing the previous local copy.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(SolaroSpace.l)
        }
        if let chapter = store.chapters.first(where: { $0.id == selection }) {
            ScrollView {
                BookChapterView(chapter: chapter)
                    .padding(SolaroSpace.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Spacer()
                Text(store.chapters.isEmpty
                     ? "No chapters cached yet."
                     : "Pick a chapter on the left.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Settings tab — list every known book with its last-refresh
/// time and a "Refresh now" button. `Refresh All` at the top
/// runs every store's `refresh()` in parallel.
struct BooksSettingsTab: View {
    @State private var stores: [BookStore] = []
    @State private var refreshingAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            HStack {
                Text("Books are downloaded from github.com/arolang/aro and cached locally.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refreshAll() }
                } label: {
                    if refreshingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(refreshingAll)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SolaroSpace.s) {
                    ForEach(stores, id: \.book.id) { store in
                        BookRow(store: store)
                    }
                }
            }
        }
        .onAppear { loadStores() }
    }

    private func loadStores() {
        stores = Book.all.map { BookStoreRegistry.store(for: $0) }
    }

    private func refreshAll() async {
        refreshingAll = true
        defer { refreshingAll = false }
        await withTaskGroup(of: Void.self) { group in
            for store in stores {
                group.addTask { await store.refresh() }
            }
        }
    }
}

private struct BookRow: View {
    @Bindable var store: BookStore

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.s) {
            Image(systemName: store.book.symbol)
                .font(.system(size: 16))
                .foregroundStyle(SolaroColor.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.book.title)
                    .font(SolaroFont.bodyBold)
                Text(store.book.blurb)
                    .font(SolaroFont.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: SolaroSpace.s) {
                    Text("\(store.chapters.count) chapters")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(.secondary)
                    if let date = store.lastRefreshed {
                        Text("· last refreshed \(Self.dateFormatter.string(from: date))")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("· never downloaded")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.stateWarn)
                    }
                }
                if let err = store.lastError {
                    Text(err)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.stateError)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing)
            .help("Re-download this book from GitHub")
        }
        .padding(.vertical, 4)
    }
}

private struct BookChapterView: View {
    let chapter: BookChapter

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            // The chapter title is already rendered by the
            // BookMarkdownView when the file starts with a
            // top-level heading; show the fallback title above
            // only when the markdown doesn't begin with `#`.
            if !chapter.markdown
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("#") {
                Text(chapter.title)
                    .font(.system(size: 30, weight: .semibold))
                    .textSelection(.enabled)
            }
            BookMarkdownView(text: chapter.markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Block-aware markdown renderer

/// Block-level markdown view used by the book viewer. Splits the
/// source into headings / paragraphs / lists / blockquotes /
/// fenced code / horizontal rules and renders each block with
/// distinct typography, then runs inline markdown (`**bold**`,
/// `*italic*`, `` `code` ``, `[links]`) through
/// `AttributedString(markdown:)`. Heavier than the AI panel's
/// `MarkdownView` — that one is optimised for chat turns where
/// paragraphs are short and block diversity is low — but reads
/// as proper book content for the long-form material under
/// `Book/` upstream.
struct BookMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(BookMarkdownParser.parse(text).enumerated()),
                    id: \.offset) { _, block in
                BookMarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum BookMarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case blockquote(String)
    case codeBlock(language: String?, body: String)
    case horizontalRule
    /// Raw block-level HTML — `<details>`, `<table>`, `<img>`, etc.
    /// Rendered via `NSAttributedString`'s HTML importer so tables,
    /// breaks, sub/super-scripts, images and the rest come through
    /// as styled rich text instead of leaking as raw `<tag>` strings.
    case htmlBlock(String)
}

private enum BookMarkdownParser {
    /// Walk the source line by line, grouping lines into blocks.
    /// The grammar handled:
    ///   `#` ATX headings (1–6 `#`s)
    ///   `>` blockquotes (consecutive lines merge)
    ///   `- ` / `* ` unordered list items
    ///   `1. ` ordered list items
    ///   ``` fenced code blocks
    ///   `---` / `***` horizontal rules
    ///   anything else → paragraph (consecutive non-blank lines merge)
    static func parse(_ source: String) -> [BookMarkdownBlock] {
        var blocks: [BookMarkdownBlock] = []
        let lines = source.split(separator: "\n",
                                 omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let line = String(lines[i])
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let inner = String(lines[i])
                    if inner.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("```")
                    {
                        i += 1
                        break
                    }
                    body.append(inner)
                    i += 1
                }
                blocks.append(.codeBlock(
                    language: lang.isEmpty ? nil : lang,
                    body: body.joined(separator: "\n")
                ))
                continue
            }

            // Blank line — end of any in-progress block.
            if trimmed.isEmpty { i += 1; continue }

            // Block-level HTML — a line that starts with `<` and
            // doesn't look like an inline closer. Accumulate
            // until a blank line so multi-line `<table>` / `<details>`
            // payloads stay together.
            if trimmed.hasPrefix("<"),
               let firstChar = trimmed.dropFirst().first,
               firstChar.isLetter || firstChar == "/" || firstChar == "!"
            {
                var html: [String] = []
                while i < lines.count {
                    let inner = String(lines[i])
                    if inner.trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                    html.append(inner)
                    i += 1
                }
                blocks.append(.htmlBlock(html.joined(separator: "\n")))
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // ATX heading.
            if let hash = trimmed.first, hash == "#" {
                var level = 0
                for ch in trimmed {
                    if ch == "#" { level += 1 } else { break }
                }
                if level <= 6 {
                    let body = String(trimmed.dropFirst(level))
                        .trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: body))
                    i += 1
                    continue
                }
            }

            // Blockquote.
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count {
                    let inner = String(lines[i])
                        .trimmingCharacters(in: .whitespaces)
                    if !inner.hasPrefix(">") { break }
                    quoted.append(String(inner.dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quoted.joined(separator: "\n")))
                continue
            }

            // Unordered list.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count {
                    let inner = String(lines[i])
                        .trimmingCharacters(in: .whitespaces)
                    if inner.hasPrefix("- ") {
                        items.append(String(inner.dropFirst(2)))
                    } else if inner.hasPrefix("* ") {
                        items.append(String(inner.dropFirst(2)))
                    } else { break }
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list — `<digits>. text`.
            if isOrderedListLine(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let inner = String(lines[i])
                        .trimmingCharacters(in: .whitespaces)
                    guard isOrderedListLine(inner),
                          let dot = inner.firstIndex(of: ".")
                    else { break }
                    items.append(String(inner[inner.index(after: dot)...])
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Paragraph — consume consecutive non-blank, non-block
            // lines and join them with a space so wrapped lines in
            // the source render as one flowing paragraph (standard
            // CommonMark soft-break behaviour).
            var paragraph: [String] = []
            while i < lines.count {
                let inner = String(lines[i])
                let innerTrim = inner.trimmingCharacters(in: .whitespaces)
                if innerTrim.isEmpty { break }
                if innerTrim.hasPrefix("```") { break }
                if innerTrim.hasPrefix("#") { break }
                if innerTrim.hasPrefix(">") { break }
                if innerTrim.hasPrefix("- ") || innerTrim.hasPrefix("* ") { break }
                if isOrderedListLine(innerTrim) { break }
                if innerTrim == "---" || innerTrim == "***" || innerTrim == "___" { break }
                paragraph.append(innerTrim)
                i += 1
            }
            if !paragraph.isEmpty {
                let joined = paragraph.joined(separator: " ")
                // If the paragraph carries any inline HTML, route
                // the whole thing through the HTML renderer so
                // tags like `<br>`, `<sub>`, `<sup>`, `<kbd>`
                // turn into the corresponding rich text instead
                // of leaking as raw `<…>` text.
                if joined.contains("<") && joined.contains(">"),
                   containsHTMLTag(joined)
                {
                    blocks.append(.htmlBlock(joined))
                } else {
                    blocks.append(.paragraph(joined))
                }
            }
        }
        return blocks
    }

    /// Heuristic: does the string contain something that looks
    /// like an HTML tag (`<word…>` or `</word>` or `<word/>`)?
    /// Plain `<x>` in code-comment-style prose still triggers,
    /// which is OK — the HTML renderer leaves bare angle-bracket
    /// content as text.
    private static func containsHTMLTag(_ s: String) -> Bool {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", s.index(after: i) < s.endIndex {
                let next = s[s.index(after: i)]
                if next.isLetter || next == "/" {
                    // Look for a matching `>` within ~50 chars
                    // to filter out things like `<my-variable>`
                    // in prose, which are common in ARO text.
                    var probe = s.index(after: i)
                    var dist = 0
                    while probe < s.endIndex, dist < 80 {
                        if s[probe] == ">" { return true }
                        if s[probe] == "<" { break }
                        probe = s.index(after: probe)
                        dist += 1
                    }
                }
            }
            i = s.index(after: i)
        }
        return false
    }

    private static func isOrderedListLine(_ line: String) -> Bool {
        // `1.` … `999.` followed by a space.
        var digits = 0
        for ch in line {
            if ch.isASCII && ch.isNumber {
                digits += 1
            } else { break }
        }
        guard digits > 0, digits < 4 else { return false }
        let afterDigits = line.index(line.startIndex, offsetBy: digits)
        guard afterDigits < line.endIndex,
              line[afterDigits] == "."
        else { return false }
        let nextIdx = line.index(after: afterDigits)
        guard nextIdx < line.endIndex,
              line[nextIdx] == " "
        else { return false }
        return true
    }
}

private struct BookMarkdownBlockView: View {
    let block: BookMarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            heading(level: level, text: text)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(SolaroColor.accent)
                        inlineText(item)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(SolaroFont.mono)
                            .foregroundStyle(SolaroColor.accent)
                            .frame(width: 22, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(SolaroColor.accent.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SolaroSpace.s)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            }
            .background(SolaroColor.surfaceRaised.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        case .codeBlock(let language, let body):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    HStack {
                        Text(language)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, SolaroSpace.s)
                    .padding(.top, 4)
                }
                Text(body)
                    .font(SolaroFont.mono)
                    .textSelection(.enabled)
                    .padding(SolaroSpace.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(SolaroColor.backdrop)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SolaroColor.divider.opacity(0.5), lineWidth: 1)
            )
        case .horizontalRule:
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(height: 1)
                .padding(.vertical, 4)
        case .htmlBlock(let html):
            HTMLBlockView(html: html)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Heading typography mirrors a Tower-like document view:
    /// H1 ~ 28pt semibold, H2 ~ 22pt semibold, H3 ~ 18pt medium,
    /// H4+ ~ 15pt medium. Each H1/H2 gets extra top padding so it
    /// reads as a section break in long chapters.
    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        let (size, weight, topPad): (CGFloat, Font.Weight, CGFloat) = {
            switch level {
            case 1: return (28, .semibold, 16)
            case 2: return (22, .semibold, 12)
            case 3: return (18, .medium, 8)
            case 4: return (15, .medium, 6)
            case 5: return (14, .semibold, 4)
            default: return (13, .semibold, 4)
            }
        }()
        inlineText(text)
            .font(.system(size: size, weight: weight))
            .padding(.top, topPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// HTML block renderer. Hands the source to AppKit's
    /// `NSAttributedString` HTML importer so tables, `<details>`
    /// summaries, `<br>`, `<sub>`/`<sup>`, `<kbd>`, `<img>` etc.
    /// come through as styled rich text. The importer respects
    /// the system's appearance (dark/light) automatically.
    private struct HTMLBlockView: View {
        let html: String

        var body: some View {
            if let attributed = Self.attributedString(from: html) {
                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Last resort: render the raw markup as monospace
                // so the user at least sees the contents.
                Text(html)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .textSelection(.enabled)
            }
        }

        /// Wrap the snippet in a small CSS shell so foreground
        /// colour respects the SOLARO theme and the rendered
        /// table/details margins look reasonable inside a SwiftUI
        /// `Text`. NSAttributedString's HTML parser inherits very
        /// little from the surrounding view so the explicit body
        /// styling matters.
        static func attributedString(from html: String) -> AttributedString? {
            let isDark = NSApp?.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bodyColor = isDark ? "#e6e6e6" : "#1a1a1a"
            let linkColor = isDark ? "#7ab8ff" : "#0066cc"
            let wrapped = """
            <style>
              body { font-family: -apple-system, system-ui; font-size: 14px; color: \(bodyColor); }
              a { color: \(linkColor); }
              table { border-collapse: collapse; margin: 0.4em 0; }
              th, td { padding: 4px 8px; border: 1px solid \(isDark ? "#444" : "#ccc"); }
              th { background: \(isDark ? "#2a2a2a" : "#f3f3f3"); }
              kbd { font-family: ui-monospace, monospace; background: \(isDark ? "#2a2a2a" : "#eee"); padding: 1px 4px; border-radius: 3px; }
              code { font-family: ui-monospace, monospace; }
              details { margin: 0.4em 0; }
              summary { cursor: pointer; font-weight: 600; }
              img { max-width: 100%; }
            </style>
            \(html)
            """
            guard let data = wrapped.data(using: .utf8) else { return nil }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            guard let ns = try? NSAttributedString(
                data: data, options: options, documentAttributes: nil
            ) else { return nil }
            return AttributedString(ns)
        }
    }

    /// Inline markdown via `AttributedString` — handles `**bold**`,
    /// `*italic*`, `` `code` ``, and `[text](url)`. Returns a bare
    /// `Text` so callers can keep stacking `.font`/`.foregroundStyle`
    /// modifiers on it. `.textSelection(.enabled)` is applied by
    /// the call site, not in here — `.textSelection` returns
    /// `some View`, not `Text`, and the previous force-cast aborted
    /// at runtime.
    private func inlineText(_ source: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let attr = try? AttributedString(
            markdown: source, options: options
        ) {
            return Text(attr)
        }
        return Text(source)
    }
}
