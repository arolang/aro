# ARO-0052: Terminal UI System

* Proposal: ARO-0052
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0004, ARO-0005, ARO-0007, ARO-0050

## Abstract

This proposal defines ARO's Terminal UI system for building beautiful, interactive terminal applications. The system provides ANSI escape code rendering, terminal capability detection, template filters for styling, and a reactive **Watch pattern** for live-updating displays. Watch is a **feature set pattern** (not an action) that combines with Handler/Observer patterns to trigger UI re-renders when events occur or data changes. The implementation is purely event-driven with no polling or timers.

## 1. Introduction

Terminal user interfaces remain relevant for CLI tools, system monitors, dashboards, and developer utilities. ARO's Terminal UI system integrates seamlessly with the language's template engine and event-driven architecture:

1. **Terminal Service**: Actor-based capability detection and ANSI rendering
2. **Template Filters**: Color and style filters for formatted output
3. **Terminal Magic Object**: Access terminal properties in templates
4. **Reactive Watch Pattern**: Event-driven UI updates without polling
5. **Interactive Actions**: Prompt, Select, Clear for user interaction
6. **Thread-Safe Operations**: All terminal access is isolated via Swift actors
7. **Graceful Degradation**: Automatic fallback for limited terminals

### Architecture Overview

```
+------------------+     +------------------+     +------------------+
| Feature Set      | --> | Watch Pattern    | --> | Event/Repo      |
| Watch Handler    |     | Registration     |     | Trigger          |
+------------------+     +------------------+     +------------------+
        |                        |                        |
        v                        v                        v
+------------------+     +------------------+     +------------------+
| Render Template  | --> | Apply Filters    | --> | ANSI Renderer    |
| with data        |     | (color, bold)    |     | Escape Codes     |
+------------------+     +------------------+     +------------------+
                                                          |
                         +------------------+             |
                         | Terminal Output  | <-----------+
                         | (stdout)         |
                         +------------------+
```

## 2. Terminal Service

### 2.1 Architecture

The `TerminalService` is a Swift actor providing thread-safe terminal operations:

```swift
public actor TerminalService: Sendable {
    private var capabilities: Capabilities?

    public func detectCapabilities() -> Capabilities
    public func render(text: String)
    public func clear()
    public func clearLine()
    public func moveCursor(row: Int, column: Int)
    public func prompt(message: String, hidden: Bool) async -> String
    public func select(options: [String], message: String, multiSelect: Bool) async -> [String]
}
```

### 2.2 Capability Detection

The system detects terminal capabilities at runtime:

**Unix/Linux/macOS**:
- Dimensions via `ioctl(STDOUT_FILENO, TIOCGWINSZ)`
- Fallback to `LINES`/`COLUMNS` environment variables
- Default: 80×24 if detection fails

**Color Support**:
- Basic: `TERM` variable (xterm-color, xterm-256color, etc.)
- True Color: `COLORTERM=truecolor` or `COLORTERM=24bit`
- Windows Terminal: `WT_SESSION` environment variable

**TTY Detection**:
- Unix: `isatty(STDOUT_FILENO)`
- Windows: Check `WT_SESSION` or `PROMPT` variables

### 2.3 Capabilities Structure

```swift
public struct Capabilities: Sendable {
    public let rows: Int              // Terminal height
    public let columns: Int           // Terminal width
    public let supportsColor: Bool    // 16-color support
    public let supportsTrueColor: Bool // 24-bit RGB support
    public let supportsUnicode: Bool  // UTF-8 support
    public let isTTY: Bool           // Connected to terminal
    public let encoding: String      // Character encoding (UTF-8)
}
```

## 3. Template Extensions

### 3.1 Terminal Filters

Templates can apply ANSI styling using filters:

**Color Filters**:
```aro
{{ <text> | color: "red" }}
{{ <text> | bg: "blue" }}
{{ <error> | color: "red" | bold }}
```

**Style Filters**:
```aro
{{ <title> | bold }}
{{ <subtitle> | dim }}
{{ <link> | underline }}
{{ <code> | italic }}
{{ <deleted> | strikethrough }}
```

**Chaining Filters**:
```aro
{{ <message> | color: "green" | bold | underline }}
```

### 3.2 Supported Colors

