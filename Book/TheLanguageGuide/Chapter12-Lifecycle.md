# Chapter 12: Application Lifecycle

*"Every program has a beginning, a middle, and an end."*

---

## 12.1 The Three Phases

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="120" viewBox="0 0 480 120" xmlns="http://www.w3.org/2000/svg">  <!-- Startup Phase -->  <rect x="20" y="35" width="120" height="50" rx="6" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="80" y="55" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="bold" fill="#1e40af">STARTUP</text>  <text x="80" y="72" text-anchor="middle" font-family="monospace" font-size="9" fill="#3b82f6">Application-Start</text>  <!-- Arrow 1 -->  <line x1="140" y1="60" x2="175" y2="60" stroke="#6b7280" stroke-width="2"/>  <polygon points="175,60 165,55 165,65" fill="#6b7280"/>  <!-- Execution Phase -->  <rect x="180" y="35" width="120" height="50" rx="6" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="240" y="55" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="bold" fill="#166534">EXECUTION</text>  <text x="240" y="72" text-anchor="middle" font-family="monospace" font-size="9" fill="#22c55e">Keepalive + Events</text>  <!-- Arrow 2 -->  <line x1="300" y1="60" x2="335" y2="60" stroke="#6b7280" stroke-width="2"/>  <polygon points="335,60 325,55 325,65" fill="#6b7280"/>  <!-- Shutdown Phase -->  <rect x="340" y="35" width="120" height="50" rx="6" fill="#fee2e2" stroke="#ef4444" stroke-width="2"/>  <text x="400" y="55" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="bold" fill="#991b1b">SHUTDOWN</text>  <text x="400" y="72" text-anchor="middle" font-family="monospace" font-size="9" fill="#ef4444">Application-End</text>  <!-- Phase labels -->  <text x="80" y="105" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Initialize</text>  <text x="240" y="105" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Process Events</text>  <text x="400" y="105" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Cleanup</text>  <!-- Top labels -->  <text x="80" y="22" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#9ca3af">required</text>  <text x="240" y="22" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#9ca3af">servers only</text>  <text x="400" y="22" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#9ca3af">optional</text></svg>
</div>

ARO applications have three distinct lifecycle phases: startup, execution, and shutdown. Each phase has specific responsibilities and corresponding feature sets that can handle them.

The startup phase initializes resources, establishes connections, and prepares the application to do work. This is when configuration is loaded, services are started, and the application transitions from inert code to a running system. Startup must complete successfully for the application to proceed.

The execution phase is where the application does its actual work. For batch applications, this might be a single sequence of operations. For servers and daemons, this is an ongoing process of handling events, requests, and other stimuli. The execution phase can last indefinitely for long-running applications.

The shutdown phase cleans up resources, closes connections, and prepares the application to terminate. This is when pending work is completed, buffers are flushed, and the application transitions from a running system back to inert code. Proper shutdown prevents resource leaks and data loss.

Each phase has a corresponding feature set that you can define to handle its responsibilities. The startup phase uses `Application-Start`, which is required. The shutdown phase uses `Application-End: Success` for normal shutdown and `Application-End: Error` for error shutdown, both of which are optional.

---

## 12.2 Application-Start

Every ARO application must have exactly one feature set named `Application-Start`. This is where execution begins. The runtime looks for this feature set when the application launches and executes it to initialize the application. Without an Application-Start feature set, there is nothing to execute, and the application cannot run.

Having multiple Application-Start feature sets is also an error. If you spread your application across multiple files and accidentally define Application-Start in more than one of them, the runtime reports the conflict and refuses to start. This constraint ensures that there is always exactly one unambiguous entry point.

The business activity (the text after the colon) can be anything descriptive of your application. Common choices include the application name, a description of its purpose, or simply "Application" or "Entry Point." This text has no semantic significance for Application-Start—it is purely documentation.

The startup feature set typically performs several initialization tasks. Loading configuration from files or environment variables is common. Starting services like HTTP servers, database connections, or file watchers is typical for server applications. Publishing values that other feature sets in the same business activity will need is another common task. Each of these tasks is expressed as statements in the feature set.

The startup feature set must return a status to indicate whether initialization succeeded. If any statement fails during startup, the runtime logs the error, invokes the error shutdown handler if one exists, and terminates the application with a non-zero exit code. A successful startup means the application is ready to do work.

---

## 12.3 The Keepalive Action

For applications that need to continue running after startup to process ongoing events indefinitely, the Keepalive action keeps the process alive. Without it, the runtime executes the startup feature set, reaches the return statement, and proceeds to the shutdown phase. This is correct for batch applications that do their work during startup (including those that emit events—`<Emit>` blocks until all downstream handlers complete), but servers and daemons need to stay running to accept new external events.

The Keepalive action blocks execution at the point where it appears. It allows the event loop to continue processing events—HTTP requests, file system changes, socket messages, timer events, and custom events—while the startup feature set waits. The application remains active, handling events as they arrive.

When the application receives a shutdown signal, either from the user pressing Ctrl+C (SIGINT) or from the operating system sending SIGTERM, the Keepalive action returns. Execution resumes from where it left off, and any statements after the Keepalive execute. Then the return statement completes the startup feature set, which triggers the shutdown phase.

Applications that do not use Keepalive execute their startup statements and then proceed to shutdown. This is appropriate for command-line tools that perform a specific task and exit, event-driven batch applications where `<Emit>` blocks until all work completes, data processing scripts that run to completion, or any application where continued execution is not needed. The absence of Keepalive does not indicate an error—it simply indicates that the application has no ongoing external events to wait for.

