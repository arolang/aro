// ============================================================
// PluginBuildProgressTests.swift
// ARORuntime — plugin builds announce themselves (GitLab #826)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

// `.serialized`: every test here redirects fd 2 to capture stderr, and
// Swift Testing runs a suite's tests in parallel by default — so two of
// them race for the one descriptor and each sees a slice of the other's
// output.
@Suite("Plugin build progress (#826)", .serialized)
struct PluginBuildProgressTests {

    /// Collect what `PluginBuildProgress` emits, through its sink.
    ///
    /// This used to redirect fd 2 to a temp file. Changing a process-global
    /// descriptor while hundreds of suites run in parallel stole stderr from
    /// unrelated tests — intermittently aborting one inside
    /// `FileHandle.readDataUpToLength` — and made the assertions depend on who
    /// else happened to be writing. The sink is local to this type.
    private func capture(_ body: () -> Void) -> String {
        let box = LineBox()
        PluginBuildProgress.setSinkForTesting { box.append($0) }
        defer { PluginBuildProgress.setSinkForTesting(nil) }
        body()
        return box.joined()
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
        func joined() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    @Test("A package build names the plugin, the command and the one-time cost")
    func announcesPackageBuild() {
        let output = capture {
            let token = PluginBuildProgress.started(
                plugin: "SQLitePlugin", command: "swift build -c release")
            PluginBuildProgress.finished(token)
        }

        #expect(output.contains("Building plugin 'SQLitePlugin'"))
        #expect(output.contains("swift build -c release"))
        // The two facts a two-minute silence hides: that it is one-time, and
        // that it reaches the network.
        #expect(output.contains("first run only"))
        #expect(output.contains("network access"))
        #expect(output.contains("Built plugin 'SQLitePlugin' in "))
    }

    @Test("A single-file compile is announced without the one-time-cost note")
    func announcesFileBuildBriefly() {
        let output = capture {
            let token = PluginBuildProgress.started(
                plugin: "Greeter", command: "swiftc -emit-library", firstRun: false)
            PluginBuildProgress.finished(token)
        }

        #expect(output.contains("Building plugin 'Greeter'"))
        #expect(!output.contains("first run only"))
    }

    @Test("A failed build reports the time it spent before failing")
    func announcesFailure() {
        let output = capture {
            let token = PluginBuildProgress.started(plugin: "Broken", command: "cargo build --release")
            PluginBuildProgress.failed(token)
        }

        #expect(output.contains("Building plugin 'Broken' failed after "))
    }

    @Test("Every line is prefixed so a harness can filter it out")
    func linesArePrefixed() {
        // A unique name, and only this plugin's lines are examined. Redirecting
        // fd 2 catches everything the *process* writes for the duration, and
        // other suites run in parallel — asserting on the total line count made
        // this pass alone and fail in a full run. The property under test is
        // that every line this type emits carries the prefix the integration
        // harness filters on, not that it had stderr to itself.
        let plugin = "PrefixProbe-\(UUID().uuidString)"
        let output = capture {
            let token = PluginBuildProgress.started(plugin: plugin, command: "swift build")
            PluginBuildProgress.finished(token)
        }

        let mine = output.split(separator: "\n").filter { $0.contains(plugin) }
        #expect(mine.count == 2, "expected a started and a finished line, got \(mine)")
        #expect(mine.allSatisfy { $0.hasPrefix("[aro] ") })
    }
}
