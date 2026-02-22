# ARO-0052: Terminal UI System

**Status:** Draft
**Author:** ARO Team
**Created:** 2026-02-22

## Abstract

This proposal introduces the `terminal` system object and template-based terminal UI capabilities, enabling developers to build beautiful, responsive terminal applications using ARO's natural language syntax. The system provides direct access to terminal properties, ANSI styling, layout helpers, and interactive widgets—all designed to work seamlessly with ARO's template engine.

## Motivation

Terminal applications remain essential for developers, system administrators, and CLI tools. Modern terminal UI libraries like [ratatui](https://ratatui.rs), Rich (Python), and Blessed (Node.js) demonstrate the demand for sophisticated terminal interfaces. However, these libraries often require deep understanding of low-level ANSI escape codes or complex widget APIs.

ARO can bring its natural language philosophy to terminal UIs: instead of learning escape sequences or widget hierarchies, developers should simply describe what they want to display using templates.

**Design Goals:**
1. **Template-First**: Terminal UIs defined in `.screen` template files
2. **Responsive**: Automatically adapt to terminal dimensions
3. **Declarative**: Describe appearance, not ANSI codes
4. **Zero Boilerplate**: No manual cursor management or buffer handling
5. **ARO-Native**: Feels like natural ARO code, not a foreign API

## The `terminal` System Object

The `terminal` object provides runtime access to terminal capabilities and state:

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `rows` | Number | Terminal height in character rows |
| `columns` | Number | Terminal width in character columns |
| `width` | Number | Alias for `columns` |
| `height` | Number | Alias for `rows` |
| `supports_color` | Boolean | True if terminal supports 8/16 colors |
| `supports_true_color` | Boolean | True if terminal supports 24-bit RGB |
| `cursor_row` | Number | Current cursor row (1-indexed) |
| `cursor_column` | Number | Current cursor column (1-indexed) |
| `is_tty` | Boolean | True if output is a terminal (not piped) |
| `encoding` | String | Terminal encoding (e.g., "UTF-8") |

### Usage in Templates

```aro
(* prompt.screen - A responsive terminal prompt *)
{{ for 0..<terminal.columns }}={{ endfor }}
{{ terminal.rows }} rows × {{ terminal.columns }} columns
{{ if terminal.supports_true_color }}
  {{ color rgb(100, 200, 255) }}✓ True color supported{{ reset }}
{{ endif }}
```

## Template Styling Syntax

ARO templates gain new directives for terminal styling:

### Color Directives

```aro
{{ color <name> }}        (* Named colors: red, green, blue, yellow, etc. *)
{{ color rgb(r, g, b) }}  (* RGB colors (0-255) if terminal supports *)
{{ bg <name> }}           (* Background color *)
{{ bg rgb(r, g, b) }}     (* RGB background *)
{{ reset }}               (* Reset all styling *)
```

**Named Colors:**
- Basic: `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`
- Bright: `bright-red`, `bright-green`, `bright-blue`, etc.
- Semantic: `success` (green), `error` (red), `warning` (yellow), `info` (blue)

### Text Style Directives

```aro
{{ bold }}                (* Bold text *)
{{ dim }}                 (* Dimmed text *)
{{ italic }}              (* Italic text *)
{{ underline }}           (* Underlined text *)
{{ strikethrough }}       (* Strikethrough text *)
{{ blink }}               (* Blinking text (if supported) *)
{{ reverse }}             (* Reverse foreground/background *)
{{ reset }}               (* Reset all styles *)
```

### Cursor Control

```aro
{{ cursor.move row col }} (* Move cursor to position *)
{{ cursor.up n }}         (* Move cursor up n rows *)
{{ cursor.down n }}       (* Move cursor down n rows *)
{{ cursor.left n }}       (* Move cursor left n columns *)
{{ cursor.right n }}      (* Move cursor right n columns *)
{{ cursor.save }}         (* Save cursor position *)
{{ cursor.restore }}      (* Restore saved position *)
{{ cursor.hide }}         (* Hide cursor *)
{{ cursor.show }}         (* Show cursor *)
```

### Screen Control

```aro
{{ screen.clear }}        (* Clear entire screen *)
{{ screen.clear-line }}   (* Clear current line *)
{{ screen.clear-up }}     (* Clear from cursor up *)
{{ screen.clear-down }}   (* Clear from cursor down *)
{{ screen.alternate }}    (* Switch to alternate buffer *)
{{ screen.main }}         (* Switch to main buffer *)
```

## Layout Widgets

ARO provides declarative layout widgets for common UI patterns:

### Box Widget

```aro
{{ box width=50 height=10 border="rounded" title="Status" }}
  Content inside the box
  {{ color green }}✓{{ reset }} Everything is working
{{ endbox }}
```

**Box Attributes:**
- `width`: Fixed width or "100%" for full terminal width
- `height`: Fixed height or "auto"
- `border`: "single", "double", "rounded", "thick", "none"
- `padding`: Space inside border (0-5)
- `align`: "left", "center", "right"
- `title`: Optional title text
- `color`: Border color
- `bg`: Background color

### Progress Bar Widget

```aro
{{ progress value=completed total=total width=40 }}
{{ progress value=0.75 width=30 label="Loading..." }}
```

**Progress Attributes:**
- `value`: Current value (0-1 for percentage or absolute count)
- `total`: Total value (if using absolute)
- `width`: Bar width in characters
- `label`: Optional label text
- `color`: Bar color (defaults to green)
- `show_percent`: Show percentage (default: true)
- `style`: "bar", "blocks", "dots", "arrow"

### Table Widget

```aro
{{ table headers=["Name", "Status", "Count"] widths=[20, 15, 10] }}
  {{ for row in data }}
    {{ row }}{{ row.name }}{{ endrow }}
    {{ row }}{{ row.status }}{{ endrow }}
    {{ row }}{{ row.count }}{{ endrow }}
  {{ endfor }}
{{ endtable }}
```

**Table Attributes:**
- `headers`: Array of column headers
- `widths`: Array of column widths or "auto"
- `border`: Border style (same as box)
- `align`: Column alignment array ["left", "center", "right"]
- `zebra`: Alternate row colors (boolean)

### Spinner Widget

```aro
{{ spinner style="dots" label="Processing..." }}
```

**Spinner Styles:**
- `dots`: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏
- `line`: - \ | /
- `arrow`: ← ↖ ↑ ↗ → ↘ ↓ ↙
- `bounce`: ⠁ ⠂ ⠄ ⠂
- `clock`: 🕐 🕑 🕒 🕓 🕔 🕕

### Panel Layout

```aro
{{ panel orientation="horizontal" }}
  {{ section width="50%" }}
    Left panel content
  {{ endsection }}

  {{ section width="50%" }}
    Right panel content
  {{ endsection }}
{{ endpanel }}
```

**Panel Attributes:**
- `orientation`: "horizontal" or "vertical"
- `sections`: Auto-sized or fixed width/height

## Responsive Design

Templates automatically adapt to terminal size using the `terminal` object:

```aro
(* Responsive header that fills terminal width *)
{{ for 0..<terminal.columns }}={{ endfor }}

(* Conditional layout based on size *)
{{ if terminal.columns >= 80 }}
  {{ panel orientation="horizontal" }}
    (* Two-column layout for wide terminals *)
  {{ endpanel }}
{{ else }}
  (* Single column for narrow terminals *)
{{ endif }}

(* Center content *)
{{ for 0..<(terminal.columns - 40) / 2 }} {{ endfor }}
Welcome to ARO
```

## Actions for Terminal Control

### Render Action

The `Render` action (from ARO-0050) is extended to support terminal output:

```aro
(Display Dashboard: Dashboard) {
    Retrieve the <metrics> from the <metrics-repository>.

    (* Render to terminal with live updates *)
    Render the <dashboard> from "dashboard.screen"
           with <metrics>
           to the <terminal>.

    Return an <OK: status> for the <display>.
}
```

### Watch Action

New action for live-updating terminal displays:

```aro
(Monitor System: System Monitor) {
    (* Clear screen and hide cursor *)
    Clear the <screen> for the <terminal>.

    (* Render template every 1 second *)
    Watch the <status> from "status.screen"
          with <system-metrics>
          every 1 second
          to the <terminal>.

    Return an <OK: status> for the <monitoring>.
}
```

**Watch Action Behavior:**
- Renders template repeatedly at specified interval
- Automatically clears screen before each render
- Updates in alternate buffer (preserves terminal history)
- Stops on SIGINT (Ctrl+C)

### Prompt Action

Interactive user input with styled prompts:

```aro
(Get User Input: CLI) {
    (* Simple text prompt *)
    Prompt the <name> with "Enter your name: " from the <terminal>.

    (* Password prompt (hidden input) *)
    Prompt the <password> with "Password: "
           hidden
           from the <terminal>.

    (* Confirm prompt (yes/no) *)
    Prompt the <confirmed> with "Continue? (y/n): "
           as a <confirmation>
           from the <terminal>.

    Return an <OK: status> with <name>.
}
```

**Prompt Qualifiers:**
- `hidden`: Don't echo input (for passwords)
- `confirmation`: Accept yes/no/y/n input, return boolean
- `default`: Default value if user presses Enter

### Select Action

Interactive selection menus:

```aro
(Choose Option: CLI) {
    Create the <options> with ["Start Server", "Run Tests", "Exit"].

    Select the <choice> from <options>
           with "What would you like to do?"
           from the <terminal>.

    When <choice> equals "Start Server" {
        (* Start server *)
    }.

    Return an <OK: status> with <choice>.
}
```

**Select Action Features:**
- Arrow key navigation
- Multi-select mode (space to toggle)
- Search/filter mode
- Vim-style keybindings (j/k navigation)

## Example: Interactive Task Manager

```aro
(* task-list.screen *)
{{ screen.alternate }}
{{ cursor.hide }}
{{ screen.clear }}

{{ box width="100%" border="rounded" title="Task Manager" color=blue }}
  {{ table headers=["ID", "Task", "Status", "Priority"] widths=[5, 40, 15, 10] }}
    {{ for task in tasks }}
      {{ row }}{{ task.id }}{{ endrow }}
      {{ row }}{{ task.name }}{{ endrow }}
      {{ row }}
        {{ if task.status == "completed" }}
          {{ color green }}✓ Done{{ reset }}
        {{ else if task.status == "in-progress" }}
          {{ color yellow }}⟳ In Progress{{ reset }}
        {{ else }}
          {{ color dim }}○ Pending{{ reset }}
        {{ endif }}
      {{ endrow }}
      {{ row }}
        {{ if task.priority == "high" }}
          {{ color red }}{{ bold }}HIGH{{ reset }}
        {{ else if task.priority == "medium" }}
          {{ color yellow }}MEDIUM{{ reset }}
        {{ else }}
          {{ color dim }}low{{ reset }}
        {{ endif }}
      {{ endrow }}
    {{ endfor }}
  {{ endtable }}
{{ endbox }}

{{ cursor.move (terminal.rows - 2) 1 }}
{{ color dim }}Press {{ reset }}{{ bold }}a{{ reset }}{{ color dim }} to add task, {{ reset }}{{ bold }}d{{ reset }}{{ color dim }} to delete, {{ reset }}{{ bold }}q{{ reset }}{{ color dim }} to quit{{ reset }}

{{ cursor.show }}
```

```aro
(* main.aro *)
(Application-Start: Task Manager) {
    Log "Task Manager starting..." to the <console>.

    Retrieve the <tasks> from the <task-repository>.

    (* Render initial view *)
    Render the <view> from "task-list.screen"
           with <tasks>
           to the <terminal>.

    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}

(Handle Key Press: Keyboard Handler) {
    Extract the <key> from the <event: key>.

    When <key> equals "a" {
        Prompt the <task-name> with "New task: " from the <terminal>.
        Create the <task> with { name: <task-name>, status: "pending" }.
        Store the <task> in the <task-repository>.
        Emit a <TasksUpdated: event>.
    }.

    When <key> equals "q" {
        Stop the <application>.
    }.

    Return an <OK: status> for the <key-press>.
}

(Refresh Display: TasksUpdated Handler) {
    Retrieve the <tasks> from the <task-repository>.

    Render the <view> from "task-list.screen"
           with <tasks>
           to the <terminal>.

    Return an <OK: status> for the <refresh>.
}
```

## Example: System Monitoring Dashboard

```aro
(* monitor.screen *)
{{ screen.clear }}
{{ cursor.move 1 1 }}

{{ color cyan }}{{ bold }}
╔═══════════════════════════════════════════════════════════════════════════╗
║                         SYSTEM MONITOR                                    ║
╚═══════════════════════════════════════════════════════════════════════════╝
{{ reset }}

{{ panel orientation="horizontal" }}
  {{ section width="50%" }}
    {{ box border="single" title="CPU Usage" padding=1 }}
      {{ for core in cpu.cores }}
        Core {{ core.id }}: {{ progress value=core.usage width=20 }}
      {{ endfor }}

      {{ color dim }}Average:{{ reset }} {{ cpu.average }}%
    {{ endbox }}

    {{ box border="single" title="Memory" padding=1 }}
      {{ progress value=memory.used total=memory.total width=30 label="RAM" }}

      {{ color dim }}{{ memory.used }}GB / {{ memory.total }}GB{{ reset }}
    {{ endbox }}
  {{ endsection }}

  {{ section width="50%" }}
    {{ box border="single" title="Network" padding=1 }}
      {{ color green }}↓{{ reset }} Download: {{ network.download }} MB/s
      {{ color blue }}↑{{ reset }} Upload:   {{ network.upload }} MB/s

      {{ color dim }}Total: {{ network.total }}GB{{ reset }}
    {{ endbox }}

    {{ box border="single" title="Disk I/O" padding=1 }}
      {{ for disk in disks }}
        {{ disk.name }}: {{ progress value=disk.used total=disk.total width=20 }}
      {{ endfor }}
    {{ endbox }}
  {{ endsection }}
{{ endpanel }}

{{ cursor.move (terminal.rows - 1) 1 }}
{{ color dim }}Last updated: {{ timestamp }}{{ reset }}
```

```aro
(Application-Start: System Monitor) {
    Log "Starting system monitor..." to the <console>.

    (* Watch updates dashboard every second *)
    Watch the <dashboard> from "monitor.screen"
          with <system-metrics>
          every 1 second
          to the <terminal>.

    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}
```

## Example: Installation Wizard

```aro
(Run Installation: Installer) {
    (* Step 1: Welcome *)
    Render the <welcome> from "welcome.screen" to the <terminal>.
    Prompt the <confirmed> with "Continue? (y/n): "
           as a <confirmation>
           from the <terminal>.

    When not <confirmed> {
        Log "Installation cancelled" to the <console>.
        Return an <OK: status> for the <cancellation>.
    }.

    (* Step 2: Choose components *)
    Create the <components> with [
        "Core System",
        "Web Server",
        "Database",
        "Monitoring Tools"
    ].

    Select the <selected> from <components>
           with "Select components to install (space to toggle):"
           as <multi-select>
           from the <terminal>.

    (* Step 3: Install with progress *)
    Render the <installing> from "install.screen"
           with { components: <selected> }
           to the <terminal>.

    For each <component> in <selected> {
        (* Simulate installation *)
        Install the <component> with <options>.

        Emit a <ComponentInstalled: event> with <component>.
    }.

    (* Step 4: Complete *)
    Render the <complete> from "complete.screen" to the <terminal>.

    Return an <OK: status> for the <installation>.
}

(Update Progress: ComponentInstalled Handler) {
    Extract the <component> from the <event: component>.

    Compute the <completed> from count(<installed>) + 1.
    Compute the <total> from count(<selected>).

    Render the <progress-view> from "install.screen"
           with { completed: <completed>, total: <total> }
           to the <terminal>.

    Return an <OK: status> for the <update>.
}
```

```aro
(* install.screen *)
{{ box width=60 border="double" title="Installing ARO" align=center }}
  {{ for component in components }}
    {{ if component.installed }}
      {{ color green }}✓{{ reset }}
    {{ else }}
      {{ spinner style="dots" }}
    {{ endif }}
    {{ component.name }}
  {{ endfor }}

  {{ progress value=completed total=total width=50 }}

  {{ color dim }}{{ completed }} of {{ total }} components installed{{ reset }}
{{ endbox }}
```

## Terminal Capabilities Detection

ARO automatically detects terminal capabilities and gracefully degrades:

| Feature | Fallback Behavior |
|---------|-------------------|
| True color RGB | Use closest 256-color or 16-color match |
| Unicode box chars | Use ASCII fallback (+, -, \|) |
| Cursor positioning | Linear output without cursor control |
| Alternate buffer | Use main buffer with screen clears |
| Hidden input | Show warning, accept visible input |

Detection is exposed via `terminal` properties:
```aro
{{ if terminal.supports_true_color }}
  {{ color rgb(100, 150, 200) }}Gradient text{{ reset }}
{{ else }}
  {{ color blue }}Blue text{{ reset }}
{{ endif }}
```

## Implementation Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    ARO Application                          │
├─────────────────────────────────────────────────────────────┤
│  Feature Sets                                               │
│  ├─ Watch action (triggers periodic renders)                │
│  ├─ Render action (one-time template render)                │
│  ├─ Prompt action (interactive input)                       │
│  └─ Select action (menu selection)                          │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ↓
┌─────────────────────────────────────────────────────────────┐
│              Terminal Service                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Capability Detection                                │  │
│  │  ├─ Color support (16/256/true color)                │  │
│  │  ├─ Terminal dimensions (rows × columns)             │  │
│  │  ├─ Unicode support                                  │  │
│  │  └─ Interactive features (keyboard input)            │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ANSI Renderer                                       │  │
│  │  ├─ Color codes (foreground/background)              │  │
│  │  ├─ Text styles (bold, italic, underline)            │  │
│  │  ├─ Cursor control (move, save, restore)             │  │
│  │  └─ Screen control (clear, alternate buffer)         │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Layout Engine                                       │  │
│  │  ├─ Box rendering with borders                       │  │
│  │  ├─ Progress bar rendering                           │  │
│  │  ├─ Table layout and column alignment                │  │
│  │  ├─ Panel/section layout (responsive)                │  │
│  │  └─ Widget positioning and overflow                  │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Input Handler                                       │  │
│  │  ├─ Raw mode (non-canonical input)                   │  │
│  │  ├─ Keyboard event parsing (arrow keys, etc.)        │  │
│  │  ├─ Line editing (backspace, history)                │  │
│  │  └─ Signal handling (SIGINT, SIGWINCH)               │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ↓
┌─────────────────────────────────────────────────────────────┐
│         Template Engine (ARO-0050)                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Parser Extensions                                   │  │
│  │  ├─ {{ color }}, {{ bg }}, {{ bold }}, etc.          │  │
│  │  ├─ {{ cursor.* }} directives                        │  │
│  │  ├─ {{ screen.* }} directives                        │  │
│  │  └─ {{ box }}, {{ progress }}, {{ table }}, etc.     │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Renderer                                            │  │
│  │  ├─ Process directives into ANSI codes               │  │
│  │  ├─ Layout widgets into positioned text              │  │
│  │  ├─ Inject runtime terminal properties               │  │
│  │  └─ Output final ANSI-formatted string               │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Core Types

```swift
// Sources/ARORuntime/Terminal/TerminalService.swift
public actor TerminalService: Sendable {
    public struct Capabilities: Sendable {
        public let rows: Int
        public let columns: Int
        public let supportsColor: Bool
        public let supportsTrueColor: Bool
        public let supportsUnicode: Bool
        public let isTTY: Bool
        public let encoding: String
    }

    public func detect() async -> Capabilities
    public func render(_ template: String, context: [String: Any]) async throws
    public func prompt(_ message: String, hidden: Bool) async throws -> String
    public func select(_ options: [String], multi: Bool) async throws -> [String]
    public func clear() async
    public func moveCursor(row: Int, column: Int) async
}

// Sources/ARORuntime/Terminal/ANSIRenderer.swift
public struct ANSIRenderer: Sendable {
    public func renderColor(_ color: TerminalColor) -> String
    public func renderStyle(_ style: TextStyle) -> String
    public func renderCursorMove(row: Int, column: Int) -> String
    public func renderClear() -> String
}

// Sources/ARORuntime/Terminal/LayoutEngine.swift
public struct LayoutEngine: Sendable {
    public func renderBox(_ config: BoxConfig, content: String) -> String
    public func renderProgress(_ config: ProgressConfig) -> String
    public func renderTable(_ config: TableConfig, rows: [[String]]) -> String
    public func renderPanel(_ config: PanelConfig, sections: [String]) -> String
}

// Sources/ARORuntime/Actions/WatchAction.swift
public struct WatchAction: ActionImplementation {
    public static let verbs: Set<String> = ["Watch"]

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let templatePath: String = try context.require(result.identifier)
        let data: [String: Any] = try context.require(object.identifier)
        let interval: TimeInterval = try context.require("interval", default: 1.0)

        let terminal = try context.service(TerminalService.self)

        // Render loop
        while !Task.isCancelled {
            try await terminal.render(templatePath, context: data)
            try await Task.sleep(for: .seconds(interval))
        }

        return ()
    }
}
```

### Template Directive Processing

Template directives are processed by extending the existing template engine:

```swift
// Sources/ARORuntime/Template/TerminalDirectives.swift
extension TemplateEngine {
    func processTerminalDirective(_ directive: Directive) throws -> String {
        switch directive.name {
        case "color":
            return ANSIRenderer.shared.renderColor(directive.argument)
        case "bg":
            return ANSIRenderer.shared.renderBackground(directive.argument)
        case "bold", "italic", "underline":
            return ANSIRenderer.shared.renderStyle(directive.name)
        case "reset":
            return "\u{001B}[0m"
        case "cursor.move":
            let (row, col) = parsePosition(directive.arguments)
            return ANSIRenderer.shared.renderCursorMove(row: row, column: col)
        // ... more directives
        default:
            throw TemplateError.unknownDirective(directive.name)
        }
    }
}
```

## File Structure

New files to be created:

```
Sources/ARORuntime/
├── Terminal/
│   ├── TerminalService.swift          # Main terminal service actor
│   ├── ANSIRenderer.swift             # ANSI escape code generation
│   ├── LayoutEngine.swift             # Widget layout and rendering
│   ├── InputHandler.swift             # Keyboard input and raw mode
│   ├── CapabilityDetector.swift       # Terminal capability detection
│   └── TerminalColor.swift            # Color types and RGB conversion
├── Actions/
│   ├── WatchAction.swift              # Watch action implementation
│   ├── PromptAction.swift             # Prompt action implementation
│   ├── SelectAction.swift             # Select action implementation
│   └── ClearAction.swift              # Clear action implementation
└── Template/
    └── TerminalDirectives.swift       # Template directive extensions

Examples/
└── TerminalUI/
    ├── main.aro                       # Application-Start with Watch
    ├── dashboard.screen               # System monitoring dashboard
    ├── task-manager/
    │   ├── main.aro                   # Task manager app
    │   ├── task-list.screen           # Task list view
    │   └── add-task.screen            # Add task form
    ├── installer/
    │   ├── main.aro                   # Installation wizard
    │   ├── welcome.screen             # Welcome screen
    │   ├── install.screen             # Progress screen
    │   └── complete.screen            # Completion screen
    └── simple-menu/
        ├── main.aro                   # Interactive menu
        └── menu.screen                # Menu template
```

## Platform Support

| Platform | Support | Notes |
|----------|---------|-------|
| macOS    | Full    | All features supported |
| Linux    | Full    | All features supported |
| Windows  | Partial | ANSI support via Windows Terminal; limited in CMD |

**Windows Considerations:**
- Windows 10+ with Windows Terminal: Full support
- Legacy CMD: Basic color support only, no cursor positioning
- Recommend detecting `$env:WT_SESSION` for Windows Terminal

## Security Considerations

1. **Input Sanitization**: All user input must be sanitized to prevent ANSI injection attacks
2. **Template Sandboxing**: Templates cannot execute arbitrary shell commands
3. **Resource Limits**: Watch action has maximum refresh rate to prevent CPU abuse
4. **Signal Handling**: Graceful cleanup on SIGINT/SIGTERM

## Future Extensions

### Phase 2: Advanced Widgets
- Chart rendering (bar charts, line charts, sparklines)
- Tree view with expand/collapse
- Form inputs with validation
- Split panes with resizable dividers

### Phase 3: Mouse Support
- Click event handling
- Drag-and-drop
- Scroll events

### Phase 4: Themes
- Predefined color schemes
- Custom theme files
- Dark/light mode detection

## References

This proposal builds upon:
- **ARO-0050**: Template Engine (Mustache syntax, Render action)
- **ARO-0008**: I/O Services (System objects architecture)
- **ARO-0031**: Context-Aware Formatting (Adaptive output concepts)

**External References:**
- [Ratatui](https://ratatui.rs) - Rust terminal UI library
- [Rich](https://github.com/Textualize/rich) - Python terminal formatting
- [Blessed](https://github.com/chjj/blessed) - Node.js terminal library
- [ANSI Escape Codes](https://en.wikipedia.org/wiki/ANSI_escape_code) - Terminal control sequences

## Conclusion

The Terminal UI system brings ARO's natural language philosophy to terminal applications. By combining the `terminal` system object with template-based rendering and declarative widgets, developers can build sophisticated terminal UIs without learning ANSI codes or complex APIs.

The design follows ARO's core principle: **describe what you want, not how to do it**. Instead of manually positioning cursors and writing escape sequences, developers write templates that declare the desired appearance—ARO handles the rest.
