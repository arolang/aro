// ============================================================
// PluginMarketplace.swift
// SOLARO — plugin browser backed by GitHub topic search (#263)
// ============================================================
//
// The catalog is *decentralised*: anyone whose public GitHub repo
// carries the topics `aro` and `plugin` shows up automatically.
// SOLARO calls the GitHub repo-search API once per sheet open,
// caches the response for 24h under
// `~/Library/Caches/SOLARO/marketplace.json`, and falls back to
// the bundled hardcoded list when the network is unavailable or
// the API rate-limits the request.
//
// An optional Personal Access Token (Settings → Backends →
// "GitHub PAT") raises the unauthenticated 60 req/h limit to
// 5000 — useful when several developers share an IP.

import SwiftUI
import Foundation

/// One row in the marketplace catalog. Mirrors the fields users
/// would want to evaluate before installing a third-party plugin.
/// Many fields are optional because the bundled fallback omits
/// them and old cache files may pre-date a schema bump.
struct MarketplaceEntry: Identifiable, Codable, Hashable {
    let id: String           // stable slug for the row
    let name: String         // display name
    let summary: String      // one-line pitch
    let language: String     // swift / rust / c / python / mixed
    let category: String     // grouping in the sidebar
    let url: String          // Git URL passed to `aro add`
    let homepage: String?    // optional docs / repo link
    /// `stargazers_count` from the GitHub search response. Used
    /// for sorting + a small chip on each row.
    var stars: Int? = nil
    /// `pushed_at` from the GitHub search response, ISO 8601.
    /// Drives a "last updated N days ago" chip and a "stale"
    /// marker once the repo crosses 12 months without a push.
    var updatedAt: String? = nil
    /// SPDX identifier from the GitHub response, e.g. "MIT".
    var license: String? = nil
    /// Topics other than `aro` + `plugin`. Drives extra chips on
    /// each row so the user can spot `database`, `qualifier`,
    /// `wasm`, etc. at a glance.
    var tags: [String]? = nil
}

/// Wrapper around the on-disk cache so we can bump the schema in
/// the future without misreading old caches.
private struct MarketplaceCache: Codable {
    let schemaVersion: Int
    let fetchedAt: Date
    let entries: [MarketplaceEntry]
}

/// Source of truth for catalog entries. Hides whether the answer
/// came from cache, the network, or the bundled fallback.
enum PluginMarketplaceCatalog {
    static let bundledFallback: [MarketplaceEntry] = [
        .init(id: "markdown-renderer",
              name: "Markdown Renderer",
              summary: "Python plugin: render markdown to HTML / plain / ANSI.",
              language: "python",
              category: "Text",
              url: "https://github.com/arolang/plugin-markdown.git",
              homepage: "https://github.com/arolang/plugin-markdown"),
        .init(id: "csv-processor",
              name: "CSV Processor",
              summary: "Rust plugin: parse, transform, and emit CSV streams.",
              language: "rust",
              category: "Data",
              url: "https://github.com/arolang/plugin-csv.git",
              homepage: "https://github.com/arolang/plugin-csv"),
        .init(id: "hash-toolkit",
              name: "Hash Toolkit",
              summary: "C plugin: SHA-256 / SHA-512 / MD5 hashes as actions.",
              language: "c",
              category: "Crypto",
              url: "https://github.com/arolang/plugin-hash.git",
              homepage: nil),
        .init(id: "collections",
              name: "Collections",
              summary: "Swift plugin: pick-random, shuffle, reverse, take-N qualifiers.",
              language: "swift",
              category: "Collections",
              url: "https://github.com/arolang/plugin-collections.git",
              homepage: nil),
        .init(id: "stats",
              name: "Stats",
              summary: "Python plugin: sort, unique, sum, avg, min, max qualifiers.",
              language: "python",
              category: "Data",
              url: "https://github.com/arolang/plugin-stats.git",
              homepage: nil),
        .init(id: "sqlite",
              name: "SQLite",
              summary: "Plugin wrapping libsqlite3 for query / store / migrate.",
              language: "swift",
              category: "Storage",
              url: "https://github.com/arolang/plugin-sqlite.git",
              homepage: nil),
        .init(id: "zip-service",
              name: "ZipService",
              summary: "Swift plugin: archive a directory or extract a .zip.",
              language: "swift",
              category: "Files",
              url: "https://github.com/arolang/plugin-zip.git",
              homepage: nil),
    ]

