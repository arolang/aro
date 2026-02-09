# ARO-0048: WebSocket Support

* Proposal: ARO-0048
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0004, ARO-0005, ARO-0007, ARO-0008

## Abstract

This proposal adds WebSocket support to ARO, enabling real-time bidirectional communication between HTTP clients and ARO applications. WebSocket connections are established via HTTP Upgrade on the existing HTTP server port, providing a seamless integration with contract-first HTTP APIs.

## Introduction

WebSocket enables persistent, full-duplex communication channels over a single TCP connection. Unlike traditional HTTP request-response cycles, WebSocket allows servers to push data to clients without polling. This is essential for:

1. **Real-time updates**: Live dashboards, notifications, status changes
2. **Collaborative features**: Multi-user editing, chat applications
3. **Event streaming**: Log tailing, sensor data, market feeds

### Architecture Overview

```
+------------------------------------------------------------------+
|                        ARO Application                            |
+------------------------------------------------------------------+
                               |
           +-------------------+-------------------+
           |                   |                   |
           v                   v                   v
+------------------+  +------------------+  +------------------+
|   HTTP Server    |  | WebSocket Server |  | Socket Server    |
|   (Port 8080)    |  | (HTTP Upgrade)   |  | (TCP Port)       |
+------------------+  +------------------+  +------------------+
           |                   |                   |
           v                   v                   v
+----------------------------------------------------------+
|                        EventBus                           |
|  http.request  |  websocket.*      |  socket.*           |
+----------------------------------------------------------+
```

WebSocket shares the HTTP port via HTTP Upgrade mechanism:

```
HTTP Client                            ARO Application
    |                                        |
    |  GET /ws HTTP/1.1                     |
    |  Upgrade: websocket                   |
    |  Connection: Upgrade                  |
    |  Sec-WebSocket-Key: ...               |
    |--------------------------------------->|
    |                                        |
    |  HTTP/1.1 101 Switching Protocols     |
    |  Upgrade: websocket                   |
    |  Connection: Upgrade                  |
    |  Sec-WebSocket-Accept: ...            |
    |<---------------------------------------|
    |                                        |
    |  <-- WebSocket frames (bidirectional) |
    |                                        |
```

---

## 1. WebSocket Events

WebSocket lifecycle is managed through three events, published to the EventBus.

### 1.1 Event Types

| Event | eventType | Triggered When |
|-------|-----------|----------------|
| `WebSocketConnectedEvent` | `websocket.connected` | Client completes WebSocket handshake |
| `WebSocketMessageEvent` | `websocket.message` | Client sends a text message |
| `WebSocketDisconnectedEvent` | `websocket.disconnected` | Connection closes (client or server) |

### 1.2 Event Properties

**WebSocketConnectedEvent**:
| Property | Type | Description |
|----------|------|-------------|
| `connectionId` | String | Unique identifier for this connection |
| `path` | String | WebSocket path (e.g., "/ws") |
| `remoteAddress` | String | Client IP address |
| `timestamp` | Date | Connection timestamp |

**WebSocketMessageEvent**:
| Property | Type | Description |
|----------|------|-------------|
| `connectionId` | String | Connection that sent the message |
| `message` | String | Text message content |
| `timestamp` | Date | Message timestamp |

**WebSocketDisconnectedEvent**:
| Property | Type | Description |
|----------|------|-------------|
| `connectionId` | String | Connection that closed |
| `reason` | String | Close reason (if provided) |
| `timestamp` | Date | Disconnection timestamp |

---

## 2. WebSocket Event Handlers

Feature sets handle WebSocket events using the `WebSocket Event Handler` business activity pattern.

### 2.1 Handler Pattern

```aro
(Handler Name: WebSocket Event Handler)
```

The handler name determines which event type triggers it:
- Contains "Connect" → `WebSocketConnectedEvent`
- Contains "Message" → `WebSocketMessageEvent`
- Contains "Disconnect" → `WebSocketDisconnectedEvent`

### 2.2 Connection Handler

```aro
(Handle WebSocket Connect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Extract> the <path> from the <event: path>.
    <Log> "WebSocket connected: " to the <console>.
    <Log> <connection-id> to the <console>.
    <Return> an <OK: status> for the <connection>.
}
```

### 2.3 Message Handler

