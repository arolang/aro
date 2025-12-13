# EchoSocket

A TCP echo server demonstrating bidirectional socket communication.

## What It Does

Starts a TCP server on port 9000 that echoes back any data received from connected clients. Handles connection, data reception, and disconnection events through dedicated event handlers.

## Features Tested

- **Socket server** - `<Start>` action with `socket-server` on port
- **Socket event handlers** - `Socket Event Handler` business activity pattern
- **Connection events** - `Handle Client Connected`, `Handle Client Disconnected`
- **Data events** - `Handle Data Received` for incoming packets
- **Send action** - `<Send>` for writing to client connections
- **Keepalive** - Long-running application with event loop

## Related Proposals

- [ARO-0024: Socket Communication](../../Proposals/ARO-0024-socket-communication.md)
- [ARO-0028: Long-Running Applications](../../Proposals/ARO-0028-keepalive.md)

## Usage

```bash
# Start the server
aro run ./Examples/EchoSocket

# In another terminal, connect with netcat
nc localhost 9000
# Type anything and press Enter - it echoes back
```

## Example Output

```
Starting echo socket on port 9000
Socket server listening on port 9000
Client connected
Echoed data back to client
Client disconnected
```

---

*Raw TCP, no ceremony. Sometimes you just need a socket and something listening on the other end.*
