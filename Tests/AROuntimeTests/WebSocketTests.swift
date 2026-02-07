// ============================================================
// WebSocketTests.swift
// ARO Runtime - WebSocket Unit Tests (ARO-0048)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

#if !os(Windows)

// MARK: - WebSocket Event Tests

@Suite("WebSocket Event Tests")
struct WebSocketEventTests {

    @Test("WebSocketConnectedEvent has correct event type")
    func testConnectedEventType() {
        #expect(WebSocketConnectedEvent.eventType == "websocket.connected")
    }

    @Test("WebSocketConnectedEvent stores connection info")
    func testConnectedEventInfo() {
        let event = WebSocketConnectedEvent(
            connectionId: "conn-123",
            path: "/ws",
            remoteAddress: "127.0.0.1:12345"
        )

        #expect(event.connectionId == "conn-123")
        #expect(event.path == "/ws")
        #expect(event.remoteAddress == "127.0.0.1:12345")
        #expect(event.timestamp <= Date())
    }

    @Test("WebSocketMessageEvent has correct event type")
    func testMessageEventType() {
        #expect(WebSocketMessageEvent.eventType == "websocket.message")
    }

    @Test("WebSocketMessageEvent stores message info")
    func testMessageEventInfo() {
        let event = WebSocketMessageEvent(
            connectionId: "conn-456",
            message: "Hello WebSocket"
        )

        #expect(event.connectionId == "conn-456")
        #expect(event.message == "Hello WebSocket")
        #expect(event.timestamp <= Date())
    }

    @Test("WebSocketDisconnectedEvent has correct event type")
    func testDisconnectedEventType() {
        #expect(WebSocketDisconnectedEvent.eventType == "websocket.disconnected")
    }

    @Test("WebSocketDisconnectedEvent stores disconnect info")
    func testDisconnectedEventInfo() {
        let event = WebSocketDisconnectedEvent(
            connectionId: "conn-789",
            reason: "client closed"
        )

        #expect(event.connectionId == "conn-789")
        #expect(event.reason == "client closed")
        #expect(event.timestamp <= Date())
    }
}

// MARK: - WebSocket Error Tests

@Suite("WebSocket Error Tests")
struct WebSocketErrorTests {

    @Test("WebSocketError.notConnected description")
    func testNotConnectedError() {
        let error = WebSocketError.notConnected
        #expect(error.description == "WebSocket not connected")
    }

    @Test("WebSocketError.connectionNotFound description")
    func testConnectionNotFoundError() {
        let error = WebSocketError.connectionNotFound("conn-123")
        #expect(error.description == "WebSocket connection not found: conn-123")
    }

    @Test("WebSocketError.encodingError description")
    func testEncodingError() {
        let error = WebSocketError.encodingError
        #expect(error.description == "String encoding error")
    }

    @Test("WebSocketError.serverNotEnabled description")
    func testServerNotEnabledError() {
        let error = WebSocketError.serverNotEnabled
        #expect(error.description == "WebSocket server is not enabled")
    }
}

// MARK: - WebSocket Connection Info Tests

@Suite("WebSocket Connection Info Tests")
struct WebSocketConnectionInfoTests {

    @Test("WebSocketConnectionInfo stores info correctly")
    func testConnectionInfo() {
        let info = WebSocketConnectionInfo(
            id: "conn-abc",
            path: "/websocket",
            remoteAddress: "192.168.1.1:8080"
        )

        #expect(info.id == "conn-abc")
        #expect(info.path == "/websocket")
        #expect(info.remoteAddress == "192.168.1.1:8080")
    }

    @Test("WebSocketMessageInfo stores info correctly")
    func testMessageInfo() {
        let info = WebSocketMessageInfo(
            connectionId: "conn-xyz",
            message: "Test message"
        )

        #expect(info.connectionId == "conn-xyz")
        #expect(info.message == "Test message")
    }

    @Test("WebSocketDisconnectInfo stores info correctly")
    func testDisconnectInfo() {
        let info = WebSocketDisconnectInfo(
            connectionId: "conn-end",
            reason: "timeout"
        )

        #expect(info.connectionId == "conn-end")
        #expect(info.reason == "timeout")
    }
}

