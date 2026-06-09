// ============================================================
// OpenAPIGraphTests.swift
// SOLARO — OpenAPI graph builder coverage
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("OpenAPIGraphBuilder")
struct OpenAPIGraphBuilderTests {

    @Test func parsesRoutesAndComponentSchemas() {
        let yaml = """
        openapi: 3.0.3
        info:
          title: Test
          version: 1.0.0
        paths:
          /users:
            get:
              operationId: listUsers
              summary: List users
              responses:
                '200':
                  content:
                    application/json:
                      schema:
                        $ref: '#/components/schemas/User'
        components:
          schemas:
            User:
              type: object
              properties:
                id:
                  type: string
                name:
                  type: string
        """
        let graph = OpenAPIGraphBuilder.build(yaml: yaml)
        #expect(graph.title == "Test")
        #expect(graph.version == "1.0.0")
        #expect(graph.nodes.contains { $0.id == "route:GET /users" })
        #expect(graph.nodes.contains { $0.id == "schema:User" })
        // The response $ref produces a response-kind edge.
        let resp = graph.refs.first { $0.kind == .response }
        #expect(resp != nil)
        #expect(resp?.fromID == "route:GET /users")
        #expect(resp?.toID == "schema:User")
    }

    @Test func schemaToSchemaRefViaProperty() {
        let yaml = """
        openapi: 3.0.3
        info: { title: t, version: '1' }
        paths: {}
        components:
          schemas:
            UserList:
              type: object
              properties:
                users:
                  type: array
                  items:
                    $ref: '#/components/schemas/User'
            User:
              type: object
              properties:
                id:
                  type: string
        """
        let graph = OpenAPIGraphBuilder.build(yaml: yaml)
        let crossRef = graph.refs.first {
            $0.fromID == "schema:UserList" && $0.toID == "schema:User"
        }
        #expect(crossRef != nil)
    }

    @Test func inlineRequestBodyMaterializesNode() {
        let yaml = """
        openapi: 3.0.3
        info: { title: t, version: '1' }
        paths:
          /signup:
            post:
              operationId: signup
              requestBody:
                content:
                  application/json:
                    schema:
                      type: object
                      properties:
                        email:
                          type: string
                        password:
                          type: string
              responses:
                '201':
                  description: created
        """
        let graph = OpenAPIGraphBuilder.build(yaml: yaml)
        let inline = graph.nodes.first { $0.id.hasPrefix("inline:") }
        #expect(inline != nil)
        if case .schema(_, let props) = inline?.kind {
            #expect(Set(props.map(\.name)) == Set(["email", "password"]))
        } else {
            Issue.record("expected inline schema node")
        }
        // Route → inline edge uses the inline-link kind so the view
        // can render it dotted.
        let inlineEdge = graph.refs.first {
            $0.fromID == "route:POST /signup" && $0.kind == .inlineLink
        }
        #expect(inlineEdge != nil)
    }
}
