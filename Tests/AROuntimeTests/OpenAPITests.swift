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
        if let paramName = param.name {
            allowEmptyValueByName[paramName] = param.allowEmptyValue ?? false
        }
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

// MARK: - AdditionalProperties Tests

@Suite("AdditionalProperties Schema Tests")
struct AdditionalPropertiesTests {

    // MARK: Decoding

    @Test("AdditionalProperties decodes from false")
    func testDecodeFromFalse() throws {
        let json = """
        {
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            },
            "additionalProperties": false
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        if case .allowed(let b) = schema.additionalProperties {
            #expect(b == false)
        } else {
            Issue.record("Expected .allowed(false)")
        }
    }

    @Test("AdditionalProperties decodes from true")
    func testDecodeFromTrue() throws {
        let json = """
        {
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            },
            "additionalProperties": true
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        if case .allowed(let b) = schema.additionalProperties {
            #expect(b == true)
        } else {
            Issue.record("Expected .allowed(true)")
        }
    }

    @Test("AdditionalProperties decodes from schema object")
    func testDecodeFromSchemaObject() throws {
        let json = """
        {
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            },
            "additionalProperties": { "type": "string" }
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        if case .schema(let ref) = schema.additionalProperties {
            #expect(ref.value.type == "string")
        } else {
            Issue.record("Expected .schema(...)")
        }
    }

    @Test("AdditionalProperties is nil when absent")
    func testDecodeNilWhenAbsent() throws {
        let json = """
        {
            "type": "object",
            "properties": {
                "name": { "type": "string" }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let schema = try JSONDecoder().decode(Schema.self, from: data)
        #expect(schema.additionalProperties == nil)
    }

    // MARK: parseValue enforcement

    private func makeObjectSchema(
        properties: [String: Schema],
        additionalProperties: AdditionalProperties? = nil
    ) -> Schema {
        let props = properties.mapValues { SchemaRef($0) }
        return Schema(type: "object", properties: props, additionalProperties: additionalProperties)
    }

    @Test("parseValue: additionalProperties false rejects extra keys")
    func testParseValueRejectsExtraKeys() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .allowed(false)
        )
        let json: [String: Any] = ["name": "Alice", "extra": "value"]
        #expect(throws: SchemaBindingError.additionalPropertiesNotAllowed(["extra"])) {
            try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        }
    }

    @Test("parseValue: additionalProperties false accepts no extra keys")
    func testParseValueAcceptsNoExtraKeys() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .allowed(false)
        )
        let json: [String: Any] = ["name": "Alice"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        let dict = result as? [String: Any]
        #expect(dict?["name"] as? String == "Alice")
    }

    @Test("parseValue: additionalProperties true passes extra keys through")
    func testParseValueAllowsExtraKeysExplicitTrue() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .allowed(true)
        )
        let json: [String: Any] = ["name": "Alice", "extra": "value"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        let dict = result as? [String: Any]
        #expect(dict?["extra"] as? String == "value")
    }

    @Test("parseValue: additionalProperties nil passes extra keys through")
    func testParseValueAllowsExtraKeysNil() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: nil
        )
        let json: [String: Any] = ["name": "Alice", "extra": "value"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        let dict = result as? [String: Any]
        #expect(dict?["extra"] as? String == "value")
    }

    @Test("parseValue: additionalProperties schema validates matching extra key")
    func testParseValueValidatesExtraKeyAgainstSchema() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .schema(SchemaRef(Schema(type: "string")))
        )
        let json: [String: Any] = ["name": "Alice", "tag": "admin"]
        let result = try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        let dict = result as? [String: Any]
        #expect(dict?["tag"] as? String == "admin")
    }

    @Test("parseValue: additionalProperties schema rejects non-matching extra key")
    func testParseValueRejectsExtraKeyViolatingSchema() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .schema(SchemaRef(Schema(type: "string")))
        )
        let json: [String: Any] = ["name": "Alice", "count": 42]
        #expect(throws: SchemaBindingError.typeMismatch(expected: "string")) {
            try SchemaBinding.parseValue(json: json, schema: schema, components: nil)
        }
    }

    // MARK: validateAgainstSchema enforcement

    @Test("validateAgainstSchema: additionalProperties false rejects extra keys")
    func testValidateRejectsExtraKeys() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .allowed(false)
        )
        let value: [String: any Sendable] = ["name": "Alice", "extra": "value"]
        #expect(throws: SchemaBindingError.additionalPropertiesNotAllowed(["extra"])) {
            try SchemaBinding.validateAgainstSchema(
                value: value,
                schemaName: "Test",
                schema: schema,
                components: nil
            )
        }
    }

    @Test("validateAgainstSchema: additionalProperties false accepts no extra keys")
    func testValidateAcceptsNoExtraKeys() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .allowed(false)
        )
        let value: [String: any Sendable] = ["name": "Alice"]
        let result = try SchemaBinding.validateAgainstSchema(
            value: value,
            schemaName: "Test",
            schema: schema,
            components: nil
        )
        let dict = result as? [String: any Sendable]
        #expect(dict?["name"] as? String == "Alice")
    }

    @Test("validateAgainstSchema: additionalProperties schema validates matching extra key")
    func testValidateExtraKeyAgainstSchema() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .schema(SchemaRef(Schema(type: "string")))
        )
        let value: [String: any Sendable] = ["name": "Alice", "tag": "admin"]
        let result = try SchemaBinding.validateAgainstSchema(
            value: value,
            schemaName: "Test",
            schema: schema,
            components: nil
        )
        let dict = result as? [String: any Sendable]
        #expect(dict?["tag"] as? String == "admin")
    }

    @Test("validateAgainstSchema: additionalProperties schema rejects non-matching extra key")
    func testValidateRejectsExtraKeyViolatingSchema() throws {
        let schema = makeObjectSchema(
            properties: ["name": Schema(type: "string")],
            additionalProperties: .schema(SchemaRef(Schema(type: "string")))
        )
        let value: [String: any Sendable] = ["name": "Alice", "count": 42]
        #expect(throws: (any Error).self) {
            try SchemaBinding.validateAgainstSchema(
                value: value,
                schemaName: "Test",
                schema: schema,
                components: nil
            )
        }
    }
}

