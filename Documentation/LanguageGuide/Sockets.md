# Sockets

ARO provides built-in TCP socket support for bidirectional real-time communication. This chapter covers socket servers and clients.

## Socket Server

### Starting a Server

Listen for TCP connections in Application-Start:

```aro
(Application-Start: Socket Server) {
    <Listen> on port 9000 as <socket-server>.
    <Log> the <message> for the <console> with "Socket server listening on port 9000".
    <Return> an <OK: status> for the <startup>.
}
```

### Connection Events

Socket servers emit events for connection lifecycle:

| Event | When Triggered |
|-------|----------------|
| `ClientConnected` | Client connects |
| `DataReceived` | Data received from client |
| `ClientDisconnected` | Client disconnects |

### Handling Connections

```aro
(Handle Connection: ClientConnected Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Extract> the <remote-address> from the <event: remoteAddress>.

    <Log> the <message> for the <console> with "Client connected: ${remote-address}".

    (* Send welcome message *)
    <Send> the <welcome> to the <event: connection> with "Welcome to the server!".

    <Return> an <OK: status> for the <connection>.
}
```

### Receiving Data

```aro
(Handle Data: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.
    <Extract> the <connection-id> from the <event: connectionId>.

    <Log> the <message> for the <console> with "Received from ${connection-id}: ${data}".

    (* Process the data *)
    <Process> the <response> from the <data>.

    (* Send response back *)
    <Send> the <response> to the <connection>.

    <Return> an <OK: status> for the <data>.
}
```

### Handling Disconnections

```aro
(Handle Disconnect: ClientDisconnected Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.
    <Extract> the <reason> from the <event: reason>.

    <Log> the <message> for the <console> with "Client ${connection-id} disconnected: ${reason}".

    (* Clean up client state *)
    <Delete> the <client-state> from the <client-registry> where id = <connection-id>.

    <Return> an <OK: status> for the <disconnect>.
}
```

## Socket Client

### Connecting to a Server

```aro
(Connect to Server: External Service) {
    <Connect> to <host: "192.168.1.100"> on port 8080 as <server-connection>.

    (* Send initial handshake *)
    <Send> the <handshake> to the <server-connection> with { type: "hello", client: "my-app" }.

    <Return> an <OK: status> for the <connection>.
}
```

### Sending Data

```aro
(Send Message: Messaging) {
    <Create> the <message> with {
        type: "chat",
        content: <content>,
        timestamp: <current-time>
    }.

    <Send> the <message: JSON> to the <server-connection>.

    <Return> an <OK: status> for the <send>.
}
```

### Receiving Responses

```aro
(Handle Server Response: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Parse> the <message: JSON> from the <data>.
    <Extract> the <type> from the <message: type>.

    match <type> {
        case "ack" {
            <Log> the <message> for the <console> with "Message acknowledged".
        }
        case "error" {
            <Extract> the <error> from the <message: error>.
            <Log> the <error: message> for the <console> with <error>.
        }
        case "data" {
            <Process> the <result> from the <message: payload>.
        }
    }

    <Return> an <OK: status> for the <response>.
}
```

## Common Patterns

### Echo Server

```aro
(Application-Start: Echo Server) {
    <Listen> on port 9000 as <echo-server>.
    <Log> the <message> for the <console> with "Echo server listening on port 9000".
    <Return> an <OK: status> for the <startup>.
}

(Echo Data: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.

    (* Echo back the received data *)
    <Send> the <data> to the <connection>.

    <Return> an <OK: status> for the <echo>.
}
```

### Chat Server

```aro
(Application-Start: Chat Server) {
    <Listen> on port 9000 as <chat-server>.
    <Create> the <clients> with [].
    <Publish> as <connected-clients> <clients>.
    <Return> an <OK: status> for the <startup>.
}

(Register Client: ClientConnected Handler) {
    <Extract> the <connection> from the <event: connection>.
    <Extract> the <connection-id> from the <event: connectionId>.

    (* Add to connected clients *)
    <Store> the <connection> into the <connected-clients> with id <connection-id>.

    (* Notify others *)
    <Broadcast> the <announcement> to the <chat-server> with "User joined".

    <Return> an <OK: status> for the <registration>.
}

(Broadcast Message: DataReceived Handler) {
    <Extract> the <message> from the <event: data>.
    <Extract> the <sender-id> from the <event: connectionId>.

    <Create> the <broadcast> with {
        from: <sender-id>,
        message: <message>,
        timestamp: <current-time>
    }.

    (* Send to all connected clients *)
    <Broadcast> the <broadcast: JSON> to the <chat-server>.

    <Return> an <OK: status> for the <broadcast>.
}

(Remove Client: ClientDisconnected Handler) {
    <Extract> the <connection-id> from the <event: connectionId>.

    (* Remove from connected clients *)
    <Delete> the <client> from the <connected-clients> where id = <connection-id>.

    (* Notify others *)
    <Broadcast> the <announcement> to the <chat-server> with "User left".

    <Return> an <OK: status> for the <removal>.
}
```

### Protocol Handler

