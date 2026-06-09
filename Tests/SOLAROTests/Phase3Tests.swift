// ============================================================
// Phase3Tests.swift
// SOLARO — time-travel / project map / OpenAPI (Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO
import AROParser

@Suite("TimeTravelReader")
struct TimeTravelReaderTests {

    @Test func parsesPauseRecord() {
        let line = #"{"t":0.015,"k":"pause","fs":"createUser","line":"5","stmt":"Create the <user> with <data>.","syms":"[{\"n\":\"data\",\"ty\":\"Map\",\"v\":\"{name:Ada}\"}]"}"#
        let records = TimeTravelReader.parse(line)
        #expect(records.count == 1)
        let r = records[0]
        #expect(abs(r.time - 0.015) < 0.0001)
        #expect(r.kind == .pause)
        #expect(r.featureSet == "createUser")
        #expect(r.line == 5)
        #expect(r.statement == "Create the <user> with <data>.")
        #expect(r.symbols.count == 1)
        #expect(r.symbols.first?.name == "data")
    }

    @Test func skipsMalformedLines() {
        let lines = """
        {"t":0.015,"k":"pause"}
        not json at all
        {"t":0.020,"k":"end"}
        """
        let records = TimeTravelReader.parse(lines)
        #expect(records.count == 2)
        #expect(records[0].kind == .pause)
        #expect(records[1].kind == .end)
    }

    @Test func handlesEmptySymbols() {
        let line = #"{"t":0.1,"k":"pause"}"#
        let records = TimeTravelReader.parse(line)
        #expect(records.first?.symbols.count == 0)
    }
}

@Suite("ProjectMap")
struct ProjectMapTests {

    @Test func nodesPerFeatureSet() throws {
        let program = try parseARO("""
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

        #expect(map.nodes.count == 3)
        #expect(Set(map.nodes.map(\.featureSetName))
                == Set(["createUser", "SendWelcomeEmail", "listOrders"]))
    }

    @Test func groupsByBusinessActivity() throws {
        let program = try parseARO("""
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
        #expect(domains.contains("User API"))
        #expect(domains.contains("Order API"))
    }

    @Test func emitSubscribeEdge() throws {
        let program = try parseARO("""
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
        #expect(emitEdges.count == 1)
        #expect(emitEdges.first?.from == "createUser")
        #expect(emitEdges.first?.to == "SendWelcomeEmail")
    }
}

@Suite("OpenAPIPalette")
struct OpenAPIPaletteTests {

    @Test func discoversEndpoints() throws {
        let tmp = try makeProjectTree(files: [
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

        let model = try ProjectModel.load(Project(rootPath: tmp))
        let endpoints = OpenAPIPalette.endpoints(in: model, programs: [])
        #expect(endpoints.count == 3)
        #expect(endpoints.contains { $0.id == "GET /users" })
        #expect(endpoints.contains { $0.id == "POST /users" })
        #expect(endpoints.contains { $0.id == "GET /users/{id}" })
        for ep in endpoints {
            #expect(ep.operationId != nil)
        }
    }

    @Test func marksUsedEndpoints() throws {
        let tmp = try makeProjectTree(files: [
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

        let model = try ProjectModel.load(Project(rootPath: tmp))
        let program = try parseARO(
            try String(contentsOf: tmp.appendingPathComponent("main.aro"), encoding: .utf8)
        )

        let endpoints = OpenAPIPalette.endpoints(in: model, programs: [program])
        let createUser = endpoints.first { $0.operationId == "createUser" }
        let listUsers  = endpoints.first { $0.operationId == "listUsers" }
        #expect(createUser?.used == true)
        #expect(listUsers?.used == false)
    }
}
