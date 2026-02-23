# Terminal UI Examples

These examples demonstrate ARO's Terminal UI system (ARO-0052) with reactive Watch patterns.

## Examples

### SimpleMenu
**Purpose**: Basic terminal output with ANSI styling
**Demonstrates**: Template filters for colored/styled output

```bash
aro run Examples/TerminalUI/SimpleMenu
```

Shows how to use terminal capabilities in templates and display formatted task lists.

### TaskManager
**Purpose**: Reactive UI updates via Repository Observer pattern
**Demonstrates**: `(Dashboard Watch: task-repository Observer)`

```bash
aro run Examples/TerminalUI/TaskManager
```

The Dashboard Watch handler triggers automatically whenever tasks are stored/updated/deleted in the repository. This creates a reactive terminal UI that updates immediately when data changes.

**Key Pattern**:
- Store data in repository
- Watch handler detects changes
- UI re-renders automatically

### SystemMonitor
**Purpose**: Reactive UI updates via Event-based Watch pattern
**Demonstrates**: `(Dashboard Watch: MetricsUpdated Handler)`

```bash
aro run Examples/TerminalUI/SystemMonitor
```

The Dashboard Watch handler triggers when MetricsUpdated events are emitted. This demonstrates event-driven terminal UIs that respond to domain events.

**Key Pattern**:
- Emit domain event
- Watch handler catches event
- UI updates reactively

## Watch Pattern

The Watch pattern is a **feature set pattern** (not an action) that combines with Handler/Observer patterns for reactive terminal UIs:

### Event-Based Watch
```aro
(Dashboard Watch: EventType Handler) {
    (* Triggered when EventType events are emitted *)
    Clear the <screen> for the <terminal>.
    Transform the <output> from the <template: dashboard.screen>.
    Log <output> to the <console>.
    Return an <OK: status>.
}
```

### Repository-Based Watch
```aro
(Dashboard Watch: repository-name Observer) {
    (* Triggered when repository data changes *)
    Retrieve the <data> from the <repository-name>.
    Transform the <output> from the <template: view.screen>.
    Log <output> to the <console>.
    Return an <OK: status>.
}
```

## Terminal Features

### Template Filters
- **Colors**: `{{ <text> | color: "red" }}`, `{{ <text> | bg: "blue" }}`
- **Styles**: `{{ <text> | bold }}`, `{{ <text> | italic }}`, `{{ <text> | underline }}`

### Terminal Object
Access terminal capabilities in templates:
```aro
{{ <terminal: rows> }}
{{ <terminal: columns> }}
{{ <terminal: supports_color> }}
```

### Terminal Actions
- **Clear**: `Clear the <screen> for the <terminal>.`
- **Prompt**: `Prompt the <input: hidden> from the <terminal>.`
- **Select**: `Select the <choice> from <options> from the <terminal>.`

## Architecture

**Purely Reactive**:
- No polling or timers
- Watch handlers trigger only on events/changes
- Leverages ARO's event-driven architecture (ARO-0007)

**Thread-Safe**:
- TerminalService is a Swift actor
- All operations are async and isolated
- Safe concurrent access from multiple feature sets

**Graceful Degradation**:
- Detects terminal capabilities at runtime
- Falls back to ASCII when Unicode unavailable
- RGB → 256-color → 16-color fallback

## See Also

- **ARO-0052**: Terminal UI Proposal
- **ARO-0007**: Event-Driven Architecture
- **ARO-0050**: Template Engine
- **Chapter 41**: Terminal UI (The Language Guide)