```aro
(Handle Protocol: DataReceived Handler) {
    <Extract> the <raw-data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.

    (* Parse protocol message *)
    <Parse> the <message: JSON> from the <raw-data>.
    <Extract> the <type> from the <message: type>.
    <Extract> the <payload> from the <message: payload>.

    match <type> {
        case "ping" {
            <Send> the <pong> to the <connection> with { type: "pong" }.
        }
        case "auth" {
            <Validate> the <payload> for the <auth-schema>.
            if <validation> is success then {
                <Send> the <auth-success> to the <connection> with { type: "auth_ok" }.
            } else {
                <Send> the <auth-failed> to the <connection> with { type: "auth_fail" }.
            }
        }
        case "subscribe" {
            <Extract> the <channel> from the <payload: channel>.
            <Subscribe> the <connection> to the <channel>.
            <Send> the <subscribed> to the <connection> with { type: "subscribed", channel: <channel> }.
        }
        case "publish" {
            <Extract> the <channel> from the <payload: channel>.
            <Extract> the <data> from the <payload: data>.
            <Publish> the <data> to the <channel>.
        }
    }

    <Return> an <OK: status> for the <protocol>.
}
```

### Client Reconnection

```aro
(Application-Start: Resilient Client) {
    <Connect> to <host: "server.example.com"> on port 9000 as <server>.
    <Return> an <OK: status> for the <startup>.
}

(Handle Disconnect: ClientDisconnected Handler) {
    <Extract> the <reason> from the <event: reason>.
    <Log> the <message> for the <console> with "Disconnected: ${reason}. Reconnecting...".

    (* Wait before reconnecting *)
    <Wait> for 5 seconds.

    (* Attempt reconnection *)
    <Connect> to <host: "server.example.com"> on port 9000 as <server>.

    <Return> an <OK: status> for the <reconnect>.
}
```

## Data Formats

### Text Data

```aro
<Send> the <text> to the <connection> with "Hello, World!".
```

### JSON Data

```aro
<Create> the <message> with {
    type: "update",
    data: { value: 42 }
}.
<Send> the <message: JSON> to the <connection>.
```

### Binary Data

```aro
<Read> the <binary: bytes> from the <file: "./data.bin">.
<Send> the <binary> to the <connection>.
```

## Broadcasting

### To All Clients

```aro
<Broadcast> the <message> to the <socket-server>.
```

### To Specific Clients

```aro
(* Send to specific connection *)
<Send> the <message> to the <connection>.

(* Send to connection by ID *)
<Retrieve> the <client> from the <connected-clients> where id = <client-id>.
<Send> the <message> to the <client: connection>.
```

## Connection Management

### Tracking Connections

```aro
(Track Connection: ClientConnected Handler) {
    <Extract> the <connection> from the <event: connection>.
    <Extract> the <connection-id> from the <event: connectionId>.
    <Extract> the <remote-address> from the <event: remoteAddress>.

    <Create> the <client-info> with {
        id: <connection-id>,
        address: <remote-address>,
        connection: <connection>,
        connectedAt: <current-time>
    }.

    <Store> the <client-info> into the <client-registry>.

    <Return> an <OK: status> for the <tracking>.
}
```

### Closing Connections

```aro
(Kick Client: Admin Action) {
    <Extract> the <client-id> from the <request: parameters>.
    <Retrieve> the <client> from the <client-registry> where id = <client-id>.

    if <client> is not empty then {
        <Send> the <kick-notice> to the <client: connection> with "You have been disconnected".
        <Close> the <client: connection>.
        <Delete> the <client> from the <client-registry> where id = <client-id>.
    }

    <Return> an <OK: status> for the <kick>.
}
```

## Best Practices

### Handle Connection Errors

```aro
(Connect to Server: Client Setup) {
    <Connect> to <host: "server.example.com"> on port 9000 as <server>.

    if <server> is empty then {
        <Log> the <error> for the <console> with "Failed to connect to server".
        <Return> a <ServiceUnavailable: status> for the <connection: error>.
    }

    <Return> an <OK: status> for the <connection>.
}
```

### Validate Incoming Data

```aro
(Handle Data: DataReceived Handler) {
    <Extract> the <raw-data> from the <event: data>.

    (* Validate data format *)
    <Parse> the <message: JSON> from the <raw-data>.

    if <message> is empty then {
        <Log> the <warning> for the <console> with "Invalid message format".
        <Return> an <OK: status> for the <validation>.
    }

    <Validate> the <message> for the <message-schema>.

    if <validation> is failed then {
        <Send> the <error> to the <event: connection> with { error: "Invalid message" }.
        <Return> an <OK: status> for the <validation>.
    }

    (* Process valid message *)
    <Process> the <result> from the <message>.
    <Return> an <OK: status> for the <processing>.
}
```

### Clean Up on Shutdown

```aro
(Application-End: Success) {
    <Log> the <message> for the <console> with "Closing all connections...".

    (* Notify all clients *)
    <Broadcast> the <shutdown-notice> to the <socket-server> with "Server shutting down".

    (* Close server *)
    <Close> the <socket-server>.

    <Return> an <OK: status> for the <shutdown>.
}
```

## Next Steps

- [Events](Events.md) - Event-driven patterns
- [HTTP Services](HTTPServices.md) - HTTP communication
- [Application Lifecycle](ApplicationLifecycle.md) - Startup and shutdown
