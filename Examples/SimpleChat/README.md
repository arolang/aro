# SimpleChat

A hybrid HTTP + WebSocket chat service demonstrating multi-protocol applications.

## What It Does

Runs both an HTTP server (port 8080) and a TCP socket server (port 9000). HTTP endpoints store and retrieve messages; socket clients receive real-time broadcasts when new messages are posted.

## Features Tested

- **Multi-protocol server** - HTTP and Socket in same application
- **Broadcast action** - `<Broadcast>` to all connected socket clients
- **Repository pattern** - `<Store>` and `<Retrieve>` with message repository
- **Socket event handlers** - Welcome messages on connect
- **HTTP+Socket integration** - HTTP POST triggers socket broadcast
- **Multi-file application** - Separate files for API and socket handlers

## Related Proposals

- [ARO-0022: HTTP Server](../../Proposals/ARO-0022-http-server.md)
- [ARO-0024: Socket Communication](../../Proposals/ARO-0024-socket-communication.md)
- [ARO-0027: Contract-First APIs](../../Proposals/ARO-0027-contract-first-api.md)

## Usage

```bash
# Start the server
aro run ./Examples/SimpleChat

# Connect a socket client (receives broadcasts)
nc localhost 9000

# Post a message via HTTP (broadcasts to socket clients)
curl -X POST http://localhost:8080/status \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello everyone!"}'
```

## Project Structure

```
SimpleChat/
├── main.aro        # Starts both HTTP and socket servers
├── api.aro         # HTTP handlers (getStatus, postStatus)
├── socket.aro      # Socket event handlers
└── openapi.yaml    # HTTP API contract
```

## Example Flow

```
1. Socket client connects → receives "Welcome to Simple Chat!"
2. HTTP POST /status with message
3. Message stored in repository
4. Message broadcast to all socket clients
5. HTTP GET /status returns last message
```

---

*Two protocols, one application. HTTP for commands, sockets for events. The architecture that makes real-time systems simple.*