```aro
(Handle WebSocket Message: WebSocket Event Handler) {
    <Extract> the <message> from the <event: message>.
    <Extract> the <connection-id> from the <event: connectionId>.

    (* Process the message *)
    <Log> "Received: " to the <console>.
    <Log> <message> to the <console>.

    (* Optionally respond to sender *)
    <Send> <response> to the <websocket-connection: connectionId>.

    <Return> an <OK: status> for the <message>.
}
```

### 2.4 Disconnection Handler

```aro
(Handle WebSocket Disconnect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Extract> the <reason> from the <event: reason>.
    <Log> "WebSocket disconnected" to the <console>.
    <Return> an <OK: status> for the <disconnection>.
}
```

---

## 3. WebSocket Actions

WebSocket integrates with existing ARO actions through context-aware dispatch.

### 3.1 Broadcast Action

Send a message to all connected WebSocket clients:

```aro
<Broadcast> the <message> to the <websocket>.
```

The runtime detects the `websocket` target and dispatches to the WebSocket server service.

### 3.2 Send Action

Send a message to a specific WebSocket connection:

```aro
<Send> the <message> to the <websocket-connection: connectionId>.
```

Or using the connection object from an event:

```aro
<Extract> the <connection> from the <event: connection>.
<Send> the <response> to the <connection>.
```

### 3.3 Close Action

Close a specific WebSocket connection:

```aro
<Close> the <websocket-connection: connectionId>.
```

---

## 4. System Objects

WebSocket adds two context-specific system objects.

### 4.1 websocket-connection

Available in WebSocket event handlers. Represents the current connection.

| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Connection identifier |
| `remoteAddress` | String | Client IP address |
| `path` | String | WebSocket path |

Usage:
```aro
<Extract> the <id> from the <websocket-connection: id>.
<Send> the <message> to the <websocket-connection>.
```

### 4.2 websocket-message

Available in message handlers. Represents the received message.

| Property | Type | Description |
|----------|------|-------------|
| `text` | String | Message content |
| `connectionId` | String | Sender connection ID |
| `timestamp` | Date | Message timestamp |

Usage:
```aro
<Extract> the <content> from the <websocket-message: text>.
```

---

## 5. WebSocket Path Configuration

WebSocket connections are accepted on a configurable path (default: `/ws`).

### 5.1 Default Path

By default, the WebSocket server accepts upgrades on `/ws`:

```javascript
const ws = new WebSocket('ws://localhost:8080/ws');
```

### 5.2 Multiple Paths

Future extension: Support multiple WebSocket endpoints with different handlers:

```aro
(* Not in initial implementation *)
<Configure> the <websocket: path> with "/notifications".
```

---

## 6. Complete Example

A real-time status board application demonstrating WebSocket:

### 6.1 Application Structure

```
StatusBoard/
├── openapi.yaml
├── main.aro
├── api.aro
├── websocket.aro
└── templates/
    └── index.html
```

### 6.2 main.aro

```aro
(Application-Start: Status Board) {
    <Log> "Starting Status Board..." to the <console>.
    <Start> the <http-server> with {}.
    <Log> "Server ready on http://localhost:8080" to the <console>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Shutting down..." to the <console>.
    <Stop> the <http-server> with <application>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### 6.3 api.aro

```aro
(homePage: Status Board API) {
    <Transform> the <html> from the <template: index.html>.
    <Return> an <OK: status> with <html>.
}

(postStatus: Status Board API) {
    <Extract> the <status-text> from the <request: body status>.
    <Create> the <status> with {
        id: <generated-id>,
        text: <status-text>,
        createdAt: now
    }.
    <Store> the <status> into the <status-repository>.

    (* Broadcast to all WebSocket clients *)
    <Broadcast> the <status> to the <websocket>.

    <Return> a <Created: status> with <status>.
}

(getStatuses: Status Board API) {
    <Retrieve> the <statuses> from the <status-repository>.
    <Return> an <OK: status> with <statuses>.
}
```

### 6.4 websocket.aro

```aro
(Handle WebSocket Connect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Log> "Client connected: " to the <console>.
    <Log> <connection-id> to the <console>.
    <Return> an <OK: status> for the <connection>.
}