// MARK: - SecurityEnforcer Tests

@Suite("SecurityEnforcer Tests")
struct SecurityEnforcerTests {

    // MARK: Helpers

    private func makeOperation(security: [[String: [String]]]? = nil) -> ARORuntime.Operation {
        ARORuntime.Operation(
            operationId: "testOp",
            summary: nil,
            description: nil,
            tags: nil,
            parameters: nil,
            requestBody: nil,
            responses: ["200": OpenAPIResponse(description: "OK", headers: nil, content: nil, ref: nil)],
            deprecated: nil,
            security: security
        )
    }

    private func bearerScheme() -> SecurityScheme {
        SecurityScheme(type: "http", description: nil, name: nil, in: nil, scheme: "bearer", bearerFormat: nil)
    }

    private func basicScheme() -> SecurityScheme {
        SecurityScheme(type: "http", description: nil, name: nil, in: nil, scheme: "basic", bearerFormat: nil)
    }

    private func apiKeyHeaderScheme(name: String = "X-API-Key") -> SecurityScheme {
        SecurityScheme(type: "apiKey", description: nil, name: name, in: "header", scheme: nil, bearerFormat: nil)
    }

    private func apiKeyQueryScheme(name: String = "api_key") -> SecurityScheme {
        SecurityScheme(type: "apiKey", description: nil, name: name, in: "query", scheme: nil, bearerFormat: nil)
    }

    private func apiKeyCookieScheme(name: String = "session") -> SecurityScheme {
        SecurityScheme(type: "apiKey", description: nil, name: name, in: "cookie", scheme: nil, bearerFormat: nil)
    }

    private func oauth2Scheme() -> SecurityScheme {
        SecurityScheme(type: "oauth2", description: nil, name: nil, in: nil, scheme: nil, bearerFormat: nil)
    }