**Named Colors (16-color)**:
- Standard: black, red, green, yellow, blue, magenta, cyan, white
- Bright: brightRed, brightGreen, brightBlue, brightCyan, etc.
- Semantic: success (green), error (red), warning (yellow), info (blue)

**RGB Colors (24-bit)**:
```aro
{{ <text> | color: "rgb(255, 100, 50)" }}
{{ <box> | bg: "rgb(30, 30, 30)" }}
```

**Automatic Fallback**:
- True color terminals: Use 24-bit RGB
- 256-color terminals: Convert RGB → closest 256-color
- 16-color terminals: Convert RGB → closest 16-color
- No color support: Strip all color codes

### 3.3 Terminal Magic Object

Templates have access to a `terminal` object with capability information:

```aro
{{ <terminal: rows> }}           (* Terminal height *)
{{ <terminal: columns> }}        (* Terminal width *)
{{ <terminal: width> }}          (* Alias for columns *)
{{ <terminal: height> }}         (* Alias for rows *)
{{ <terminal: supports_color> }} (* Boolean: color support *)
{{ <terminal: supports_true_color> }} (* Boolean: RGB support *)
{{ <terminal: is_tty> }}         (* Boolean: connected to TTY *)
{{ <terminal: encoding> }}       (* String: UTF-8, ASCII, etc. *)
```

**Example: Responsive Design**:
```aro
{{when <terminal: columns> > 120}}
  {{ "Wide layout" }}
{{else}}
  {{ "Narrow layout" }}
{{end}}
```

## 4. Reactive Watch Pattern

### 4.1 Watch as Feature Set Pattern

**Watch is NOT an action** - it's a **feature set pattern** that combines with Handler/Observer patterns to create reactive terminal UIs.

**Syntax Patterns**:
1. **Event-Based**: `(Name Watch: EventType Handler)`
2. **Repository-Based**: `(Name Watch: repository Observer)`

### 4.2 Event-Based Watch

Watch handlers trigger when specific domain events are emitted:

```aro
(* Application emits event *)
(Application-Start: System Monitor) {
    Create the <metrics> with { cpu: 45, memory: 67, disk: 89 }.
    Emit a <MetricsUpdated: event> with <metrics>.

    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Watch handler catches event and re-renders *)
(Dashboard Watch: MetricsUpdated Handler) {
    Clear the <screen> for the <terminal>.

    (* Render updated dashboard *)
    Transform the <output> from the <template: monitor.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}
```

**Flow**:
1. Feature set emits `MetricsUpdated` event
2. `ExecutionEngine.registerWatchHandlers()` detects Watch pattern
3. Watch handler registered to EventBus for MetricsUpdated
4. When event emitted, handler executes asynchronously
5. Template rendered with fresh data
6. Output displayed to terminal

### 4.3 Repository-Based Watch

Watch handlers trigger when repository data changes:

```aro
(* Store task in repository *)
(Add Task: Task API) {
    Create the <task> with { title: "Write docs", status: "pending" }.
    Store the <task> into the <task-repository>.

    Return an <OK: status> for the <creation>.
}

(* Watch handler detects repository change *)
(Dashboard Watch: task-repository Observer) {
    Clear the <screen> for the <terminal>.

    (* Retrieve updated tasks *)
    Retrieve the <tasks> from the <task-repository>.

    (* Render task list *)
    Transform the <output> from the <template: task-list.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}
```

**Flow**:
1. Feature set stores/updates/deletes data in repository
2. `RepositoryChangedEvent` emitted by repository
3. Watch handler registered to EventBus for repository-name
4. When repository changes, handler executes
5. Fresh data retrieved and rendered
6. Updated display shown to user

### 4.4 Implementation

**ExecutionEngine Registration**:
```swift
private func registerWatchHandlers(for program: AnalyzedProgram, baseContext: RuntimeContext) {
    let watchHandlers = program.featureSets.filter { analyzedFS in
        analyzedFS.featureSet.businessActivity.contains(" Watch:")
    }

    for analyzedFS in watchHandlers {
        let activity = analyzedFS.featureSet.businessActivity

        if pattern.hasSuffix(" Handler") {
            // Event-based watch
            let eventType = extractEventType(from: pattern)
            eventBus.subscribe(to: DomainEvent.self) { event in
                guard event.domainEventType == eventType else { return }
                await self.executeWatchHandler(analyzedFS, event: event)
            }
        } else if pattern.hasSuffix(" Observer") {
            // Repository-based watch
            let repositoryName = extractRepositoryName(from: pattern)
            eventBus.subscribe(to: RepositoryChangedEvent.self) { event in
                guard event.repositoryName == repositoryName else { return }
                await self.executeWatchHandler(analyzedFS, event: event)
            }
        }
    }
}
```