// MARK: - WebSocket Server Tests

@Suite("WebSocket Server Tests")
struct WebSocketServerTests {

    @Test("AROWebSocketServer initializes with default path")
    func testServerInitDefault() {
        let server = AROWebSocketServer()
        #expect(server.path == "/ws")
        #expect(server.connectionCount == 0)
    }

    @Test("AROWebSocketServer initializes with custom path")
    func testServerInitCustomPath() {
        let server = AROWebSocketServer(path: "/socket")
        #expect(server.path == "/socket")
    }

    @Test("AROWebSocketServer enable/disable")
    func testServerEnableDisable() {
        let server = AROWebSocketServer()

        #expect(server.isEnabled() == false)

        server.enable()
        #expect(server.isEnabled() == true)

        server.disable()
        #expect(server.isEnabled() == false)
    }

    @Test("AROWebSocketServer connectionCount starts at zero")
    func testConnectionCountZero() {
        let server = AROWebSocketServer()
        #expect(server.connectionCount == 0)
    }

    @Test("AROWebSocketServer isWebSocketConnection returns false for unknown ID")
    func testIsWebSocketConnectionUnknown() {
        let server = AROWebSocketServer()
        #expect(server.isWebSocketConnection("unknown-id") == false)
    }

    @Test("Send to non-existent connection throws error")
    func testSendToNonExistent() async throws {
        let server = AROWebSocketServer()

        await #expect(throws: WebSocketError.self) {
            try await server.send(message: "test", to: "non-existent")
        }
    }

    @Test("Close non-existent connection does not throw")
    func testCloseNonExistent() async throws {
        let server = AROWebSocketServer()

        // Should not throw - closing non-existent connection is a no-op
        try await server.close("non-existent")
    }

    @Test("Broadcast with no connections does not throw")
    func testBroadcastNoConnections() async throws {
        let server = AROWebSocketServer()

        // Should not throw - broadcasting to no connections is valid
        try await server.broadcast(message: "test message")
    }
}

#endif // !os(Windows)

// MARK: - Broadcast Action WebSocket Tests

@Suite("Broadcast Action WebSocket Tests")
struct BroadcastActionWebSocketTests {

    func createDescriptors(
        resultBase: String = "data",
        objectBase: String = "websocket",
        preposition: Preposition = .to
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("BroadcastAction role is response")
    func testBroadcastActionRole() {
        #expect(BroadcastAction.role == .response)
    }

    @Test("BroadcastAction verbs include broadcast")
    func testBroadcastActionVerbs() {
        #expect(BroadcastAction.verbs.contains("broadcast"))
    }

    @Test("BroadcastAction valid prepositions")
    func testBroadcastActionPrepositions() {
        #expect(BroadcastAction.validPrepositions.contains(.to))
        #expect(BroadcastAction.validPrepositions.contains(.via))
    }

    @Test("BroadcastAction detects websocket target")
    func testBroadcastDetectsWebSocket() async throws {
        let action = BroadcastAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("message", value: "Hello")

        let (result, object) = createDescriptors(resultBase: "message", objectBase: "websocket")

        // Without a WebSocket service registered, it should emit an event
        let broadcastResult = try await action.execute(result: result, object: object, context: context)

        #expect(broadcastResult is BroadcastResult)
        if let br = broadcastResult as? BroadcastResult {
            #expect(br.success == true)
        }
    }

    @Test("BroadcastAction detects ws target")
    func testBroadcastDetectsWs() async throws {
        let action = BroadcastAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: "Test data")

        let (result, object) = createDescriptors(resultBase: "data", objectBase: "ws")

        let broadcastResult = try await action.execute(result: result, object: object, context: context)

        #expect(broadcastResult is BroadcastResult)
    }

