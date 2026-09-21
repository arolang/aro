// ============================================================
// RequestReplayTests.swift
// SOLARO — sending a recorded request again (GitLab #766)
// ============================================================
//
// The try-it-out panel has written a history file since it existed.
// Nothing read it back, and the entries recorded that a request had
// happened but not what it was — so "send this one again" could only
// have meant "send a different request to the same path".

import Testing
import Foundation
@testable import SOLARO

@Suite("Request replay", .serialized)
struct RequestReplayTests {

    private func temporaryProject() throws -> Project {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return Project(rootPath: root)
    }

    private func entry(path: String = "/users/{id}",
                       status: Int = 200) -> OpenAPIHistoryEntry {
        OpenAPIHistoryEntry(
            timestamp: Date(), environment: "local",
            method: "GET", path: path, status: status, durationMS: 12,
            pathParameters: ["id": "530"],
            queryParameters: ["verbose": "true"],
            headers: ["X-Trace": "abc"],
            body: nil
        )
    }

    @Test func anEntryRoundTripsThroughTheHistoryFile() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        OpenAPIEnvStore.appendHistory(entry(), in: project)
        let loaded = OpenAPIEnvStore.loadHistory(in: project)
        #expect(loaded.count == 1)
        #expect(loaded[0].pathParameters?["id"] == "530")
        #expect(loaded[0].queryParameters?["verbose"] == "true")
        #expect(loaded[0].headers?["X-Trace"] == "abc")
    }

    @Test func historyComesBackNewestFirst() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let older = OpenAPIHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            environment: "local", method: "GET", path: "/a",
            status: 200, durationMS: 1)
        let newer = OpenAPIHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            environment: "local", method: "GET", path: "/b",
            status: 200, durationMS: 1)
        OpenAPIEnvStore.appendHistory(older, in: project)
        OpenAPIEnvStore.appendHistory(newer, in: project)

        let loaded = OpenAPIEnvStore.loadHistory(in: project)
        #expect(loaded.first?.path == "/b")
    }

    @Test func aTruncatedLineIsSkippedRatherThanFailingTheRead() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        OpenAPIEnvStore.appendHistory(entry(), in: project)
        // The file is appended to by a live process; a half-written
        // last line is ordinary, not a reason to show no history.
        let url = OpenAPIEnvStore.historyURL(in: project)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"timestamp\":\"2026".utf8))
        try handle.close()

        #expect(OpenAPIEnvStore.loadHistory(in: project).count == 1)
    }

    @Test func anEmptyHistoryIsNotAnError() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }
        #expect(OpenAPIEnvStore.loadHistory(in: project).isEmpty)
    }

    @Test func anOldEntryStillDecodesAndSaysItCannotReplay() throws {
        let project = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        // Entries written before replay existed are in people's
        // projects and must keep loading.
        let legacy = OpenAPIHistoryEntry(
            timestamp: Date(), environment: "local", method: "GET",
            path: "/users", status: 200, durationMS: 7)
        OpenAPIEnvStore.appendHistory(legacy, in: project)

        let loaded = try #require(OpenAPIEnvStore.loadHistory(in: project).first)
        #expect(!loaded.isReplayable)
        #expect(entry().isReplayable)
    }

    @Test func secretHeadersAreNotWrittenToTheHistory() {
        // Secrets do not go in a file inside the user's repository
        // (#745), so a replay takes auth from the environment instead.
        let redacted = OpenAPIHistoryEntry.redactingSecrets([
            "Authorization": "Bearer hunter2",
            "X-API-Key": "k",
            "X-Trace": "abc",
            "Content-Type": "application/json",
        ])
        #expect(redacted["Authorization"] == nil)
        #expect(redacted["X-API-Key"] == nil)
        #expect(redacted["X-Trace"] == "abc")
        #expect(redacted["Content-Type"] == "application/json")
    }

    @MainActor
    @Test func restoringPutsTheRequestBackInTheForm() {
        let model = TryItOutModel()
        model.restore(entry())
        #expect(model.pathParamValues["id"] == "530")
        #expect(model.queryParamValues["verbose"] == "true")
        #expect(model.headerValues["X-Trace"] == "abc")
        #expect(model.requestBody.isEmpty)
    }

    @MainActor
    @Test func restoringAnOldEntryClearsTheFormRatherThanLying() {
        let model = TryItOutModel()
        model.pathParamValues = ["id": "1"]
        model.restore(OpenAPIHistoryEntry(
            timestamp: Date(), environment: "local", method: "GET",
            path: "/users", status: 200, durationMS: 7))
        // Nothing was recorded, so nothing is claimed.
        #expect(model.pathParamValues.isEmpty)
    }
}
