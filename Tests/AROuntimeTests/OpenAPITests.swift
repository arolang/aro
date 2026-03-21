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

    @Test("Parse spec with server variables")
    func testParseSpecWithServerVariables() throws {
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
                    "url": "{scheme}://api.{environment}.example.com:{port}",
                    "description": "Configurable server",
                    "variables": {
                        "scheme": {
                            "default": "https",
                            "enum": ["https", "http"],
                            "description": "The transfer protocol"
                        },
                        "environment": {
                            "default": "production"
                        },
                        "port": {
                            "default": "8080",
                            "enum": ["8080", "443"]
                        }
                    }
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)

        let server = try #require(spec.servers?.first)
        #expect(server.url == "{scheme}://api.{environment}.example.com:{port}")
        let variables = try #require(server.variables)
        #expect(variables.count == 3)
        #expect(variables["scheme"]?.default == "https")
        #expect(variables["scheme"]?.enum == ["https", "http"])
        #expect(variables["scheme"]?.description == "The transfer protocol")
        #expect(variables["environment"]?.default == "production")
        #expect(variables["environment"]?.enum == nil)
        #expect(variables["port"]?.default == "8080")
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

// MARK: - Server Variable Tests

@Suite("Server Variable Tests")
struct ServerVariableTests {

    @Test("resolvedURL substitutes all variable defaults")
    func testResolvedURLSubstitutesAllVariables() {
        let server = Server(
            url: "{scheme}://api.{environment}.example.com:{port}",
            description: nil,
            variables: [
                "scheme": ServerVariable(default: "https", enum: nil, description: nil),
                "environment": ServerVariable(default: "production", enum: nil, description: nil),
                "port": ServerVariable(default: "8080", enum: nil, description: nil)
            ]
        )
        #expect(server.resolvedURL == "https://api.production.example.com:8080")
    }

    @Test("resolvedURL returns original URL when variables is nil")
    func testResolvedURLWithNoVariables() {
        let server = Server(url: "https://api.example.com:9000", description: nil, variables: nil)
        #expect(server.resolvedURL == "https://api.example.com:9000")
    }

    @Test("resolvedURL leaves unreferenced placeholders intact")
    func testResolvedURLLeavesUnknownPlaceholders() {
        let server = Server(
            url: "{scheme}://api.{environment}.example.com:{port}",
            description: nil,
            variables: [
                "scheme": ServerVariable(default: "https", enum: nil, description: nil)
                // environment and port not provided
            ]
        )
        let resolved = server.resolvedURL
        #expect(resolved == "https://api.{environment}.example.com:{port}")
    }

