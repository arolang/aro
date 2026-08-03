// ============================================================
// BreakpointConfigTests.swift
// SOLARO — conditional breakpoints + logpoints (issue #259)
// ============================================================
//
// Covers the sidecar half of #259:
//   * old (pre-#259) sidecar JSON migrates forward — every breakpoint
//     reads back as a plain regular breakpoint, no data dropped;
//   * conditional + logpoint refinements round-trip through disk;
//   * the schema version is bumped 1 → 2 and a v1 file re-stamps to v2.

import Testing
import Foundation
@testable import SOLARO

@Suite("Breakpoint configs (#259)")
struct BreakpointConfigTests {

    /// Write a raw `.layout.json` at the project root for `source`, then
    /// return the source URL so `LayoutSidecar.load(for:)` resolves it.
    private func writeRawStore(_ json: String, forFileNamed name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-bp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(name)
        try "(Application-Start: Probe) { Log \"hi\" to the <console>. }"
            .write(to: source, atomically: true, encoding: .utf8)
        let store = root.appendingPathComponent(ProjectLayoutStore.storeFilename)
        try json.write(to: store, atomically: true, encoding: .utf8)
        return source
    }

    // MARK: - Old → new migration

    @Test func oldSidecarWithoutConfigsMigratesToPlainRegular() throws {
        // A v1 store: `breakpoints` present, no `breakpointConfigs` key.
        let json = """
        {
          "version": 1,
          "files": {
            "main.aro": {
              "paneMode": "text",
              "nodes": {},
              "view": { "zoom": 1, "scrollX": 0, "scrollY": 0 },
              "breakpoints": [3, 7, 12]
            }
          }
        }
        """
        let source = try writeRawStore(json, forFileNamed: "main.aro")
        defer { try? FileManager.default.removeItem(
            at: source.deletingLastPathComponent()) }

        let sidecar = LayoutSidecar.load(for: source)
        // Breakpoint lines survive.
        #expect(sidecar.breakpoints == [3, 7, 12])
        // No configs present — every line reads back as plain regular.
        #expect(sidecar.breakpointConfigs.isEmpty)
        for line in [3, 7, 12] {
            let config = sidecar.breakpointConfig(forLine: line)
            #expect(config.kind == .regular)
            #expect(config.condition == nil)
            #expect(config.logMessage == nil)
            #expect(config.isPlainRegular)
        }
    }

    @Test func loadingV1StoreRestampsToCurrentSchemaVersion() throws {
        let json = """
        { "version": 1, "files": {} }
        """
        let source = try writeRawStore(json, forFileNamed: "main.aro")
        defer { try? FileManager.default.removeItem(
            at: source.deletingLastPathComponent()) }

        let store = ProjectLayoutStore.load(for: source)
        #expect(ProjectLayoutStore.currentSchemaVersion == 2)
        #expect(store.version == 2)
    }

    // MARK: - Round-trip of new fields

    @Test func conditionalAndLogpointRoundTripThroughDisk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-bp-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("main.aro")
        try "(Application-Start: Probe) { Log \"hi\" to the <console>. }"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var sidecar = LayoutSidecar()
        sidecar.breakpoints = [5, 9]
        sidecar.setBreakpointConfig(
            .init(kind: .regular, condition: "<user: id> == 530"),
            forLine: 5)
        sidecar.setBreakpointConfig(
            .init(kind: .logpoint, logMessage: "count is {count}"),
            forLine: 9)
        try sidecar.save(for: url)

        let reloaded = LayoutSidecar.load(for: url)
        #expect(reloaded.breakpoints == [5, 9])

        let cond = reloaded.breakpointConfig(forLine: 5)
        #expect(cond.kind == .regular)
        #expect(cond.condition == "<user: id> == 530")
        #expect(cond.logMessage == nil)

        let log = reloaded.breakpointConfig(forLine: 9)
        #expect(log.kind == .logpoint)
        #expect(log.logMessage == "count is {count}")

        // The whole store re-stamps to v2.
        let store = ProjectLayoutStore.load(for: url)
        #expect(store.version == 2)
    }

    @Test func plainRegularConfigIsPrunedFromStorage() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-bp-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("main.aro")
        try "(Application-Start: Probe) { Log \"hi\" to the <console>. }"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var sidecar = LayoutSidecar()
        sidecar.breakpoints = [4]
        // Setting a plain-regular config is a no-op on storage.
        sidecar.setBreakpointConfig(.init(kind: .regular), forLine: 4)
        #expect(sidecar.breakpointConfigs.isEmpty)

        // Setting then clearing a condition leaves no residue.
        sidecar.setBreakpointConfig(.init(condition: "x > 1"), forLine: 4)
        #expect(sidecar.breakpointConfigs.count == 1)
        sidecar.setBreakpointConfig(.init(condition: ""), forLine: 4)
        #expect(sidecar.breakpointConfigs.isEmpty)

        try sidecar.save(for: url)
        let reloaded = LayoutSidecar.load(for: url)
        #expect(reloaded.breakpoints == [4])
        #expect(reloaded.breakpointConfigs.isEmpty)
    }
}