(Handle WebSocket Disconnect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Log> "Client disconnected: " to the <console>.
    <Log> <connection-id> to the <console>.
    <Return> an <OK: status> for the <disconnection>.
}
```

### 6.5 Client JavaScript

```javascript
// Connect to WebSocket
const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const ws = new WebSocket(`${protocol}//${location.host}/ws`);

ws.onopen = () => console.log('Connected');

ws.onmessage = (event) => {
    const status = JSON.parse(event.data);
    displayStatus(status);
};

ws.onclose = () => {
    console.log('Disconnected, reconnecting...');
    setTimeout(connect, 3000);
};
```

---

## 7. Implementation Notes

### 7.1 SwiftNIO Integration

WebSocket is implemented using SwiftNIO's WebSocket support:

```swift
import NIOWebSocket

// HTTP Upgrade detection in HTTPHandler
if isWebSocketUpgrade(head) {
    let upgrader = NIOWebSocketServerUpgrader(
        shouldUpgrade: { channel, head in
            channel.eventLoop.makeSucceededFuture([:])
        },
        upgradePipelineHandler: { channel, head in
            channel.pipeline.addHandler(WebSocketHandler(...))
        }
    )
}
```

### 7.2 Connection Management

WebSocket connections are tracked by `WebSocketConnectionManager`:

```swift
actor WebSocketConnectionManager {
    private var connections: [String: WebSocketChannel] = [:]

    func add(_ channel: WebSocketChannel, id: String)
    func remove(_ id: String)
    func send(message: String, to id: String) async throws
    func broadcast(message: String) async
}
```

### 7.3 Frame Handling

The WebSocket handler processes different frame types:

| Frame Type | Handling |
|------------|----------|
| `.text` | Emit `WebSocketMessageEvent` |
| `.binary` | Convert to string, emit event |
| `.ping` | Respond with `.pong` |
| `.pong` | Ignore (keep-alive) |
| `.close` | Emit `WebSocketDisconnectedEvent`, close channel |

### 7.4 Service Protocol

```swift
public protocol WebSocketServerService: Sendable {
    var connectionCount: Int { get async }
    func isEnabled() -> Bool
    func send(message: String, to connectionId: String) async throws
    func broadcast(message: String) async throws
    func close(_ connectionId: String) async throws
}
```

---

## 8. Comparison with TCP Sockets

| Feature | WebSocket | TCP Socket |
|---------|-----------|------------|
| Protocol | WebSocket (RFC 6455) | Raw TCP |
| Port | HTTP port via Upgrade | Dedicated port |
| Framing | Message-based | Stream-based |
| Browser support | Native WebSocket API | Not supported |
| Use case | Web real-time apps | Backend services |
| Handler pattern | `WebSocket Event Handler` | `Socket Event Handler` |
| Events | `websocket.*` | `socket.*` |

---

## 9. Future Extensions

### 9.1 Binary Messages

Support for binary WebSocket frames:

```aro
(Handle WebSocket Binary: WebSocket Event Handler) {
    <Extract> the <data> from the <event: binary>.
    (* Process binary data *)
}
```

### 9.2 Subprotocols

WebSocket subprotocol negotiation:

```aro
<Configure> the <websocket> with { protocols: ["chat", "json"] }.
```

### 9.3 Per-Path Handlers

Different handlers for different WebSocket paths:

```aro
(Handle Chat Message: WebSocket Event Handler /chat) { ... }
(Handle Notifications: WebSocket Event Handler /notifications) { ... }
```

---

## 10. Grammar

### 10.1 WebSocket Handler

```
websocket-handler = "(" handler-name ":" "WebSocket Event Handler" ")" block
handler-name      = identifier
```

### 10.2 WebSocket Actions

```
broadcast-websocket = "<Broadcast>" article result "to" article "<websocket>" "."
send-websocket      = "<Send>" article result "to" article "<websocket-connection" ":" connection-id ">" "."
close-websocket     = "<Close>" article "<websocket-connection" ":" connection-id ">" "."
```

---

## References

- [RFC 6455: The WebSocket Protocol](https://tools.ietf.org/html/rfc6455)
- [SwiftNIO WebSocket](https://github.com/apple/swift-nio/tree/main/Sources/NIOWebSocket)
- ARO-0007: Events and Reactive Patterns
- ARO-0008: I/O Services (Section 6: Socket Communication)
