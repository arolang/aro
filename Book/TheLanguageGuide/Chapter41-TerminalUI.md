# Chapter 41: Terminal UI

> "Terminal interfaces aren't just for the past—they're the fastest way to build powerful, focused tools."
> — Unknown

ARO's Terminal UI system enables you to build beautiful, interactive terminal applications with reactive live updates. By combining ANSI escape codes for styling, template filters for formatting, and the reactive Watch pattern for automatic re-rendering, you can create sophisticated dashboards, monitors, and CLI tools that respond instantly to data changes—without polling.

## 41.1 Introduction to Terminal UIs

Terminal user interfaces remain the optimal choice for many scenarios: system monitors, development tools, dashboards, CLI utilities, and real-time data displays. ARO makes terminal UI development natural and intuitive by integrating terminal capabilities directly into the template system and event-driven architecture.

```
┌─────────────────────────────────────────────────────────────┐
│                 Terminal UI Architecture                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Data Changes          Watch Pattern        Terminal       │
│   ┌──────────┐         ┌──────────┐         ┌──────────┐   │
│   │  Store   │────────►│  Watch   │────────►│ Render   │   │
│   │  Task    │  Event  │ Handler  │ Template│ Output   │   │
│   └──────────┘         └──────────┘         └──────────┘   │
│                                                              │
│   Repository changes trigger Watch handlers                  │
│   Templates apply ANSI styling filters                       │
│   Output appears instantly in terminal                       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Features

**Reactive Updates**: The Watch pattern triggers UI re-renders when events occur or data changes—no polling required.

**ANSI Styling**: Template filters apply colors, bold, italics, and other styles using ANSI escape codes.

**Capability Detection**: ARO automatically detects terminal capabilities (dimensions, color support, Unicode) and degrades gracefully.

**Thread-Safe**: All terminal operations use Swift actors for safe concurrent access.

## 41.2 The Terminal System Object

Templates automatically have access to a `terminal` object containing capability information:

```aro
{{ <terminal: rows> }}           (* Terminal height in lines *)
{{ <terminal: columns> }}        (* Terminal width in characters *)
{{ <terminal: width> }}          (* Alias for columns *)
{{ <terminal: height> }}         (* Alias for rows *)
{{ <terminal: supports_color> }} (* Boolean: can display colors *)
{{ <terminal: supports_true_color> }} (* Boolean: 24-bit RGB support *)
{{ <terminal: is_tty> }}         (* Boolean: connected to terminal *)
{{ <terminal: encoding> }}       (* String: UTF-8, ASCII, etc. *)
```

**Example Template (templates/status.screen)**:
```aro
Terminal: {{ <terminal: columns> }}×{{ <terminal: rows> }}
Color Support: {{ <terminal: supports_color> }}

{{when <terminal: columns> > 120}}
  (* Wide layout *)
  {{ "=== Detailed Dashboard ===" | bold | color: "cyan" }}
{{when <terminal: columns> > 80}}
  (* Medium layout *)
  {{ "=== Dashboard ===" | bold }}
{{else}}
  (* Narrow layout *)
  {{ "=Dashboard=" }}
{{end}}
```

This enables responsive terminal designs that adapt to the user's terminal size automatically.

## 41.3 Styling with Template Filters

ARO provides template filters for applying ANSI styling to text. These filters integrate seamlessly with the template engine you learned in Chapter 38.

### 41.3.1 Color Filters

Apply foreground and background colors using the `color` and `bg` filters:

```aro
{{ "Success!" | color: "green" }}
{{ "Error!" | color: "red" }}
{{ "Warning" | color: "yellow" }}

{{ "Highlight" | bg: "blue" }}
{{ "Alert" | color: "white" | bg: "red" }}
```

**Named Colors**:
- **Standard**: black, red, green, yellow, blue, magenta, cyan, white
- **Bright**: brightRed, brightGreen, brightBlue, brightCyan, brightYellow, etc.
- **Semantic**: success (green), error (red), warning (yellow), info (blue)

**RGB Colors** (24-bit true color):
```aro
{{ "Custom Color" | color: "rgb(100, 200, 50)" }}
{{ "Dark Background" | bg: "rgb(30, 30, 30)" }}
```

ARO automatically converts RGB to the best available color mode:
- True color terminals: Use full 24-bit RGB
- 256-color terminals: Convert to closest 256-color
- 16-color terminals: Convert to closest basic color
- No color support: Strip all color codes

### 41.3.2 Style Filters

Apply text styles using simple filters:

```aro
{{ "Important" | bold }}
{{ "Subdued" | dim }}
{{ "Emphasis" | italic }}
{{ "Link" | underline }}
{{ "Removed" | strikethrough }}
```

### 41.3.3 Chaining Filters

Combine multiple filters for rich formatting:

```aro
{{ "SUCCESS" | color: "green" | bold }}
{{ "ERROR" | color: "red" | bold | underline }}
{{ "Debug Info" | color: "cyan" | dim }}
```

**Example Template (templates/task-list.screen)**:
```aro
{{ "=== Task List ===" | bold | color: "cyan" }}

