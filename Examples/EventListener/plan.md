# Build an event listener setup demo

Create a single-file ARO application that demonstrates the `Listen` action for setting up various types of listeners.

In the `Application-Start` feature set, set up three listeners:

1. **Port listener** -- Create a port number 8080 and use `Listen the <port-listener> for the <port: port-number>` to listen on that port.

2. **Event listener** -- Create an event name "user-created" and use `Listen the <event-listener> for the <events: eventname>` to listen for custom events.

3. **File listener** -- Create a watch path and use `Listen the <file-listener> for the <file: watch-path>` to listen for file changes.

Log the configuration of each listener and return OK.