---

## 12.4 Application-End: Success

The success shutdown handler runs when the application terminates normally. This includes when the Application-Start feature set completes and returns, when the user sends a shutdown signal (Ctrl+C or SIGTERM), or when the application calls for shutdown programmatically. It is an opportunity to perform cleanup or final logging on every normal exit.

The handler is optional. If you do not define one, the application terminates without any cleanup phase. For simple applications that do not hold external resources, this is fine. For applications with database connections, open files, or other resources that should be closed properly, defining a success handler is important.

Typical cleanup tasks include stopping services so they stop accepting new work, draining any pending operations so they complete rather than being lost, closing database connections so they are returned to connection pools, flushing log buffers so no messages are lost, and performing any other resource release that should happen on shutdown.

The handler should be designed to complete reasonably quickly. Shutdown has a default timeout, and if the handler takes too long, the process is terminated forcibly. If you have long-running cleanup tasks, consider whether they can be shortened or made asynchronous.

The shutdown handler receives no special input—unlike error shutdown, there is no error context because nothing went wrong. It simply performs its cleanup and returns a status indicating that shutdown completed successfully.

---

## 12.5 Application-End: Error

The error shutdown handler runs when the application terminates due to an unhandled error. This means an exception occurred that was not caught by any handler, a fatal condition was detected, or some other error situation triggered abnormal termination.

Unlike success shutdown, error shutdown provides access to the error that caused the termination. You can extract this error from the shutdown context and use it for logging, alerting, or diagnostic purposes. The error contains information about what went wrong, where it happened, and any associated context.

The handler is optional, but defining one is strongly recommended for production applications. Without it, errors cause silent termination with no opportunity for cleanup or notification. With it, you can ensure that administrators are alerted, logs contain sufficient information for diagnosis, and resources are released even in error scenarios.

Cleanup during error shutdown should be defensive. Some resources might be in inconsistent states due to the error. Cleanup code should be prepared for failures and should continue even if some cleanup steps fail. The goal is best-effort cleanup, not guaranteed perfect cleanup.

The distinction between success and error shutdown allows you to handle these cases differently. Success shutdown might wait for pending work to complete. Error shutdown might skip that wait and proceed directly to resource release. Success shutdown might log a friendly goodbye message. Error shutdown might log a detailed error report.

---

## 12.6 Shutdown Signals

The operating system communicates with processes through signals. ARO handles the common shutdown signals appropriately.

SIGINT is sent when the user presses Ctrl+C in the terminal. ARO treats this as a request for graceful shutdown. The Keepalive action returns, and the success shutdown handler executes. This allows the user to stop a running application cleanly.

SIGTERM is the standard signal for requesting process termination. Process managers, container orchestrators, and system shutdown sequences typically send SIGTERM before escalating to forced termination. ARO handles SIGTERM the same as SIGINT—graceful shutdown with the success handler.

SIGKILL cannot be caught or handled. When a process receives SIGKILL, the operating system terminates it immediately. There is no opportunity for cleanup. This is the last resort for stopping a process that does not respond to SIGTERM. Applications should not rely on SIGKILL for normal operation—if your application requires SIGKILL to stop, something is wrong with its shutdown handling.

The shutdown process has a timeout. If the shutdown handlers do not complete within a reasonable time (typically 30 seconds), the process is terminated forcibly. This prevents hung shutdown handlers from keeping the process alive indefinitely. Design your handlers to complete quickly enough to finish before the timeout.

---

## 12.7 Startup Errors

If the Application-Start feature set fails, the application cannot proceed. The runtime logs the error with full context, invokes the error shutdown handler if one exists, and terminates the process with a non-zero exit code.

Common startup failures include configuration files that do not exist or contain invalid data, services that cannot be reached such as databases or external APIs, permissions that prevent the application from accessing needed resources, and port conflicts where a server cannot bind to its configured port.

The error messages for startup failures follow the same pattern as other ARO errors. They describe what the statement was trying to accomplish in business terms. "Cannot read the config from the file with config.json" tells you exactly what failed. The error includes additional context about why it failed—file not found, permission denied, or similar.

Designing for startup resilience involves validating assumptions early. If your application requires a configuration file, failing fast during startup is better than failing later when the configuration is first used. The startup feature set is the appropriate place to verify that all prerequisites are met.

---

## 12.8 Best Practices

Use Keepalive for server applications. If your application starts an HTTP server, file watcher, socket listener, or any other service that should run continuously and accept external events, the Keepalive action is necessary to keep the process alive. Batch applications that emit events and wait for their completion do not need Keepalive—`<Emit>` blocks until all downstream handlers finish.

Define both shutdown handlers for production applications. The success handler ensures clean shutdown during normal operation. The error handler ensures that error conditions are logged and resources are released even when things go wrong.

Log lifecycle events for operational visibility. Logging at startup provides confirmation that the application started successfully and with what configuration. Logging at shutdown helps diagnose whether shutdown completed cleanly. These logs are invaluable for debugging operational issues.

Clean up resources in reverse order of acquisition. If you start the database, then the cache, then the HTTP server during startup, stop the HTTP server, then the cache, then the database during shutdown. This order ensures that dependent resources are still available when cleanup needs them.

Keep shutdown handlers fast. Long shutdown times frustrate operators and can cause problems with process managers that expect quick termination. If you have work that takes a long time to complete, consider whether it can be deferred or done asynchronously rather than during shutdown.

---

*Next: Chapter 13 — Custom Events*
