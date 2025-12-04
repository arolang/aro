# Getting Started with ARO

This guide walks you through installing ARO and creating your first application.

## Installation

### Prerequisites

- macOS 13.0+ or Linux
- Swift 6.0 or later

### Building from Source

```bash
git clone https://github.com/KrisSimon/aro.git
cd aro
swift build -c release
sudo cp .build/release/aro /usr/local/bin/
```

## Your First ARO Application

### Step 1: Create a Project Directory

```bash
mkdir HelloWorld
cd HelloWorld
```

### Step 2: Create main.aro

```aro
(Application-Start: Hello World) {
    <Log> the <greeting: message> for the <console> with "Hello, World!".
    <Return> an <OK: status> for the <startup>.
}
```

### Step 3: Run Your Application

```bash
aro run ./HelloWorld
```

## Creating a Web API

ARO uses contract-first HTTP development. Define routes in `openapi.yaml`:

### Directory Structure

```
HelloAPI/
├── openapi.yaml      # Required: Defines HTTP routes
├── main.aro          # Application lifecycle
└── handlers.aro      # Feature sets matching operationIds
```

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Hello API
  version: 1.0.0

paths:
  /hello:
    get:
      operationId: sayHello
      responses:
        '200':
          description: Success
```

### main.aro

```aro
(Application-Start: Hello API) {
    <Log> the <startup: message> for the <console> with "Hello API starting...".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### handlers.aro

```aro
(sayHello: Hello API) {
    <Create> the <response> with { message: "Hello, World!" }.
    <Return> an <OK: status> with <response>.
}
```

## CLI Commands

```bash
aro run ./MyApp       # Run the application
aro check ./MyApp     # Syntax validation
aro build ./MyApp     # Compile to native binary
```

## Next Steps

- [A Tour of ARO](language-tour.html)
- [HTTP Services](guide/httpservices.html)
- [Events](guide/events.html)
