// ============================================================
// SystemObjectIntegrationTests.swift
// ARO Runtime - System Objects Integration Tests
// ARO-0043: System Objects with Sink Syntax
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Console Objects Tests

@Suite("Console System Objects")
struct ConsoleSystemObjectTests {

    @Test("ConsoleObject capabilities")
    func testConsoleCapabilities() {
        let console = ConsoleObject()
        #expect(console.capabilities == .sink)
    }

    @Test("ConsoleObject identifier")
    func testConsoleIdentifier() {
        #expect(ConsoleObject.identifier == "console")
    }

    @Test("ConsoleObject write operation")
    func testConsoleWrite() async throws {
        let console = ConsoleObject()
        // Should not throw
        try await console.write("Test message")
    }

    @Test("ConsoleObject read throws error")
    func testConsoleReadThrows() async {
        let console = ConsoleObject()
        do {
            _ = try await console.read(property: nil)
            Issue.record("Expected read to throw error")
        } catch {
            // Expected
        }
    }
}

@Suite("Stderr System Object")
struct StderrSystemObjectTests {

    @Test("StderrObject capabilities")
    func testStderrCapabilities() {
        let stderr = StderrObject()
        #expect(stderr.capabilities == .sink)
    }

    @Test("StderrObject identifier")
    func testStderrIdentifier() {
        #expect(StderrObject.identifier == "stderr")
    }

    @Test("StderrObject write operation")
    func testStderrWrite() async throws {
        let stderr = StderrObject()
        // Should not throw
        try await stderr.write("Error message")
    }

    @Test("StderrObject read throws error")
    func testStderrReadThrows() async {
        let stderr = StderrObject()
        do {
            _ = try await stderr.read(property: nil)
            Issue.record("Expected read to throw error")
        } catch {
            // Expected
        }
    }
}

@Suite("Stdin System Object")
struct StdinSystemObjectTests {

    @Test("StdinObject capabilities")
    func testStdinCapabilities() {
        let stdin = StdinObject()
        #expect(stdin.capabilities == .source)
    }

    @Test("StdinObject identifier")
    func testStdinIdentifier() {
        #expect(StdinObject.identifier == "stdin")
    }

    @Test("StdinObject write throws error")
    func testStdinWriteThrows() async {
        let stdin = StdinObject()
        do {
            try await stdin.write("Cannot write to stdin")
            Issue.record("Expected write to throw error")
        } catch {
            // Expected
        }
    }
}

// MARK: - Environment Object Tests

@Suite("Environment System Object")
struct EnvironmentSystemObjectTests {

    @Test("EnvironmentObject capabilities")
    func testEnvironmentCapabilities() {
        let env = EnvironmentObject()
        #expect(env.capabilities == .source)
    }

    @Test("EnvironmentObject identifier")
    func testEnvironmentIdentifier() {
        #expect(EnvironmentObject.identifier == "env")
    }

    @Test("EnvironmentObject read all variables")
    func testEnvironmentReadAll() async throws {
        let env = EnvironmentObject()
        let allVars = try await env.read(property: nil)

        // Should return a dictionary
        #expect(allVars is [String: String])

        let vars = allVars as! [String: String]
        // Should contain at least some standard environment variables
        #expect(!vars.isEmpty)
    }

    @Test("EnvironmentObject read specific variable")
    func testEnvironmentReadSpecific() async throws {
        let env = EnvironmentObject()

        // Set a test environment variable (cross-platform)
        #if os(Windows)
        _putenv("ARO_TEST_VAR=test_value")
        defer { _putenv("ARO_TEST_VAR=") }
        #else
        setenv("ARO_TEST_VAR", "test_value", 1)
        defer { unsetenv("ARO_TEST_VAR") }
        #endif

        let value = try await env.read(property: "ARO_TEST_VAR")
        #expect(value as? String == "test_value")
    }

    @Test("EnvironmentObject read non-existent variable throws")
    func testEnvironmentReadNonExistent() async {
        let env = EnvironmentObject()

        do {
            _ = try await env.read(property: "NONEXISTENT_VAR_12345")
            Issue.record("Expected read to throw error for non-existent variable")
        } catch {
            // Expected
        }
    }

    @Test("EnvironmentObject write throws error")
    func testEnvironmentWriteThrows() async {
        let env = EnvironmentObject()
        do {
            try await env.write("Cannot write to env")
            Issue.record("Expected write to throw error")
        } catch {
            // Expected
        }
    }
}

// MARK: - File Object Tests

@Suite("File System Object")
struct FileSystemObjectTests {

