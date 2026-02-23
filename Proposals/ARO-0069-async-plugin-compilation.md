# ARO-0069: Async Plugin Compilation

* Proposal: ARO-0069
* Author: ARO Language Team
* Status: **Proposed**
* Related Issues: GitLab #117

## Abstract

ARO plugins (especially Rust plugins) are currently compiled synchronously during application startup, blocking the main thread. This proposal introduces asynchronous plugin compilation to improve startup performance and user experience.

## Problem

Plugin compilation (e.g., `cargo build` for Rust plugins) happens synchronously:

```swift
// Current (blocking):
let plugin = try loadPlugin(config)  // Waits for cargo build
app.start()  // Can't start until plugin ready
```

Impact:
- 30+ second startup time for Rust plugins
- No feedback during compilation
- Application blocked until all plugins compile

## Solution

### Phase 1: Background Compilation

Make plugin compilation async and non-blocking:

```swift
// Proposed (non-blocking):
let pluginTask = Task {
    try await loadPluginAsync(config)
}
app.start()  // Starts immediately
// Actions using plugin wait if needed
```

### Phase 2: Lazy Action Registration

Actions using plugins wait for compilation:

```swift
ActionRegistry.shared.registerDynamic("parse-csv") { result, object, ctx in
    let plugin = try await PluginLoader.shared.awaitPlugin("csv-plugin")
    return try plugin.execute(action: "parse-csv", input: ...)
}
```

### Phase 3: Progress Events

Emit compilation progress for better UX:

```swift
eventBus.publish(PluginCompilationStarted(plugin: "csv-plugin"))
// During compilation...
eventBus.publish(PluginCompilationProgress(plugin: "csv-plugin", percent: 50))
// On completion...
eventBus.publish(PluginCompilationCompleted(plugin: "csv-plugin"))
```

## Benefits

1. **Faster startup**: Application starts before plugins finish compiling
2. **Parallel compilation**: Multiple plugins compile simultaneously
3. **Better UX**: Progress indication during compilation
4. **Graceful degradation**: Actions wait for plugins or fail with clear message

## Implementation

### PluginLoader Actor

```swift
public actor PluginLoader {
    private var compilationTasks: [String: Task<NativePluginHost, Error>] = [:]

    public func loadPluginAsync(_ config: PluginConfig) async throws {
        let task = Task { () -> NativePluginHost in
            return try await compileAndLoad(config)
        }
        compilationTasks[config.name] = task
    }

    public func awaitPlugin(_ name: String) async throws -> NativePluginHost {
        guard let task = compilationTasks[name] else {
            throw PluginError.notLoading(name)
        }
        return try await task.value
    }
}
```

### Async Compilation

```swift
private func compileRustPluginAsync(projectDir: URL) async throws -> URL {
    return try await withCheckedThrowingContinuation { continuation in
        Task.detached {
            do {
                let url = try self.compileRustPlugin(projectDir: projectDir)
                continuation.resume(returning: url)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

## Future Work

- Progress bars in CLI output
- Plugin precompilation cache
- Incremental compilation support

Fixes GitLab #117
