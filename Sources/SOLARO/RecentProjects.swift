// ============================================================
// RecentProjects.swift
// SOLARO — recent-projects persistence (ADR-007 compliant)
// ============================================================
//
// Stores the list of recently-opened projects under the user's config
// directory. Strictly local — no telemetry, no sync, no analytics
// per ADR-007. Storing only the project root paths and the most
// recent open time.

import Foundation

enum RecentProjects {

    /// Where the file lives, per platform XDG-ish convention.
    /// macOS:   ~/Library/Application Support/SOLARO/recents.json
    /// Linux:   $XDG_CONFIG_HOME/solaro/recents.json (or ~/.config/solaro/...)
    /// Windows: %APPDATA%/SOLARO/recents.json
    static var fileURL: URL {
        let manager = FileManager.default
        #if os(macOS)
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SOLARO/recents.json")
        #elseif os(Windows)
        let appdata = ProcessInfo.processInfo.environment["APPDATA"]
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: appdata)
            .appendingPathComponent("SOLARO/recents.json")
        #else
        let configBase = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config").path
        return URL(fileURLWithPath: configBase)
            .appendingPathComponent("solaro/recents.json")
        #endif
    }

    private struct Entry: Codable, Hashable {
        let path: String
        let openedAt: Date
    }

    /// Load the list, freshest first. Returns empty when the file is
    /// missing or unreadable — never throws into the UI.
    static func load() -> [Project] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
            .sorted { $0.openedAt > $1.openedAt }
            .prefix(10)
            .map { Project(rootPath: URL(fileURLWithPath: $0.path)) }
    }

    /// Insert / refresh a project at the top of the list, capped at 10.
    static func remember(_ project: Project) {
        let now = Date()
        var existing = (try? loadEntries()) ?? []
        existing.removeAll { $0.path == project.rootPath.path }
        existing.insert(Entry(path: project.rootPath.path, openedAt: now), at: 0)
        existing = Array(existing.prefix(10))
        try? save(existing)
    }

    private static func loadEntries() throws -> [Entry] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Entry].self, from: data)
    }

    private static func save(_ entries: [Entry]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Forget all recents. Surfaced through a "Clear recent projects"
    /// menu item in the workspace — privacy-friendly per ADR-007.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
