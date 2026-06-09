// ============================================================
// OpenAPISourceMapTests.swift
// SOLARO — verify YAML line lookup for double-click-to-jump.
// ============================================================

import Testing
@testable import SOLARO

@Suite("OpenAPISourceMap")
struct OpenAPISourceMapTests {
    private let sample = """
    openapi: 3.0.3
    info:
      title: User API
      version: 1.0.0
    paths:
      /users:
        get:
          operationId: listUsers
          responses:
            "200":
              description: list
        post:
          operationId: createUser
      /users/{id}:
        get:
          operationId: getUser
    components:
      schemas:
        User:
          type: object
          properties:
            id:
              type: integer
        Error:
          type: object
    """

    @Test func locatesGetUsersOnGetLine() {
        let line = OpenAPISourceMap.line(for: "route:GET /users", in: sample)
        // `get:` under `/users:` is on line 7 (1-based).
        #expect(line == 7)
    }

    @Test func locatesPostUsers() {
        let line = OpenAPISourceMap.line(for: "route:POST /users", in: sample)
        // `post:` is line 12 (1-based).
        #expect(line == 12)
    }

    @Test func locatesParameterisedRoute() {
        let line = OpenAPISourceMap.line(for: "route:GET /users/{id}", in: sample)
        #expect(line == 15)
    }

    @Test func locatesSchemaUser() {
        let line = OpenAPISourceMap.line(for: "schema:User", in: sample)
        #expect(line == 19)
    }

    @Test func locatesSchemaErrorBesidesUser() {
        let line = OpenAPISourceMap.line(for: "schema:Error", in: sample)
        #expect(line == 24)
    }

    @Test func returnsNilForUnknown() {
        #expect(OpenAPISourceMap.line(for: "route:GET /missing", in: sample) == nil)
        #expect(OpenAPISourceMap.line(for: "schema:Missing", in: sample) == nil)
    }
}
