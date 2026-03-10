// ============================================================
// VersioningTests.swift
// ARO Package Manager Tests - Plugin versioning (Issue #120)
// ============================================================

import Testing
import Foundation
@testable import AROPackageManager

// MARK: - AROVersionChecker Tests

@Suite("AROVersionChecker Tests")
struct AROVersionCheckerTests {

    // MARK: Exact match

    @Test("Exact version match")
    func exactVersionMatch() {
        #expect(AROVersionChecker.satisfies(version: "1.2.3", constraint: "1.2.3"))
    }

    @Test("Exact version mismatch")
    func exactVersionMismatch() {
        #expect(!AROVersionChecker.satisfies(version: "1.2.3", constraint: "1.2.4"))
    }

    @Test("Exact version with v-prefix in constraint")
    func exactVersionVPrefix() {
        #expect(AROVersionChecker.satisfies(version: "1.2.3", constraint: "v1.2.3"))
    }

    // MARK: >= constraints

    @Test("Greater-or-equal: satisfied")
    func greaterOrEqualSatisfied() {
        #expect(AROVersionChecker.satisfies(version: "1.5.0", constraint: ">=1.0.0"))
    }

    @Test("Greater-or-equal: exact boundary")
    func greaterOrEqualBoundary() {
        #expect(AROVersionChecker.satisfies(version: "1.0.0", constraint: ">=1.0.0"))
    }

    @Test("Greater-or-equal: not satisfied")
    func greaterOrEqualNotSatisfied() {
        #expect(!AROVersionChecker.satisfies(version: "0.9.9", constraint: ">=1.0.0"))
    }

    // MARK: < constraints

    @Test("Less-than: satisfied")
    func lessThanSatisfied() {
        #expect(AROVersionChecker.satisfies(version: "1.9.9", constraint: "<2.0.0"))
    }

    @Test("Less-than: boundary (not satisfied)")
    func lessThanBoundary() {
        #expect(!AROVersionChecker.satisfies(version: "2.0.0", constraint: "<2.0.0"))
    }

    // MARK: Range (space-separated)

    @Test("Range constraint: inside")
    func rangeInside() {
        #expect(AROVersionChecker.satisfies(version: "1.3.0", constraint: ">=1.0.0 <2.0.0"))
    }

    @Test("Range constraint: below lower bound")
    func rangeBelowLower() {
        #expect(!AROVersionChecker.satisfies(version: "0.9.0", constraint: ">=1.0.0 <2.0.0"))
    }

    @Test("Range constraint: at upper bound")
    func rangeAtUpper() {
        #expect(!AROVersionChecker.satisfies(version: "2.0.0", constraint: ">=1.0.0 <2.0.0"))
    }

    // MARK: Caret (^) constraints

    @Test("Caret: same major, higher minor")
    func caretHigherMinor() {
        #expect(AROVersionChecker.satisfies(version: "1.5.0", constraint: "^1.2.0"))
    }

    @Test("Caret: same major, exact")
    func caretExact() {
        #expect(AROVersionChecker.satisfies(version: "1.2.0", constraint: "^1.2.0"))
    }

    @Test("Caret: different major")
    func caretDifferentMajor() {
        #expect(!AROVersionChecker.satisfies(version: "2.0.0", constraint: "^1.2.0"))
    }

    // MARK: Tilde (~) constraints

    @Test("Tilde: same major.minor, higher patch")
    func tildePatch() {
        #expect(AROVersionChecker.satisfies(version: "1.2.9", constraint: "~1.2.0"))
    }

    @Test("Tilde: same major.minor, exact")
    func tildeExact() {
        #expect(AROVersionChecker.satisfies(version: "1.2.0", constraint: "~1.2.0"))
    }

    @Test("Tilde: different minor")
    func tildeDifferentMinor() {
        #expect(!AROVersionChecker.satisfies(version: "1.3.0", constraint: "~1.2.0"))
    }

    // MARK: Pre-release / build metadata stripping

    @Test("Running version with -dirty suffix is stripped")
    func dirtyVersionStripped() {
        #expect(AROVersionChecker.satisfies(version: "1.2.0-dirty", constraint: ">=1.0.0"))
    }

    @Test("Running version with git describe tag format")
    func gitDescribeFormat() {
        #expect(AROVersionChecker.satisfies(version: "v1.3.2", constraint: ">=1.0.0 <2.0.0"))
    }
}

// MARK: - LockFile Tests

@Suite("LockFile Tests")
struct LockFileTests {

    @Test("Upsert and retrieve a locked plugin")
    func upsertAndRetrieve() throws {
        var lock = PluginsLock()
        let entry = LockedPlugin(name: "csv-plugin", version: "1.2.0", git: "https://example.com/csv.git", ref: "v1.2.0", commit: "abc123")
        lock.upsert(entry)
        let found = lock.entry(for: "csv-plugin")
        #expect(found?.version == "1.2.0")
        #expect(found?.commit == "abc123")
    }

    @Test("Upsert overwrites existing entry")
    func upsertOverwrites() throws {
        var lock = PluginsLock()
        lock.upsert(LockedPlugin(name: "my-plugin", version: "1.0.0", commit: "aaa"))
        lock.upsert(LockedPlugin(name: "my-plugin", version: "1.1.0", commit: "bbb"))
        #expect(lock.locked.count == 1)
        #expect(lock.locked[0].version == "1.1.0")
        #expect(lock.locked[0].commit == "bbb")
    }

    @Test("Remove an entry")
    func removeEntry() throws {
        var lock = PluginsLock()
        lock.upsert(LockedPlugin(name: "plugin-a", version: "1.0.0"))
        lock.upsert(LockedPlugin(name: "plugin-b", version: "2.0.0"))
        lock.remove(name: "plugin-a")
        #expect(lock.locked.count == 1)
        #expect(lock.entry(for: "plugin-a") == nil)
        #expect(lock.entry(for: "plugin-b") != nil)
    }

    @Test("Round-trip save and load")
    func roundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lockURL = tempDir.appendingPathComponent("plugins.lock")
        var original = PluginsLock()
        original.upsert(LockedPlugin(name: "csv-plugin", version: "1.2.0", git: "https://example.com/csv.git", ref: "v1.2.0", commit: "abc123def456"))
        original.upsert(LockedPlugin(name: "json-plugin", version: "2.0.1", git: "https://example.com/json.git", ref: "main", commit: "deadbeef1234"))

        try original.save(to: lockURL)
        let loaded = try PluginsLock.load(from: lockURL)

        #expect(loaded.formatVersion == 1)
        #expect(loaded.locked.count == 2)
        let csv = loaded.entry(for: "csv-plugin")
        #expect(csv?.version == "1.2.0")
        #expect(csv?.commit == "abc123def456")
    }
}

// MARK: - PluginManifest System Field Tests

@Suite("PluginManifest system field")
struct PluginManifestSystemTests {

    @Test("Parses system dependencies from YAML")
    func parseSystemDependencies() throws {
        let yaml = """
        name: sqlite-plugin
        version: 1.0.0
        system:
          - libsqlite3
          - libz
        provides:
          - type: c-plugin
            path: src/
        """
        let manifest = try PluginManifest.parse(yaml: yaml)
        #expect(manifest.system == ["libsqlite3", "libz"])
    }

    @Test("Manifest without system field has nil system")
    func noSystemField() throws {
        let yaml = """
        name: simple-plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """
        let manifest = try PluginManifest.parse(yaml: yaml)
        #expect(manifest.system == nil)
    }
}