    private static func createTempDir() throws -> String {
        let tempDir = NSTemporaryDirectory() + "ARO-FileObjectTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("FileObject capabilities")
    func testFileCapabilities() throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let file = try FileObject(path: tempDir + "/test.txt", fileService: service)
        #expect(file.capabilities == .bidirectional)
    }

    @Test("FileObject identifier")
    func testFileIdentifier() {
        #expect(FileObject.identifier == "file")
    }

    @Test("FileObject write and read text file")
    func testFileWriteReadText() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        // Use .md extension which returns raw content without modification
        let testFile = tempDir + "/test.md"
        let file = try FileObject(path: testFile, fileService: service)

        let content = "Hello, ARO!"
        try await file.write(content)

        let readContent = try await file.read(property: nil)
        #expect(readContent as? String == content)
    }

    @Test("FileObject write and read JSON file")
    func testFileWriteReadJSON() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/data.json"
        let file = try FileObject(path: testFile, fileService: service)

        let data: [String: any Sendable] = ["key": "value", "number": 42]
        try await file.write(data)

        let readContent = try await file.read(property: nil)
        #expect(readContent is [String: Any])
    }

    @Test("FileObject rejects path traversal")
    func testFilePathTraversalRejection() {
        let service = AROFileSystemService()

        do {
            _ = try FileObject(path: "../../../etc/passwd", fileService: service)
            Issue.record("Expected path traversal to be rejected")
        } catch {
            // Expected
        }
    }

    @Test("FileObject rejects malicious paths")
    func testFileRejectsMaliciousPaths() {
        let service = AROFileSystemService()
        // Test paths that attempt directory traversal
        let maliciousPaths = [
            "../secret.txt",  // Tries to go up one level
            "some/path/../../../etc/passwd"  // Tries to escape via nested traversal
        ]

        for path in maliciousPaths {
            do {
                _ = try FileObject(path: path, fileService: service)
                Issue.record("Expected malicious path to be rejected: \(path)")
            } catch {
                // Expected
            }
        }
    }
}

// MARK: - HTTP Context Objects Tests

@Suite("HTTP Request System Object")
struct HTTPRequestSystemObjectTests {

    @Test("RequestObject capabilities")
    func testRequestCapabilities() {
        let request = RequestObject(
            method: "GET",
            path: "/users",
            headers: [:],
            body: nil,
            queryParameters: [:],
            pathParameters: [:]
        )
        #expect(request.capabilities == .source)
    }

    @Test("RequestObject identifier")
    func testRequestIdentifier() {
        #expect(RequestObject.identifier == "request")
    }

    @Test("RequestObject read method")
    func testRequestReadMethod() async throws {
        let request = RequestObject(
            method: "POST",
            path: "/api/users",
            headers: [:],
            body: nil,
            queryParameters: [:],
            pathParameters: [:]
        )

        let method = try await request.read(property: "method")
        #expect(method as? String == "POST")
    }

    @Test("RequestObject read path")
    func testRequestReadPath() async throws {
        let request = RequestObject(
            method: "GET",
            path: "/api/users/123",
            headers: [:],
            body: nil,
            queryParameters: [:],
            pathParameters: [:]
        )

        let path = try await request.read(property: "path")
        #expect(path as? String == "/api/users/123")
    }

    @Test("RequestObject read headers")
    func testRequestReadHeaders() async throws {
        let headers = ["Authorization": "Bearer token123", "Content-Type": "application/json"]
        let request = RequestObject(
            method: "GET",
            path: "/api",
            headers: headers,
            body: nil,
            queryParameters: [:],
            pathParameters: [:]
        )

        let auth = try await request.read(property: "headers.Authorization")
        #expect(auth as? String == "Bearer token123")
    }

    @Test("RequestObject read body")
    func testRequestReadBody() async throws {
        let body: [String: any Sendable] = ["name": "John", "age": 30]
        let request = RequestObject(
            method: "POST",
            path: "/api/users",
            headers: [:],
            body: body,
            queryParameters: [:],
            pathParameters: [:]
        )

        let readBody = try await request.read(property: "body")
        #expect(readBody is [String: Any])
    }

    @Test("RequestObject read full request")
    func testRequestReadFull() async throws {
        let request = RequestObject(
            method: "GET",
            path: "/api/users",
            headers: ["Accept": "application/json"],
            body: nil,
            queryParameters: ["limit": "10"],
            pathParameters: ["id": "123"]
        )

        let fullRequest = try await request.read(property: nil)
        #expect(fullRequest is [String: Any])

        let dict = fullRequest as! [String: Any]
        #expect(dict["method"] as? String == "GET")
        #expect(dict["path"] as? String == "/api/users")
    }