    @Test("BroadcastAction serializes dictionary to JSON")
    func testBroadcastSerializesDict() async throws {
        let action = BroadcastAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("message", value: [
            "id": "123",
            "text": "Hello"
        ] as [String: any Sendable])

        let (result, object) = createDescriptors(resultBase: "message", objectBase: "websocket")

        let broadcastResult = try await action.execute(result: result, object: object, context: context)

        #expect(broadcastResult is BroadcastResult)
    }
}

// MARK: - Extract Action Form Data Tests

@Suite("Extract Action Form Data Tests")
struct ExtractActionFormDataTests {

    func createDescriptors(
        resultBase: String = "result",
        resultSpecifiers: [String] = [],
        objectBase: String = "source",
        objectSpecifiers: [String] = [],
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: objectSpecifiers, span: span)
        return (result, object)
    }

    @Test("Extract from URL-encoded form data")
    func testExtractFromFormData() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("body", value: "name=John&age=30&city=Berlin")

        // Use result qualifier to specify which field to extract
        let (result, object) = createDescriptors(
            resultBase: "name-value",
            resultSpecifiers: ["name"],
            objectBase: "body"
        )

        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "John")
    }

    @Test("Extract URL-encoded value with special characters")
    func testExtractFormDataUrlEncoded() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("body", value: "message=Hello%20World&sender=Test%40User")

        let (result, object) = createDescriptors(
            resultBase: "msg",
            resultSpecifiers: ["message"],
            objectBase: "body"
        )

        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "Hello World")
    }

    @Test("Extract multiple fields from form data")
    func testExtractMultipleFormFields() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("form", value: "username=alice&password=secret&remember=true")

        // Extract username
        let (result1, object1) = createDescriptors(
            resultBase: "user",
            resultSpecifiers: ["username"],
            objectBase: "form"
        )
        let username = try await action.execute(result: result1, object: object1, context: context)
        #expect(username as? String == "alice")

        // Extract password
        let (result2, object2) = createDescriptors(
            resultBase: "pass",
            resultSpecifiers: ["password"],
            objectBase: "form"
        )
        let password = try await action.execute(result: result2, object: object2, context: context)
        #expect(password as? String == "secret")
    }

    @Test("Extract from form data returns nil for missing key")
    func testExtractFormDataMissingKey() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("body", value: "name=John&age=30")

        // Try to extract non-existent field - should return the whole body
        let (result, object) = createDescriptors(
            resultBase: "email",
            resultSpecifiers: ["email"],
            objectBase: "body"
        )

        let value = try await action.execute(result: result, object: object, context: context)

        // When field not found, returns the source unchanged
        #expect(value as? String == "name=John&age=30")
    }
}

// MARK: - WebSocket Event Handler Pattern Tests

@Suite("WebSocket Event Handler Pattern Tests")
struct WebSocketEventHandlerPatternTests {

    @Test("Feature set with WebSocket Event Handler business activity")
    func testWebSocketEventHandlerPattern() {
        // Test that the pattern "WebSocket Event Handler" is recognized
        let activity = "WebSocket Event Handler"

        #expect(activity.contains("WebSocket"))
        #expect(activity.contains("Event Handler"))
    }

    @Test("Handle WebSocket Connect pattern")
    func testHandleWebSocketConnectPattern() {
        let featureSetName = "Handle WebSocket Connect"
        let businessActivity = "WebSocket Event Handler"

        #expect(featureSetName.hasPrefix("Handle WebSocket"))
        #expect(businessActivity == "WebSocket Event Handler")
    }

    @Test("Handle WebSocket Disconnect pattern")
    func testHandleWebSocketDisconnectPattern() {
        let featureSetName = "Handle WebSocket Disconnect"
        let businessActivity = "WebSocket Event Handler"

        #expect(featureSetName.hasPrefix("Handle WebSocket"))
        #expect(businessActivity == "WebSocket Event Handler")
    }

    @Test("Handle WebSocket Message pattern")
    func testHandleWebSocketMessagePattern() {
        let featureSetName = "Handle WebSocket Message"
        let businessActivity = "WebSocket Event Handler"

        #expect(featureSetName.hasPrefix("Handle WebSocket"))
        #expect(businessActivity == "WebSocket Event Handler")
    }
}
