// ============================================================
// PluginMarketplace.swift
// SOLARO — curated plugin browser (#250)
// ============================================================
//
// Until there's a hosted registry, SOLARO ships a small curated
// list of ARO plugins so users can find and install something
// useful from the IDE without having to know exact Git URLs. The
// list is loaded from a bundled JSON catalog by default; users
// can point it at a remote URL via Settings (next iteration).

import SwiftUI
import Foundation

/// One row in the marketplace catalog. Mirrors the fields users
/// would want to evaluate before installing a third-party plugin.
struct MarketplaceEntry: Identifiable, Decodable, Hashable {
    let id: String           // stable slug for the row
    let name: String         // display name
    let summary: String      // one-line pitch
    let language: String     // swift / rust / c / python
    let category: String     // grouping in the sidebar
    let url: String          // Git URL passed to `aro add`
    let homepage: String?    // optional docs / repo link
}

/// Loads the catalog. Right now we have one source: a bundled
/// JSON file at `Resources/marketplace.json`. The function falls
/// back to a small hardcoded list so the marketplace still works
/// even when the bundle is built without resources (e.g. during
/// `swift build` without copying the SOLARO bundle).
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
              homepage: nil)
    ]

    /// Resolve the catalog. Looks for `marketplace.json` in the
    /// app bundle; falls back to the static list above.
    static func load() -> [MarketplaceEntry] {
        if let url = Bundle.main.url(forResource: "marketplace",
                                     withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let entries = try? JSONDecoder().decode([MarketplaceEntry].self,
                                                   from: data)
        {
            return entries
        }
        return bundledFallback
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
    /// Slug of the row whose Install button was clicked last —
    /// the row uses this to show its progress indicator inline.
    @State private var installingID: MarketplaceEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
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
        .frame(minWidth: 760, minHeight: 480)
        .background(SolaroColor.surface)
        .onAppear {
            entries = PluginMarketplaceCatalog.load()
            if selected == nil { selected = entries.first?.id }
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
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var filterBar: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SolaroColor.textTertiary)
            TextField("Filter by name, language, or category…", text: $filter)
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
                                Label("Install", systemImage: "arrow.down.circle.fill")
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
                    detailRow("Source",   entry.url, mono: true)
                    if let homepage = entry.homepage {
                        detailRow("Homepage", homepage, mono: true)
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
            Text("Installation runs `aro add` in your project. Review code before granting network or filesystem access.")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Button("Close", action: onClose)
        }
    }

    // MARK: - Helpers

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SolaroSpace.s) {
            Text(label)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(width: 80, alignment: .trailing)
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
        case "c", "c++", "cpp": return Color(red: 0.40, green: 0.50, blue: 0.78)
        case "python": return Color(red: 0.20, green: 0.60, blue: 0.40)
        default:       return SolaroColor.textTertiary
        }
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
            entry.name.lowercased().contains(trimmed) ||
            entry.summary.lowercased().contains(trimmed) ||
            entry.language.lowercased().contains(trimmed) ||
            entry.category.lowercased().contains(trimmed)
        }
    }

    private struct Group {
        let category: String
        let entries: [MarketplaceEntry]
    }

    private var grouped: [Group] {
        let buckets = Dictionary(grouping: filtered, by: { $0.category })
        return buckets
            .map { Group(category: $0.key, entries: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }
}
