# Build an application lifecycle demo with shutdown handlers

Create an ARO application that demonstrates both `Application-End` handlers. The `main.aro` file should contain:

- `Application-Start` -- Log "Application started successfully", use Keepalive to keep the application running for events (so SIGINT triggers graceful shutdown), and return OK.

- `Application-End: Success` -- Log "Graceful shutdown complete" and return OK. This handler runs when the application is terminated normally (e.g., via SIGINT/Ctrl+C).

- `Application-End: Error` -- Extract the error from `<shutdown: error>`, log "Error shutdown triggered", and return OK. This handler runs when the application terminates due to an unhandled error.