    /// Synchronous load used by views that want to render
    /// *something* before the async fetch returns. Tries the
    /// cache first (any age), falls back to the bundled list.
    static func loadSync() -> [MarketplaceEntry] {
        if let cached = readCache() {
            return cached.entries
        }
        return bundledFallback
    }

    /// Async load: returns the freshest catalog we can produce.
    /// Order: (1) cache that's < `cacheTTL` old, (2) live GitHub
    /// fetch, (3) any cache regardless of age, (4) bundled
    /// fallback. The returned `(entries, source)` tuple lets the
    /// UI render an "offline" banner when network failed.
    static func loadAsync(refresh: Bool = false)
    async -> (entries: [MarketplaceEntry], source: Source) {
        if !refresh, let cached = readCache(),
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return (cached.entries, .cache)
        }
        let fetcher = GitHubMarketplaceFetcher()
        if let live = await fetcher.fetch() {
            writeCache(live)
            return (live, .network)
        }
        if let cached = readCache() {
            return (cached.entries, .staleCache)
        }
        return (bundledFallback, .bundled)
    }

    enum Source { case cache, network, staleCache, bundled }

    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("SOLARO/marketplace.json")
    }

    private static func readCache() -> MarketplaceCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MarketplaceCache.self, from: data)
    }

    private static func writeCache(_ entries: [MarketplaceEntry]) {
        let payload = MarketplaceCache(
            schemaVersion: 2,
            fetchedAt: Date(),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: [.atomic])
    }
}

/// Wraps the GitHub `repo-search` call so the catalog logic
/// stays mockable in tests. Returns nil on any failure — the
/// caller falls back to the previous cache.
struct GitHubMarketplaceFetcher: Sendable {
    /// Honoured at fetch time; user fills this in Settings →
    /// Backends → "GitHub PAT" to raise the rate limit.
    static let patDefaultsKey = "solaro.github.pat"

