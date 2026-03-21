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

#endif  // !os(Windows)