**Key Characteristics**:
- **Purely Reactive**: No polling, no timers, no intervals
- **Event-Driven**: Uses ARO's EventBus (ARO-0007)
- **Asynchronous**: Handlers execute without blocking
- **Thread-Safe**: Leverages Swift actor isolation

### 4.5 Watch vs Traditional Approaches

**ARO Watch Pattern**:
```aro
(* Reactive - triggers on changes *)
(Dashboard Watch: task-repository Observer) {
    Retrieve the <tasks> from the <task-repository>.
    Transform the <view> from the <template: dashboard.screen>.
    Log <view> to the <console>.
    Return an <OK: status>.
}
```

**Traditional Polling (NOT in ARO)**:
```javascript
// Other languages - polling with timers
setInterval(() => {
    const tasks = getTasks();
    renderDashboard(tasks);
}, 1000);  // Check every second
```

ARO's approach is superior:
- ✅ Updates immediately on changes (not after delay)
- ✅ No wasted CPU cycles polling
- ✅ No timer management complexity
- ✅ Integrates with event-driven architecture

## 5. Terminal Actions

### 5.1 Clear Action

Clears the terminal screen or current line.

**Syntax**:
```aro
Clear the <screen> for the <terminal>.
Clear the <line> for the <terminal>.
```

**Implementation**:
- Verb: `clear`
- Role: `.own` (internal operation)
- Preposition: `.for`

**ANSI Codes**:
- Screen: `\u{001B}[2J\u{001B}[H` (clear + home)
- Line: `\u{001B}[2K`

### 5.2 Prompt Action

Prompts the user for text input.

**Syntax**:
```aro
Prompt the <name> from the <terminal>.
Prompt the <password: hidden> from the <terminal>.
```

**Implementation**:
- Verbs: `prompt`, `ask`
- Role: `.request` (external input)
- Prepositions: `.with`, `.from`
- Hidden Mode: Check for `hidden` in specifiers

**Hidden Input**:
- Unix: Uses `termios` to disable echo
- Restores terminal state after input
- Prints newline after hidden input

### 5.3 Select Action

Displays an interactive selection menu.

**Syntax**:
```aro
Create the <options> with ["Red", "Green", "Blue"].
Select the <choice> from <options> from the <terminal>.

(* Multi-select *)
Select the <choices: multi-select> from <options> from the <terminal>.
```

**Implementation**:
- Verbs: `select`, `choose`
- Role: `.request` (external selection)
- Prepositions: `.from`, `.with`
- Multi-Select: Check for `multi` in specifiers

**Current Implementation**:
- Numbered menu display
- User enters number
- Returns selected option(s)

**Future Enhancement**:
- Arrow key navigation
- Visual cursor
- Space to toggle (multi-select)

## 6. ANSI Renderer

### 6.1 Color Codes

**Foreground Colors**:
```swift
public enum TerminalColor: String {
    case black = "black"           // 30
    case red = "red"               // 31
    case green = "green"           // 32
    case yellow = "yellow"         // 33
    case blue = "blue"             // 34
    case magenta = "magenta"       // 35
    case cyan = "cyan"             // 36
    case white = "white"           // 37

    case brightRed = "brightRed"   // 91
    case brightGreen = "brightGreen" // 92
    // ...

    public var foregroundCode: Int { /* ... */ }
    public var backgroundCode: Int { foregroundCode + 10 }
}
```

**RGB Colors**:
```swift
// 24-bit true color
public static func colorRGB(r: Int, g: Int, b: Int, capabilities: Capabilities) -> String {
    if capabilities.supportsTrueColor {
        return "\u{001B}[38;2;\(r);\(g);\(b)m"
    } else {
        // Fallback to 256-color
        let colorIndex = closestColor256(r: r, g: g, b: b)
        return "\u{001B}[38;5;\(colorIndex)m"
    }
}
```

### 6.2 Style Codes

