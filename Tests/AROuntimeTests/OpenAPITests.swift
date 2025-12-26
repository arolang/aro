// ============================================================
// OpenAPITests.swift
// ARO Runtime - OpenAPI Integration Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - OpenAPI Spec Parsing Tests

@Suite("OpenAPI Spec Parsing Tests")
struct OpenAPISpecParsingTests {

    @Test("Parse simple OpenAPI spec from JSON")
    func testParseSimpleSpec() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": {
                "title": "Test API",
                "version": "1.0.0"
            },
            "paths": {}
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        #expect(spec.openapi == "3.0.3")
        #expect(spec.info.title == "Test API")
        #expect(spec.info.version == "1.0.0")
        #expect(spec.paths.isEmpty)
    }

    @Test("Parse spec with paths")
    func testParseSpecWithPaths() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": {
                "title": "User API",
                "version": "1.0.0"
            },
            "paths": {
                "/users": {
                    "get": {
                        "operationId": "listUsers",
                        "summary": "List all users",
                        "responses": {
                            "200": {
                                "description": "Success"
                            }
                        }
                    },
                    "post": {
                        "operationId": "createUser",
                        "responses": {
                            "201": {
                                "description": "Created"
                            }
                        }
                    }
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        #expect(spec.paths.count == 1)
        #expect(spec.paths["/users"] != nil)
        #expect(spec.paths["/users"]?.get?.operationId == "listUsers")
        #expect(spec.paths["/users"]?.post?.operationId == "createUser")
    }

    @Test("Parse spec with servers")
    func testParseSpecWithServers() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": {
                "title": "Test API",
                "version": "1.0.0"
            },
            "paths": {},
            "servers": [
                {
                    "url": "http://localhost:8080",
                    "description": "Local development"
                },
                {
                    "url": "https://api.example.com"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        #expect(spec.servers?.count == 2)
        #expect(spec.servers?[0].url == "http://localhost:8080")
        #expect(spec.servers?[0].description == "Local development")
    }

    @Test("Parse spec with path parameters")
    func testParseSpecWithParameters() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": {
                "title": "Test API",
                "version": "1.0.0"
            },
            "paths": {
                "/users/{id}": {
                    "get": {
                        "operationId": "getUser",
                        "parameters": [
                            {
                                "name": "id",
                                "in": "path",
                                "required": true
                            }
                        ],
                        "responses": {
                            "200": {
                                "description": "Success"
                            }
                        }
                    }
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        let getOp = spec.paths["/users/{id}"]?.get
        #expect(getOp?.operationId == "getUser")
        #expect(getOp?.parameters?.first?.name == "id")
        #expect(getOp?.parameters?.first?.in == "path")
        #expect(getOp?.parameters?.first?.required == true)
    }

    @Test("Parse spec with description")
    func testParseSpecWithDescription() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": {
                "title": "Test API",
                "version": "1.0.0",
                "description": "A test API for unit testing"
            },
            "paths": {}
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        #expect(spec.info.description == "A test API for unit testing")
    }
}

// MARK: - PathItem Tests

@Suite("PathItem Tests")
struct PathItemTests {

    @Test("PathItem all operations extraction")
    func testPathItemAllOperations() throws {
        let json = """
        {
            "get": {
                "operationId": "getOp",
                "responses": {"200": {"description": "OK"}}
            },
            "post": {
                "operationId": "postOp",
                "responses": {"200": {"description": "OK"}}
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pathItem = try JSONDecoder().decode(PathItem.self, from: data)

        let ops = pathItem.allOperations
        #expect(ops.count == 2)
    }

    @Test("PathItem with single method")
    func testPathItemSingleMethod() throws {
        let json = """
        {
            "delete": {
                "operationId": "deleteOp",
                "responses": {"204": {"description": "No Content"}}
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pathItem = try JSONDecoder().decode(PathItem.self, from: data)

        #expect(pathItem.delete?.operationId == "deleteOp")
        #expect(pathItem.get == nil)
        #expect(pathItem.post == nil)
    }
}

// MARK: - Operation Tests

@Suite("Operation Tests")
struct OperationTests {

    @Test("Operation parsing")
    func testOperationParsing() throws {
        let json = """
        {
            "operationId": "testOp",
            "summary": "Test operation",
            "description": "A test operation for unit testing",
            "responses": {
                "200": {"description": "Success"}
            }
        }
        """

        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(Operation.self, from: data)

        #expect(operation.operationId == "testOp")
        #expect(operation.summary == "Test operation")
        #expect(operation.description == "A test operation for unit testing")
    }

    @Test("Operation with tags")
    func testOperationWithTags() throws {
        let json = """
        {
            "operationId": "taggedOp",
            "tags": ["users", "admin"],
            "responses": {"200": {"description": "OK"}}
        }
        """

        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(Operation.self, from: data)

        #expect(operation.tags?.count == 2)
        #expect(operation.tags?.contains("users") == true)
    }

    @Test("Operation deprecated flag")
    func testOperationDeprecated() throws {
        let json = """
        {
            "operationId": "oldOp",
            "deprecated": true,
            "responses": {"200": {"description": "OK"}}
        }
        """

        let data = json.data(using: .utf8)!
        let operation = try JSONDecoder().decode(Operation.self, from: data)

        #expect(operation.deprecated == true)
    }
}

// MARK: - Parameter Tests

@Suite("Parameter Tests")
struct ParameterTests {

    @Test("Path parameter parsing")
    func testPathParameter() throws {
        let json = """
        {
            "name": "userId",
            "in": "path",
            "required": true
        }
        """

        let data = json.data(using: .utf8)!
        let param = try JSONDecoder().decode(Parameter.self, from: data)

        #expect(param.name == "userId")
        #expect(param.in == "path")
        #expect(param.required == true)
    }

    @Test("Query parameter parsing")
    func testQueryParameter() throws {
        let json = """
        {
            "name": "page",
            "in": "query",
            "required": false,
            "description": "Page number"
        }
        """

        let data = json.data(using: .utf8)!
        let param = try JSONDecoder().decode(Parameter.self, from: data)

        #expect(param.name == "page")
        #expect(param.in == "query")
        #expect(param.required == false)
        #expect(param.description == "Page number")
    }

    @Test("Header parameter parsing")
    func testHeaderParameter() throws {
        let json = """
        {
            "name": "X-API-Key",
            "in": "header",
            "required": true
        }
        """

        let data = json.data(using: .utf8)!
        let param = try JSONDecoder().decode(Parameter.self, from: data)

        #expect(param.name == "X-API-Key")
        #expect(param.in == "header")
    }
}

// MARK: - OpenAPI Response Tests

@Suite("OpenAPI Response Tests")
struct OpenAPIResponseTests {

    @Test("Response parsing")
    func testResponseParsing() throws {
        let json = """
        {
            "description": "Successful response"
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(OpenAPIResponse.self, from: data)

        #expect(response.description == "Successful response")
    }

    @Test("Response with content")
    func testResponseWithContent() throws {
        let json = """
        {
            "description": "JSON response",
            "content": {
                "application/json": {
                    "schema": {
                        "type": "object"
                    }
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(OpenAPIResponse.self, from: data)

        #expect(response.content?["application/json"] != nil)
    }
}
