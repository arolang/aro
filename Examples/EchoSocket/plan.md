# Build a TCP echo socket server

Create a single-file ARO application that runs a TCP socket server which echoes received data back to clients.

The `main.aro` file should contain:

- `Application-Start: Echo Socket` -- Log a startup message, start the socket server with `{ port: 9000 }`, log that it's listening, use Keepalive, and return OK.

- `Handle Client Connected: Socket Event Handler` -- Extract `<client-id>` from `<connection: id>` and `<remote-address>` from `<connection: remoteAddress>`. Log "Client connected".

- `Handle Data Received: Socket Event Handler` -- Extract `<received-data>` from `<packet: buffer>` and `<client>` from `<packet: connection>`. Send the received data back to the client using `Send the <received-data> to the <client>`. Log "Echoed data back to client".

- `Handle Client Disconnected: Socket Event Handler` -- Extract the client id from the event and log "Client disconnected".