| Style | Code | Reset |
|-------|------|-------|
| Bold | `\u{001B}[1m` | `\u{001B}[0m` |
| Dim | `\u{001B}[2m` | `\u{001B}[0m` |
| Italic | `\u{001B}[3m` | `\u{001B}[0m` |
| Underline | `\u{001B}[4m` | `\u{001B}[0m` |
| Blink | `\u{001B}[5m` | `\u{001B}[0m` |
| Reverse | `\u{001B}[7m` | `\u{001B}[0m` |
| Strikethrough | `\u{001B}[9m` | `\u{001B}[0m` |

### 6.3 Cursor Control

```swift
public static func moveCursor(row: Int, column: Int) -> String {
    return "\u{001B}[\(row);\(column)H"
}

public static func hideCursor() -> String {
    return "\u{001B}[?25l"
}

public static func showCursor() -> String {
    return "\u{001B}[?25h"
}

public static func cursorUp(_ n: Int = 1) -> String {
    return "\u{001B}[\(n)A"
}
```

### 6.4 Screen Control

```swift
public static func clearScreen() -> String {
    return "\u{001B}[2J\u{001B}[H"  // Clear + move to home
}

public static func clearLine() -> String {
    return "\u{001B}[2K"
}

public static func alternateScreen() -> String {
    return "\u{001B}[?1049h"  // Switch to alternate buffer
}

public static func mainScreen() -> String {
    return "\u{001B}[?1049l"  // Restore main buffer
}
```

## 7. Platform Support

### 7.1 Full Support

**macOS**:
- ✅ Full ANSI support (iTerm2, Terminal.app)
- ✅ True color support (iTerm2)
- ✅ `ioctl()` dimension detection
- ✅ `termios` for hidden input

**Linux**:
- ✅ Full ANSI support (GNOME Terminal, Konsole, etc.)
- ✅ True color support (modern terminals)
- ✅ `ioctl()` dimension detection
- ✅ `termios` for hidden input

### 7.2 Partial Support

**Windows**:
- ⚠️ Windows Terminal: Full support
- ⚠️ CMD/PowerShell: Limited ANSI support (Windows 10+)
- ⚠️ Dimension detection via environment variables only
- ⚠️ Hidden input: Falls back to regular input (TODO)

### 7.3 Graceful Degradation

**No Color Support**:
- All color codes stripped
- Styles (bold, underline) may still work
- Text remains readable

**No TTY**:
- Capability detection returns safe defaults
- Interactive actions may fail (return empty/default)
- Templates render without ANSI codes

**ASCII-Only Terminals**:
- Unicode box-drawing → ASCII equivalents
- Smart characters (arrows, bullets) → ASCII fallbacks

## 8. Complete Examples

### 8.1 Task Manager (Repository Observer)

**main.aro**:
```aro
(Application-Start: Task Manager) {
    (* Initialize tasks *)
    Create the <task1> with { id: 1, title: "Write docs", status: "pending" }.
    Create the <task2> with { id: 2, title: "Fix bugs", status: "in-progress" }.

    Store the <task1> into the <task-repository>.
    Store the <task2> into the <task-repository>.

    Log "Task Manager started. Tasks tracked reactively." to the <console>.

    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Reactive UI - triggers on repository changes *)
(Dashboard Watch: task-repository Observer) {
    Clear the <screen> for the <terminal>.

    Retrieve the <tasks> from the <task-repository>.
    Transform the <output> from the <template: templates/task-list.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Add new task - triggers repository change *)
(Add Task: TaskAdded Handler) {
    Extract the <title> from the <event: title>.

    Create the <new-task> with { title: <title>, status: "pending" }.
    Store the <new-task> into the <task-repository>.

    Return an <OK: status> for the <task-creation>.
}
```

**templates/task-list.screen**:
```aro
{{ "=== Task Manager ===" | bold | color: "cyan" }}

Terminal: {{ <terminal: columns> }} columns × {{ <terminal: rows> }} rows

{{ "Tasks:" | bold }}

{{for task in tasks}}
  [{{ <task: id> }}] {{ <task: title> | color: "white" }} - {{ <task: status> | color: "yellow" }}
{{end}}

{{ "---" }}
Total: {{ <tasks> | length }} tasks
```

### 8.2 System Monitor (Event-Based)