    @Test("serverPort uses resolvedURL to extract port")
    func testServerPortUsesResolvedURL() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {},
            "servers": [
                {
                    "url": "http://localhost:{port}",
                    "variables": {
                        "port": { "default": "9090" }
                    }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        #expect(spec.serverPort == 9090)
    }

    @Test("serverHost uses resolvedURL to extract host")
    func testServerHostUsesResolvedURL() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {},
            "servers": [
                {
                    "url": "{scheme}://{host}:8080",
                    "variables": {
                        "scheme": { "default": "http" },
                        "host": { "default": "myserver.local" }
                    }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        #expect(spec.serverHost == "myserver.local")
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

// MARK: - Contract Validation Tests

@Suite("Contract Validation Tests")
struct ContractValidationTests {

    /// A minimal spec with two operations: listUsers (GET /users) and createUser (POST /users).
    private static let twoOperationSpecJSON = """
    {
        "openapi": "3.0.3",
        "info": { "title": "User API", "version": "1.0.0" },
        "paths": {
            "/users": {
                "get": {
                    "operationId": "listUsers",
                    "responses": { "200": { "description": "OK" } }
                },
                "post": {
                    "operationId": "createUser",
                    "responses": { "201": { "description": "Created" } }
                }
            }
        }
    }
    """

    private var spec: OpenAPISpec {
        get throws {
            let data = Self.twoOperationSpecJSON.data(using: .utf8)!
            return try JSONDecoder().decode(OpenAPISpec.self, from: data)
        }
    }

    @Test("validate reports all missing handlers at once")
    func testMissingHandlersAllReported() throws {
        let source = """
        (Application-Start: Test App) {
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let featureSets = result.analyzedProgram.featureSets

        do {
            try ContractValidator.validate(spec: try spec, featureSets: featureSets)
            Issue.record("Expected ContractValidationError.missingHandlers to be thrown")
        } catch let error as ContractValidationError {
            guard case .missingHandlers(let handlers) = error else {
                Issue.record("Expected .missingHandlers, got \(error)")
                return
            }
            #expect(handlers.count == 2)
            let ids = Set(handlers.map { $0.operationId })
            #expect(ids.contains("listUsers"))
            #expect(ids.contains("createUser"))
        }
    }

    @Test("validate passes when all operationIds have matching feature sets")
    func testAllHandlersPresent() throws {
        let source = """
        (listUsers: User API) {
            Return an <OK: status> for the <users>.
        }
        (createUser: User API) {
            Return a <Created: status> for the <user>.
        }
        """
        let result = Compiler().compile(source)
        let featureSets = result.analyzedProgram.featureSets

        // Must not throw
        try ContractValidator.validate(spec: try spec, featureSets: featureSets)
    }

    @Test("validate passes when feature sets are a superset of operationIds")
    func testExtraFeatureSetsAreAllowed() throws {
        let source = """
        (listUsers: User API) {
            Return an <OK: status> for the <users>.
        }
        (createUser: User API) {
            Return a <Created: status> for the <user>.
        }
        (deleteUser: User API) {
            Return an <OK: status> for the <result>.
        }
        """
        let result = Compiler().compile(source)
        let featureSets = result.analyzedProgram.featureSets

        // Extra feature set not in spec is fine
        try ContractValidator.validate(spec: try spec, featureSets: featureSets)
    }

    @Test("Application.run() throws ContractValidationError before the server starts")
    func testEagerValidationOnRun() async throws {
        // ARO source has Application-Start but no listUsers / createUser handlers
        let source = """
        (Application-Start: Test App) {
            Return an <OK: status> for the <startup>.
        }
        """
        let app = try Application(
            sources: [("main.aro", source)],
            openAPISpec: try spec
        )

        do {
            _ = try await app.run()
            Issue.record("Expected Application.run() to throw ContractValidationError.missingHandlers")
        } catch let error as ContractValidationError {
            guard case .missingHandlers(let handlers) = error else {
                Issue.record("Expected .missingHandlers, got \(error)")
                return
            }
            #expect(!handlers.isEmpty)
            let ids = Set(handlers.map { $0.operationId })
            #expect(ids.contains("listUsers"))
            #expect(ids.contains("createUser"))
        }
    }
}

// MARK: - Path-Level Parameter Merging Tests

@Suite("Path-Level Parameter Merging Tests")
struct PathLevelParameterMergingTests {

    @Test("effectiveParameters includes path-level id param for GET operation without operation-level params")
    func testPathLevelParamInheritedByGet() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/items/{id}": {
                    "parameters": [
                        { "name": "id", "in": "path", "required": true }
                    ],
                    "get": {
                        "operationId": "getItem",
                        "responses": { "200": { "description": "OK" } }
                    },
                    "delete": {
                        "operationId": "deleteItem",
                        "responses": { "204": { "description": "No Content" } }
                    }
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        let registry = OpenAPIRouteRegistry(spec: spec)

        let getMatch = try #require(registry.match(method: "GET", path: "/items/42"))
        #expect(getMatch.effectiveParameters.count == 1)
        #expect(getMatch.effectiveParameters.first?.name == "id")
        #expect(getMatch.effectiveParameters.first?.in == "path")

        let deleteMatch = try #require(registry.match(method: "DELETE", path: "/items/42"))
        #expect(deleteMatch.effectiveParameters.count == 1)
        #expect(deleteMatch.effectiveParameters.first?.name == "id")
        #expect(deleteMatch.effectiveParameters.first?.in == "path")
    }

    @Test("operation-level parameter overrides path-level parameter with same name and in")
    func testOperationLevelOverridesPathLevel() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/items/{id}": {
                    "parameters": [
                        { "name": "id", "in": "path", "required": true, "description": "path-level" }
                    ],
                    "get": {
                        "operationId": "getItem",
                        "parameters": [
                            { "name": "id", "in": "path", "required": true, "description": "operation-level" }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        let registry = OpenAPIRouteRegistry(spec: spec)

        let match = try #require(registry.match(method: "GET", path: "/items/99"))
        // Only one parameter should remain (operation-level wins)
        #expect(match.effectiveParameters.count == 1)
        #expect(match.effectiveParameters.first?.description == "operation-level")
    }

    @Test("effectiveParameters combines path-level and operation-level params with different names")
    func testPathAndOperationLevelParamsCombined() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/items/{id}": {
                    "parameters": [
                        { "name": "id", "in": "path", "required": true }
                    ],
                    "get": {
                        "operationId": "getItem",
                        "parameters": [
                            { "name": "expand", "in": "query", "required": false }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        let registry = OpenAPIRouteRegistry(spec: spec)

        let match = try #require(registry.match(method: "GET", path: "/items/7"))
        #expect(match.effectiveParameters.count == 2)
        let names = Set(match.effectiveParameters.map { $0.name })
        #expect(names.contains("id"))
        #expect(names.contains("expand"))
    }

    @Test("effectiveParameters is empty when neither path-level nor operation-level params exist")
    func testNoParamsGivesEmptyEffectiveParameters() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/health": {
                    "get": {
                        "operationId": "healthCheck",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        let registry = OpenAPIRouteRegistry(spec: spec)

        let match = try #require(registry.match(method: "GET", path: "/health"))
        #expect(match.effectiveParameters.isEmpty)
    }
}

// MARK: - Deprecation Warning Tests

#if !os(Windows)

@Suite("Deprecation Warning Tests")
struct DeprecationWarningTests {

    private func makeSpec(deprecated: Bool, parameters: [[String: Any]] = []) throws -> OpenAPISpec {
        var operationDict: [String: Any] = [
            "operationId": "oldOp",
            "deprecated": deprecated,
            "responses": ["200": ["description": "OK"]]
        ]
        if !parameters.isEmpty {
            operationDict["parameters"] = parameters
        }
        let specDict: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "Test API", "version": "1.0.0"],
            "paths": [
                "/legacy": [
                    "get": operationDict
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: specDict)
        return try JSONDecoder().decode(OpenAPISpec.self, from: data)
    }

    private func makeHandler(spec: OpenAPISpec) -> OpenAPIHTTPHandler {
        let registry = OpenAPIRouteRegistry(spec: spec)
        let bus = EventBus()
        return OpenAPIHTTPHandler(routeRegistry: registry, eventBus: bus)
    }

    @Test("Deprecated operation adds Deprecation: true response header")
    func testDeprecatedOperationAddsHeader() async throws {
        let spec = try makeSpec(deprecated: true)
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/legacy")
        let response = await handler.handleRequest(request)

        #expect(response.headers["Deprecation"] == "true")
    }

    @Test("Non-deprecated operation does not add Deprecation header")
    func testNonDeprecatedOperationNoHeader() async throws {
        let spec = try makeSpec(deprecated: false)
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/legacy")
        let response = await handler.handleRequest(request)

        #expect(response.headers["Deprecation"] == nil)
    }

    @Test("Deprecated operation preserves standard response headers")
    func testDeprecatedOperationPreservesStandardHeaders() async throws {
        let spec = try makeSpec(deprecated: true)
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/legacy")
        let response = await handler.handleRequest(request)

        #expect(response.headers["Content-Type"] == "application/json")
        #expect(response.headers["X-Operation-ID"] == "oldOp")
        #expect(response.headers["Deprecation"] == "true")
    }

    @Test("Deprecated parameter field is parsed from JSON")
    func testDeprecatedParameterParsed() throws {
        let json = """
        {
            "name": "legacyParam",
            "in": "query",
            "deprecated": true
        }
        """
        let data = json.data(using: .utf8)!
        let param = try JSONDecoder().decode(Parameter.self, from: data)

        #expect(param.deprecated == true)
    }

    @Test("Non-deprecated parameter has nil deprecated field")
    func testNonDeprecatedParameterFieldIsNil() throws {
        let json = """
        {
            "name": "normalParam",
            "in": "query"
        }
        """
        let data = json.data(using: .utf8)!
        let param = try JSONDecoder().decode(Parameter.self, from: data)

        #expect(param.deprecated == nil)
    }

    @Test("Unmatched route returns 404 without Deprecation header")
    func testUnmatchedRouteNoDeprecationHeader() async throws {
        let spec = try makeSpec(deprecated: true)
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/nonexistent")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 404)
        #expect(response.headers["Deprecation"] == nil)
    }
}

// MARK: - allowEmptyValue Filtering Tests

/// Pure helper that mirrors the allowEmptyValue filter logic in OpenAPIHTTPHandler.handleRequest().
/// Parameters with allowEmptyValue absent or false and an empty value are removed.
/// Parameters not listed in the spec always pass through.
private func applyAllowEmptyValueFilter(
    queryParameters: [String: String],
    specParameters: [Parameter]
) -> [String: String] {
    var allowEmptyValueByName: [String: Bool] = [:]
    for param in specParameters where param.in == "query" {
        allowEmptyValueByName[param.name] = param.allowEmptyValue ?? false
    }
    return queryParameters.filter { name, value in
        guard value.isEmpty else { return true }
        guard let allowEmpty = allowEmptyValueByName[name] else { return true }
        return allowEmpty
    }
}

@Suite("allowEmptyValue Filtering Tests")
struct AllowEmptyValueFilteringTests {

    private func makeParameters(_ dicts: [[String: Any]]) throws -> [Parameter] {
        let data = try JSONSerialization.data(withJSONObject: dicts)
        return try JSONDecoder().decode([Parameter].self, from: data)
    }

    @Test("Empty query param is filtered out when allowEmptyValue is not set (defaults to false)")
    func testEmptyValueFilteredWhenAllowEmptyValueNotSet() throws {
        let params = try makeParameters([["name": "status", "in": "query"]])
        let result = applyAllowEmptyValueFilter(queryParameters: ["status": ""], specParameters: params)
        #expect(result["status"] == nil,
                "Empty 'status' should be filtered out when allowEmptyValue is not set")
    }

    @Test("Empty query param passes through when allowEmptyValue is true")
    func testEmptyValuePassesThroughWhenAllowEmptyValueTrue() throws {
        let params = try makeParameters([
            ["name": "status", "in": "query", "allowEmptyValue": true]
        ])
        let result = applyAllowEmptyValueFilter(queryParameters: ["status": ""], specParameters: params)
        #expect(result["status"] == "",
                "Empty 'status' should pass through when allowEmptyValue is true")
    }

    @Test("Non-empty query param always passes through regardless of allowEmptyValue")
    func testNonEmptyValueAlwaysPassesThrough() throws {
        let params = try makeParameters([["name": "status", "in": "query"]])
        let result = applyAllowEmptyValueFilter(queryParameters: ["status": "active"], specParameters: params)
        #expect(result["status"] == "active",
                "Non-empty 'status' should always pass through")
    }

    @Test("Query param not listed in spec always passes through even if empty")
    func testUnknownParamPassesThroughEvenIfEmpty() throws {
        // spec declares 'status' but request sends 'unknown'
        let params = try makeParameters([["name": "status", "in": "query"]])
        let result = applyAllowEmptyValueFilter(queryParameters: ["unknown": ""], specParameters: params)
        #expect(result["unknown"] == "",
                "Param not in spec should pass through even if empty")
    }

    @Test("allowEmptyValue: false explicitly also filters empty value")
    func testExplicitAllowEmptyValueFalseFiltersEmpty() throws {
        let params = try makeParameters([
            ["name": "tag", "in": "query", "allowEmptyValue": false]
        ])
        let result = applyAllowEmptyValueFilter(queryParameters: ["tag": ""], specParameters: params)
        #expect(result["tag"] == nil,
                "Empty 'tag' should be filtered when allowEmptyValue is explicitly false")
    }

    @Test("Mixed params: empty+not-allowed filtered, empty+allowed kept, non-empty kept")
    func testMixedParamsFiltering() throws {
        let params = try makeParameters([
            ["name": "status", "in": "query"],                              // allowEmptyValue absent → false
            ["name": "tag", "in": "query", "allowEmptyValue": true],        // explicitly true
            ["name": "name", "in": "query", "allowEmptyValue": false]       // explicitly false
        ])
        let result = applyAllowEmptyValueFilter(queryParameters: [
            "status": "",       // should be filtered (no allowEmptyValue)
            "tag": "",          // should pass (allowEmptyValue: true)
            "name": "",         // should be filtered (allowEmptyValue: false)
            "extra": "",        // should pass (not in spec)
            "q": "hello"        // non-empty, should pass
        ], specParameters: params)
        #expect(result["status"] == nil)
        #expect(result["tag"] == "")
        #expect(result["name"] == nil)
        #expect(result["extra"] == "")
        #expect(result["q"] == "hello")
    }

    @Test("allowEmptyValue filter uses effectiveParameters (path-level + operation-level merged)")
    func testFilterUsesEffectiveParameters() throws {
        // Path-level declares 'tag' with allowEmptyValue: false; operation-level overrides with true
        let pathLevelParams = try makeParameters([
            ["name": "tag", "in": "query", "allowEmptyValue": false]
        ])
        let operationLevelParams = try makeParameters([
            ["name": "tag", "in": "query", "allowEmptyValue": true]
        ])
        let effective = mergedParameters(pathLevel: pathLevelParams, operationLevel: operationLevelParams)
        let result = applyAllowEmptyValueFilter(queryParameters: ["tag": ""], specParameters: effective)
        #expect(result["tag"] == "",
                "Operation-level allowEmptyValue: true should override path-level false")
    }
}

// MARK: - Required Parameter Validation Tests

@Suite("Required Parameter Validation Tests")
struct RequiredParameterValidationTests {

    private func makeSpec(parameters: [[String: Any]], inPath: String = "/items") throws -> OpenAPISpec {
        let specDict: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "Test API", "version": "1.0.0"],
            "paths": [
                inPath: [
                    "get": [
                        "operationId": "getItems",
                        "parameters": parameters,
                        "responses": ["200": ["description": "OK"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: specDict)
        return try JSONDecoder().decode(OpenAPISpec.self, from: data)
    }

    private func makeHandler(spec: OpenAPISpec) -> OpenAPIHTTPHandler {
        let registry = OpenAPIRouteRegistry(spec: spec)
        let bus = EventBus()
        return OpenAPIHTTPHandler(routeRegistry: registry, eventBus: bus)
    }

    // MARK: Required query parameter

    @Test("Missing required query parameter returns 400")
    func testMissingRequiredQueryParamReturns400() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Required query parameter"))
            #expect(text.contains("'q'"))
        }
    }

    @Test("Present required query parameter does not return 400")
    func testPresentRequiredQueryParamNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items", queryParameters: ["q": "hello"])
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Optional query parameter missing does not return 400")
    func testMissingOptionalQueryParamNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query", "required": false]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Query parameter with no required field missing does not return 400")
    func testMissingQueryParamWithoutRequiredFieldNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query"]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    // MARK: Required header parameter

    @Test("Missing required header returns 400")
    func testMissingRequiredHeaderReturns400() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "X-API-Key", "in": "header", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Required header"))
            #expect(text.contains("'X-API-Key'"))
        }
    }

    @Test("Present required header does not return 400")
    func testPresentRequiredHeaderNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "X-API-Key", "in": "header", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items", headers: ["X-API-Key": "secret"])
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Required header check is case-insensitive")
    func testRequiredHeaderCaseInsensitive() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "X-API-Key", "in": "header", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        // Provide the header with all-lowercase name
        let request = HTTPRequest(method: "GET", path: "/items", headers: ["x-api-key": "secret"])
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Optional header missing does not return 400")
    func testMissingOptionalHeaderNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "X-API-Key", "in": "header", "required": false]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    // MARK: Path-level required parameters

    @Test("Required query param from path-level parameters also triggers 400 when missing")
    func testPathLevelRequiredQueryParamMissingReturns400() async throws {
        let specDict: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "Test API", "version": "1.0.0"],
            "paths": [
                "/items": [
                    "parameters": [
                        ["name": "version", "in": "query", "required": true]
                    ],
                    "get": [
                        "operationId": "getItems",
                        "responses": ["200": ["description": "OK"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: specDict)
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: data)
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Required query parameter"))
            #expect(text.contains("'version'"))
        }
    }

    @Test("400 response body contains JSON error and message fields")
    func testMissingRequiredParamResponseBodyIsJSON() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        #expect(response.headers["Content-Type"] == "application/json")
        let body = try #require(response.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["error"] == "Bad Request")
        #expect(json["message"] != nil)
    }
}

// MARK: - Header Parameter Binding Tests

@Suite("Header Parameter Binding Tests")
struct HeaderParameterBindingTests {

    @Test("bindHeaderParameters creates headerParameters dict with lowercase keys")
    func testBindHeaderParametersDict() {
        let headers = ["X-Api-Key": "secret", "Authorization": "Bearer token"]
        let result = OpenAPIContextBinder.bindHeaderParameters(headers)

        let dict = result["headerParameters"] as? [String: String]
        #expect(dict != nil)
        #expect(dict?["x-api-key"] == "secret")
        #expect(dict?["authorization"] == "Bearer token")
    }

    @Test("bindHeaderParameters creates individual headerParameters.{name} keys")
    func testBindHeaderParametersIndividualKeys() {
        let headers = ["X-Api-Key": "my-key", "Content-Type": "application/json"]
        let result = OpenAPIContextBinder.bindHeaderParameters(headers)

        #expect(result["headerParameters.x-api-key"] as? String == "my-key")
        #expect(result["headerParameters.content-type"] as? String == "application/json")
    }

    @Test("bindHeaderParameters with empty headers produces empty dict")
    func testBindHeaderParametersEmpty() {
        let result = OpenAPIContextBinder.bindHeaderParameters([:])

        let dict = result["headerParameters"] as? [String: String]
        #expect(dict != nil)
        #expect(dict?.isEmpty == true)
    }

    @Test("bindHeaderParameters normalises mixed-case header names")
    func testBindHeaderParametersCaseNormalisation() {
        let headers = [
            "X-REQUEST-ID": "abc123",
            "x-correlation-id": "xyz789",
            "X-Forwarded-For": "192.168.1.1"
        ]
        let result = OpenAPIContextBinder.bindHeaderParameters(headers)

        let dict = result["headerParameters"] as? [String: String]
        #expect(dict?["x-request-id"] == "abc123")
        #expect(dict?["x-correlation-id"] == "xyz789")
        #expect(dict?["x-forwarded-for"] == "192.168.1.1")
    }

    @Test("bindHeaderParameters does not include non-header entries in main dict")
    func testBindHeaderParametersOnlyContainsHeaderKeys() {
        let headers = ["X-Api-Key": "key1", "Accept": "application/json"]
        let result = OpenAPIContextBinder.bindHeaderParameters(headers)

        // The top-level result should have exactly 4 keys: headerParameters + 2 individual entries
        #expect(result.count == 3)
        #expect(result["headerParameters"] != nil)
        #expect(result["headerParameters.x-api-key"] != nil)
        #expect(result["headerParameters.accept"] != nil)
    }
}

// MARK: - Cookie Header Parsing Tests

@Suite("Cookie Header Parsing Tests")
struct CookieHeaderParsingTests {

    @Test("parseCookieHeader parses a single cookie")
    func testSingleCookie() {
        let result = parseCookieHeader("session-id=abc123")
        #expect(result["session-id"] == "abc123")
        #expect(result.count == 1)
    }

    @Test("parseCookieHeader parses multiple cookies")
    func testMultipleCookies() {
        let result = parseCookieHeader("session-id=abc123; token=xyz789; theme=dark")
        #expect(result["session-id"] == "abc123")
        #expect(result["token"] == "xyz789")
        #expect(result["theme"] == "dark")
        #expect(result.count == 3)
    }

    @Test("parseCookieHeader returns empty dict for empty string")
    func testEmptyString() {
        let result = parseCookieHeader("")
        #expect(result.isEmpty)
    }

    @Test("parseCookieHeader percent-decodes values")
    func testPercentEncodedValue() {
        let result = parseCookieHeader("redirect=%2Fdashboard%2Fhome")
        #expect(result["redirect"] == "/dashboard/home")
    }

    @Test("parseCookieHeader handles value containing equals sign")
    func testValueWithEqualsSign() {
        // Base64-encoded values contain '='; only the first '=' should split name from value
        let result = parseCookieHeader("token=aGVsbG8=")
        #expect(result["token"] == "aGVsbG8=")
    }

    @Test("parseCookieHeader skips malformed pairs with no equals sign")
    func testMalformedPairSkipped() {
        let result = parseCookieHeader("badpair; session-id=ok")
        #expect(result["badpair"] == nil)
        #expect(result["session-id"] == "ok")
    }

    @Test("parseCookieHeader trims whitespace around name and value")
    func testWhitespaceTrimmed() {
        let result = parseCookieHeader("  name  =  value  ")
        #expect(result["name"] == "value")
    }
}

// MARK: - Cookie Parameter Binding Tests

@Suite("Cookie Parameter Binding Tests")
struct CookieParameterBindingTests {

    @Test("bindCookieParameters creates cookieParameters dict")
    func testBindCookieParametersDict() {
        let cookies = ["session-id": "abc123", "theme": "dark"]
        let result = OpenAPIContextBinder.bindCookieParameters(cookies)

        let dict = result["cookieParameters"] as? [String: String]
        #expect(dict != nil)
        #expect(dict?["session-id"] == "abc123")
        #expect(dict?["theme"] == "dark")
    }

    @Test("bindCookieParameters creates individual cookieParameters.{name} keys")
    func testBindCookieParametersIndividualKeys() {
        let cookies = ["session-id": "abc123", "token": "xyz789"]
        let result = OpenAPIContextBinder.bindCookieParameters(cookies)

        #expect(result["cookieParameters.session-id"] as? String == "abc123")
        #expect(result["cookieParameters.token"] as? String == "xyz789")
    }

    @Test("bindCookieParameters with empty dict produces empty cookieParameters")
    func testBindCookieParametersEmpty() {
        let result = OpenAPIContextBinder.bindCookieParameters([:])

        let dict = result["cookieParameters"] as? [String: String]
        #expect(dict != nil)
        #expect(dict?.isEmpty == true)
    }

    @Test("bindCookieParameters result count equals 1 + number of cookies")
    func testBindCookieParametersResultCount() {
        let cookies = ["a": "1", "b": "2"]
        let result = OpenAPIContextBinder.bindCookieParameters(cookies)

        // cookieParameters dict + 2 individual keys = 3 entries
        #expect(result.count == 3)
    }
}

// MARK: - Required Cookie Parameter Validation Tests

@Suite("Required Cookie Parameter Validation Tests")
struct RequiredCookieParameterValidationTests {

    private func makeSpec(parameters: [[String: Any]], inPath: String = "/items") throws -> OpenAPISpec {
        let specDict: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "Test API", "version": "1.0.0"],
            "paths": [
                inPath: [
                    "get": [
                        "operationId": "getItems",
                        "parameters": parameters,
                        "responses": ["200": ["description": "OK"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: specDict)
        return try JSONDecoder().decode(OpenAPISpec.self, from: data)
    }

    private func makeHandler(spec: OpenAPISpec) -> OpenAPIHTTPHandler {
        let registry = OpenAPIRouteRegistry(spec: spec)
        let bus = EventBus()
        return OpenAPIHTTPHandler(routeRegistry: registry, eventBus: bus)
    }

    @Test("Missing required cookie returns 400")
    func testMissingRequiredCookieReturns400() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "session-id", "in": "cookie", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        if let body = response.body, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains("Required cookie"))
            #expect(text.contains("session-id"))
        }
    }

    @Test("Present required cookie does not return 400")
    func testPresentRequiredCookieNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "session-id", "in": "cookie", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(
            method: "GET",
            path: "/items",
            headers: ["Cookie": "session-id=abc123"]
        )
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Optional cookie missing does not return 400")
    func testMissingOptionalCookieNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "session-id", "in": "cookie", "required": false]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Cookie parameter with no required field missing does not return 400")
    func testMissingCookieWithoutRequiredFieldNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "session-id", "in": "cookie"]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("400 response body for missing cookie contains JSON error and message fields")
    func testMissingRequiredCookieResponseBodyIsJSON() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "session-id", "in": "cookie", "required": true]
        ])
        let handler = makeHandler(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode == 400)
        #expect(response.headers["Content-Type"] == "application/json")
        let body = try #require(response.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["error"] == "Bad Request")
        #expect(json["message"] != nil)
    }
}

// MARK: - AnyCodableValue Tests

@Suite("AnyCodableValue Tests")
struct AnyCodableValueTests {

    @Test("Decode string value")
    func testDecodeString() throws {
        let data = #""hello""#.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .string("hello"))
    }

    @Test("Decode integer value")
    func testDecodeInt() throws {
        let data = "42".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .int(42))
    }

    @Test("Decode double value")
    func testDecodeDouble() throws {
        let data = "3.14".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .double(3.14))
    }

    @Test("Decode boolean value")
    func testDecodeBool() throws {
        let data = "true".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .bool(true))
    }

    @Test("Decode null value")
    func testDecodeNull() throws {
        let data = "null".data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(value == .null)
    }

    @Test("Round-trip encode/decode string")
    func testRoundTripString() throws {
        let original = AnyCodableValue.string("active")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip encode/decode integer")
    func testRoundTripInt() throws {
        let original = AnyCodableValue.int(7)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip encode/decode double")
    func testRoundTripDouble() throws {
        let original = AnyCodableValue.double(2.718)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip encode/decode bool")
    func testRoundTripBool() throws {
        let original = AnyCodableValue.bool(false)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip encode/decode null")
    func testRoundTripNull() throws {
        let original = AnyCodableValue.null
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("anyValue returns correct underlying value for string")
    func testAnyValueString() {
        let val = AnyCodableValue.string("pending")
        #expect(val.anyValue as? String == "pending")
    }

    @Test("anyValue returns correct underlying value for int")
    func testAnyValueInt() {
        let val = AnyCodableValue.int(3)
        #expect(val.anyValue as? Int == 3)
    }

    @Test("Decode array of mixed enum values from schema")
    func testDecodeMixedEnumArray() throws {
        let json = """
        {
            "type": "string",
            "enum": ["active", "inactive", "pending"]
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        #expect(schema.enumValues?.count == 3)
        #expect(schema.enumValues?[0] == .string("active"))
        #expect(schema.enumValues?[1] == .string("inactive"))
        #expect(schema.enumValues?[2] == .string("pending"))
    }

    @Test("Decode integer enum values from schema")
    func testDecodeIntegerEnumArray() throws {
        let json = """
        {
            "type": "integer",
            "enum": [1, 2, 3]
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        #expect(schema.enumValues?.count == 3)
        #expect(schema.enumValues?[0] == .int(1))
        #expect(schema.enumValues?[1] == .int(2))
        #expect(schema.enumValues?[2] == .int(3))
    }
}

// MARK: - Schema Enum Validation Tests

@Suite("Schema Enum Validation Tests")
struct SchemaEnumValidationTests {

    // MARK: - parseValue enum validation

    @Test("Valid string enum value passes parseValue")
    func testValidStringEnumPasses() throws {
        let schema = Schema(type: "string", enumValues: [.string("active"), .string("inactive"), .string("pending")])
        let result = try SchemaBinding.parseValue(json: "active", schema: schema, components: nil)
        #expect(result as? String == "active")
    }

    @Test("Invalid string enum value throws enumViolation in parseValue")
    func testInvalidStringEnumThrows() throws {
        let schema = Schema(type: "string", enumValues: [.string("active"), .string("inactive")])
        #expect(throws: SchemaBindingError.self) {
            _ = try SchemaBinding.parseValue(json: "deleted", schema: schema, components: nil)
        }
    }

    @Test("Invalid string enum error message contains value and allowed list")
    func testInvalidStringEnumErrorMessage() {
        let schema = Schema(type: "string", enumValues: [.string("active"), .string("inactive")])
        do {
            _ = try SchemaBinding.parseValue(json: "deleted", schema: schema, components: nil)
            Issue.record("Expected enumViolation error to be thrown")
        } catch let error as SchemaBindingError {
            if case .enumViolation(let value, let allowed) = error {
                #expect(value == "deleted")
                #expect(allowed.contains("active"))
                #expect(allowed.contains("inactive"))
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Valid integer enum value passes parseValue")
    func testValidIntEnumPasses() throws {
        let schema = Schema(type: "number", enumValues: [.int(1), .int(2), .int(3)])
        let result = try SchemaBinding.parseValue(json: 2, schema: schema, components: nil)
        #expect(result as? Double == 2.0)
    }

    @Test("Invalid integer enum value throws enumViolation in parseValue")
    func testInvalidIntEnumThrows() throws {
        let schema = Schema(type: "number", enumValues: [.int(1), .int(2), .int(3)])
        #expect(throws: SchemaBindingError.self) {
            _ = try SchemaBinding.parseValue(json: 4, schema: schema, components: nil)
        }
    }

    @Test("Empty enum array skips validation in parseValue")
    func testEmptyEnumArraySkipsValidation() throws {
        let schema = Schema(type: "string", enumValues: [])
        let result = try SchemaBinding.parseValue(json: "anything", schema: schema, components: nil)
        #expect(result as? String == "anything")
    }

    @Test("Nil enumValues skips validation in parseValue")
    func testNilEnumValuesSkipsValidation() throws {
        let schema = Schema(type: "string", enumValues: nil)
        let result = try SchemaBinding.parseValue(json: "anything", schema: schema, components: nil)
        #expect(result as? String == "anything")
    }

    // MARK: - validateAgainstSchema enum validation

    @Test("Valid string enum passes validateAgainstSchema")
    func testValidStringEnumPassesValidate() throws {
        let schema = Schema(type: "string", enumValues: [.string("red"), .string("green"), .string("blue")])
        let result = try SchemaBinding.validateAgainstSchema(value: "green", schemaName: "Color", schema: schema, components: nil)
        #expect(result as? String == "green")
    }

    @Test("Invalid string enum throws enumViolation in validateAgainstSchema")
    func testInvalidStringEnumThrowsValidate() throws {
        let schema = Schema(type: "string", enumValues: [.string("red"), .string("green"), .string("blue")])
        #expect(throws: SchemaBindingError.self) {
            _ = try SchemaBinding.validateAgainstSchema(value: "yellow", schemaName: "Color", schema: schema, components: nil)
        }
    }

    @Test("Valid integer enum passes validateAgainstSchema")
    func testValidIntEnumPassesValidate() throws {
        let schema = Schema(type: "integer", enumValues: [.int(10), .int(20), .int(30)])
        let result = try SchemaBinding.validateAgainstSchema(value: 10, schemaName: "Priority", schema: schema, components: nil)
        #expect(result as? Int == 10)
    }

    @Test("Invalid integer enum throws enumViolation in validateAgainstSchema")
    func testInvalidIntEnumThrowsValidate() throws {
        let schema = Schema(type: "integer", enumValues: [.int(10), .int(20), .int(30)])
        #expect(throws: SchemaBindingError.self) {
            _ = try SchemaBinding.validateAgainstSchema(value: 99, schemaName: "Priority", schema: schema, components: nil)
        }
    }

    @Test("Empty enum array skips validation in validateAgainstSchema")
    func testEmptyEnumArraySkipsValidationValidate() throws {
        let schema = Schema(type: "string", enumValues: [])
        let result = try SchemaBinding.validateAgainstSchema(value: "anything", schemaName: "Test", schema: schema, components: nil)
        #expect(result as? String == "anything")
    }

    @Test("enumViolation description is human-readable")
    func testEnumViolationDescription() {
        let error = SchemaBindingError.enumViolation(value: "yellow", allowed: "red, green, blue")
        #expect(error.description == "Value 'yellow' is not allowed. Must be one of: red, green, blue")
    }
}

// MARK: - Schema Default Value Tests

@Suite("Schema Default Value Tests")
struct SchemaDefaultValueTests {

    @Test("Schema decodes string default value")
    func testSchemaDecodesStringDefault() throws {
        let json = """
        {
            "type": "string",
            "default": "active"
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)

        #expect(schema.defaultValue == .string("active"))
    }

    @Test("Schema decodes integer default value")
    func testSchemaDecodesIntDefault() throws {
        let json = """
        {
            "type": "integer",
            "default": 1
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)

        #expect(schema.defaultValue == .int(1))
    }

    @Test("Schema decodes boolean default value")
    func testSchemaDecodesBoolDefault() throws {
        let json = """
        {
            "type": "boolean",
            "default": true
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)

        #expect(schema.defaultValue == .bool(true))
    }

    @Test("Schema without default has nil defaultValue")
    func testSchemaWithoutDefaultIsNil() throws {
        let json = """
        {
            "type": "string"
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)

        #expect(schema.defaultValue == nil)
    }

    @Test("Schema init sets defaultValue")
    func testSchemaInitSetsDefault() {
        let schema = Schema(type: "string", defaultValue: .string("pending"))
        #expect(schema.defaultValue == .string("pending"))
    }
}

// MARK: - Query Parameter Default Injection Tests

@Suite("Query Parameter Default Injection Tests")
struct QueryParameterDefaultInjectionTests {

    private func makeSpec(parameters: [[String: Any]]) throws -> OpenAPISpec {
        let specDict: [String: Any] = [
            "openapi": "3.0.3",
            "info": ["title": "Test API", "version": "1.0.0"],
            "paths": [
                "/items": [
                    "get": [
                        "operationId": "getItems",
                        "parameters": parameters,
                        "responses": ["200": ["description": "OK"]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: specDict)
        return try JSONDecoder().decode(OpenAPISpec.self, from: data)
    }

    private func makeHandlerAndBus(spec: OpenAPISpec) -> (OpenAPIHTTPHandler, EventBus) {
        let bus = EventBus()
        let registry = OpenAPIRouteRegistry(spec: spec)
        let handler = OpenAPIHTTPHandler(routeRegistry: registry, eventBus: bus)
        return (handler, bus)
    }

    @Test("Absent query param with string default is injected")
    func testAbsentQueryParamWithStringDefaultInjected() async throws {
        let spec = try makeSpec(parameters: [
            [
                "name": "status",
                "in": "query",
                "required": false,
                "schema": ["type": "string", "default": "active"]
            ]
        ])
        let (handler, bus) = makeHandlerAndBus(spec: spec)

        let latch = EventLatch()
        _ = bus.subscribe(to: HTTPOperationEvent.self) { event in
            await latch.store(event)
        }

        let request = HTTPRequest(method: "GET", path: "/items")
        _ = await handler.handleRequest(request)
        let event = await latch.wait()
        #expect(event.queryParameters["status"] == "active")
    }

    @Test("Present query param is not overwritten by default")
    func testPresentQueryParamNotOverwrittenByDefault() async throws {
        let spec = try makeSpec(parameters: [
            [
                "name": "status",
                "in": "query",
                "required": false,
                "schema": ["type": "string", "default": "active"]
            ]
        ])
        let (handler, bus) = makeHandlerAndBus(spec: spec)

        let latch = EventLatch()
        _ = bus.subscribe(to: HTTPOperationEvent.self) { event in
            await latch.store(event)
        }

        let request = HTTPRequest(method: "GET", path: "/items", queryParameters: ["status": "inactive"])
        _ = await handler.handleRequest(request)
        let event = await latch.wait()
        #expect(event.queryParameters["status"] == "inactive")
    }

    @Test("Absent required query param with default does not return 400")
    func testAbsentRequiredQueryParamWithDefaultNotRejected() async throws {
        let spec = try makeSpec(parameters: [
            [
                "name": "status",
                "in": "query",
                "required": true,
                "schema": ["type": "string", "default": "active"]
            ]
        ])
        let (handler, _) = makeHandlerAndBus(spec: spec)

        let request = HTTPRequest(method: "GET", path: "/items")
        let response = await handler.handleRequest(request)

        #expect(response.statusCode != 400)
    }

    @Test("Absent query param with integer default is injected as string")
    func testAbsentQueryParamWithIntDefaultInjected() async throws {
        let spec = try makeSpec(parameters: [
            [
                "name": "page",
                "in": "query",
                "required": false,
                "schema": ["type": "integer", "default": 1]
            ]
        ])
        let (handler, bus) = makeHandlerAndBus(spec: spec)

        let latch = EventLatch()
        _ = bus.subscribe(to: HTTPOperationEvent.self) { event in
            await latch.store(event)
        }

        let request = HTTPRequest(method: "GET", path: "/items")
        _ = await handler.handleRequest(request)
        let event = await latch.wait()
        #expect(event.queryParameters["page"] == "1")
    }

    @Test("Query param without schema default is not injected")
    func testQueryParamWithoutSchemaDefaultNotInjected() async throws {
        let spec = try makeSpec(parameters: [
            ["name": "q", "in": "query", "required": false]
        ])
        let (handler, bus) = makeHandlerAndBus(spec: spec)

        let latch = EventLatch()
        _ = bus.subscribe(to: HTTPOperationEvent.self) { event in
            await latch.store(event)
        }

        let request = HTTPRequest(method: "GET", path: "/items")
        _ = await handler.handleRequest(request)
        let event = await latch.wait()
        #expect(event.queryParameters["q"] == nil)
    }
}

// MARK: - Object Property Default Injection Tests

@Suite("Object Property Default Injection Tests")
struct ObjectPropertyDefaultInjectionTests {

    @Test("Missing optional property gets default string value")
    func testMissingPropertyGetsStringDefault() throws {
        let schema = Schema(
            type: "object",
            properties: [
                "name": SchemaRef(Schema(type: "string")),
                "status": SchemaRef(Schema(type: "string", defaultValue: .string("active")))
            ]
        )
        let json: [String: Any] = ["name": "Alice"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["name"] as? String == "Alice")
        #expect(dict["status"] as? String == "active")
    }

    @Test("Missing optional property gets default integer value")
    func testMissingPropertyGetsIntDefault() throws {
        let schema = Schema(
            type: "object",
            properties: [
                "name": SchemaRef(Schema(type: "string")),
                "priority": SchemaRef(Schema(type: "integer", defaultValue: .int(0)))
            ]
        )
        let json: [String: Any] = ["name": "Task"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["priority"] as? Int == 0)
    }

    @Test("Present optional property is not replaced by default")
    func testPresentPropertyNotReplacedByDefault() throws {
        let schema = Schema(
            type: "object",
            properties: [
                "status": SchemaRef(Schema(type: "string", defaultValue: .string("active")))
            ]
        )
        let json: [String: Any] = ["status": "inactive"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["status"] as? String == "inactive")
    }

    @Test("Missing property without default is not injected")
    func testMissingPropertyWithoutDefaultNotInjected() throws {
        let schema = Schema(
            type: "object",
            properties: [
                "name": SchemaRef(Schema(type: "string")),
                "tag": SchemaRef(Schema(type: "string"))
            ]
        )
        let json: [String: Any] = ["name": "Alice"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["tag"] == nil)
    }

    @Test("Missing boolean property gets default false value")
    func testMissingPropertyGetsBoolDefault() throws {
        let schema = Schema(
            type: "object",
            properties: [
                "active": SchemaRef(Schema(type: "boolean", defaultValue: .bool(false)))
            ]
        )
        let json: [String: Any] = [:]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)

        let dict = try #require(result as? [String: Any])
        #expect(dict["active"] as? Bool == false)
    }
}

/// Minimal async latch for coordinating test event capture.
private actor EventLatch {
    private var continuation: CheckedContinuation<HTTPOperationEvent, Never>?
    private var stored: HTTPOperationEvent?

    func store(_ event: HTTPOperationEvent) {
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: event)
        } else {
            stored = event
        }
    }

    func wait() async -> HTTPOperationEvent {
        if let s = stored {
            stored = nil
            return s
        }
        return await withCheckedContinuation { cont in
            continuation = cont
        }
    }
}

#endif  // !os(Windows)
