// ============================================================
// MCPServer.swift
// ARO MCP - Model Context Protocol Server
// ============================================================

import Foundation

/// ARO MCP Server
/// Exposes ARO capabilities to LLMs via the Model Context Protocol
public actor MCPServer {
    private let transport: StdioTransport
    private let jsonRpc: JSONRPCHandler
    private let toolProvider: MCPToolProvider
    private let resourceProvider: MCPResourceProvider
    private let promptProvider: MCPPromptProvider

    private var isRunning = false
    private var isInitialized = false
    private var verbose: Bool
    private let version: String

    public init(basePath: String? = nil, verbose: Bool = false, version: String = "0.3.0") {
        self.transport = StdioTransport()
        self.jsonRpc = JSONRPCHandler()
        self.toolProvider = MCPToolProvider()
        self.resourceProvider = basePath.map { MCPResourceProvider(basePath: $0) } ?? MCPResourceProvider()
        self.promptProvider = MCPPromptProvider()
        self.verbose = verbose
        self.version = version
    }

    /// Start the MCP server
    public func run() async {
        isRunning = true

        do {
            try await transport.start()

            if verbose {
                await transport.log("ARO MCP Server started")
            }

            // Main message loop
            while isRunning {
                guard let line = try await transport.receive() else {
                    // EOF - stdin closed
                    if verbose {
                        await transport.log("Input stream closed")
                    }
                    break
                }

                if line.isEmpty {
                    continue
                }

                if verbose {
                    await transport.log("Received: \(line)")
                }

                // Handle the message
                let response = await handleMessage(line)

                if let response = response {
                    if verbose {
                        await transport.log("Sending: \(response)")
                    }
                    try await transport.send(response)
                }
            }
        } catch {
            if verbose {
                await transport.log("Error: \(error)")
            }
        }

        await transport.stop()

        if verbose {
            await transport.log("ARO MCP Server stopped")
        }
    }

    /// Stop the server
    public func stop() {
        isRunning = false
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: String) async -> String? {
        do {
            let request = try jsonRpc.parseRequest(message)

            // Notifications don't get responses
            if request.isNotification {
                await handleNotification(request)
                return nil
            }

            // Handle the request
            let result = await handleRequest(request)
            let response = jsonRpc.successResponse(id: request.id, result: result)
            return try jsonRpc.encodeResponse(response)
        } catch let error as JSONRPCError {
            let response = jsonRpc.errorResponse(id: nil, error: error)
            return try? jsonRpc.encodeResponse(response)
        } catch {
            let response = jsonRpc.errorResponse(id: nil, error: .internalError)
            return try? jsonRpc.encodeResponse(response)
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) async {
        switch request.method {
        case "notifications/initialized":
            // Client has completed initialization
            if verbose {
                await transport.log("Client initialized")
            }

        case "notifications/cancelled":
            // Request was cancelled
            if verbose {
                await transport.log("Request cancelled")
            }

        default:
            if verbose {
                await transport.log("Unknown notification: \(request.method)")
            }
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) async -> JSONValue {
        switch request.method {
        // Lifecycle
        case "initialize":
            return handleInitialize(request.params)

        // Tools
        case "tools/list":
            return handleToolsList()

        case "tools/call":
            return await handleToolsCall(request.params)

        // Resources
        case "resources/list":
            return await handleResourcesList()

        case "resources/read":
            return await handleResourcesRead(request.params)

        // Prompts
        case "prompts/list":
            return handlePromptsList()

        case "prompts/get":
            return handlePromptsGet(request.params)

        // Ping (for health check)
        case "ping":
            return .object([:])

        default:
            // Method not found - return error as result
            // (Real implementation would return JSON-RPC error)
            return .object([
                "error": .string("Method not found: \(request.method)")
            ])
        }
    }

    // MARK: - Lifecycle Handlers

    private func handleInitialize(_ params: JSONValue?) -> JSONValue {
        isInitialized = true

        let result = MCPInitializeResult(
            protocolVersion: MCPProtocol.version,
            serverInfo: MCPServerInfo(
                name: "aro",
                version: version
            ),
            capabilities: MCPCapabilities(
                tools: MCPToolsCapability(listChanged: false),
                resources: MCPResourcesCapability(subscribe: false, listChanged: false),
                prompts: MCPPromptsCapability(listChanged: false)
            )
        )

        return result.toJSONValue()
    }

    // MARK: - Tools Handlers

    private func handleToolsList() -> JSONValue {
        let result = toolProvider.listTools()
        return result.toJSONValue()
    }

    private func handleToolsCall(_ params: JSONValue?) async -> JSONValue {
        guard let params = params?.objectValue,
              let name = params["name"]?.stringValue else {
            return MCPToolCallResult(
                content: [.text("Missing tool name")],
                isError: true
            ).toJSONValue()
        }

        let arguments = params["arguments"]
        let result = await toolProvider.callTool(name: name, arguments: arguments)
        return result.toJSONValue()
    }

    // MARK: - Resources Handlers

    private func handleResourcesList() async -> JSONValue {
        let result = await resourceProvider.listResources()
        return result.toJSONValue()
    }

    private func handleResourcesRead(_ params: JSONValue?) async -> JSONValue {
        guard let params = params?.objectValue,
              let uri = params["uri"]?.stringValue else {
            return .object([
                "error": .object([
                    "code": .number(-32602),
                    "message": .string("Missing uri parameter")
                ])
            ])
        }

        guard let result = await resourceProvider.readResource(uri: uri) else {
            return .object([
                "error": .object([
                    "code": .number(-32002),
                    "message": .string("Resource not found"),
                    "data": .object(["uri": .string(uri)])
                ])
            ])
        }

        return result.toJSONValue()
    }

    // MARK: - Prompts Handlers

    private func handlePromptsList() -> JSONValue {
        let result = promptProvider.listPrompts()
        return result.toJSONValue()
    }

    private func handlePromptsGet(_ params: JSONValue?) -> JSONValue {
        guard let params = params?.objectValue,
              let name = params["name"]?.stringValue else {
            return .object([
                "error": .object([
                    "code": .number(-32602),
                    "message": .string("Missing name parameter")
                ])
            ])
        }

        // Extract arguments if present
        var arguments: [String: String]?
        if let argsValue = params["arguments"]?.objectValue {
            arguments = [:]
            for (key, value) in argsValue {
                if let str = value.stringValue {
                    arguments?[key] = str
                }
            }
        }

        guard let result = promptProvider.getPrompt(name: name, arguments: arguments) else {
            return .object([
                "error": .object([
                    "code": .number(-32602),
                    "message": .string("Unknown prompt: \(name)")
                ])
            ])
        }

        return result.toJSONValue()
    }
}