**main.aro**:
```aro
(Application-Start: System Monitor) {
    Log "System Monitor starting..." to the <console>.

    (* Emit initial metrics *)
    Create the <metrics> with { cpu: 23, memory: 45, disk: 67 }.
    Emit a <MetricsUpdated: event> with <metrics>.

    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Reactive UI - triggers on metrics events *)
(Dashboard Watch: MetricsUpdated Handler) {
    Clear the <screen> for the <terminal>.

    Transform the <output> from the <template: templates/monitor.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Collect metrics periodically (could be triggered by timer event) *)
(Collect Metrics: MetricsTimer Handler) {
    (* Read actual system metrics here *)
    Create the <new-metrics> with { cpu: 45, memory: 67, disk: 89 }.
    Emit a <MetricsUpdated: event> with <new-metrics>.

    Return an <OK: status> for the <collection>.
}
```

**templates/monitor.screen**:
```aro
{{ "=== System Monitor ===" | bold | color: "green" }}

{{ "CPU Usage:" | bold }}
  {{ <cpu> }}% {{ "[" ++ "=" * (<cpu> / 5) ++ " " * (20 - <cpu> / 5) ++ "]" | color: "cyan" }}

{{ "Memory Usage:" | bold }}
  {{ <memory> }}% {{ "[" ++ "=" * (<memory> / 5) ++ " " * (20 - <memory> / 5) ++ "]" | color: "yellow" }}

{{ "Disk Usage:" | bold }}
  {{ <disk> }}% {{ "[" ++ "=" * (<disk> / 5) ++ " " * (20 - <disk> / 5) ++ "]" | color: "magenta" }}

{{ "---" }}
{{ "Press Ctrl+C to exit" | dim }}
```

## 9. Best Practices

### 9.1 Responsive Design

Check terminal dimensions for layout decisions:

```aro
{{when <terminal: columns> > 120}}
  (* Wide layout - show detailed view *)
  Transform the <view> from the <template: wide-dashboard.screen>.
{{when <terminal: columns> > 80}}
  (* Medium layout - show summary *)
  Transform the <view> from the <template: medium-dashboard.screen>.
{{else}}
  (* Narrow layout - show compact view *)
  Transform the <view> from the <template: narrow-dashboard.screen>.
{{end}}
```

### 9.2 Graceful Degradation

Check capabilities before using advanced features:

```aro
{{when <terminal: supports_color>}}
  {{ <error> | color: "red" | bold }}
{{else}}
  ERROR: {{ <error> }}
{{end}}
```

### 9.3 Efficient Re-Rendering

Only clear and re-render when necessary:

```aro
(Dashboard Watch: data-repository Observer) {
    (* Clear before re-render for clean display *)
    Clear the <screen> for the <terminal>.

    Retrieve the <data> from the <data-repository>.
    Transform the <view> from the <template: dashboard.screen>.
    Log <view> to the <console>.

    Return an <OK: status>.
}
```

### 9.4 Event Throttling

For high-frequency updates, consider throttling:

```aro
(* In a real application, you might want to throttle events *)
(* This prevents overwhelming the terminal with rapid updates *)
(High Frequency Handler: RapidUpdates Handler) {
    (* Only re-render if enough time has passed *)
    (* Implementation would check timestamp *)

    Return an <OK: status>.
}
```

## 10. Implementation Notes

### 10.1 Thread Safety

All terminal operations are thread-safe via Swift actors:

```swift
public actor TerminalService: Sendable {
    // All methods are automatically serialized
    // Multiple feature sets can call concurrently
    // Actor ensures sequential execution
}
```

### 10.2 Service Registration

TerminalService is registered in Application.swift:

```swift
#if !os(Windows)
if isatty(STDOUT_FILENO) != 0 {
    let terminalService = TerminalService()
    await runtime.register(service: terminalService)
}
#else
if ProcessInfo.processInfo.environment["WT_SESSION"] != nil {
    let terminalService = TerminalService()
    await runtime.register(service: terminalService)
}
#endif
```

### 10.3 Template Executor Integration

TemplateExecutor injects terminal object and applies filters:

