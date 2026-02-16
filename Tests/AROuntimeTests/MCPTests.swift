// ============================================================
// MCPTests.swift
// ARO MCP Server Tests
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

@Suite("MCP Server Tests")
struct MCPTests {

    // MARK: - JSON-RPC Handler Tests

    @Suite("JSON-RPC Handler")
    struct JSONRPCHandlerTests {

        @Test("Parse valid request")
        func parseValidRequest() throws {
            let handler = JSONRPCHandler()
            let json = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            """

            let request = try handler.parseRequest(json)

            #expect(request.jsonrpc == "2.0")
            #expect(request.method == "initialize")
            #expect(request.id == .number(1))
            #expect(request.params != nil)
        }

        @Test("Parse request with string ID")
        func parseRequestWithStringId() throws {
            let handler = JSONRPCHandler()
            let json = """
            {"jsonrpc":"2.0","id":"abc-123","method":"test"}
            """

            let request = try handler.parseRequest(json)

            #expect(request.id == .string("abc-123"))
        }

        @Test("Parse notification (no ID)")
        func parseNotification() throws {
            let handler = JSONRPCHandler()
            let json = """
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """

            let request = try handler.parseRequest(json)

            #expect(request.id == nil)
            #expect(request.isNotification == true)
        }

        @Test("Encode success response")
        func encodeSuccessResponse() throws {
            let handler = JSONRPCHandler()
            let response = handler.successResponse(
                id: .number(1),
                result: .object(["status": .string("ok")])
            )

            let encoded = try handler.encodeResponse(response)

            #expect(encoded.contains("\"jsonrpc\":\"2.0\""))
            #expect(encoded.contains("\"id\":1"))
            #expect(encoded.contains("\"status\":\"ok\""))
        }

        @Test("Encode error response")
        func encodeErrorResponse() throws {
            let handler = JSONRPCHandler()
            let response = handler.errorResponse(
                id: .number(1),
                error: .methodNotFound
            )

            let encoded = try handler.encodeResponse(response)

            #expect(encoded.contains("\"code\":-32601"))
            #expect(encoded.contains("Method not found"))
        }
    }

    // MARK: - JSONValue Tests

    @Suite("JSONValue")
    struct JSONValueTests {

        @Test("String value access")
        func stringValueAccess() {
            let value = JSONValue.string("hello")
            #expect(value.stringValue == "hello")
            #expect(value.intValue == nil)
        }

        @Test("Number value access")
        func numberValueAccess() {
            let value = JSONValue.number(42)
            #expect(value.intValue == 42)
            #expect(value.doubleValue == 42.0)
            #expect(value.stringValue == nil)
        }

        @Test("Object subscript access")
        func objectSubscriptAccess() {
            let value = JSONValue.object([
                "name": .string("test"),
                "count": .number(5)
            ])

            #expect(value["name"]?.stringValue == "test")
            #expect(value["count"]?.intValue == 5)
            #expect(value["missing"] == nil)
        }

        @Test("Array subscript access")
        func arraySubscriptAccess() {
            let value = JSONValue.array([.string("a"), .string("b"), .string("c")])

            #expect(value[0]?.stringValue == "a")
            #expect(value[2]?.stringValue == "c")
            #expect(value[10] == nil)
        }
    }

    // MARK: - Tool Provider Tests

    @Suite("MCP Tool Provider")
    struct ToolProviderTests {

        @Test("List tools returns expected tools")
        func listToolsReturnsExpectedTools() {
            let provider = MCPToolProvider()
            let result = provider.listTools()

            let toolNames = result.tools.map { $0.name }

            #expect(toolNames.contains("aro_check"))
            #expect(toolNames.contains("aro_run"))
            #expect(toolNames.contains("aro_actions"))
            #expect(toolNames.contains("aro_parse"))
            #expect(toolNames.contains("aro_syntax"))
        }

        @Test("aro_check validates correct code")
        func aroCheckValidatesCorrectCode() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(
                name: "aro_check",
                arguments: .object([
                    "code": .string("(Test: Demo) { <Log> \"Hello\" to the <console>. <Return> an <OK: status> for the <result>. }")
                ])
            )

            #expect(result.isError == nil || result.isError == false)
            #expect(result.content.first?.text?.contains("Syntax OK") == true)
        }

        @Test("aro_check detects syntax errors")
        func aroCheckDetectsSyntaxErrors() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(
                name: "aro_check",
                arguments: .object([
                    "code": .string("(Test: Demo) { <Log> invalid syntax }")
                ])
            )

            #expect(result.isError == true)
        }

        @Test("aro_actions returns action documentation")
        func aroActionsReturnsDocumentation() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(name: "aro_actions", arguments: nil)

            let text = result.content.first?.text ?? ""

            #expect(text.contains("ARO Actions"))
            #expect(text.contains("Extract"))
            #expect(text.contains("Return"))
            #expect(text.contains("Log"))
        }

        @Test("aro_syntax returns syntax reference")
        func aroSyntaxReturnsSyntaxReference() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(name: "aro_syntax", arguments: nil)

            let text = result.content.first?.text ?? ""

            #expect(text.contains("Feature Set"))
            #expect(text.contains("Statement"))
        }

        @Test("aro_syntax with topic returns specific content")
        func aroSyntaxWithTopicReturnsSpecificContent() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(
                name: "aro_syntax",
                arguments: .object(["topic": .string("http-api")])
            )

            let text = result.content.first?.text ?? ""

            #expect(text.contains("HTTP API"))
            #expect(text.contains("openapi.yaml"))
            #expect(text.contains("operationId"))
        }

        @Test("aro_parse returns AST")
        func aroParseReturnsAST() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(
                name: "aro_parse",
                arguments: .object([
                    "code": .string("(Test: Demo) { <Log> \"Hello\" to the <console>. }")
                ])
            )

            let text = result.content.first?.text ?? ""

            #expect(text.contains("Test"))
            #expect(text.contains("Demo"))
            #expect(text.contains("Log"))
        }

        @Test("Unknown tool returns error")
        func unknownToolReturnsError() async {
            let provider = MCPToolProvider()
            let result = await provider.callTool(name: "unknown_tool", arguments: nil)

            #expect(result.isError == true)
            #expect(result.content.first?.text?.contains("Unknown tool") == true)
        }
    }

    // MARK: - Resource Provider Tests

    @Suite("MCP Resource Provider")
    struct ResourceProviderTests {

        @Test("List resources returns expected categories")
        func listResourcesReturnsExpectedCategories() async {
            let provider = MCPResourceProvider()
            let result = await provider.listResources()

            let uris = result.resources.map { $0.uri }

            #expect(uris.contains("aro://proposals"))
            #expect(uris.contains("aro://examples"))
            #expect(uris.contains("aro://books"))
            #expect(uris.contains("aro://syntax"))
            #expect(uris.contains("aro://actions"))
        }

        @Test("Read syntax resource")
        func readSyntaxResource() async {
            let provider = MCPResourceProvider()
            let result = await provider.readResource(uri: "aro://syntax")

            #expect(result != nil)
            #expect(result?.contents.first?.text?.contains("ARO Syntax") == true)
        }

        @Test("Read actions resource")
        func readActionsResource() async {
            let provider = MCPResourceProvider()
            let result = await provider.readResource(uri: "aro://actions")

            #expect(result != nil)
            #expect(result?.contents.first?.text?.contains("Action Reference") == true)
        }

        @Test("Read books list")
        func readBooksList() async {
            let provider = MCPResourceProvider()
            let result = await provider.readResource(uri: "aro://books")

            #expect(result != nil)
            let text = result?.contents.first?.text ?? ""
            #expect(text.contains("language-guide"))
            #expect(text.contains("plugin-guide"))
        }

        @Test("Invalid URI returns nil")
        func invalidUriReturnsNil() async {
            let provider = MCPResourceProvider()
            let result = await provider.readResource(uri: "invalid://uri")

            #expect(result == nil)
        }
    }

    // MARK: - Prompt Provider Tests

    @Suite("MCP Prompt Provider")
    struct PromptProviderTests {

        @Test("List prompts returns expected prompts")
        func listPromptsReturnsExpectedPrompts() {
            let provider = MCPPromptProvider()
            let result = provider.listPrompts()

            let names = result.prompts.map { $0.name }

            #expect(names.contains("create_feature_set"))
            #expect(names.contains("create_http_api"))
            #expect(names.contains("create_event_handler"))
            #expect(names.contains("debug_error"))
            #expect(names.contains("create_plugin"))
            #expect(names.contains("convert_to_aro"))
        }

        @Test("Get create_feature_set prompt")
        func getCreateFeatureSetPrompt() {
            let provider = MCPPromptProvider()
            let result = provider.getPrompt(
                name: "create_feature_set",
                arguments: ["name": "TestFeature", "purpose": "test something"]
            )

            #expect(result != nil)
            #expect(result?.messages.count == 1)

            let text = result?.messages.first?.content.text ?? ""
            #expect(text.contains("TestFeature"))
            #expect(text.contains("test something"))
        }

        @Test("Get create_http_api prompt")
        func getCreateHttpApiPrompt() {
            let provider = MCPPromptProvider()
            let result = provider.getPrompt(
                name: "create_http_api",
                arguments: ["resource": "products", "operations": "list,create"]
            )

            #expect(result != nil)
            let text = result?.messages.first?.content.text ?? ""
            #expect(text.contains("products"))
            #expect(text.contains("openapi.yaml"))
        }

        @Test("Get create_plugin prompt with swift")
        func getCreatePluginPromptSwift() {
            let provider = MCPPromptProvider()
            let result = provider.getPrompt(
                name: "create_plugin",
                arguments: ["language": "swift", "action": "CustomHash"]
            )

            #expect(result != nil)
            let text = result?.messages.first?.content.text ?? ""
            #expect(text.contains("Swift"))
            #expect(text.contains("@_cdecl"))
            #expect(text.contains("CustomHash"))
        }

        @Test("Get create_plugin prompt with rust")
        func getCreatePluginPromptRust() {
            let provider = MCPPromptProvider()
            let result = provider.getPrompt(
                name: "create_plugin",
                arguments: ["language": "rust", "action": "Encrypt"]
            )

            #expect(result != nil)
            let text = result?.messages.first?.content.text ?? ""
            #expect(text.contains("Rust"))
            #expect(text.contains("#[no_mangle]"))
        }

        @Test("Unknown prompt returns nil")
        func unknownPromptReturnsNil() {
            let provider = MCPPromptProvider()
            let result = provider.getPrompt(name: "unknown_prompt", arguments: nil)

            #expect(result == nil)
        }
    }

    // MARK: - MCP Types Tests

    @Suite("MCP Types")
    struct MCPTypesTests {

        @Test("MCPInitializeResult toJSONValue")
        func initializeResultToJSONValue() {
            let result = MCPInitializeResult(
                protocolVersion: "2025-06-18",
                serverInfo: MCPServerInfo(name: "aro", version: "1.0.0"),
                capabilities: MCPCapabilities(
                    tools: MCPToolsCapability(listChanged: false),
                    resources: MCPResourcesCapability(subscribe: false, listChanged: false),
                    prompts: MCPPromptsCapability(listChanged: false)
                )
            )

            let json = result.toJSONValue()

            #expect(json["protocolVersion"]?.stringValue == "2025-06-18")
            #expect(json["serverInfo"]?["name"]?.stringValue == "aro")
            #expect(json["capabilities"]?["tools"]?["listChanged"]?.boolValue == false)
        }

        @Test("MCPToolsListResult toJSONValue")
        func toolsListResultToJSONValue() {
            let result = MCPToolsListResult(tools: [
                MCPTool(
                    name: "test_tool",
                    description: "A test tool",
                    inputSchema: .object(["type": .string("object")])
                )
            ])

            let json = result.toJSONValue()
            let tools = json["tools"]?.arrayValue

            #expect(tools?.count == 1)
            #expect(tools?[0]["name"]?.stringValue == "test_tool")
        }

        @Test("MCPToolCallResult toJSONValue")
        func toolCallResultToJSONValue() {
            let result = MCPToolCallResult(
                content: [.text("Test output")],
                isError: false
            )

            let json = result.toJSONValue()

            #expect(json["isError"]?.boolValue == false)
            let content = json["content"]?.arrayValue
            #expect(content?.first?["type"]?.stringValue == "text")
            #expect(content?.first?["text"]?.stringValue == "Test output")
        }

        @Test("MCPContent text helper")
        func mcpContentTextHelper() {
            let content = MCPContent.text("Hello, World!")

            #expect(content.type == "text")
            #expect(content.text == "Hello, World!")
        }
    }

    // MARK: - MCP Server Tests

    @Suite("MCP Server Message Handling")
    struct MCPServerTests {

        @Test("Initialize response contains required fields")
        func initializeResponseContainsRequiredFields() async throws {
            let server = MCPServer(verbose: false, version: "1.0.0-test")

            // We can't directly call handleMessage, but we can verify the
            // MCPInitializeResult structure matches MCP spec
            let result = MCPInitializeResult(
                protocolVersion: MCPProtocol.version,
                serverInfo: MCPServerInfo(name: "aro", version: "1.0.0-test"),
                capabilities: MCPCapabilities(
                    tools: MCPToolsCapability(listChanged: false),
                    resources: MCPResourcesCapability(subscribe: false, listChanged: false),
                    prompts: MCPPromptsCapability(listChanged: false)
                )
            )

            let json = result.toJSONValue()

            // Verify MCP 2025-06-18 required fields
            #expect(json["protocolVersion"]?.stringValue == "2025-06-18")
            #expect(json["serverInfo"]?["name"]?.stringValue == "aro")
            #expect(json["serverInfo"]?["version"]?.stringValue == "1.0.0-test")
            #expect(json["capabilities"] != nil)
            #expect(json["capabilities"]?["tools"] != nil)
            #expect(json["capabilities"]?["resources"] != nil)
            #expect(json["capabilities"]?["prompts"] != nil)
        }

        @Test("Protocol version is correct")
        func protocolVersionIsCorrect() {
            #expect(MCPProtocol.version == "2025-06-18")
        }

        @Test("Server can be instantiated with custom base path")
        func serverCanBeInstantiatedWithCustomBasePath() {
            let server = MCPServer(basePath: "/tmp/test", verbose: false)
            // Should not crash
            #expect(server != nil)
        }

        @Test("JSON-RPC request routing - tools/list")
        func jsonRpcRoutingToolsList() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":1,"method":"tools/list"}
                """)

