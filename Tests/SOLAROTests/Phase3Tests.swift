// ============================================================
// Phase3Tests.swift
// SOLARO — Phase 3 unit tests (time-travel, project map, OpenAPI)
// ============================================================

import XCTest
@testable import SOLARO
import AROParser

final class Phase3Tests: XCTestCase {

    // MARK: - TimeTravelReader

    func testTimeTravelReaderParsesPauseRecord() {
        let line = #"{"t":0.015,"k":"pause","fs":"createUser","line":"5","stmt":"Create the <user> with <data>.","syms":"[{\"n\":\"data\",\"ty\":\"Map\",\"v\":\"{name:Ada}\"}]"}"#
        let records = TimeTravelReader.parse(line)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.time, 0.015, accuracy: 0.0001)
        XCTAssertEqual(r.kind, .pause)
        XCTAssertEqual(r.featureSet, "createUser")
        XCTAssertEqual(r.line, 5)
        XCTAssertEqual(r.statement, "Create the <user> with <data>.")
        XCTAssertEqual(r.symbols.count, 1)
        XCTAssertEqual(r.symbols.first?.name, "data")
    }

    func testTimeTravelReaderSkipsMalformedLines() {
        let lines = """
        {"t":0.015,"k":"pause"}
        not json at all
        {"t":0.020,"k":"end"}
        """
        let records = TimeTravelReader.parse(lines)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].kind, .pause)
        XCTAssertEqual(records[1].kind, .end)
    }

    func testTimeTravelReaderHandlesEmptySymbols() {
        let line = #"{"t":0.1,"k":"pause"}"#
        let records = TimeTravelReader.parse(line)
        XCTAssertEqual(records.first?.symbols.count, 0)
    }

    // MARK: - ProjectMap

    func testProjectMapNodesPerFeatureSet() throws {
        let program = try parse("""
        (createUser: User API) {
            Emit a <UserCreated: event> with <user>.
        }

        (SendWelcomeEmail: UserCreated Handler) {
            Return an <OK: status> for the <r>.
        }

        (listOrders: Order API) {
            Return an <OK: status> for the <r>.
        }
        """)
        let map = ProjectMap.build(from: [program])

        XCTAssertEqual(map.nodes.count, 3)
        XCTAssertEqual(Set(map.nodes.map(\.featureSetName)),
                       Set(["createUser", "SendWelcomeEmail", "listOrders"]))
    }

    func testProjectMapGroupsByBusinessActivity() throws {
        let program = try parse("""
        (createUser: User API) {
            Return an <OK: status> for the <r>.
        }
        (listUsers: User API) {
            Return an <OK: status> for the <r>.
        }
        (createOrder: Order API) {
            Return an <OK: status> for the <r>.
        }
        """)
        let map = ProjectMap.build(from: [program])
        let domains = map.domains
        XCTAssertTrue(domains.contains("User API"))
        XCTAssertTrue(domains.contains("Order API"))
    }

    func testProjectMapEdgeForEmitSubscribe() throws {
        let program = try parse("""
        (createUser: User API) {
            Emit a <UserCreated: event> with <user>.
        }
        (SendWelcomeEmail: UserCreated Handler) {
            Return an <OK: status> for the <r>.
        }
        """)
        let map = ProjectMap.build(from: [program])
        let emitEdges = map.edges.filter {
            if case .eventEmitSubscribe = $0.kind { return true }
            return false
        }
        XCTAssertEqual(emitEdges.count, 1)
        XCTAssertEqual(emitEdges.first?.from, "createUser")
        XCTAssertEqual(emitEdges.first?.to, "SendWelcomeEmail")
    }

    // MARK: - OpenAPIPalette

    func testOpenAPIPaletteDiscoversEndpoints() throws {
        let tmp = try makeTree(files: [
            "main.aro": "(Application-Start: x) { Return an <OK: status> for the <r>. }",
            "openapi.yaml": """
            openapi: 3.0.3
            info:
              title: Test
              version: 1.0.0
            paths:
              /users:
                get:
                  operationId: listUsers
                post:
                  operationId: createUser
              /users/{id}:
                get:
                  operationId: getUser
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)
        let endpoints = OpenAPIPalette.endpoints(in: model, programs: [])
        XCTAssertEqual(endpoints.count, 3)
        XCTAssertTrue(endpoints.contains { $0.id == "GET /users" })
        XCTAssertTrue(endpoints.contains { $0.id == "POST /users" })
        XCTAssertTrue(endpoints.contains { $0.id == "GET /users/{id}" })
        for ep in endpoints {
            XCTAssertNotNil(ep.operationId)
        }
    }

    func testOpenAPIPaletteMarksUsedEndpoints() throws {
        let tmp = try makeTree(files: [
            "main.aro": """
            (createUser: User API) {
                Return an <OK: status> for the <r>.
            }
            """,
            "openapi.yaml": """
            openapi: 3.0.3
            info: { title: t, version: '1.0.0' }
            paths:
              /users:
                post:
                  operationId: createUser
                get:
                  operationId: listUsers
            """,
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = Project(rootPath: tmp)
        let model = try ProjectModel.load(project)
        let program = try parse(
            try String(contentsOf: tmp.appendingPathComponent("main.aro"), encoding: .utf8)
        )

        let endpoints = OpenAPIPalette.endpoints(in: model, programs: [program])
        let createUser = endpoints.first { $0.operationId == "createUser" }
        let listUsers = endpoints.first { $0.operationId == "listUsers" }
        XCTAssertEqual(createUser?.used, true)
        XCTAssertEqual(listUsers?.used, false)
    }

    // MARK: - Helpers

    private func parse(_ source: String) throws -> Program {
        let tokens = try Lexer(source: source).tokenize()
        let parser = Parser(tokens: tokens)
        return try parser.parse()
    }

    private func makeTree(files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relPath, body) in files {
            let url = root.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