```swift
// Inject terminal object
if let terminalService = context.service(TerminalService.self) {
    let capabilities = await terminalService.detectCapabilities()
    let terminalObject: [String: any Sendable] = [
        "rows": capabilities.rows,
        "columns": capabilities.columns,
        "supports_color": capabilities.supportsColor,
        // ...
    ]
    templateContext.bind("terminal", value: terminalObject)
}

// Apply filters
case "color":
    if let colorName = filter.arg {
        let caps = await getTerminalCapabilities(from: context)
        result = ANSIRenderer.color(colorName, capabilities: caps) + result + ANSIRenderer.reset()
    }
```

## 11. Future Enhancements

### 11.1 Advanced Input Handling

- Arrow key navigation for Select action
- Inline editing with cursor movement
- Tab completion
- Input validation

### 11.2 Layout Widgets

Optional widget actions for advanced layouts:

```aro
(* Box widget with borders *)
Box the <content> with { width: 50, border: "rounded", title: "Status" }.

(* Progress bar *)
Progress the <status> with { value: 0.75, width: 40, label: "Loading" }.

(* Table rendering *)
Table the <data> with { headers: <headers>, columns: <columns> }.
```

### 11.3 Mouse Events

Support for mouse interactions:

```aro
(Handle Click: Mouse Event Handler) {
    Extract the <x> from the <event: x>.
    Extract the <y> from the <event: y>.

    (* Process click at (x, y) *)

    Return an <OK: status>.
}
```

### 11.4 Alternative Screen Buffer

Proper full-screen TUI applications:

```aro
(Application-Start: Full Screen App) {
    (* Switch to alternate buffer *)
    Enable the <alternate-screen> for the <terminal>.

    Keepalive the <application> for the <events>.
    Return an <OK: status>.
}

(Application-End: Success) {
    (* Restore main buffer *)
    Disable the <alternate-screen> for the <terminal>.
    Return an <OK: status>.
}
```

## 12. Performance Optimization

For production terminal UIs with frequent updates (dashboards, monitors, progress indicators), ARO provides a **shadow buffer** optimization system detailed in **ARO-0053: Terminal Shadow Buffer Optimization**.

### Key Optimizations

1. **Double Buffering**: Maintains current and previous screen states
2. **Dirty Region Tracking**: Only renders cells that changed
3. **Cell-Level Diffing**: Compares buffers before emitting ANSI codes
4. **Batch Rendering**: Collects updates for optimal cursor movement
5. **Terminal State Tracking**: Avoids redundant style changes

### Performance Benefits

| Scenario | Without Buffer | With Shadow Buffer | Improvement |
|----------|----------------|-------------------|-------------|
| Metrics update (10 cells) | 1920 ops | 10 ops | **192× faster** |
| Task list (200 cells) | 1920 ops | 200 ops | **9.6× faster** |
| Progress bar (80 cells) | 1920 ops | 80 ops | **24× faster** |

The shadow buffer is automatically enabled for TTY terminals and integrates transparently with the Watch pattern - no syntax changes required.

**See**: ARO-0053 for complete implementation details and benchmarks.

## 13. Related Proposals

- **ARO-0001**: Language fundamentals (actions, feature sets)
- **ARO-0002**: Control flow (when guards, iteration)
- **ARO-0004**: Action semantics and roles
- **ARO-0005**: Application architecture and lifecycle
- **ARO-0007**: Event-driven architecture (EventBus, observers)
- **ARO-0050**: Template engine (rendering, filters, inclusion)
- **ARO-0053**: Terminal shadow buffer optimization

## 14. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02-22 | Initial proposal with reactive Watch pattern |
| 1.1 | 2026-02-23 | Added ARO-0053 shadow buffer optimization reference |

## 15. Summary

ARO's Terminal UI system provides a complete, reactive solution for building beautiful terminal applications. The Watch pattern eliminates polling by leveraging the event-driven architecture, creating responsive UIs that update immediately when data changes. Integration with the template engine allows declarative styling with automatic capability detection and graceful degradation. All operations are thread-safe via Swift actors, making concurrent terminal access safe and predictable.

**Key Innovations**:
1. **Reactive Watch Pattern**: Event-driven UI updates without polling
2. **Template Integration**: Styling via filters, capability-aware rendering
3. **Thread-Safe Design**: Actor-based isolation for concurrent access
4. **Platform Adaptability**: Automatic fallback for limited terminals
5. **Natural Syntax**: Combines seamlessly with ARO's action-based paradigm