    @Test("RequestObject write throws error")
    func testRequestWriteThrows() async {
        let request = RequestObject(
            method: "GET",
            path: "/",
            headers: [:],
            body: nil,
            queryParameters: [:],
            pathParameters: [:]
        )

        do {
            try await request.write("Cannot write")
            Issue.record("Expected write to throw error")
        } catch {
            // Expected
        }
    }
}

@Suite("Path Parameters System Object")
struct PathParametersSystemObjectTests {

    @Test("PathParametersObject capabilities")
    func testPathParametersCapabilities() {
        let params = PathParametersObject(parameters: [:])
        #expect(params.capabilities == .source)
    }

    @Test("PathParametersObject identifier")
    func testPathParametersIdentifier() {
        #expect(PathParametersObject.identifier == "pathParameters")
    }

    @Test("PathParametersObject read specific parameter")
    func testPathParametersReadSpecific() async throws {
        let params = PathParametersObject(parameters: ["id": "123", "name": "john"])

        let id = try await params.read(property: "id")
        #expect(id as? String == "123")

        let name = try await params.read(property: "name")
        #expect(name as? String == "john")
    }

    @Test("PathParametersObject read all parameters")
    func testPathParametersReadAll() async throws {
        let params = PathParametersObject(parameters: ["id": "123", "name": "john"])

        let all = try await params.read(property: nil)
        let dict = all as! [String: String]
        #expect(dict["id"] == "123")
        #expect(dict["name"] == "john")
    }
}

@Suite("Query Parameters System Object")
struct QueryParametersSystemObjectTests {

    @Test("QueryParametersObject capabilities")
    func testQueryParametersCapabilities() {
        let params = QueryParametersObject(parameters: [:])
        #expect(params.capabilities == .source)
    }

    @Test("QueryParametersObject identifier")
    func testQueryParametersIdentifier() {
        #expect(QueryParametersObject.identifier == "queryParameters")
    }

    @Test("QueryParametersObject read specific parameter")
    func testQueryParametersReadSpecific() async throws {
        let params = QueryParametersObject(parameters: ["limit": "10", "offset": "20"])

        let limit = try await params.read(property: "limit")
        #expect(limit as? String == "10")
    }

    @Test("QueryParametersObject read all parameters")
    func testQueryParametersReadAll() async throws {
        let params = QueryParametersObject(parameters: ["page": "1", "size": "50"])

        let all = try await params.read(property: nil)
        let dict = all as! [String: String]
        #expect(dict["page"] == "1")
        #expect(dict["size"] == "50")
    }
}

@Suite("Headers System Object")
struct HeadersSystemObjectTests {

    @Test("HeadersObject capabilities")
    func testHeadersCapabilities() {
        let headers = HeadersObject(headers: [:])
        #expect(headers.capabilities == .source)
    }

    @Test("HeadersObject identifier")
    func testHeadersIdentifier() {
        #expect(HeadersObject.identifier == "headers")
    }

    @Test("HeadersObject read specific header case insensitive")
    func testHeadersReadCaseInsensitive() async throws {
        let headers = HeadersObject(headers: ["Content-Type": "application/json"])

        let contentType1 = try await headers.read(property: "content-type")
        #expect(contentType1 as? String == "application/json")

        let contentType2 = try await headers.read(property: "Content-Type")
        #expect(contentType2 as? String == "application/json")
    }

    @Test("HeadersObject read all headers")
    func testHeadersReadAll() async throws {
        let headerDict = ["Accept": "application/json", "Authorization": "Bearer token"]
        let headers = HeadersObject(headers: headerDict)

        let all = try await headers.read(property: nil)
        let dict = all as! [String: String]
        #expect(dict["Accept"] == "application/json")
        #expect(dict["Authorization"] == "Bearer token")
    }
}

@Suite("Body System Object")
struct BodySystemObjectTests {

    @Test("BodyObject capabilities")
    func testBodyCapabilities() {
        let body = BodyObject(body: [:] as [String: any Sendable])
        #expect(body.capabilities == .source)
    }

    @Test("BodyObject identifier")
    func testBodyIdentifier() {
        #expect(BodyObject.identifier == "body")
    }

    @Test("BodyObject read full body")
    func testBodyReadFull() async throws {
        let bodyDict: [String: any Sendable] = ["name": "Alice", "age": 25]
        let body = BodyObject(body: bodyDict)

        let readBody = try await body.read(property: nil)
        let dict = readBody as! [String: Any]
        #expect(dict["name"] as? String == "Alice")
        #expect(dict["age"] as? Int == 25)
    }