            #expect(request.method == "tools/list")
            #expect(request.id == .number(1))
        }

        @Test("JSON-RPC request routing - tools/call")
        func jsonRpcRoutingToolsCall() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"aro_check","arguments":{"code":"test"}}}
                """)

            #expect(request.method == "tools/call")
            #expect(request.params?["name"]?.stringValue == "aro_check")
            #expect(request.params?["arguments"]?["code"]?.stringValue == "test")
        }

        @Test("JSON-RPC request routing - resources/list")
        func jsonRpcRoutingResourcesList() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":3,"method":"resources/list"}
                """)

            #expect(request.method == "resources/list")
        }

        @Test("JSON-RPC request routing - resources/read")
        func jsonRpcRoutingResourcesRead() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"aro://syntax"}}
                """)

            #expect(request.method == "resources/read")
            #expect(request.params?["uri"]?.stringValue == "aro://syntax")
        }

        @Test("JSON-RPC request routing - prompts/list")
        func jsonRpcRoutingPromptsList() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":5,"method":"prompts/list"}
                """)

            #expect(request.method == "prompts/list")
        }

        @Test("JSON-RPC request routing - prompts/get")
        func jsonRpcRoutingPromptsGet() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"create_feature_set","arguments":{"name":"Test","purpose":"testing"}}}
                """)

            #expect(request.method == "prompts/get")
            #expect(request.params?["name"]?.stringValue == "create_feature_set")
            #expect(request.params?["arguments"]?["name"]?.stringValue == "Test")
        }

        @Test("JSON-RPC notification - initialized")
        func jsonRpcNotificationInitialized() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","method":"notifications/initialized"}
                """)

            #expect(request.method == "notifications/initialized")
            #expect(request.isNotification == true)
            #expect(request.id == nil)
        }

        @Test("JSON-RPC notification - cancelled")
        func jsonRpcNotificationCancelled() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"abc-123"}}
                """)

            #expect(request.method == "notifications/cancelled")
            #expect(request.isNotification == true)
        }

        @Test("JSON-RPC ping request")
        func jsonRpcPingRequest() throws {
            let handler = JSONRPCHandler()
            let request = try handler.parseRequest("""
                {"jsonrpc":"2.0","id":99,"method":"ping"}
                """)

            #expect(request.method == "ping")
            #expect(request.id == .number(99))
        }

        @Test("JSON-RPC invalid JSON returns parse error")
        func jsonRpcInvalidJsonReturnsParseError() throws {
            let handler = JSONRPCHandler()

            #expect(throws: JSONRPCError.self) {
                try handler.parseRequest("not valid json")
            }
        }

        @Test("JSON-RPC missing jsonrpc field returns invalid request")
        func jsonRpcMissingVersionReturnsInvalidRequest() throws {
            let handler = JSONRPCHandler()

            #expect(throws: JSONRPCError.self) {
                try handler.parseRequest("""
                    {"id":1,"method":"test"}
                    """)
            }
        }

        @Test("JSON-RPC missing method field returns invalid request")
        func jsonRpcMissingMethodReturnsInvalidRequest() throws {
            let handler = JSONRPCHandler()

            #expect(throws: JSONRPCError.self) {
                try handler.parseRequest("""
                    {"jsonrpc":"2.0","id":1}
                    """)
            }
        }

        @Test("JSON-RPC error codes are correct")
        func jsonRpcErrorCodesAreCorrect() {
            #expect(JSONRPCError.parseError.code == -32700)
            #expect(JSONRPCError.invalidRequest.code == -32600)
            #expect(JSONRPCError.methodNotFound.code == -32601)
            #expect(JSONRPCError.invalidParams.code == -32602)
            #expect(JSONRPCError.internalError.code == -32603)
        }
    }

    // MARK: - End-to-End MCP Flow Tests

    @Suite("MCP End-to-End Flows")
    struct MCPEndToEndTests {

        @Test("Full tools flow: list -> call")
        func fullToolsFlow() async {
            // List tools
            let provider = MCPToolProvider()
            let listResult = provider.listTools()

            // Verify aro_check is available
            let aroCheck = listResult.tools.first { $0.name == "aro_check" }
            #expect(aroCheck != nil)
            #expect(aroCheck?.inputSchema != nil)

            // Call aro_check
            let callResult = await provider.callTool(
                name: "aro_check",
                arguments: .object([
                    "code": .string("(Test: App) { <Return> an <OK: status> for the <result>. }")
                ])
            )

            #expect(callResult.isError != true)
        }

        @Test("Full resources flow: list -> read")
        func fullResourcesFlow() async {
            // List resources
            let provider = MCPResourceProvider()
            let listResult = await provider.listResources()

            // Verify syntax resource is available
            let syntaxResource = listResult.resources.first { $0.uri == "aro://syntax" }
            #expect(syntaxResource != nil)

            // Read syntax resource
            let readResult = await provider.readResource(uri: "aro://syntax")

            #expect(readResult != nil)
            #expect(readResult?.contents.count ?? 0 > 0)
        }

        @Test("Full prompts flow: list -> get")
        func fullPromptsFlow() {
            // List prompts
            let provider = MCPPromptProvider()
            let listResult = provider.listPrompts()

            // Verify create_feature_set is available
            let createPrompt = listResult.prompts.first { $0.name == "create_feature_set" }
            #expect(createPrompt != nil)

            // Get prompt with arguments
            let getResult = provider.getPrompt(
                name: "create_feature_set",
                arguments: ["name": "OrderProcessor", "purpose": "process customer orders"]
            )

            #expect(getResult != nil)
            #expect(getResult?.messages.first?.content.text?.contains("OrderProcessor") == true)
        }

        @Test("aro_run requires directory argument")
        func aroRunRequiresDirectoryArgument() async {
            let provider = MCPToolProvider()

            // Missing directory argument should return error
            let result = await provider.callTool(
                name: "aro_run",
                arguments: .object([:])
            )

            #expect(result.isError == true)
            #expect(result.content.first?.text?.contains("directory") == true)
        }
    }
}
