# ARO-0024: Socket Communication

* Proposal: ARO-0024
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0012

## Abstract

This proposal defines TCP socket server and client capabilities for ARO applications using SwiftNIO, enabling bidirectional real-time communication.

## Motivation

Applications often need real-time bidirectional communication:

1. **Socket Servers**: Accept incoming TCP connections
2. **Socket Clients**: Connect to external services
3. **Bidirectional Data**: Send and receive data streams
4. **Event Integration**: Publish connection and data events

## Proposed Solution

### 1. Socket Server

Start a TCP socket server using the `<Listen>` action:

```aro
(Application-Start: Echo Server) {
    <Log> the <message> for the <console> with "Starting socket server".
    <Listen> on port 9000 as <socket-server>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### 2. Connection Events

Handle client connections:

```swift
public struct ClientConnectedEvent: RuntimeEvent {
    public let connectionId: String
    public let remoteAddress: String
    public let localPort: Int
}

public struct ClientDisconnectedEvent: RuntimeEvent {
    public let connectionId: String
    public let reason: String?
}

public struct DataReceivedEvent: RuntimeEvent {
    public let connectionId: String
    public let data: Data
}
```

### 3. Connection Handlers

```aro
(Handle Client Connected: Socket Event Handler) {
    <Extract> the <client-id> from the <connection: id>.
    <Extract> the <remote-address> from the <connection: remoteAddress>.
    <Log> the <connection: info> for the <console> with <remote-address>.
    <Return> an <OK: status> for the <connection>.
}

(Handle Data Received: Socket Event Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <client> from the <event: connection>.

    (* Process received data *)
    <Transform> the <response> from the <data>.

    (* Send response back *)
    <Send> the <response> to the <client>.

    <Return> an <OK: status> for the <event>.
}

(Handle Client Disconnected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> the <disconnection: info> for the <console> with <client-id>.
    <Return> an <OK: status> for the <event>.
}
```

### 4. Socket Client

Connect to external services:

```aro
(Connect to Service: Socket Client) {
    <Connect> to <host: "192.168.1.100"> on port 8080 as <service-connection>.
    <Send> the <handshake-data> to the <service-connection>.
    <Return> an <OK: status> for the <connection>.
}
```

### 5. Data Operations

```aro
(* Send data to a specific connection *)
<Send> the <data> to the <connection>.

(* Send to all connected clients *)
<Broadcast> the <message> to the <socket-server>.

(* Close a connection *)
<Close> the <connection>.
```

### 6. SwiftNIO Integration

```swift
public final class AROSocketServer: SocketServerService {
    private let group: MultiThreadedEventLoopGroup
    private let eventBus: EventBus
    private var connections: [String: SocketConnection] = [:]

    public func listen(port: Int) async throws {
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    SocketHandler(
                        server: self,
                        eventBus: self.eventBus
                    )
                )
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        eventBus.publish(SocketServerStartedEvent(port: port))
    }

    public func send(data: Data, to connectionId: String) async throws {
        guard let connection = connections[connectionId] else {
            throw SocketError.connectionNotFound(connectionId)
        }
        try await connection.send(data)
    }

    public func broadcast(data: Data) async throws {
        for connection in connections.values {
            try await connection.send(data)
        }
    }
}

public final class AROSocketClient: SocketClientService {
    private let group: MultiThreadedEventLoopGroup
    private let eventBus: EventBus

    public func connect(host: String, port: Int) async throws -> SocketConnection {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    ClientSocketHandler(eventBus: self.eventBus)
                )
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        return SocketConnection(channel: channel)
    }
}
```

---

## Grammar Extension

```ebnf
(* Socket operations *)
listen_statement = "<Listen>" , "on" , "port" , integer , "as" , identifier ;
connect_statement = "<Connect>" , "to" , host_reference , "on" , "port" , integer , "as" , identifier ;
send_statement = "<Send>" , "the" , value , "to" , "the" , identifier ;
broadcast_statement = "<Broadcast>" , "the" , value , "to" , "the" , identifier ;
close_statement = "<Close>" , "the" , identifier ;

host_reference = "host:" , string_literal ;
```

---

## Complete Example

```aro
(* Echo Socket Server - Bidirectional TCP communication *)

(Application-Start: Echo Socket) {
    <Log> the <message> for the <console> with "Starting echo socket on port 9000".
    <Listen> on port 9000 as <socket-server>.
    <Log> the <message> for the <console> with "Socket server listening on port 9000".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Handle Client Connected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Extract> the <remote-address> from the <event: remoteAddress>.
    <Log> the <message> for the <console> with "Client connected".
    <Return> an <OK: status> for the <connection>.
}

(Handle Data Received: Socket Event Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <client> from the <event: connection>.

    (* Echo back the received data *)
    <Send> the <data> to the <client>.

    <Log> the <message> for the <console> with "Echoed data back to client".
    <Return> an <OK: status> for the <event>.
}

(Handle Client Disconnected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> the <message> for the <console> with "Client disconnected".
    <Return> an <OK: status> for the <event>.
}
```

---

## Implementation Notes

- Uses SwiftNIO for non-blocking I/O
- Connections are managed with unique IDs
- Thread-safe connection storage
- Events published for all connection lifecycle stages
- Supports binary and text data
- Use `<Keepalive>` action to keep the application running for socket events

---

## Implementation Location

The socket communication system is implemented in:

- `Sources/ARORuntime/Sockets/SocketServer.swift` - `AROSocketServer` and `AROSocketClient` classes
- `Sources/ARORuntime/Actions/BuiltIn/ServerActions.swift` - Socket actions (`Start`, `Listen`, `Connect`, `Broadcast`, `Close`)
- `Sources/ARORuntime/Actions/BuiltIn/ResponseActions.swift` - `Send` action for socket data

Socket events are defined in:
- `Sources/ARORuntime/Sockets/SocketServer.swift` - `ClientConnectedEvent`, `ClientDisconnectedEvent`, `DataReceivedEvent`, etc.
- `Sources/ARORuntime/Events/EventTypes.swift` - Event type definitions

Example:
- `Examples/EchoSocket/` - Complete echo server example

See also `Documentation/LanguageGuide/Sockets.md` for comprehensive documentation.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 1.1 | 2024-12 | Implemented with SwiftNIO, added Connect/Broadcast/Close actions |
