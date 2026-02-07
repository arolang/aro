# Chapter 39: WebSockets

ARO provides built-in WebSocket support for real-time bidirectional communication. WebSocket connections are established via HTTP Upgrade on the same port as the HTTP server, making it easy to add real-time features to web applications.

## Why WebSockets?

Unlike traditional HTTP request-response cycles, WebSocket enables:

- **Real-time updates**: Push data to clients without polling
- **Bidirectional communication**: Both server and client can initiate messages
- **Low latency**: Persistent connection eliminates handshake overhead

## Architecture

WebSocket shares the HTTP server port via the HTTP Upgrade mechanism:

```
Browser                           ARO Application
   |                                    |
   |  GET /ws HTTP/1.1                 |
   |  Upgrade: websocket               |
   |  Connection: Upgrade              |
   |----------------------------------->|
   |                                    |
   |  HTTP/1.1 101 Switching Protocols |
   |<-----------------------------------|
   |                                    |
   |  <-- WebSocket frames -->         |
   |                                    |
```

## WebSocket Events

WebSocket lifecycle is managed through three event types:

| Event | Handler Name Contains | Triggered When |
|-------|----------------------|----------------|
| Connect | "Connect" | Client completes WebSocket handshake |
| Message | "Message" | Client sends a text message |
| Disconnect | "Disconnect" | Connection closes |

## Event Handlers

Handle WebSocket events using the `WebSocket Event Handler` business activity pattern:

```aro
(Handler Name: WebSocket Event Handler)
```

### Connection Handler

```aro
(Handle WebSocket Connect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: id>.
    <Log> "WebSocket client connected" to the <console>.
    <Return> an <OK: status> for the <connection>.
}
```

The `event` object contains:

| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Unique connection identifier |
| `path` | String | WebSocket path (e.g., "/ws") |
| `remoteAddress` | String | Client IP address |

### Message Handler

```aro
(Handle WebSocket Message: WebSocket Event Handler) {
    <Extract> the <message> from the <event: message>.
    <Extract> the <connection-id> from the <event: connectionId>.
    <Log> "Received: " to the <console>.
    <Log> <message> to the <console>.
    <Return> an <OK: status> for the <message>.
}
```

The `event` object contains:

| Property | Type | Description |
|----------|------|-------------|
| `message` | String | Text message content |
| `connectionId` | String | Sender's connection ID |

### Disconnection Handler

```aro
(Handle WebSocket Disconnect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Log> "WebSocket client disconnected" to the <console>.
    <Return> an <OK: status> for the <disconnection>.
}
```

The `event` object contains:

| Property | Type | Description |
|----------|------|-------------|
| `connectionId` | String | Connection that closed |
| `reason` | String | Close reason (if provided) |

## Sending Messages

### Broadcast to All Clients

Send a message to all connected WebSocket clients:

```aro
<Broadcast> the <message> to the <websocket>.
```

This is commonly used when new data should be pushed to all clients, such as a new chat message or status update.

### Send to Specific Client

Send a message to a single connection (future extension):

```aro
<Send> the <message> to the <websocket-connection: connectionId>.
```

## Complete Example: Web Chat

A real-time chat application demonstrating WebSocket integration.

### Project Structure

```
WebChat/
├── openapi.yaml
├── main.aro
├── api.aro
├── websocket.aro
└── templates/
    └── index.html
```

### main.aro

```aro
(Application-Start: Web Chat) {
    <Log> "Starting Web Chat..." to the <console>.
    <Start> the <http-server> with {}.
    <Log> "Server ready on http://localhost:8080" to the <console>.
    <Log> "WebSocket available on ws://localhost:8080/ws" to the <console>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Web Chat shutting down..." to the <console>.
    <Stop> the <http-server> with {}.
    <Return> an <OK: status> for the <shutdown>.
}
```

### api.aro

```aro
(homePage: Web Chat API) {
    <Transform> the <html> from the <template: index.html>.
    <Return> an <OK: status> with <html>.
}

(getMessages: Web Chat API) {
    <Retrieve> the <all-messages> from the <message-repository>.
    <Return> an <OK: status> with <all-messages>.
}

(postMessage: Web Chat API) {
    <Extract> the <body> from the <request: body>.
    <Extract> the <message-text: message> from the <body>.
    <Create> the <message: Message> with {
        message: <message-text>,
        createdAt: <now>
    }.
    <Store> the <message> into the <message-repository>.

    (* Broadcast to all WebSocket clients *)
    <Broadcast> the <message> to the <websocket>.

    <Return> a <Created: status> with <message>.
}
```

### websocket.aro

```aro
(Handle WebSocket Connect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: id>.
    <Log> "WebSocket client connected" to the <console>.
    <Return> an <OK: status> for the <connection>.
}

(Handle WebSocket Disconnect: WebSocket Event Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Log> "WebSocket client disconnected" to the <console>.
    <Return> an <OK: status> for the <disconnection>.
}
```

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Web Chat API
  version: 1.0.0

paths:
  /home:
    get:
      operationId: homePage
      summary: Serve the chat interface
      responses:
        '200':
          description: HTML page

  /messages:
    get:
      operationId: getMessages
      summary: Get all messages
      responses:
        '200':
          description: List of messages
    post:
      operationId: postMessage
      summary: Post a new message
      responses:
        '201':
          description: Message created
```

### Client JavaScript

```javascript
// Connect to WebSocket
const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const ws = new WebSocket(`${protocol}//${location.host}/ws`);

ws.onopen = () => {
    console.log('Connected');
    document.getElementById('status').textContent = 'Connected';
};

ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    displayMessage(message);
};

ws.onclose = () => {
    console.log('Disconnected');
    document.getElementById('status').textContent = 'Disconnected';
    // Reconnect after 3 seconds
    setTimeout(connect, 3000);
};

// Post message via HTTP, receive via WebSocket
async function postMessage(text) {
    await fetch('/messages', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: 'message=' + encodeURIComponent(text)
    });
}
```

## WebSocket Path

By default, WebSocket connections are accepted on `/ws`:

```javascript
const ws = new WebSocket('ws://localhost:8080/ws');
```

## Comparison with TCP Sockets

| Feature | WebSocket | TCP Socket |
|---------|-----------|------------|
| Protocol | WebSocket (RFC 6455) | Raw TCP |
| Port | HTTP port via Upgrade | Dedicated port |
| Browser support | Native WebSocket API | Not supported |
| Use case | Web real-time apps | Backend services |
| Handler pattern | `WebSocket Event Handler` | `Socket Event Handler` |

## Implementation Notes

- WebSocket uses SwiftNIO's WebSocket support
- Connections are automatically managed by the runtime
- JSON messages are automatically serialized when broadcasting
- Available on macOS and Linux (not Windows)

---

*Next: Appendix A — Action Reference*