    @Test("BodyObject read nested property")
    func testBodyReadNested() async throws {
        let bodyDict: [String: any Sendable] = ["name": "Bob", "email": "bob@example.com"]
        let body = BodyObject(body: bodyDict)

        let name = try await body.read(property: "name")
        #expect(name as? String == "Bob")

        let email = try await body.read(property: "email")
        #expect(email as? String == "bob@example.com")
    }
}

// MARK: - Event Context Objects Tests

@Suite("Event System Object")
struct EventSystemObjectTests {

    @Test("EventObject capabilities")
    func testEventCapabilities() {
        let event = EventObject(eventType: "UserCreated", payload: [:])
        #expect(event.capabilities == .source)
    }

    @Test("EventObject identifier")
    func testEventIdentifier() {
        #expect(EventObject.identifier == "event")
    }

    @Test("EventObject read event type")
    func testEventReadType() async throws {
        let event = EventObject(eventType: "OrderPlaced", payload: [:])

        let type = try await event.read(property: "type")
        #expect(type as? String == "OrderPlaced")
    }

    @Test("EventObject read payload property")
    func testEventReadPayload() async throws {
        let payload: [String: any Sendable] = ["userId": "123", "orderId": "456"]
        let event = EventObject(eventType: "OrderPlaced", payload: payload)

        let userId = try await event.read(property: "userId")
        #expect(userId as? String == "123")

        let orderId = try await event.read(property: "orderId")
        #expect(orderId as? String == "456")
    }

    @Test("EventObject read full event")
    func testEventReadFull() async throws {
        let payload: [String: any Sendable] = ["data": "test"]
        let event = EventObject(eventType: "TestEvent", payload: payload)

        let fullEvent = try await event.read(property: nil)
        let dict = fullEvent as! [String: Any]
        #expect(dict["type"] as? String == "TestEvent")
        #expect(dict["data"] as? String == "test")
    }

    @Test("EventObject read nested payload")
    func testEventReadNestedPayload() async throws {
        let payload: [String: any Sendable] = [
            "user": ["id": "123", "name": "Alice"] as [String: any Sendable]
        ]
        let event = EventObject(eventType: "UserEvent", payload: payload)

        let user = try await event.read(property: "user")
        #expect(user is [String: Any])
    }
}

@Suite("Shutdown System Object")
struct ShutdownSystemObjectTests {

    @Test("ShutdownObject capabilities")
    func testShutdownCapabilities() {
        let shutdown = ShutdownObject(reason: "User initiated")
        #expect(shutdown.capabilities == .source)
    }

    @Test("ShutdownObject identifier")
    func testShutdownIdentifier() {
        #expect(ShutdownObject.identifier == "shutdown")
    }

    @Test("ShutdownObject read reason")
    func testShutdownReadReason() async throws {
        let shutdown = ShutdownObject(reason: "Graceful shutdown", exitCode: 0)

        let reason = try await shutdown.read(property: "reason")
        #expect(reason as? String == "Graceful shutdown")
    }

    @Test("ShutdownObject read exit code")
    func testShutdownReadExitCode() async throws {
        let shutdown = ShutdownObject(reason: "Error", exitCode: 1)

        let code = try await shutdown.read(property: "exitCode")
        #expect(code as? Int == 1)
    }

    @Test("ShutdownObject read signal")
    func testShutdownReadSignal() async throws {
        let shutdown = ShutdownObject(reason: "Signal", signal: "SIGTERM")

        let signal = try await shutdown.read(property: "signal")
        #expect(signal as? String == "SIGTERM")
    }

    @Test("ShutdownObject read full context")
    func testShutdownReadFull() async throws {
        let shutdown = ShutdownObject(reason: "Complete", signal: "SIGINT", exitCode: 0)

        let fullContext = try await shutdown.read(property: nil)
        let dict = fullContext as! [String: Any]
        #expect(dict["reason"] as? String == "Complete")
        #expect(dict["signal"] as? String == "SIGINT")
        #expect(dict["exitCode"] as? Int == 0)
    }
}

// MARK: - Socket Context Objects Tests

@Suite("Connection System Object")
struct ConnectionSystemObjectTests {

    @Test("ConnectionObject capabilities")
    func testConnectionCapabilities() {
        let connection = ConnectionObject(connectionId: "conn-1", remoteAddress: "127.0.0.1:8080")
        #expect(connection.capabilities == .bidirectional)
    }

