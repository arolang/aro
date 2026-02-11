# Greeting Plugin Example

This example demonstrates how to install and use a Git-based Swift plugin.

## Plugin Used

- **plugin-swift-hello**: A Swift plugin that provides greeting functionality
  - Repository: https://github.com/arolang/plugin-swift-hello

## Actions Provided

| Action | Description | Input |
|--------|-------------|-------|
| `greet` | Generate a personalized greeting | `{ name: "..." }` |
| `farewell` | Generate a goodbye message | `{ name: "..." }` |

## Installation

Install the plugin using the ARO package manager:

```bash
cd Examples/GreetingPlugin
aro add https://github.com/arolang/plugin-swift-hello.git
```

Or the plugin will be installed automatically based on `aro.yaml` when you run:

```bash
aro run ./Examples/GreetingPlugin
```

## Expected Output

```
=== Greeting Plugin Demo ===

Hello, ARO Developer!
Goodbye, ARO Developer! See you soon!

Plugin demo completed!
```
