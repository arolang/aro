// ============================================================
// FileActionsTests.swift
// ARO Runtime - File Actions Unit Tests
// ARO-0036: Native File and Directory Operations
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - List Action Tests

@Suite("List Action Tests")
struct ListActionTests {

    @Test("List action role is request")
    func testListActionRole() {
        #expect(ListAction.role == .request)
    }

    @Test("List action verbs")
    func testListActionVerbs() {
        #expect(ListAction.verbs.contains("list"))
    }

    @Test("List action valid prepositions")
    func testListActionPrepositions() {
        #expect(ListAction.validPrepositions.contains(.from))
        #expect(ListAction.validPrepositions.count == 1)
    }
}

// MARK: - Stat Action Tests

@Suite("Stat Action Tests")
struct StatActionTests {

    @Test("Stat action role is request")
    func testStatActionRole() {
        #expect(StatAction.role == .request)
    }

    @Test("Stat action verbs")
    func testStatActionVerbs() {
        #expect(StatAction.verbs.contains("stat"))
    }

    @Test("Stat action valid prepositions")
    func testStatActionPrepositions() {
        #expect(StatAction.validPrepositions.contains(.for))
    }
}

// MARK: - Exists Action Tests

@Suite("Exists Action Tests")
struct ExistsActionTests {

    @Test("Exists action role is request")
    func testExistsActionRole() {
        #expect(ExistsAction.role == .request)
    }

    @Test("Exists action verbs")
    func testExistsActionVerbs() {
        #expect(ExistsAction.verbs.contains("exists"))
    }

    @Test("Exists action valid prepositions")
    func testExistsActionPrepositions() {
        #expect(ExistsAction.validPrepositions.contains(.for))
    }
}

// MARK: - CreateDirectory Action Tests

@Suite("CreateDirectory Action Tests")
struct CreateDirectoryActionTests {

    @Test("CreateDirectory action role is own")
    func testCreateDirectoryActionRole() {
        #expect(CreateDirectoryAction.role == .own)
    }

    @Test("CreateDirectory action verbs")
    func testCreateDirectoryActionVerbs() {
        #expect(CreateDirectoryAction.verbs.contains("createdirectory"))
        #expect(CreateDirectoryAction.verbs.contains("mkdir"))
    }

    @Test("CreateDirectory action valid prepositions")
    func testCreateDirectoryActionPrepositions() {
        #expect(CreateDirectoryAction.validPrepositions.contains(.to))
        #expect(CreateDirectoryAction.validPrepositions.contains(.for))
    }
}

// MARK: - Copy Action Tests

@Suite("Copy Action Tests")
struct CopyActionTests {

    @Test("Copy action role is own")
    func testCopyActionRole() {
        #expect(CopyAction.role == .own)
    }

    @Test("Copy action verbs")
    func testCopyActionVerbs() {
        #expect(CopyAction.verbs.contains("copy"))
    }

    @Test("Copy action valid prepositions")
    func testCopyActionPrepositions() {
        #expect(CopyAction.validPrepositions.contains(.to))
    }
}

// MARK: - Move Action Tests

@Suite("Move Action Tests")
struct MoveActionTests {

    @Test("Move action role is own")
    func testMoveActionRole() {
        #expect(MoveAction.role == .own)
    }

    @Test("Move action verbs")
    func testMoveActionVerbs() {
        #expect(MoveAction.verbs.contains("move"))
        #expect(MoveAction.verbs.contains("rename"))
    }

    @Test("Move action valid prepositions")
    func testMoveActionPrepositions() {
        #expect(MoveAction.validPrepositions.contains(.to))
    }
}

// MARK: - Append Action Tests

@Suite("Append Action Tests")
struct AppendActionTests {

    @Test("Append action role is response")
    func testAppendActionRole() {
        #expect(AppendAction.role == .response)
    }

    @Test("Append action verbs")
    func testAppendActionVerbs() {
        #expect(AppendAction.verbs.contains("append"))
    }

    @Test("Append action valid prepositions")
    func testAppendActionPrepositions() {
        #expect(AppendAction.validPrepositions.contains(.to))
        #expect(AppendAction.validPrepositions.contains(.into))
    }
}

// MARK: - Result Type Tests

@Suite("File Action Result Types")
struct FileActionResultTypeTests {

    @Test("CreateDirectoryResult creation")
    func testCreateDirectoryResult() {
        let result = CreateDirectoryResult(path: "/test/dir", success: true)
        #expect(result.path == "/test/dir")
        #expect(result.success == true)
    }

    @Test("CopyResult creation")
    func testCopyResult() {
        let result = CopyResult(source: "/src/file.txt", destination: "/dst/file.txt", success: true)
        #expect(result.source == "/src/file.txt")
        #expect(result.destination == "/dst/file.txt")
        #expect(result.success == true)
    }

    @Test("MoveResult creation")
    func testMoveResult() {
        let result = MoveResult(source: "/old/path", destination: "/new/path", success: true)
        #expect(result.source == "/old/path")
        #expect(result.destination == "/new/path")
        #expect(result.success == true)
    }

    @Test("AppendResult creation")
    func testAppendResult() {
        let result = AppendResult(path: "/log/file.log", success: true)
        #expect(result.path == "/log/file.log")
        #expect(result.success == true)
    }
}