    var token: String? {
        let raw = UserDefaults.standard.string(forKey: Self.patDefaultsKey) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// Pages we walk (`per_page=100` × pageLimit = max 300
    /// plugins surfaced). GitHub caps repo-search at 1000 results
    /// per query anyway.
    var pageLimit: Int = 3

    func fetch() async -> [MarketplaceEntry]? {
        var all: [GitHubRepo] = []
        for page in 1...pageLimit {
            let pageItems = await fetchPage(page)
            guard let pageItems else {
                // Network / API failure — bail out so we don't
                // ship a half catalog to the cache.
                return page == 1 ? nil : nil
            }
            if pageItems.isEmpty { break }
            all.append(contentsOf: pageItems)
            if pageItems.count < 100 { break }
        }
        return all.map(\.asEntry)
    }

    private func fetchPage(_ page: Int) async -> [GitHubRepo]? {
        guard var components = URLComponents(
            string: "https://api.github.com/search/repositories"
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: "topic:aro+topic:plugin"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json",
                     forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",
                     forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("SOLARO",
                     forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            req.setValue("Bearer \(token)",
                         forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(SearchResponse.self,
                                                   from: data)
            return payload.items
        } catch {
            return nil
        }
    }

    private struct SearchResponse: Decodable {
        let items: [GitHubRepo]
    }

    private struct GitHubRepo: Decodable {
        let name: String
        let full_name: String
        let description: String?
        let html_url: String
        let homepage: String?
        let language: String?
        let stargazers_count: Int
        let pushed_at: String
        let topics: [String]
        let license: License?

        struct License: Decodable {
            let spdx_id: String?
        }

        var asEntry: MarketplaceEntry {
            // Drop the two filter topics from the displayed tag
            // chips — they're table stakes for being in the
            // catalog at all.
            let trimmedTags = topics
                .filter { $0 != "aro" && $0 != "plugin" }
            // Group plugins by what looks like their primary
            // domain. We try the first non-filter topic, then a
            // few well-known keywords from the name, then
            // "Other" as the fallback.
            let category: String
            if let first = trimmedTags.first {
                category = first.capitalized
            } else if name.lowercased().contains("data") {
                category = "Data"
            } else if name.lowercased().contains("crypto") {
                category = "Crypto"
            } else {
                category = "Other"
            }
            return MarketplaceEntry(
                id: full_name.replacingOccurrences(of: "/", with: "-"),
                name: name,
                summary: description ?? "(no description)",
                language: (language ?? "Mixed").lowercased(),
                category: category,
                url: "github:\(full_name)",
                homepage: (homepage?.isEmpty == false) ? homepage : html_url,
                stars: stargazers_count,
                updatedAt: pushed_at,
                license: license?.spdx_id,
                tags: trimmedTags.isEmpty ? nil : trimmedTags
            )
        }
    }
}

/// Sheet UI listing the catalog with a filter field and an
/// Install button on every row. Reuses AddPluginProcess so the
/// progress log behaves the same as the manual Add Plugin path.
struct PluginMarketplaceSheet: View {
    let project: Project
    let onClose: () -> Void
    let onInstalled: () -> Void

    @State private var entries: [MarketplaceEntry] = []
    @State private var filter: String = ""
    @State private var selected: MarketplaceEntry.ID?
    @State private var installer = AddPluginProcess()
    @State private var installingID: MarketplaceEntry.ID?
    @State private var source: PluginMarketplaceCatalog.Source = .bundled
    @State private var isRefreshing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            sourceBanner
            filterBar
            Divider()
            HSplitView {
                catalogList
                    .frame(minWidth: 280, idealWidth: 320)
                detailPane
                    .frame(minWidth: 320)
            }
            footer
        }
        .padding(SolaroSpace.l)
        .frame(minWidth: 780, minHeight: 520)
        .background(SolaroColor.surface)
        .task {
            // Render whatever cache we have first so the sheet
            // doesn't open empty, then refresh in the background.
            entries = PluginMarketplaceCatalog.loadSync()
            if selected == nil { selected = entries.first?.id }
            await refresh(force: false)
        }
        .onChange(of: installer.state) { _, state in
            if case .success = state {
                installingID = nil
                onInstalled()
            } else if case .failed = state {
                installingID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .foregroundStyle(SolaroColor.accent)
            Text("Plugin marketplace")
                .font(SolaroFont.toolbarTitle)
            Text("\(entries.count) plugins")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Button {
                Task { await refresh(force: true) }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .help("Re-fetch the catalog from GitHub (cached for 24 h)")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var sourceBanner: some View {
        switch source {
        case .staleCache:
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: SolaroColor.stateWarn,
                text: "Showing the previously cached catalog — GitHub didn't answer. Click Refresh to retry."
            )
        case .bundled:
            banner(
                icon: "wifi.slash",
                tint: SolaroColor.stateWarn,
                text: "Showing the offline fallback catalog — GitHub is unreachable. Add a GitHub PAT in Settings → Backends if you hit a rate limit."
            )
        case .network, .cache:
            EmptyView()
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(SolaroSpace.s)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private var filterBar: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SolaroColor.textTertiary)
            TextField("Filter by name, language, tag, or category…",
                      text: $filter)
                .textFieldStyle(.plain)
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private var catalogList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                ForEach(grouped, id: \.category) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(for: entry)
                        }
                    } header: {
                        Text(group.category)
                            .font(SolaroFont.sectionTitle)
                            .tracking(2)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(.top, SolaroSpace.xs)
                    }
                }
                if grouped.isEmpty {
                    Text("No plugins match \"\(filter)\".")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .padding(SolaroSpace.m)
                }
            }
            .padding(SolaroSpace.s)
        }
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private func row(for entry: MarketplaceEntry) -> some View {
        Button {
            selected = entry.id
        } label: {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                languageBadge(entry.language)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(SolaroColor.textPrimary)
                    Text(entry.summary)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(2)
                    HStack(spacing: SolaroSpace.xs) {
                        if let stars = entry.stars {
                            Label("\(stars)", systemImage: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SolaroColor.stateWarn)
                        }
                        if let relativePush = relativeAge(entry.updatedAt) {
                            Text(relativePush)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SolaroColor.textTertiary)
                        }
                        if let license = entry.license {
                            Text(license)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(SolaroColor.textTertiary)
                        }
                    }
                }
                Spacer()
                if installingID == entry.id {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(SolaroSpace.s)
            .background(
                selected == entry.id
                    ? SolaroColor.selection
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = entries.first(where: { $0.id == selected }) {
            ScrollView {
                VStack(alignment: .leading, spacing: SolaroSpace.m) {
                    HStack {
                        Text(entry.name).font(SolaroFont.toolbarTitle)
                        languageBadge(entry.language)
                        Spacer()
                        Button {
                            install(entry)
                        } label: {
                            if installingID == entry.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Install",
                                      systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installingID != nil)
                    }
                    Text(entry.summary)
                        .font(SolaroFont.body)
                        .foregroundStyle(SolaroColor.textPrimary)
                    detailRow("Category", entry.category)
                    detailRow("Language", entry.language)
                    detailRow("Source", entry.url, mono: true)
                    if let homepage = entry.homepage {
                        detailRow("Homepage", homepage, mono: true)
                    }
                    if let stars = entry.stars {
                        detailRow("Stars", String(stars))
                    }
                    if let license = entry.license {
                        detailRow("License", license)
                    }
                    if let updatedAt = entry.updatedAt,
                       let pretty = relativeAge(updatedAt) {
                        detailRow("Last push", pretty)
                    }
                    if let tags = entry.tags, !tags.isEmpty {
                        detailRow("Tags", tags.joined(separator: ", "))
                    }
                    if !installer.log.isEmpty {
                        Text("Install log")
                            .font(SolaroFont.sectionTitle)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .tracking(2)
                            .padding(.top, SolaroSpace.s)
                        ScrollView {
                            Text(installer.log)
                                .font(SolaroFont.mono)
                                .foregroundStyle(SolaroColor.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(SolaroSpace.s)
                        }
                        .background(SolaroColor.backdrop)
                        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
                        .frame(minHeight: 120, maxHeight: 200)
                    }
                    if case .failed(let message) = installer.state {
                        Text(message)
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.stateError)
                    }
                    Spacer(minLength: 0)
                }
                .padding(SolaroSpace.m)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a plugin to see details.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "hand.raised")
                .foregroundStyle(SolaroColor.textTertiary)
            Text("Discovery via GitHub topic search (`aro` + `plugin`). Installation runs `aro add` in your project — review code before granting network or filesystem access.")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Close", action: onClose)
        }
    }

    private func refresh(force: Bool) async {
        isRefreshing = true
        let result = await PluginMarketplaceCatalog.loadAsync(refresh: force)
        entries = result.entries
        source = result.source
        if selected == nil { selected = entries.first?.id }
        isRefreshing = false
    }

    // MARK: - Helpers

    private func detailRow(_ label: String,
                           _ value: String,
                           mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SolaroSpace.s) {
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(mono ? SolaroFont.mono : SolaroFont.body)
                .foregroundStyle(SolaroColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func languageBadge(_ language: String) -> some View {
        Text(language.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(languageColor(language))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func languageColor(_ language: String) -> Color {
        switch language.lowercased() {
        case "swift":  return Color(red: 0.96, green: 0.42, blue: 0.30)
        case "rust":   return Color(red: 0.75, green: 0.40, blue: 0.20)
        case "c", "c++", "cpp":
            return Color(red: 0.40, green: 0.50, blue: 0.78)
        case "python": return Color(red: 0.20, green: 0.60, blue: 0.40)
        default:       return SolaroColor.textTertiary
        }
    }

    /// "3 days ago" / "1 year ago" style label from an ISO 8601
    /// timestamp. Returns nil when parsing fails so the row just
    /// skips the chip.
    private func relativeAge(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private func install(_ entry: MarketplaceEntry) {
        installingID = entry.id
        installer.install(
            url: entry.url,
            ref: nil,
            branch: nil,
            project: project
        )
    }

    // MARK: - Filtering / grouping

    private var filtered: [MarketplaceEntry] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.name.lowercased().contains(trimmed)
                || entry.summary.lowercased().contains(trimmed)
                || entry.language.lowercased().contains(trimmed)
                || entry.category.lowercased().contains(trimmed)
                || (entry.tags?.contains(where: { $0.lowercased().contains(trimmed) }) ?? false)
        }
    }

    private struct Group {
        let category: String
        let entries: [MarketplaceEntry]
    }

    private var grouped: [Group] {
        let buckets = Dictionary(grouping: filtered, by: { $0.category })
        return buckets
            .map { Group(category: $0.key,
                         entries: $0.value.sorted {
                             // Sort by stars descending within a
                             // category so the most-used plugins
                             // float to the top.
                             ($0.stars ?? 0) > ($1.stars ?? 0)
                         }) }
            .sorted { $0.category < $1.category }
    }
}
