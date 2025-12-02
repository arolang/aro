# Getting Started with ARO

This guide walks you through installing ARO and creating your first application.

## Installation

### Prerequisites

- macOS 13.0+ or Linux
- Swift 6.0 or later

### Building from Source

```bash
# Clone the repository
git clone https://github.com/KrisSimon/aro.git
cd aro-parser

# Build the project
swift build -c release

# The aro command is now available
.build/release/aro --help
```

### Installing the CLI

```bash
# Install to /usr/local/bin
sudo cp .build/release/aro /usr/local/bin/

# Verify installation
aro --version
```

## Your First ARO Application

### Step 1: Create a Project Directory

ARO applications are directories containing `.aro` source files:

```bash
mkdir HelloWorld
cd HelloWorld
```

### Step 2: Create the Main File

Create a file named `main.aro`:

```aro
(* HelloWorld/main.aro *)
(* A simple ARO application *)

(Application-Start: Hello World) {
    <Log> the <greeting: message> for the <console> with "Hello, World!".
    <Log> the <info: message> for the <console> with "Welcome to ARO!".
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> the <farewell: message> for the <console> with "Goodbye, World!".
    <Return> an <OK: status> for the <shutdown>.
}
```

### Step 3: Run Your Application

```bash
aro run ./HelloWorld
```

Output:
```
Hello, World!
Welcome to ARO!
^C
Goodbye, World!
```

Press `Ctrl+C` to trigger graceful shutdown.

## Understanding the Code

Let's break down what we wrote:

### Comments

```aro
(* This is a comment *)
```

ARO uses `(* ... *)` for comments, similar to Pascal or ML.

### Feature Sets

```aro
(Application-Start: Hello World) {
    ...
}
```

A **feature set** is defined with a name and business activity:
- `Application-Start` is the feature set name
- `Hello World` is the business activity description
- The curly braces contain the statements

### Statements

```aro
<Log> the <greeting: message> for the <console> with "Hello, World!".
```

ARO statements follow the **Action-Result-Object** pattern:
- `<Log>` is the **action** (verb)
- `<greeting: message>` is the **result** (what we're creating/using)
- `<console>` is the **object** (where/what we're acting on)
- `"Hello, World!"` is additional data

Every statement ends with a period (`.`).

### Return Statement

```aro
<Return> an <OK: status> for the <startup>.
```

Feature sets should return a status indicating success or failure.

## Creating a Web Server

Let's create a more interesting application - a simple HTTP server:

### Directory Structure

```
WebServer/
├── main.aro
└── routes.aro
```

### main.aro

```aro
(Application-Start: Web Server) {
    <Log> the <startup: message> for the <console> with "Starting web server...".
    <Start> the <http-server> on port 8080.
    <Log> the <ready: message> for the <console> with "Server running at http://localhost:8080".

    (* Keep the application running to process HTTP requests *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Stopping web server...".
    <Stop> the <http-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### routes.aro

```aro
(* HTTP route handlers *)

(GET /: Home Page) {
    <Create> the <response> with { message: "Welcome to ARO!" }.
    <Return> an <OK: status> with <response>.
}

(GET /hello/{name}: Greeting) {
    <Extract> the <name> from the <request: parameters>.
    <Create> the <response> with { message: "Hello, ${name}!" }.
    <Return> an <OK: status> with <response>.
}

(GET /health: Health Check) {
    <Create> the <status> with { healthy: true, uptime: <server: uptime> }.
    <Return> an <OK: status> with <status>.
}
```

### Run the Server

```bash
aro run ./WebServer
```

Note: The server uses the `<Keepalive>` action to stay running until interrupted.

Test it:
```bash
curl http://localhost:8080/
curl http://localhost:8080/hello/ARO
curl http://localhost:8080/health
```

## CLI Commands

ARO provides several commands:

### Run an Application

```bash
aro run ./MyApp              # Run and exit when done
# For servers, use <Keepalive> action in your code to keep running
```

### Compile Without Running

```bash
aro compile ./MyApp          # Compile and check for errors
```

### Quick Syntax Check

```bash
aro check ./MyApp            # Fast syntax validation
```

## Project Structure Best Practices

### Organize by Feature

```
MyApp/
├── main.aro           # Application-Start and Application-End
├── users.aro          # User-related feature sets
├── orders.aro         # Order-related feature sets
├── notifications.aro  # Notification handlers
└── events.aro         # Domain event handlers
```

### Naming Conventions

- **Files**: Use lowercase with descriptive names (`users.aro`, `orders.aro`)
- **Feature Sets**: Use descriptive names matching business terminology
- **Variables**: Use hyphenated lowercase (`user-data`, `order-total`)

## Next Steps

Now that you've created your first ARO applications:

1. **[A Tour of ARO](LanguageTour.md)** - Comprehensive language overview
2. **[The Basics](LanguageGuide/TheBasics.md)** - Deep dive into syntax
3. **[Events](LanguageGuide/Events.md)** - Event-driven programming
4. **[HTTP Services](LanguageGuide/HTTPServices.md)** - Building web APIs

## Troubleshooting

### "No entry point defined"

Every ARO application needs exactly one `Application-Start` feature set.

### "Multiple entry points found"

You have `Application-Start` in multiple files. Remove duplicates.

### "No source files found"

Make sure your directory contains `.aro` files (not `.txt` or other extensions).

### Syntax Errors

Run `aro check ./MyApp` for detailed error messages with line numbers.
