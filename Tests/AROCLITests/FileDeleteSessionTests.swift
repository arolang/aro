// ============================================================
// FileDeleteSessionTests.swift
// AROCLI — file deletion through Delete (GitLab #493)
// ============================================================
//
// `Delete the <gone> from "./path"` used to answer ok while deleting
// nothing: the executor's expression shortcut bound the path string to
// the result and never ran the action, and DeleteAction itself only
// knew repositories, dictionaries, and arrays. These tests pin the
// fixed contract from ARO-0036 §7: file-shaped objects delete the
// file, a missing path is a hard error (so a rerun fails loudly),
// and the pre-existing delete targets keep working.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("File Delete via session (GitLab #493)", .serialized)
struct FileDeleteSessionTests {

    /// Fresh scratch directory per test.
    private func makeScratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-delete-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(in dir: URL, name: String = "victim.txt") throws -> URL {
        let file = dir.appendingPathComponent(name)
        try "delete me".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("Delete from a bare string path removes the file")
    func deleteBareStringPath() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch)

        let session = REPLSession()
        let result = try await session.executeStatement(
            "Delete the <gone> from \"\(file.path)\".")

        #expect(result.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Delete from the <file: ...> qualified object removes the file")
    func deleteFileQualifiedObject() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch)

        let session = REPLSession()
        let result = try await session.executeStatement(
            "Delete the <gone> from the <file: \"\(file.path)\">.")

        #expect(result.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Delete from the <directory: ...> removes the tree recursively")
    func deleteDirectoryRecursively() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tree = scratch.appendingPathComponent("tree/sub")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        _ = try makeFile(in: tree, name: "leaf.txt")

        let session = REPLSession()
        let target = scratch.appendingPathComponent("tree")
        let result = try await session.executeStatement(
            "Delete the <dropped> from the <directory: \"\(target.path)\">.")

        #expect(result.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Delete from a string variable treats the value as the path")
    func deleteStringVariablePath() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch)

        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <target> with \"\(file.path)\".")
        let result = try await session.executeStatement(
            "Delete the <gone> from the <target>.")

        #expect(result.isSuccess)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Deleting a missing file is a hard error, so a rerun fails loudly")
    func deleteMissingFileErrors() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = try makeFile(in: scratch)

        let session = REPLSession()
        let first = try await session.executeStatement(
            "Delete the <gone> from \"\(file.path)\".")
        #expect(first.isSuccess)

        // Rerun — e.g. a re-executed notebook cell — must not pretend success.
        let second = try await session.executeStatement(
            "Delete the <gone-again> from \"\(file.path)\".")
        guard case .error(let message) = second else {
            Issue.record("expected error for missing file, got \(second)")
            return
        }
        #expect(message.contains("not found") || message.contains("Cannot delete"))
    }

    @Test("An unsupported delete target errors instead of answering ok")
    func deleteUnsupportedTargetErrors() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement("Create the <n> with 42.")
        let result = try await session.executeStatement(
            "Delete the <gone> from the <n>.")

        guard case .error = result else {
            Issue.record("expected error for non-deletable target, got \(result)")
            return
        }
    }

    @Test("Repository delete with a where clause still works")
    func repositoryDeleteStillWorks() async throws {
        let session = REPLSession()
        let repo = "del\(UUID().uuidString.lowercased().filter { $0.isLetter }.prefix(8))-repository"

        _ = try await session.executeStatement(
            "Create the <item> with { id: \"sku-1\", name: \"Beans\" }.")
        _ = try await session.executeStatement(
            "Store the <item> into the <\(repo)>.")
        let del = try await session.executeStatement(
            "Delete the <retired> from the <\(repo)> where <id> is \"sku-1\".")
        #expect(del.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <left> from the <\(repo)>.")
        let left = session.getVariable("left")
        if let list = left as? [any Sendable] {
            #expect(list.isEmpty)
        }
    }

    @Test("Repository delete without a where clause clears the repository")
    func repositoryClearAllStillWorks() async throws {
        let session = REPLSession()
        let repo = "clr\(UUID().uuidString.lowercased().filter { $0.isLetter }.prefix(8))-repository"

        _ = try await session.executeStatement(
            "Create the <item> with { id: \"i1\" }.")
        _ = try await session.executeStatement(
            "Store the <item> into the <\(repo)>.")
        let del = try await session.executeStatement(
            "Delete the <all> from the <\(repo)>.")
        #expect(del.isSuccess)

        _ = try await session.executeStatement(
            "Retrieve the <after> from the <\(repo)>.")
        let after = session.getVariable("after")
        if let list = after as? [any Sendable] {
            #expect(list.isEmpty)
        }
    }

    @Test("Dictionary delete still removes the key")
    func dictionaryDeleteStillWorks() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement(
            "Create the <d> with { a: 1, b: 2 }.")
        let result = try await session.executeStatement(
            "Delete the <a> from the <d>.")
        #expect(result.isSuccess)

        // Delete binds the shrunken dictionary to the result name.
        let shrunken = session.getVariable("a")
        if let dict = shrunken as? [String: any Sendable] {
            #expect(dict["a"] == nil)
            #expect(dict["b"] as? Int == 2)
        } else {
            Issue.record("expected dictionary result, got \(String(describing: shrunken))")
        }
    }
}