{{for task in tasks}}
  [{{ <task: id> }}] {{ <task: title> | bold }} - {{ <task: status> | color: "yellow" }}
{{end}}

{{ "Total: " }}{{ <tasks> | length }} {{ "tasks" | dim }}
```

## 41.4 Reactive Watch Pattern

The Watch pattern is ARO's approach to live-updating terminal UIs. Unlike traditional polling (checking for changes repeatedly), Watch is **purely reactive**—handlers trigger only when actual changes occur.

### 41.4.1 Watch as a Feature Set Pattern

Watch is **not an action**—it's a **feature set pattern** that combines with Handler or Observer patterns:

**Event-Based Watch**:
```aro
(Name Watch: EventType Handler)
```

**Repository-Based Watch**:
```aro
(Name Watch: repository Observer)
```

### 41.4.2 Repository Observer Watch

The most common pattern: UI updates automatically when repository data changes.

**Complete Example**:

```aro
(* main.aro *)
(Application-Start: Task Manager) {
    (* Initialize some tasks *)
    Create the <task1> with { id: 1, title: "Write docs", status: "pending" }.
    Create the <task2> with { id: 2, title: "Review PR", status: "in-progress" }.

    Store the <task1> into the <task-repository>.
    Store the <task2> into the <task-repository>.

    Log "Task Manager started. UI updates reactively." to the <console>.

    (* Keep application running *)
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Watch handler - triggers on repository changes *)
(Dashboard Watch: task-repository Observer) {
    (* Optional: clear screen for clean render *)
    Clear the <screen> for the <terminal>.

    (* Retrieve current tasks *)
    Retrieve the <tasks> from the <task-repository>.

    (* Render template with fresh data *)
    Transform the <output> from the <template: templates/dashboard.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Add new task - this triggers the Watch handler *)
(Add Task: TaskAdded Handler) {
    Extract the <title> from the <event: title>.

    Create the <new-task> with { title: <title>, status: "pending" }.

    (* This Store triggers the repository Observer *)
    Store the <new-task> into the <task-repository>.

    Return an <OK: status> for the <task-creation>.
}
```

**templates/dashboard.screen**:
```aro
{{ "=== Task Dashboard ===" | bold | color: "cyan" }}

{{ "Active Tasks:" | bold }}

{{for task in tasks}}
  {{ "[" }}{{ <task: id> }}{{ "] " }}{{ <task: title> | color: "white" }} - {{ <task: status> | color: "yellow" }}
{{end}}

{{ "---" }}
{{ "Total: " }}{{ <tasks> | length }}{{ " tasks" }}
{{ "Terminal: " }}{{ <terminal: columns> }}{{ "×" }}{{ <terminal: rows> }}
```

**Flow**:
1. `Application-Start` stores initial tasks
2. Each `Store` triggers `RepositoryChangedEvent`
3. Watch handler detects event for `task-repository`
4. Handler retrieves fresh tasks
5. Template renders with updated data
6. Output appears in terminal

**Result**: Every time a task is stored/updated/deleted, the dashboard automatically re-renders!

### 41.4.3 Event-Based Watch

Watch handlers can also trigger on custom domain events:

```aro
(* main.aro *)
(Application-Start: System Monitor) {
    Log "System Monitor starting..." to the <console>.

    (* Emit initial metrics *)
    Create the <metrics> with { cpu: 23, memory: 45, disk: 67 }.
    Emit a <MetricsUpdated: event> with <metrics>.

    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Watch handler - triggers on MetricsUpdated events *)
