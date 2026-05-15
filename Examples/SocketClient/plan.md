# Build a TCP socket client

Create a single-file ARO application that connects to a TCP server, sends a message, and receives the echo response.

The `main.aro` file should contain:

- `Application-Start: Socket Client Demo` -- Log a connecting message, create a host variable "localhost", use `Connect the <conn> to the <host> with { port: 9001 }` to establish a connection. Create a message "Hello from ARO!" and `Send the <message> to the <conn>`. Use Keepalive to stay running and receive the echo response.

- `Handle Data Received: Socket Event Handler` -- Extract the response from `<packet: message>`, concatenate "Received: " with the response using the `++` operator, and log the result.
