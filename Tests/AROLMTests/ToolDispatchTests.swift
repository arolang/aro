// ============================================================
// ToolDispatchTests.swift
// ============================================================

import XCTest
@testable import AROLM

final class ToolDispatchTests: XCTestCase {
    func testRegistryDispatchesByName() async throws {
        let registry = ToolRegistry()
        let tool = LMToolDescriptor(
            name: "echo",
            description: "echo the input",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")])
                ])
            ])
        ) { args in
            args["text"]?.stringValue ?? ""
        }
        await registry.register(tool)
        let out = try await registry.dispatch(name: "echo", argumentsJSON: "{\"text\":\"hi\"}")
        XCTAssertEqual(out, "hi")
    }

    func testUnknownToolThrows() async {
        let registry = ToolRegistry()
        do {
            _ = try await registry.dispatch(name: "nope", argumentsJSON: "{}")
            XCTFail("expected error")
        } catch {
            // expected
        }
    }

    func testReadFileRespectsPathGuard() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-lm-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("hello.txt")
        try Data("line1\nline2\n".utf8).write(to: file)

        let pathGuard = PathGuard(root: dir)
        let tool = FileTools.readFile(guard: pathGuard)

        let out = try await tool.execute(.object(["path": .string("hello.txt")]))
        XCTAssertTrue(out.contains("line1"))
        XCTAssertTrue(out.contains("line2"))
    }

    func testPathGuardRejectsEscapes() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-lm-guard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pathGuard = PathGuard(root: dir)
        XCTAssertThrowsError(try pathGuard.resolve("../etc/passwd"))
        XCTAssertThrowsError(try pathGuard.resolve("/etc/passwd"))
    }
}