(Dashboard Watch: MetricsUpdated Handler) {
    Clear the <screen> for the <terminal>.

    (* In real app, you'd extract metrics from event *)
    Transform the <output> from the <template: templates/monitor.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Periodic collection could emit events *)
(Collect Metrics: Timer Handler) {
    (* Read actual system metrics *)
    Create the <metrics> with { cpu: 45, memory: 67, disk: 89 }.

    (* This Emit triggers the Watch handler *)
    Emit a <MetricsUpdated: event> with <metrics>.

    Return an <OK: status> for the <collection>.
}
```

**Flow**:
1. `Application-Start` emits initial `MetricsUpdated` event
2. Watch handler catches event
3. Template renders with metrics
4. Later, `Timer Handler` emits new metrics
5. Watch handler triggers again
6. UI updates with fresh data

### 41.4.4 Why Watch is Superior to Polling

**Traditional Polling** (other languages):
```javascript
// NOT in ARO - this is what we avoid!
setInterval(() => {
    const tasks = getTasks();
    renderDashboard(tasks);
}, 1000);  // Check every second - wasteful!
```

**Problems with polling**:
- ❌ Wastes CPU cycles checking when nothing changed
- ❌ Updates delayed until next poll
- ❌ Must choose between responsiveness and efficiency
- ❌ Complex timer management

**ARO Watch Pattern**:
```aro
(Dashboard Watch: task-repository Observer) {
    Retrieve the <tasks> from the <task-repository>.
    Transform the <view> from the <template: dashboard.screen>.
    Log <view> to the <console>.
    Return an <OK: status>.
}
```

**Benefits**:
- ✅ Zero CPU usage when idle
- ✅ Instant updates when data changes
- ✅ No timers to manage
- ✅ Integrates with event-driven architecture

The Watch pattern is **purely reactive**: handlers execute only when actual changes occur, making it both efficient and responsive.

## 41.5 Terminal Actions

ARO provides actions for terminal interaction and control.

### 41.5.1 Clear Action

Clear the terminal screen or current line:

```aro
Clear the <screen> for the <terminal>.
Clear the <line> for the <terminal>.
```

**Common usage**: Clear before re-rendering in Watch handlers to prevent screen clutter.

### 41.5.2 Prompt Action

Request text input from the user:

```aro
(* Basic input *)
Prompt the <name> from the <terminal>.
Log "Hello, <name>!" to the <console>.

(* Hidden input for passwords *)
Prompt the <password: hidden> from the <terminal>.
Compute the <length: length> from <password>.
Log "Password is <length> characters long" to the <console>.
```

The `hidden` specifier disables echo for password entry.

### 41.5.3 Select Action

Display an interactive menu:

```aro
(* Create options *)
Create the <options> with ["Red", "Green", "Blue", "Yellow"].

(* Single selection *)
Select the <choice> from <options> from the <terminal>.
Log "You selected: <choice>" to the <console>.

(* Multi-selection *)
Select the <choices: multi-select> from <options> from the <terminal>.
Log "You selected: <choices>" to the <console>.
```

**Current implementation**: Numbered menu with user input.
**Future**: Arrow key navigation, visual cursor, space to toggle.

## 41.6 The Render Action and Section Compositor

`Log` appends text to the terminal and moves on. `Render` is different: it manages **named screen sections** and keeps track of where every region lives so re-renders update only what changed—without ever clearing the screen.

```aro
Render the <menu> to the <console>.
Render the <status-bar> to the <console>.
```

The variable name (`menu`, `status-bar`, …) is the **section ID**. The compositor uses it to decide whether this is a new section or an update to an existing one.

### 41.6.1 How the Section Compositor Works

```
┌─────────────────────────────────────────────────────────────┐
│                  Section Compositor Model                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  First render of <name>   →  Appended below previous rows   │
│  Re-render of same <name> →  Only changed lines rewritten   │
│  Height grows / shrinks   →  Sections below shift and       │
│                               re-render at new positions     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

Given a typical interactive application:

```aro
Render <loading> to the <console>.   (* row  0..2  – static *)
Render <splash>  to the <console>.   (* row  3..6  – static *)
Render <welcome> to the <console>.   (* row  7..9  – static *)
Render <menu>    to the <console>.   (* row 10..21 – reactive *)
```

When the menu is re-rendered after the user presses a key, **only the marker character** on the selected row changes. The compositor moves the cursor to that single line, overwrites it, and leaves every other row—including splash and welcome—completely untouched. No flicker, no full-screen clear.

When a reactive section changes height (e.g. switching from a 12-line menu to a 9-line task list):

1. Orphaned rows of the old content are erased
2. The new content is written starting from the section's original top row
3. Every section below is shifted by the height delta and re-rendered at its new position

### 41.6.2 Starting Fresh with Clear

The compositor state is reset whenever the screen is explicitly cleared. Use `Clear` exactly once at the very beginning of the application—never inside event handlers or observers:

```aro
(Application-Start: My App) {
    (* Clear once: compositor starts from row 0 *)
    Clear the <screen> for the <terminal>.

    (* Every Render after this appends or updates in-place *)
    Transform the <splash> from the <template: splash.screen>.
    Render the <splash> to the <console>.
    ...
}
```

In non-TTY mode (pipes, tests) `Clear` is a silent no-op, so the application always produces clean output when run non-interactively.

### 41.6.3 The Content-Area Pattern

Many applications have a fixed chrome (header, status bar) and a single **content area** that swaps between different views. The key is to always render all views into the **same variable name**—the compositor treats the variable name as the section identity.

```aro
(* Both menu and task-list render into <content>, replacing each other *)
Transform the <content> from the <template: menu.screen>.
Render the <content> to the <console>.

...

Transform the <content> from the <template: tasks.screen>.
Render the <content> to the <console>.   (* replaces menu in-place *)
```

The header section above `<content>` is never touched.

---

## 41.7 Keyboard-Driven Interactive UIs

ARO provides first-class support for keyboard-driven applications—menus, editors, dashboards with hotkeys—through the `Listen` action and `KeyPress Handler` feature sets.

### 41.7.1 Starting Keyboard Input

```aro
Listen the <keyboard> to the <stdin>.
```

This puts the terminal in **raw mode**: each key press is delivered immediately, without waiting for Enter. Arrow keys, function keys, and control sequences are all parsed and made available as named keys.

In non-TTY mode (pipes, tests, CI) `Listen` is a silent no-op so applications work identically in both environments.

### 41.7.2 KeyPress Handlers

A `KeyPress Handler` feature set fires whenever a key is pressed. There are two forms:

**Universal handler** — fires on every key press:
```aro
(Navigate Menu: KeyPress Handler) {
    Extract the <key> from the <event: key>.
    ...
}
```

**Filtered handler** — fires only when a specific key is pressed:
```aro
(Select Item: KeyPress Handler<key:enter>) { ... }
(Go Back:     KeyPress Handler<key:backspace>) { ... }
(Quit App:    KeyPress Handler<key:q>) { ... }
```

The filter is declared in angle brackets as `<key:name>` inside the business activity. Named keys include:

| Key name | Physical key |
|---|---|
| `enter` | Return / Enter |
| `backspace` | Backspace / Delete |
| `up` | ↑ arrow |
| `down` | ↓ arrow |
| `left` | ← arrow |
| `right` | → arrow |
| `q`, `a`, … | Any character |

### 41.7.3 Reading the Pressed Key

Inside a universal handler, extract the key name from the event:

```aro
(Navigate Menu: KeyPress Handler) {
    Extract the <pressed-key> from the <event: key>.

    match <pressed-key> {
        case "up"   { ... }
        case "down" { ... }
    }

    Return an <OK: status> for the <navigation>.
}
```

### 41.7.4 View State Pattern

The cleanest architecture for interactive menus separates **state** from **rendering**:

- **Handlers** only update the repository state (`selection`, `view`, …)
- **One observer** watches the repository and renders the correct template

This means handlers contain no template logic at all:

```aro
(Select Item: KeyPress Handler<key:enter>) {
    Retrieve the <state> from the <app-repository> where <key> is "app".
    Extract the <cur> from the <state: selection>.

    match <cur> {
        case 0 {
            Create the <new-view> with "tasks".
            Update the <state: view> with <new-view>.
            Store the <state> into the <app-repository>.
        }
        case 1 {
            Create the <new-view> with "logs".
            Update the <state: view> with <new-view>.
            Store the <state> into the <app-repository>.
        }
    }

    Return an <OK: status> for the <selection>.
}
```

The observer handles the rendering:

```aro
(Refresh View: app-repository Observer) {
    Extract the <state> from the <event: newValue>.
    Extract the <view> from the <state: view>.

    match <view> {
        case "menu"  { (* build menu items *) Transform the <content> from the <template: menu.screen>.  }
        case "tasks" { (* build task list *) Transform the <content> from the <template: tasks.screen>. }
        case "logs"  { Transform the <content> from the <template: logs.screen>. }
    }

    Render the <content> to the <console>.
    Return an <OK: status> for the <refresh>.
}
```

Because all views render into the same `<content>` section, the compositor replaces the previous view in-place. If the new template is taller or shorter, sections below shift automatically.

### 41.7.5 Stopping the Application Cleanly

```aro
Stop the <keyboard> with <application>.
```

This does two things in one statement:

1. Restores the terminal from raw mode to normal mode
2. Signals a clean shutdown—`Keepalive` unblocks and Application-Start returns normally

The process exits with **code 0**. Without this explicit signal, `Keepalive` would remain in long-running service mode and the process would hang.

A typical exit sequence:

```aro
(Quit App: KeyPress Handler<key:q>) {
    Transform the <content> from the <template: goodbye.screen>.
    Render the <content> to the <console>.
    Stop the <keyboard> with <application>.
    Return an <OK: status> for the <quit>.
}
```

---

## 41.8 Complete Example: Interactive Menu

`Examples/TerminalSimpleMenu` demonstrates all the concepts above in a working application: keyboard navigation, in-place reactive rendering, the content-area pattern, view state management, and clean exit.

**Directory Structure**:
```
TerminalSimpleMenu/
├── main.aro
├── handlers.aro
├── observer.aro
└── templates/
    ├── starting.screen
    ├── splash.screen
    ├── welcome.screen
    ├── menu.screen
    ├── tasks.screen
    ├── logs.screen
    └── goodbye.screen
```

### Screen Layout

The application composes four sections on one screen. Three are static chrome; one is the interactive content area:

```
┌─────────────────────────────────────────┐  ← section "loading"  (static)
│ Starting Simple Menu App...             │
│ Please wait...                          │
├─────────────────────────────────────────┤  ← section "splash"   (static)
│ ╔═══════════════════════════════════╗   │
│ ║       Welcome to ARO             ║   │
│ ╚═══════════════════════════════════╝   │
├─────────────────────────────────────────┤  ← section "welcome"  (static)
│ === Simple Terminal Menu ===            │
│ Navigate the menu below...             │
├─────────────────────────────────────────┤  ← section "menu"     (reactive)
│   MAIN MENU                            │
│   ───────────────────────────────────  │
│   ▶ View Tasks                         │  ← only this line changes on ↑↓
│     View Logs                          │
│     Exit                               │
│   ───────────────────────────────────  │
│   ↑↓ navigate · Enter select · q quit  │
└─────────────────────────────────────────┘
```

When the user navigates, only the marker line is rewritten. When a menu item is selected, the entire `menu` section is replaced with the chosen view (tasks, logs, or goodbye) with automatic height adjustment.

### main.aro

```aro
(Application-Start: Simple Menu) {
    (* Clear the terminal once — compositor starts from row 0 *)
    Clear the <screen> for the <terminal>.

    (* Static chrome — rendered once, never touched again *)
    Create the <service> with "Simple Menu App".
    Transform the <loading> from the <template: starting.screen>.
    Render <loading> to the <console>.

    Transform the <splash> from the <template: splash.screen>.
    Render <splash> to the <console>.

    Create the <title> with "Simple Terminal Menu".
    Transform the <welcome> from the <template: welcome.screen>.
    Render <welcome> to the <console>.

    (* Store initial state — the observer renders the menu section *)
    Create the <init-state> with { key: "menu", selection: 0, view: "menu" }.
    Store the <init-state> into the <selection-repository>.

    (* Start keyboard input *)
    Listen the <keyboard> to the <stdin>.

    (* Block until Stop the <keyboard> is called *)
    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}
```

`Store` triggers the `selection-repository Observer`, which renders the initial menu into the `menu` section.

### observer.aro

The observer is the **single source of rendering truth**. It reads the `view` field and renders the appropriate template—always into the same `<menu>` section.

```aro
(Refresh View: selection-repository Observer) {
    Extract the <new-state> from the <event: newValue>.
    Extract the <selection> from the <new-state: selection>.
    Extract the <view> from the <new-state: view>.

    match <view> {
        case "menu" {
            match <selection> {
                case 0 {
                    Create the <d1> with { label: "View Tasks", marker: "▶" }.
                    Create the <d2> with { label: "View Logs",  marker: " " }.
                    Create the <d3> with { label: "Exit",       marker: " " }.
                }
                case 1 {
                    Create the <d1> with { label: "View Tasks", marker: " " }.
                    Create the <d2> with { label: "View Logs",  marker: "▶" }.
                    Create the <d3> with { label: "Exit",       marker: " " }.
                }
                case 2 {
                    Create the <d1> with { label: "View Tasks", marker: " " }.
                    Create the <d2> with { label: "View Logs",  marker: " " }.
                    Create the <d3> with { label: "Exit",       marker: "▶" }.
                }
            }
            Create the <menu-items> with [<d1>, <d2>, <d3>].
            Transform the <menu> from the <template: menu.screen>.
            Render the <menu> to the <console>.
        }
        case "tasks" {
            Create the <task1> with { id: 1, name: "Write docs",   status: "done"    }.
            Create the <task2> with { id: 2, name: "Fix bugs",     status: "pending" }.
            Create the <task3> with { id: 3, name: "Write tests",  status: "pending" }.
            Create the <tasks> with [<task1>, <task2>, <task3>].
            Transform the <menu> from the <template: tasks.screen>.
            Render the <menu> to the <console>.
        }
        case "logs" {
            Transform the <menu> from the <template: logs.screen>.
            Render the <menu> to the <console>.
        }
    }

    Return an <OK: status> for the <refresh>.
}
```

All three cases end with `Render the <menu>`. The variable name `menu` is the section ID — the compositor re-renders that region in-place regardless of which template was used.

### handlers.aro

Handlers contain **no template or rendering code**. They only update repository state and let the observer do the rest.

```aro
(* Up/down navigation — only active in menu view *)
(Navigate Menu: KeyPress Handler) {
    Extract the <pressed-key> from the <event: key>.
    Retrieve the <state> from the <selection-repository> where <key> is "menu".
    Extract the <view> from the <state: view>.

    match <view> {
        case "menu" {
            Extract the <cur> from the <state: selection>.
            match <pressed-key> {
                case "up" {
                    match <cur> {
                        case 0 { Create the <new-val> with 2. }
                        case 1 { Create the <new-val> with 0. }
                        case 2 { Create the <new-val> with 1. }
                    }
                    Update the <state: selection> with <new-val>.
                    Store the <state> into the <selection-repository>.
                }
                case "down" {
                    match <cur> {
                        case 0 { Create the <new-val> with 1. }
                        case 1 { Create the <new-val> with 2. }
                        case 2 { Create the <new-val> with 0. }
                    }
                    Update the <state: selection> with <new-val>.
                    Store the <state> into the <selection-repository>.
                }
            }
        }
    }
    Return an <OK: status> for the <navigation>.
}

(* Enter activates the highlighted item — only in menu view *)
(Select Item: KeyPress Handler<key:enter>) {
    Retrieve the <state> from the <selection-repository> where <key> is "menu".
    Extract the <view> from the <state: view>.

    match <view> {
        case "menu" {
            Extract the <cur> from the <state: selection>.
            match <cur> {
                case 0 {
                    Create the <new-view> with "tasks".
                    Update the <state: view> with <new-view>.
                    Store the <state> into the <selection-repository>.
                }
                case 1 {
                    Create the <new-view> with "logs".
                    Update the <state: view> with <new-view>.
                    Store the <state> into the <selection-repository>.
                }
                case 2 {
                    Transform the <menu> from the <template: goodbye.screen>.
                    Render the <menu> to the <console>.
                    Stop the <keyboard> with <application>.
                }
            }
        }
    }
    Return an <OK: status> for the <selection>.
}

(* Backspace returns from any sub-view to the menu *)
(Go Back: KeyPress Handler<key:backspace>) {
    Retrieve the <state> from the <selection-repository> where <key> is "menu".
    Create the <back-view> with "menu".
    Update the <state: view> with <back-view>.
    Store the <state> into the <selection-repository>.
    Return an <OK: status> for the <back>.
}

(* q exits from anywhere *)
(Quit App: KeyPress Handler<key:q>) {
    Transform the <menu> from the <template: goodbye.screen>.
    Render the <menu> to the <console>.
    Stop the <keyboard> with <application>.
    Return an <OK: status> for the <quit>.
}
```

### Interaction Flow

```
User presses ↓
  → Navigate Menu fires
  → Retrieves state {selection:0, view:"menu"}
  → view == "menu": increments selection to 1
  → Stores {selection:1, view:"menu"}
  → Observer fires (Refresh View)
  → view == "menu", selection == 1: builds items with d2 marked
  → Render the <menu>  →  compositor diffs section "menu"
  → Only the two changed marker lines are rewritten on screen

User presses Enter (selection == 1)
  → Select Item fires
  → view == "menu", cur == 1: sets view to "logs"
  → Stores {selection:1, view:"logs"}
  → Observer fires
  → view == "logs": renders logs.screen into <menu>
  → Compositor replaces section "menu" with new content
  → If height differs, sections below shift automatically

User presses Backspace
  → Go Back fires
  → Sets view to "menu"
  → Observer fires, re-renders navigation menu

User presses q
  → Quit App fires
  → Renders goodbye.screen into <menu>
  → Stop the <keyboard> with <application>
  → Terminal restored to normal mode
  → Keepalive unblocks, process exits with code 0
```

---

## 41.9 Complete Example: Live Task Dashboard

Let's build a complete task management dashboard that updates reactively.

**Directory Structure**:
```
TaskDashboard/
├── main.aro
└── templates/
    └── dashboard.screen
```

**main.aro**:
```aro
(Application-Start: Task Dashboard) {
    Log "Task Dashboard starting..." to the <console>.

    (* Initialize with sample tasks *)
    Create the <task1> with {
        id: 1,
        title: "Implement feature",
        status: "in-progress",
        priority: "high"
    }.
    Create the <task2> with {
        id: 2,
        title: "Write tests",
        status: "pending",
        priority: "medium"
    }.
    Create the <task3> with {
        id: 3,
        title: "Update docs",
        status: "done",
        priority: "low"
    }.

    (* Store in repository - triggers initial render *)
    Store the <task1> into the <task-repository>.
    Store the <task2> into the <task-repository>.
    Store the <task3> into the <task-repository>.

    Log "Dashboard ready. Tasks tracked in real-time." to the <console>.

    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Reactive dashboard - updates on any task change *)
(Dashboard Watch: task-repository Observer) {
    Clear the <screen> for the <terminal>.

    Retrieve the <all-tasks> from the <task-repository>.

    (* Filter by status *)
    Filter the <done> from <all-tasks> where <status> = "done".
    Filter the <in-progress> from <all-tasks> where <status> = "in-progress".
    Filter the <pending> from <all-tasks> where <status> = "pending".

    (* Compute statistics *)
    Compute the <done-count: length> from <done>.
    Compute the <progress-count: length> from <in-progress>.
    Compute the <pending-count: length> from <pending>.
    Compute the <total-count: length> from <all-tasks>.

    (* Render dashboard with statistics *)
    Transform the <output> from the <template: templates/dashboard.screen>.
    Log <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Complete a task - triggers reactive update *)
(Complete Task: TaskCompleted Handler) {
    Extract the <task-id> from the <event: taskId>.

    Retrieve the <task> from the <task-repository> where id = <task-id>.
    Update the <task: status> with "done" into the <task-repository>.

    (* Watch handler triggers automatically! *)

    Return an <OK: status> for the <completion>.
}

(* Add new task *)
(Add Task: TaskAdded Handler) {
    Extract the <title> from the <event: title>.
    Extract the <priority> from the <event: priority>.

    Create the <new-task> with {
        title: <title>,
        status: "pending",
        priority: <priority>
    }.

    Store the <new-task> into the <task-repository>.

    Return an <OK: status> for the <task-creation>.
}
```

**templates/dashboard.screen**:
```aro
{{ "╔════════════════════════════════════════════════════════════╗" }}
{{ "║ " }}{{ "TASK DASHBOARD" | bold | color: "cyan" }}{{ "                                            ║" }}
{{ "╚════════════════════════════════════════════════════════════╝" }}

{{ "Terminal: " }}{{ <terminal: columns> }}{{ "×" }}{{ <terminal: rows> }}{{ " | Color: " }}{{ <terminal: supports_color> }}

{{ "📊 Statistics:" | bold }}
  {{ "✓ Done:        " }}{{ <done-count> | color: "green" }}
  {{ "◷ In Progress: " }}{{ <progress-count> | color: "yellow" }}
  {{ "○ Pending:     " }}{{ <pending-count> | color: "blue" }}
  {{ "━━━━━━━━━━━━━" }}
  {{ "  Total:       " }}{{ <total-count> | bold }}

{{ "🔄 In Progress" | bold | color: "yellow" }}
{{for task in in-progress}}
  {{ "  [" }}{{ <task: id> }}{{ "] " }}{{ <task: title> | bold }} {{ "(" }}{{ <task: priority> | color: "magenta" }}{{ ")" }}
{{end}}

{{ "📋 Pending" | bold | color: "blue" }}
{{for task in pending}}
  {{ "  [" }}{{ <task: id> }}{{ "] " }}{{ <task: title> }} {{ "(" }}{{ <task: priority> | dim }}{{ ")" }}
{{end}}

{{ "✅ Completed" | bold | color: "green" }}
{{for task in done}}
  {{ "  [" }}{{ <task: id> }}{{ "] " }}{{ <task: title> | dim | strikethrough }}
{{end}}

{{ "────────────────────────────────────────────────────────────" | dim }}
{{ "Last updated: reactively on data changes" | dim }}
```

**Running the Dashboard**:
```bash
aro run TaskDashboard
```

**What Happens**:
1. App starts and stores 3 initial tasks
2. Each Store triggers the Watch handler (3 renders)
3. Dashboard displays categorized tasks with statistics
4. When `TaskCompleted` or `TaskAdded` events occur:
   - Tasks are updated/created in repository
   - Watch handler detects change
   - Dashboard re-renders automatically with fresh data
5. User sees live updates without any polling!

## 41.10 Best Practices

### 41.10.1 Responsive Design

Adapt layouts to terminal size:

```aro
{{when <terminal: columns> > 120}}
  (* Wide screen: show detailed 3-column layout *)
  Transform the <view> from the <template: templates/wide.screen>.
{{when <terminal: columns> > 80}}
  (* Medium screen: show 2-column layout *)
  Transform the <view> from the <template: templates/medium.screen>.
{{else}}
  (* Narrow screen: show stacked layout *)
  Transform the <view> from the <template: templates/narrow.screen>.
{{end}}
```

### 41.10.2 Graceful Degradation

Check capabilities before using advanced features:

```aro
{{when <terminal: supports_color>}}
  {{ <error> | color: "red" | bold }}
  {{ <success> | color: "green" | bold }}
{{else}}
  {{ "ERROR: " }}{{ <error> }}
  {{ "SUCCESS: " }}{{ <success> }}
{{end}}

{{when <terminal: supports_unicode>}}
  {{ "✓ ✗ ★ ▶ ◀" }}
{{else}}
  {{ "* X > <" }}
{{end}}
```

### 41.10.3 Efficient Re-Rendering

Only clear and re-render when necessary:

```aro
(* Good: Clear before full re-render *)
(Dashboard Watch: data-repository Observer) {
    Clear the <screen> for the <terminal>.
    Retrieve the <data> from the <data-repository>.
    Transform the <view> from the <template: dashboard.screen>.
    Log <view> to the <console>.
    Return an <OK: status>.
}

(* Also good: Update specific line without clearing *)
(Status Watch: status-repository Observer) {
    (* Don't clear - just update status line *)
    Retrieve the <status> from the <status-repository>.
    Log "Status: <status>" to the <console>.
    Return an <OK: status>.
}
```

### 41.10.4 Testing Terminal UIs

Test with different terminal configurations:

```bash
# Test with limited terminal
TERM=dumb aro run MyApp

# Test with specific dimensions
COLUMNS=80 LINES=24 aro run MyApp

# Test without color support
TERM=xterm aro run MyApp

# Test with full color support
TERM=xterm-256color aro run MyApp
```

## 41.11 Platform Support

ARO's Terminal UI system works across platforms with automatic adaptation:

**macOS & Linux**: Full support
- ✅ ANSI color codes (16-color, 256-color, 24-bit RGB)
- ✅ Text styles (bold, italic, underline, dim, strikethrough)
- ✅ `ioctl()` dimension detection
- ✅ `termios` for hidden input
- ✅ Cursor control and screen clearing

**Windows**:
- ✅ Windows Terminal: Full support
- ⚠️  CMD/PowerShell: Limited ANSI support (Windows 10+)
- ⚠️  Dimension detection via environment variables only

**Graceful Degradation**:
- No color support → All color codes stripped
- No TTY → Safe defaults, interactive actions may fail
- ASCII-only → Unicode symbols replaced with ASCII equivalents

## 41.12 Summary

ARO's Terminal UI system brings together several powerful features:

1. **Reactive Watch Pattern**: UI updates instantly when data changes—no polling
2. **Template Integration**: Apply ANSI styling with simple filters
3. **Terminal Object**: Access capabilities for responsive design
4. **Thread-Safe**: Actor-based isolation for concurrent access
5. **Platform Adaptive**: Automatic capability detection and fallback

**Quick Reference**:

| Feature | Syntax | Example |
|---------|--------|---------|
| Watch (Repository) | `(Name Watch: repository Observer)` | `(Dashboard Watch: task-repository Observer)` |
| Watch (Event) | `(Name Watch: EventType Handler)` | `(Monitor Watch: MetricsUpdated Handler)` |
| Color Filter | `{{ <text> | color: "name" }}` | `{{ "Error" | color: "red" }}` |
| Style Filter | `{{ <text> | style }}` | `{{ "Title" | bold }}` |
| Terminal Object | `{{ <terminal: property> }}` | `{{ <terminal: columns> }}` |
| Clear Screen | `Clear the <screen> for the <terminal>.` | - |
| Prompt Input | `Prompt the <input> from the <terminal>.` | - |
| Select Menu | `Select the <choice> from <options> from the <terminal>.` | - |

The Watch pattern is ARO's key innovation: by triggering on actual changes rather than polling, your terminal UIs are both highly responsive and efficient. Combined with template styling and capability detection, you can build professional terminal applications that adapt to any environment.

## What's Next

- **Chapter 42**: Advanced Topics (if available)
- **Appendix A**: Complete Action Reference
- **Examples**: See `Examples/TerminalUI/` for working applications

For more details, see Proposal ARO-0052: Terminal UI System.