    private func openIdConnectScheme() -> SecurityScheme {
        SecurityScheme(type: "openIdConnect", description: nil, name: nil, in: nil, scheme: nil, bearerFormat: nil)
    }

    // MARK: No Security

    @Test("No security field on spec and operation — passes")
    func testNoSecurityPassesThrough() {
        let op = makeOperation(security: nil)
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: nil,
            headers: [:],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("Empty global security array — passes")
    func testEmptyGlobalSecurityPasses() {
        let op = makeOperation(security: nil)
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: [],
            securitySchemes: nil,
            headers: [:],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("Empty operation security array — explicitly public, passes")
    func testEmptyOperationSecurityMeansPublic() {
        let op = makeOperation(security: [])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: [["bearerAuth": []]],
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    // MARK: HTTP Bearer

    @Test("Bearer token present — passes")
    func testBearerTokenPresent() {
        let op = makeOperation(security: [["bearerAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: ["Authorization": "Bearer mytoken123"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("Bearer token missing — 401")
    func testBearerTokenMissing() {
        let op = makeOperation(security: [["bearerAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    @Test("Bearer check is case-insensitive on header name")
    func testBearerCaseInsensitiveHeaderName() {
        let op = makeOperation(security: [["bearerAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: ["authorization": "Bearer tok"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("HTTP basic present — passes")
    func testBasicAuthPresent() {
        let op = makeOperation(security: [["basicAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["basicAuth": basicScheme()],
            headers: ["Authorization": "Basic dXNlcjpwYXNz"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("HTTP basic missing — 401")
    func testBasicAuthMissing() {
        let op = makeOperation(security: [["basicAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["basicAuth": basicScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: apiKey — header

    @Test("apiKey header present — passes")
    func testApiKeyHeaderPresent() {
        let op = makeOperation(security: [["apiKeyAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["apiKeyAuth": apiKeyHeaderScheme()],
            headers: ["X-API-Key": "secret"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("apiKey header missing — 401")
    func testApiKeyHeaderMissing() {
        let op = makeOperation(security: [["apiKeyAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["apiKeyAuth": apiKeyHeaderScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    @Test("apiKey header name match is case-insensitive")
    func testApiKeyHeaderCaseInsensitive() {
        let op = makeOperation(security: [["apiKeyAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["apiKeyAuth": apiKeyHeaderScheme(name: "X-API-Key")],
            headers: ["x-api-key": "secret"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    // MARK: apiKey — query

    @Test("apiKey query present — passes")
    func testApiKeyQueryPresent() {
        let op = makeOperation(security: [["queryAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["queryAuth": apiKeyQueryScheme()],
            headers: [:],
            queryParameters: ["api_key": "mykey"]
        )
        #expect(result == nil)
    }

    @Test("apiKey query missing — 401")
    func testApiKeyQueryMissing() {
        let op = makeOperation(security: [["queryAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["queryAuth": apiKeyQueryScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: apiKey — cookie

    @Test("apiKey cookie present — passes")
    func testApiKeyCookiePresent() {
        let op = makeOperation(security: [["cookieAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["cookieAuth": apiKeyCookieScheme()],
            headers: ["Cookie": "session=abc123"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("apiKey cookie missing — 401")
    func testApiKeyCookieMissing() {
        let op = makeOperation(security: [["cookieAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["cookieAuth": apiKeyCookieScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: oauth2 / openIdConnect

    @Test("oauth2 with Bearer token — passes")
    func testOAuth2BearerPresent() {
        let op = makeOperation(security: [["oauth2Auth": ["read"]]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["oauth2Auth": oauth2Scheme()],
            headers: ["Authorization": "Bearer access_token"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("oauth2 without token — 401")
    func testOAuth2BearerMissing() {
        let op = makeOperation(security: [["oauth2Auth": ["read"]]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["oauth2Auth": oauth2Scheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    @Test("openIdConnect with Bearer token — passes")
    func testOpenIdConnectBearerPresent() {
        let op = makeOperation(security: [["oidcAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["oidcAuth": openIdConnectScheme()],
            headers: ["Authorization": "Bearer id_token"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("openIdConnect without token — 401")
    func testOpenIdConnectBearerMissing() {
        let op = makeOperation(security: [["oidcAuth": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["oidcAuth": openIdConnectScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: OR'd requirements

    @Test("OR'd requirements: second satisfied — passes")
    func testOrRequirementsSecondSatisfied() {
        let op = makeOperation(security: [
            ["bearerAuth": []],
            ["apiKeyAuth": []]
        ])
        // No Bearer header, but API key present — second requirement satisfied
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: [
                "bearerAuth": bearerScheme(),
                "apiKeyAuth": apiKeyHeaderScheme()
            ],
            headers: ["X-API-Key": "secret"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    @Test("OR'd requirements: neither satisfied — 401")
    func testOrRequirementsNeitherSatisfied() {
        let op = makeOperation(security: [
            ["bearerAuth": []],
            ["apiKeyAuth": []]
        ])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: [
                "bearerAuth": bearerScheme(),
                "apiKeyAuth": apiKeyHeaderScheme()
            ],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: Global security fallback

    @Test("Operation inherits global security — missing credentials return 401")
    func testOperationInheritsGlobalSecurity() {
        let op = makeOperation(security: nil)
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: [["bearerAuth": []]],
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    @Test("Operation inherits global security — valid credentials pass")
    func testOperationInheritsGlobalSecurityPasses() {
        let op = makeOperation(security: nil)
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: [["bearerAuth": []]],
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: ["Authorization": "Bearer tok"],
            queryParameters: [:]
        )
        #expect(result == nil)
    }

    // MARK: Unknown scheme name

    @Test("Unknown scheme name in requirement — 401")
    func testUnknownSchemeNameReturns401() {
        let op = makeOperation(security: [["unknownScheme": []]])
        let result = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: [:],
            headers: ["Authorization": "Bearer tok"],
            queryParameters: [:]
        )
        #expect(result?.statusCode == 401)
    }

    // MARK: 401 response shape

    @Test("401 response contains correct status code and WWW-Authenticate header")
    func test401ResponseShape() {
        let op = makeOperation(security: [["bearerAuth": []]])
        let response = SecurityEnforcer.enforce(
            operation: op,
            globalSecurity: nil,
            securitySchemes: ["bearerAuth": bearerScheme()],
            headers: [:],
            queryParameters: [:]
        )
        #expect(response?.statusCode == 401)
        #expect(response?.headers["WWW-Authenticate"] == "Bearer")
        #expect(response?.headers["Content-Type"] == "application/json")
    }

    // MARK: OpenAPISpec global security parsing

    @Test("Parse OpenAPISpec with global security field")
    func testParseGlobalSecurity() throws {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Secure API", "version": "1.0.0" },
            "paths": {},
            "security": [{"bearerAuth": []}],
            "components": {
                "securitySchemes": {
                    "bearerAuth": {
                        "type": "http",
                        "scheme": "bearer"
                    }
                }
            }
        }
        """
        let spec = try JSONDecoder().decode(OpenAPISpec.self, from: json.data(using: .utf8)!)
        #expect(spec.security?.count == 1)
        #expect(spec.security?.first?["bearerAuth"] != nil)
        #expect(spec.components?.securitySchemes?["bearerAuth"]?.type == "http")
        #expect(spec.components?.securitySchemes?["bearerAuth"]?.scheme == "bearer")
    }
}

// MARK: - Content-Type Negotiation Tests (Issue #179)

@Suite("Content-Type Negotiation Tests")
struct ContentTypeNegotiationTests {

    // MARK: - findMatchingMediaType unit tests

    @Test("Exact match returns matching media type")
    func testExactMatch() {
        let jsonMediaType = MediaType(schema: nil)
        let content: [String: MediaType] = ["application/json": jsonMediaType]
        let result = findMatchingMediaType(in: content, for: "application/json")
        #expect(result != nil)
    }

    @Test("Parameters are stripped before matching")
    func testParameterStripping() {
        let jsonMediaType = MediaType(schema: nil)
        let content: [String: MediaType] = ["application/json": jsonMediaType]
        let result = findMatchingMediaType(in: content, for: "application/json; charset=utf-8")
        #expect(result != nil)
    }

    @Test("Subtype wildcard matches when exact type absent")
    func testSubtypeWildcard() {
        let wildcardMediaType = MediaType(schema: nil)
        let content: [String: MediaType] = ["application/*": wildcardMediaType]
        let result = findMatchingMediaType(in: content, for: "application/json")
        #expect(result != nil)
    }

    @Test("Catch-all wildcard matches any content type")
    func testCatchAllWildcard() {
        let wildcardMediaType = MediaType(schema: nil)
        let content: [String: MediaType] = ["*/*": wildcardMediaType]
        let result = findMatchingMediaType(in: content, for: "text/plain")
        #expect(result != nil)
    }

    @Test("Exact match takes precedence over subtype wildcard")
    func testExactMatchPrecedenceOverSubtypeWildcard() {
        let exactMediaType = MediaType(schema: SchemaRef(Schema(type: "object")))
        let wildcardMediaType = MediaType(schema: SchemaRef(Schema(type: "string")))
        let content: [String: MediaType] = [
            "application/json": exactMediaType,
            "application/*": wildcardMediaType
        ]
        let result = findMatchingMediaType(in: content, for: "application/json")
        // Must return exact match, not wildcard
        #expect(result?.schema?.value.type == "object")
    }

    @Test("Subtype wildcard takes precedence over catch-all wildcard")
    func testSubtypeWildcardPrecedenceOverCatchAll() {
        let subtypeMediaType = MediaType(schema: SchemaRef(Schema(type: "object")))
        let catchAllMediaType = MediaType(schema: SchemaRef(Schema(type: "string")))
        let content: [String: MediaType] = [
            "application/*": subtypeMediaType,
            "*/*": catchAllMediaType
        ]
        let result = findMatchingMediaType(in: content, for: "application/json")
        #expect(result?.schema?.value.type == "object")
    }

    @Test("Returns nil when content type not in spec")
    func testNoMatch() {
        let jsonMediaType = MediaType(schema: nil)
        let content: [String: MediaType] = ["application/json": jsonMediaType]
        let result = findMatchingMediaType(in: content, for: "text/xml")
        #expect(result == nil)
    }

    @Test("Returns nil for empty content map")
    func testEmptyContent() {
        let result = findMatchingMediaType(in: [:], for: "application/json")
        #expect(result == nil)
    }

    // MARK: - Integration tests via OpenAPIHTTPHandler.handleRequest

    private func makeSpec() throws -> OpenAPISpec {
        let json = """
        {
            "openapi": "3.0.3",
            "info": { "title": "Test API", "version": "1.0.0" },
            "paths": {
                "/items": {
                    "post": {
                        "operationId": "createItem",
                        "requestBody": {
                            "required": true,
                            "content": {
                                "application/json": {
                                    "schema": { "type": "object" }
                                }
                            }
                        },
                        "responses": { "201": { "description": "Created" } }
                    }
                },
                "/wildcard": {
                    "post": {
                        "operationId": "createWildcard",
                        "requestBody": {
                            "content": {
                                "*/*": {}
                            }
                        },
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }
        """
        return try JSONDecoder().decode(OpenAPISpec.self, from: json.data(using: .utf8)!)
    }

    private func makeHandler(spec: OpenAPISpec) -> OpenAPIHTTPHandler {
        let registry = OpenAPIRouteRegistry(spec: spec)
        let bus = EventBus()
        return OpenAPIHTTPHandler(routeRegistry: registry, eventBus: bus)
    }

    @Test("application/json matches application/json spec — 200 response")
    func testExactContentTypeAccepted() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = #"{"name":"widget"}"#.data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }

    @Test("application/json; charset=utf-8 matches application/json spec — no 415")
    func testContentTypeWithParametersAccepted() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = #"{"name":"widget"}"#.data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }

    @Test("Unsupported Content-Type returns 415 with error body")
    func testUnsupportedContentTypeReturns415() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = "<item><name>widget</name></item>".data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "text/xml"],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode == 415)
        #expect(response.headers["Content-Type"] == "application/json")
        if let data = response.body, let text = String(data: data, encoding: .utf8) {
            #expect(text.contains("Unsupported Media Type"))
            #expect(text.contains("text/xml"))
            #expect(text.contains("application/json"))
        }
    }

    @Test("415 error message lists supported media types")
    func test415ErrorListsSupportedTypes() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = "plain text".data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "text/plain"],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode == 415)
        if let data = response.body, let text = String(data: data, encoding: .utf8) {
            #expect(text.contains("application/json"))
        }
    }

    @Test("*/* in spec accepts any content type — no 415")
    func testCatchAllWildcardInSpecAcceptsAnyType() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = "anything".data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/wildcard",
            headers: ["Content-Type": "text/csv"],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }

    @Test("No Content-Type header and body present — backward compatible, no 415")
    func testMissingContentTypeHeaderIsBackwardCompatible() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let body = #"{"name":"widget"}"#.data(using: .utf8)
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: [:],
            body: body
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }

    @Test("No body — content-type negotiation is skipped, no 415")
    func testNoBodySkipsContentTypeNegotiation() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "text/xml"],
            body: nil
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }

    @Test("Empty body — content-type negotiation is skipped, no 415")
    func testEmptyBodySkipsContentTypeNegotiation() async throws {
        let handler = makeHandler(spec: try makeSpec())
        let request = HTTPRequest(
            method: "POST",
            path: "/items",
            headers: ["Content-Type": "text/xml"],
            body: Data()
        )
        let response = await handler.handleRequest(request)
        #expect(response.statusCode != 415)
    }
}

// MARK: - parseQueryString Tests

@Suite("parseQueryString Tests")
struct ParseQueryStringTests {

    @Test("Empty query string returns empty dict")
    func testEmptyQueryString() {
        let result = parseQueryString("")
        #expect(result.isEmpty)
    }

    @Test("Single key-value pair")
    func testSinglePair() {
        let result = parseQueryString("foo=bar")
        #expect(result["foo"] == ["bar"])
    }

    @Test("Multiple distinct keys")
    func testMultipleDistinctKeys() {
        let result = parseQueryString("a=1&b=2&c=3")
        #expect(result["a"] == ["1"])
        #expect(result["b"] == ["2"])
        #expect(result["c"] == ["3"])
    }

    @Test("Repeated key produces multiple values")
    func testRepeatedKey() {
        let result = parseQueryString("ids=1&ids=2&ids=3")
        #expect(result["ids"] == ["1", "2", "3"])
    }

    @Test("Percent-encoded values are decoded")
    func testPercentEncoding() {
        let result = parseQueryString("name=hello%20world")
        #expect(result["name"] == ["hello world"])
    }

    @Test("Value with no key is ignored")
    func testEmptyKey() {
        let result = parseQueryString("=value")
        #expect(result.isEmpty)
    }

    @Test("Key without value gets empty string")
    func testKeyWithoutValue() {
        let result = parseQueryString("flag")
        #expect(result["flag"] == [""])
    }

    @Test("Mixed repeated and unique keys")
    func testMixedKeys() {
        let result = parseQueryString("ids=1&name=alice&ids=2")
        #expect(result["ids"] == ["1", "2"])
        #expect(result["name"] == ["alice"])
    }
}

// MARK: - deserializeParameter Tests

@Suite("SchemaBinding.deserializeParameter Tests")
struct DeserializeParameterTests {

    // Helper to build a Parameter with the given schema type, style, and explode
    private func makeParam(
        name: String = "ids",
        schemaType: String,
        style: String? = nil,
        explode: Bool? = nil
    ) -> Parameter {
        let schemaJSON = """
        {"type":"\(schemaType)","items":{"type":"string"}}
        """
        let schemaRef = try! JSONDecoder().decode(SchemaRef.self, from: schemaJSON.data(using: .utf8)!)
        let paramJSON = """
        {"name":"\(name)","in":"query"}
        """
        // Build via JSON to get default codable state, then we need explicit fields
        // Since Parameter doesn't have a memberwise public init, decode from JSON including optional fields
        var jsonDict: [String: Any] = ["name": name, "in": "query", "schema": ["type": schemaType, "items": ["type": "string"]]]
        if let s = style { jsonDict["style"] = s }
        if let e = explode { jsonDict["explode"] = e }
        let data = try! JSONSerialization.data(withJSONObject: jsonDict)
        return try! JSONDecoder().decode(Parameter.self, from: data)
    }

    private func makeScalarParam(name: String = "q", schemaType: String = "string") -> Parameter {
        var jsonDict: [String: Any] = ["name": name, "in": "query", "schema": ["type": schemaType]]
        let data = try! JSONSerialization.data(withJSONObject: jsonDict)
        return try! JSONDecoder().decode(Parameter.self, from: data)
    }

    @Test("form + explode:true (default) → rawValues as array")
    func testFormExplodeTrue() {
        let param = makeParam(schemaType: "array", style: "form", explode: true)
        let result = SchemaBinding.deserializeParameter(rawValues: ["1", "2", "3"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["1", "2", "3"])
    }

    @Test("form + explode:false → comma-split single value")
    func testFormExplodeFalse() {
        let param = makeParam(schemaType: "array", style: "form", explode: false)
        let result = SchemaBinding.deserializeParameter(rawValues: ["1,2,3"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["1", "2", "3"])
    }

    @Test("form default (no explode specified) → explode:true behaviour")
    func testFormDefaultExplode() {
        let param = makeParam(schemaType: "array", style: "form")
        let result = SchemaBinding.deserializeParameter(rawValues: ["a", "b"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["a", "b"])
    }

    @Test("pipeDelimited + explode:false → pipe-split single value")
    func testPipeDelimited() {
        let param = makeParam(schemaType: "array", style: "pipeDelimited", explode: false)
        let result = SchemaBinding.deserializeParameter(rawValues: ["a|b|c"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["a", "b", "c"])
    }

    @Test("spaceDelimited + explode:false → space-split single value")
    func testSpaceDelimited() {
        let param = makeParam(schemaType: "array", style: "spaceDelimited", explode: false)
        let result = SchemaBinding.deserializeParameter(rawValues: ["a b c"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["a", "b", "c"])
    }

    @Test("spaceDelimited + percent-encoded space")
    func testSpaceDelimitedPercentEncoded() {
        let param = makeParam(schemaType: "array", style: "spaceDelimited", explode: false)
        let result = SchemaBinding.deserializeParameter(rawValues: ["a%20b%20c"], parameter: param, components: nil)
        let arr = result as? [String]
        #expect(arr == ["a", "b", "c"])
    }

    @Test("Scalar param with multiple values → returns first value as String")
    func testScalarParamReturnsFirst() {
        let param = makeScalarParam()
        let result = SchemaBinding.deserializeParameter(rawValues: ["first", "second"], parameter: param, components: nil)
        let str = result as? String
        #expect(str == "first")
    }

    @Test("Param with no schema → treated as scalar, returns first value")
    func testNoSchema() {
        let data = """
        {"name":"x","in":"query"}
        """.data(using: .utf8)!
        let param = try! JSONDecoder().decode(Parameter.self, from: data)
        let result = SchemaBinding.deserializeParameter(rawValues: ["val"], parameter: param, components: nil)
        let str = result as? String
        #expect(str == "val")
    }

    @Test("Empty rawValues for scalar → empty string")
    func testEmptyRawValuesScalar() {
        let param = makeScalarParam()
        let result = SchemaBinding.deserializeParameter(rawValues: [], parameter: param, components: nil)
        let str = result as? String
        #expect(str == "")
    }
}

#endif  // !os(Windows)
