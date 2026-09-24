// ============================================================
// ExistsBooleanTests.swift
// AROCLI — Exists binds a boolean for every spelling (GitLab #494)
// ============================================================
//
// `Exists the <flag> for "./path"` used to bind the PATH: the executor's
// expression shortcut assigned the string to <flag> and never ran the
// action, so only the `for the <file: "...">` spelling produced a real
// boolean. These tests pin the fixed contract: both spellings execute
// ExistsAction, agree with each other, and yield a Bool that `when`
// guards can evaluate.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Exists binds a boolean (GitLab #494)", .serialized)
struct ExistsBooleanTests {

    /// Fresh scratch directory per test.
    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-exists-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Bare string object binds true for an existing file")
    func bareStringExistingFile() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("present.txt")
        try "here".write(to: file, atomically: true, encoding: .utf8)

        let session = REPLSession()
        let result = try await session.executeStatement(
            "Exists the <flag> for \"\(file.path)\".")
        #expect(result.isSuccess)

        let flag = session.getVariable("flag")
        #expect(flag as? Bool == true, "expected Bool true, got \(String(describing: flag))")
    }

    @Test("Bare string object binds false for a missing path")
    func bareStringMissingFile() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("nope.txt")

        let session = REPLSession()
        let result = try await session.executeStatement(
            "Exists the <flag> for \"\(missing.path)\".")
        #expect(result.isSuccess)

        // The bug bound the path string here — a truthy non-Bool that made
        // "file exists" checks pass for files that were never written.
        let flag = session.getVariable("flag")
        #expect(flag as? Bool == false, "expected Bool false, got \(String(describing: flag))")
    }

    @Test("Bare string and <file: ...> spellings agree")
    func bothSpellingsAgree() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("agree.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let session = REPLSession()

        // Existing file: both true.
        _ = try await session.executeStatement("Exists the <bare-yes> for \"\(file.path)\".")
        _ = try await session.executeStatement("Exists the <qual-yes> for the <file: \"\(file.path)\">.")
        #expect(session.getVariable("bare-yes") as? Bool == true)
        #expect(session.getVariable("qual-yes") as? Bool == true)

        // Missing file: both false.
        try FileManager.default.removeItem(at: file)
        _ = try await session.executeStatement("Exists the <bare-no> for \"\(file.path)\".")
        _ = try await session.executeStatement("Exists the <qual-no> for the <file: \"\(file.path)\">.")
        #expect(session.getVariable("bare-no") as? Bool == false)
        #expect(session.getVariable("qual-no") as? Bool == false)
    }

    @Test("The bound flag drives a when guard")
    func flagDrivesWhenGuard() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("guard.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let session = REPLSession()
        _ = try await session.executeStatement("Exists the <present> for \"\(file.path)\".")
        _ = try await session.executeStatement(
            "Exists the <absent> for \"\(scratch.appendingPathComponent("missing.txt").path)\".")

        // A guard on the true flag runs its statement; on the false flag it
        // must skip — under the bug both flags held path strings, and a
        // non-empty string is not `== true`, so *neither* guard could fire.
        _ = try await session.executeStatement(
            "Create the <fired> with \"yes\" when <present> == true.")
        _ = try await session.executeStatement(
            "Create the <skipped> with \"yes\" when <absent> == true.")

        #expect(session.getVariable("fired") as? String == "yes")
        #expect(session.getVariable("skipped") == nil)
    }

    @Test("String variable object still resolves as the path")
    func stringVariablePathStillWorks() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("via-var.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let session = REPLSession()
        _ = try await session.executeStatement("Create the <target> with \"\(file.path)\".")
        let result = try await session.executeStatement(
            "Exists the <flag> for the <file: target>.")
        #expect(result.isSuccess)
        #expect(session.getVariable("flag") as? Bool == true)
    }

    @Test("Directory spelling still distinguishes files from directories")
    func directoryTypeCheckStillWorks() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("plain.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let session = REPLSession()
        let dirCheck = try await session.executeStatement(
            "Exists the <seen-dir> for the <directory: \"\(file.path)\">.")
        let fileCheck = try await session.executeStatement(
            "Exists the <seen-file> for the <file: \"\(file.path)\">.")
        #expect(dirCheck.isSuccess)
        #expect(fileCheck.isSuccess)

        // A file is not a directory; the typed spellings keep that contract.
        #expect(session.getVariable("seen-dir") as? Bool == false)
        #expect(session.getVariable("seen-file") as? Bool == true)
    }
}