    @Test("ConnectionObject identifier")
    func testConnectionIdentifier() {
        #expect(ConnectionObject.identifier == "connection")
    }

    @Test("ConnectionObject read connection id")
    func testConnectionReadId() async throws {
        let connection = ConnectionObject(connectionId: "conn-123", remoteAddress: "192.168.1.1:9000")

        let id = try await connection.read(property: "id")
        #expect(id as? String == "conn-123")
    }

    @Test("ConnectionObject read remote address")
    func testConnectionReadRemoteAddress() async throws {
        let connection = ConnectionObject(connectionId: "conn-1", remoteAddress: "10.0.0.1:3000")

        let address = try await connection.read(property: "remoteAddress")
        #expect(address as? String == "10.0.0.1:3000")
    }

    @Test("ConnectionObject read full connection info")
    func testConnectionReadFull() async throws {
        let connection = ConnectionObject(connectionId: "conn-456", remoteAddress: "localhost:8888")

        let info = try await connection.read(property: nil)
        let dict = info as! [String: Any]
        #expect(dict["id"] as? String == "conn-456")
        #expect(dict["remoteAddress"] as? String == "localhost:8888")
    }
}

@Suite("Packet System Object")
struct PacketSystemObjectTests {

    @Test("PacketObject capabilities")
    func testPacketCapabilities() {
        let packet = PacketObject(buffer: Data(), connectionId: "conn-1")
        #expect(packet.capabilities == .source)
    }

    @Test("PacketObject identifier")
    func testPacketIdentifier() {
        #expect(PacketObject.identifier == "packet")
    }

    @Test("PacketObject read buffer")
    func testPacketReadBuffer() async throws {
        let data = "Hello, Socket!".data(using: .utf8)!
        let packet = PacketObject(buffer: data, connectionId: "conn-1")

        let buffer = try await packet.read(property: "buffer")
        #expect(buffer as? String == "Hello, Socket!")
    }

    @Test("PacketObject read connection id")
    func testPacketReadConnectionId() async throws {
        let data = Data()
        let packet = PacketObject(buffer: data, connectionId: "conn-789")

        let connId = try await packet.read(property: "connectionId")
        #expect(connId as? String == "conn-789")
    }

    @Test("PacketObject read size")
    func testPacketReadSize() async throws {
        let data = "Test data".data(using: .utf8)!
        let packet = PacketObject(buffer: data, connectionId: "conn-1")

        let size = try await packet.read(property: "size")
        #expect(size as? Int == data.count)
    }

    @Test("PacketObject read full packet info")
    func testPacketReadFull() async throws {
        let data = "Packet data".data(using: .utf8)!
        let packet = PacketObject(buffer: data, connectionId: "conn-123")

        let info = try await packet.read(property: nil)
        let dict = info as! [String: Any]
        #expect(dict["connectionId"] as? String == "conn-123")
        #expect(dict["size"] as? Int == data.count)
    }
}

// MARK: - System Object Registry Tests

@Suite("System Object Registry")
struct SystemObjectRegistryTests {

    @Test("Registry has console objects registered")
    func testRegistryConsoleObjects() {
        let registry = SystemObjectRegistry.shared

        #expect(registry.isRegistered("console"))
        #expect(registry.isRegistered("stderr"))
        #expect(registry.isRegistered("stdin"))
    }

    @Test("Registry has environment objects registered")
    func testRegistryEnvironmentObjects() {
        let registry = SystemObjectRegistry.shared

        #expect(registry.isRegistered("env"))
    }

    @Test("Registry has file objects registered")
    func testRegistryFileObjects() {
        let registry = SystemObjectRegistry.shared

        #expect(registry.isRegistered("file"))
    }

    @Test("Registry has all built-in objects registered")
    func testRegistryAllBuiltIns() {
        let registry = SystemObjectRegistry.shared

        // Verify all 14 built-in objects are registered
        #expect(registry.isRegistered("console"))
        #expect(registry.isRegistered("stderr"))
        #expect(registry.isRegistered("stdin"))
        #expect(registry.isRegistered("env"))
        #expect(registry.isRegistered("file"))
        #expect(registry.isRegistered("request"))
        #expect(registry.isRegistered("pathParameters"))
        #expect(registry.isRegistered("queryParameters"))
        #expect(registry.isRegistered("headers"))
        #expect(registry.isRegistered("body"))
        #expect(registry.isRegistered("event"))
        #expect(registry.isRegistered("shutdown"))
        #expect(registry.isRegistered("connection"))
        #expect(registry.isRegistered("packet"))
    }
}
