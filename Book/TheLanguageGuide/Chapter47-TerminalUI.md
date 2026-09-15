# Chapter 47: Terminal UI

> "Terminal interfaces aren't just for the past—they're the fastest way to build powerful, focused tools."
> — Unknown

ARO's Terminal UI system enables you to build beautiful, interactive terminal applications with reactive live updates. By combining ANSI escape codes for styling, template filters for formatting, and the reactive Watch pattern for automatic re-rendering, you can create sophisticated dashboards, monitors, and CLI tools that respond instantly to data changes—without polling.

## 47.1 Introduction to Terminal UIs

Terminal user interfaces remain the optimal choice for many scenarios: system monitors, development tools, dashboards, CLI utilities, and real-time data displays. ARO makes terminal UI development natural and intuitive by integrating terminal capabilities directly into the template system and event-driven architecture.

<div style="text-align: center; margin: 2em 0;">
<svg width="540" height="150" viewBox="0 0 540 150" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowTU" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
  </defs>

  <text x="270" y="16" text-anchor="middle" font-size="11" font-weight="bold" fill="#374151">Terminal UI Architecture</text>

  <!-- Data change -->
  <rect x="20" y="34" width="130" height="56" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="85" y="56" text-anchor="middle" font-size="11" font-weight="bold" fill="#4338ca">Store</text>
  <text x="85" y="74" text-anchor="middle" font-size="9" fill="#4338ca">a repository changes</text>

  <line x1="152" y1="62" x2="198" y2="62" stroke="#374151" stroke-width="2" marker-end="url(#arrowTU)"/>
  <text x="175" y="54" text-anchor="middle" font-size="8" fill="#374151">event</text>

  <!-- Watch -->
  <rect x="200" y="34" width="140" height="56" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="270" y="56" text-anchor="middle" font-size="11" font-weight="bold" fill="#92400e">Observer</text>
  <text x="270" y="74" text-anchor="middle" font-size="9" fill="#92400e">renders a template</text>

  <line x1="342" y1="62" x2="388" y2="62" stroke="#374151" stroke-width="2" marker-end="url(#arrowTU)"/>
  <text x="365" y="54" text-anchor="middle" font-size="8" fill="#374151">text</text>

  <!-- Render -->
  <rect x="390" y="34" width="130" height="56" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="455" y="56" text-anchor="middle" font-size="11" font-weight="bold" fill="#166534">Render</text>
  <text x="455" y="74" text-anchor="middle" font-size="9" fill="#166534">only changed lines</text>

  <text x="270" y="112" text-anchor="middle" font-size="9" fill="#374151">No polling: handlers run only when data actually changes.</text>
  <text x="270" y="128" text-anchor="middle" font-size="9" fill="#374151">Templates apply ANSI styling filters; the compositor diffs the section.</text>
</svg>
</div>

### Key Features

**Reactive Updates**: The Watch pattern triggers UI re-renders when events occur or data changes—no polling required.

**ANSI Styling**: Template filters apply colors, bold, italics, and other styles using ANSI escape codes.

**Capability Detection**: ARO automatically detects terminal capabilities (dimensions, color support, Unicode) and degrades gracefully.

**Thread-Safe**: All terminal operations use Swift actors for safe concurrent access.

## 47.2 The Terminal System Object

Templates automatically have access to a `terminal` object containing capability information:

```text
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
```text
Terminal: {{ <terminal: columns> }}×{{ <terminal: rows> }}
Color Support: {{ <terminal: supports_color> }}

{{ Print "=== Detailed Dashboard ===" to the <template> when <terminal: columns> > 120. }}
{{ Print "=== Dashboard ===" to the <template> when <terminal: columns> <= 120. }}
```

There is no `{{when}} … {{else}} … {{end}}` block: the template engine has
exactly four constructs — static text, the expression shorthand `{{ <x> }}`,
a statement block, and the `for each` spanning block of Section 44.6.
Conditionals are ordinary `when` guards on the statements inside a block, so
alternatives are written as mutually exclusive guards, as above. For anything
more branching than that, decide in the feature set and render a different
template — Section 47.7.4 shows the pattern.

This enables responsive terminal designs that adapt to the user's terminal size automatically.

## 47.3 Styling with Template Filters

ARO provides template filters for applying ANSI styling to text. These filters integrate seamlessly with the template engine you learned in Chapter 44.

**Filters apply to a variable reference or to a string literal.**
`{{ <heading> | bold }}` styles the value bound to `heading`, and
`{{ "=== Task List ===" | bold }}` styles the text as written — which is how a
styled heading is usually spelled, and the only reason to put a literal inside
the braces at all. A *bare* literal (`{{ "Heading" }}`) is still not an
expression; static text belongs outside the braces (Section 44.3).

A filtered literal used to be a parse error — `Expected action verb …, but got
string` — because classification required a `<` prefix
([GitLab #568](https://git.ausdertechnik.de/arolang/aro/-/issues/568)). If you
bound headings in the feature set to work around that, both spellings work now:

```aro
Create the <heading> with "=== Task List ===".
Transform the <view> from the <template: task-list.screen>.
```

Static text that needs no styling is simply written as static text; it does not
need a block at all.

### 47.3.1 Color Filters

Apply foreground and background colors using the `color` and `bg` filters:

```text
{{ <success-line> | color: "green" }}
{{ <error-line> | color: "red" }}
{{ <warning-line> | color: "yellow" }}

{{ <highlight> | bg: "blue" }}
{{ <alert> | color: "white" | bg: "red" }}
```

**Named Colors**:
- **Standard**: black, red, green, yellow, blue, magenta, cyan, white
- **Bright**: brightRed, brightGreen, brightBlue, brightCyan, brightYellow, etc.
- **Semantic**: success (green), error (red), warning (yellow), info (blue)

**RGB Colors** (24-bit true color):
```text
{{ <label> | color: "rgb(100, 200, 50)" }}
{{ <panel> | bg: "rgb(30, 30, 30)" }}
```

ARO automatically converts RGB to the best available color mode:
- True color terminals: Use full 24-bit RGB
- 256-color terminals: Convert to closest 256-color
- 16-color terminals: Convert to closest basic color
- No color support: Strip all color codes

### 47.3.2 Style Filters

Apply text styles using simple filters:

```text
{{ <important> | bold }}
{{ <subdued> | dim }}
{{ <emphasis> | italic }}
{{ <link> | underline }}
{{ <removed> | strikethrough }}
```

The seven styling filters above — `color`, `bg`, `bold`, `dim`, `italic`,
`underline`, `strikethrough` — are joined by the value filters `date`,
`uppercase`, `lowercase`, `trim`, `markdown`, `rows`, and `length`:

```aro
Total: {{ <tasks> | length }} tasks     (* elements in a collection *)
{{ <title> | length }}                  (* characters in a string   *)
{{ <tasks> | count }}                    (* the same filter          *)
```

`length` used to be missing from the table, and an unknown filter was skipped
in silence — so `{{ <tasks> | length }}` printed the whole collection with no
diagnostic ([GitLab #568](https://git.ausdertechnik.de/arolang/aro/-/issues/568)).
Counting in the feature set (`Compute the <task-count: length> from <tasks>.`)
still works and is the better choice when the count is used more than once.

### 47.3.3 Chaining Filters

Combine multiple filters for rich formatting:

```text
{{ <status-line> | color: "green" | bold }}
{{ <error-line> | color: "red" | bold | underline }}
{{ <debug-line> | color: "cyan" | dim }}
```

**Example Template (templates/task-list.screen)**:
```text
{{ <heading> | bold | color: "cyan" }}

{{ for each <task> in <tasks> { }}  [{{ <task: id> }}] {{ <task: title> | bold }} - {{ <task: status> | color: "yellow" }}
{{ } }}
Total: {{ <task-count> }} tasks
```

The loop is the `for each` spanning block of Section 44.6 — an opening
`{{ for each <x> in <xs> { }}` and a closing `{{ } }}`, both on lines of their
own. The feature set binds `heading` and `task-count` before rendering.

## 47.4 Reactive Watch Pattern

The Watch pattern is ARO's approach to live-updating terminal UIs. Unlike traditional polling (checking for changes repeatedly), Watch is **purely reactive**—handlers trigger only when actual changes occur.

### 47.4.1 Watch as a Feature Set Pattern

Watch is **not an action**—it's a **feature set pattern** that combines with Handler or Observer patterns:

**Event-Based Watch**:
```aro
(Name Watch: EventType Handler) {
    (* re-render when the event fires *)
    Return an <OK: status> for the <watch>.
}
```

**Repository-Based Watch**:
```aro
(Name Watch: repository Observer) {
    (* re-render when the repository changes *)
    Return an <OK: status> for the <watch>.
}
```

### 47.4.2 Repository Observer Watch

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
    (* No Clear here — the compositor updates the section in place.
       Clear belongs once in Application-Start; see Section 47.6.2. *)
    Retrieve the <tasks> from the <task-repository>.

    (* Render template with fresh data *)
    Transform the <output> from the <template: dashboard.screen>.
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
```text
{{ <heading> | bold | color: "cyan" }}

Active Tasks:

{{ for each <task> in <tasks> { }}  [{{ <task: id> }}] {{ <task: title> | color: "white" }} - {{ <task: status> | color: "yellow" }}
{{ } }}
---
Total: {{ <task-count> }} tasks
Terminal: {{ <terminal: columns> }}×{{ <terminal: rows> }}
```

The handler binds `heading` and `task-count` alongside `tasks` before it calls
`Transform` — static labels stay static text, and anything styled or counted is
a binding.

**Flow**:
1. `Application-Start` stores initial tasks
2. Each `Store` triggers `RepositoryChangedEvent`
3. Watch handler detects event for `task-repository`
4. Handler retrieves fresh tasks
5. Template renders with updated data
6. Output appears in terminal

**Result**: Every time a task is stored/updated/deleted, the dashboard automatically re-renders!

### 47.4.3 Event-Based Watch

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
    (* In real app, you'd extract metrics from event *)
    Transform the <output> from the <template: monitor.screen>.
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

### 47.4.4 Why Watch is Superior to Polling

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
    Return an <OK: status> for the <dashboard>.
}
```

**Benefits**:
- ✅ Zero CPU usage when idle
- ✅ Instant updates when data changes
- ✅ No timers to manage
- ✅ Integrates with event-driven architecture

The Watch pattern is **purely reactive**: handlers execute only when actual changes occur, making it both efficient and responsive.

## 47.5 Terminal Actions

ARO provides actions for terminal interaction and control.

### 47.5.1 Clear Action

Clear the terminal screen or current line:

```aro
Clear the <screen> for the <terminal>.
Clear the <line> for the <terminal>.
```

**Common usage**: Clear before re-rendering in Watch handlers to prevent screen clutter.

### 47.5.2 Prompt Action

Request text input from the user:

```aro
(* Basic input *)
Prompt the <name> from the <terminal>.
Log "Hello, ${name}!" to the <console>.

(* Hidden input for passwords *)
Prompt the <password: hidden> from the <terminal>.
Compute the <length: length> from <password>.
Log "Password is ${length} characters long" to the <console>.
```

The `hidden` specifier disables echo for password entry.

### 47.5.3 Select Action

Display an interactive menu:

```aro
(* Create options *)
Create the <options> with ["Red", "Green", "Blue", "Yellow"].

(* Single selection *)
Select the <choice> from the <options>.
Log "You selected: ${choice}" to the <console>.

(* Multi-selection *)
Select the <choices: multi-select> from the <options>.
Log "You selected: ${choices}" to the <console>.
```

**Current implementation**: Numbered menu with user input.
**Future**: Arrow key navigation, visual cursor, space to toggle.

## 47.6 The Render Action and Section Compositor

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="220" viewBox="0 0 480 220" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowSC" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
  </defs>

  <!-- Terminal window frame -->
  <rect x="20" y="10" width="240" height="200" rx="6" fill="#f9fafb" stroke="#1f2937" stroke-width="2.5"/>
  <!-- Window title bar -->
  <rect x="20" y="10" width="240" height="20" rx="6" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <rect x="20" y="22" width="240" height="8" fill="#1f2937" stroke="none"/>
  <circle cx="36" cy="20" r="4" fill="#ef4444"/>
  <circle cx="52" cy="20" r="4" fill="#f59e0b"/>
  <circle cx="68" cy="20" r="4" fill="#22c55e"/>
  <text x="140" y="24" text-anchor="middle" font-size="9" fill="#9ca3af">terminal</text>

  <!-- Section 1: header -->
  <rect x="28" y="34" width="224" height="24" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1.5"/>
  <text x="140" y="50" text-anchor="middle" font-size="10" font-weight="bold" fill="#4338ca">header</text>

  <!-- Section 2: menu (taller) -->
  <rect x="28" y="62" width="224" height="90" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="140" y="112" text-anchor="middle" font-size="10" font-weight="bold" fill="#92400e">menu</text>
  <text x="140" y="126" text-anchor="middle" font-size="9" fill="#92400e">(main content area)</text>

  <!-- Section 3: status -->
  <rect x="28" y="156" width="224" height="24" rx="3" fill="#d1fae5" stroke="#22c55e" stroke-width="1.5"/>
  <text x="140" y="172" text-anchor="middle" font-size="10" font-weight="bold" fill="#166534">status</text>

  <!-- Arrows pointing to section labels on the right -->
  <line x1="252" y1="46" x2="290" y2="46" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowSC)"/>
  <text x="300" y="44" font-size="9" fill="#374151">renderSection(name:</text>
  <text x="300" y="55" font-size="9" fill="#374151">&quot;header&quot;, content:)</text>

  <line x1="252" y1="107" x2="290" y2="107" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowSC)"/>
  <text x="300" y="105" font-size="9" fill="#374151">renderSection(name:</text>
  <text x="300" y="116" font-size="9" fill="#374151">&quot;menu&quot;, content:)</text>

  <line x1="252" y1="168" x2="290" y2="168" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowSC)"/>
  <text x="300" y="166" font-size="9" fill="#374151">renderSection(name:</text>
  <text x="300" y="177" font-size="9" fill="#374151">&quot;status&quot;, content:)</text>

  <!-- Reflow annotation -->
  <text x="300" y="196" font-size="8" fill="#9ca3af">reflow: section height</text>
  <text x="300" y="207" font-size="8" fill="#9ca3af">change shifts sections below</text>
</svg>
</div>

`Log` appends text to the terminal and moves on. `Render` is different: it manages **named screen sections** and keeps track of where every region lives so re-renders update only what changed—without ever clearing the screen.

```aro
Render the <menu> to the <console>.
Render the <status-bar> to the <console>.
```

The variable name (`menu`, `status-bar`, …) is the **section ID**. The compositor uses it to decide whether this is a new section or an update to an existing one.

### 47.6.1 How the Section Compositor Works

| Situation | What the compositor does |
|---|---|
| First render of `<name>` | Appends below the previous rows |
| Re-render of the same `<name>` | Rewrites only the lines that changed |
| The section grows or shrinks | Shifts every section below it and re-renders them at their new positions |

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

### 47.6.2 Starting Fresh with Clear

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

### 47.6.3 The Content-Area Pattern

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

## 47.7 Keyboard-Driven Interactive UIs

ARO provides first-class support for keyboard-driven applications—menus, editors, dashboards with hotkeys—through the `Listen` action and `KeyPress Handler` feature sets.

### 47.7.1 Starting Keyboard Input

```aro
Listen the <keyboard> to the <stdin>.
```

This puts the terminal in **raw mode**: each key press is delivered immediately, without waiting for Enter. Arrow keys, function keys, and control sequences are all parsed and made available as named keys.

In non-TTY mode (pipes, tests, CI) `Listen` is a silent no-op so applications work identically in both environments.

### 47.7.2 KeyPress Handlers

A `KeyPress Handler` feature set fires whenever a key is pressed. There are two forms:

**Universal handler** — fires on every key press:
```aro
(Navigate Menu: KeyPress Handler) {
    Extract the <key> from the <event: key>.
    (* ... handle the key ... *)
    Return an <OK: status> for the <navigation>.
}
```

**Filtered handler** — fires only when a specific key is pressed:
```aro
(Select Item: KeyPress Handler<key:enter>) { (* ... *) }
(Go Back:     KeyPress Handler<key:backspace>) { (* ... *) }
(Quit App:    KeyPress Handler<key:q>) { (* ... *) }
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

### 47.7.3 Reading the Pressed Key

Inside a universal handler, extract the key name from the event:

```aro
(Navigate Menu: KeyPress Handler) {
    Extract the <pressed-key> from the <event: key>.

    match <pressed-key> {
        case "up"   { (* ... *) }
        case "down" { (* ... *) }
    }

    Return an <OK: status> for the <navigation>.
}
```

### 47.7.4 View State Pattern

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

### 47.7.5 Stopping the Application Cleanly

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

## 47.8 Complete Example: Interactive Menu

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

## 47.9 Complete Example: Live Task Dashboard

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
    Retrieve the <all-tasks> from the <task-repository>.

    (* Filter by status *)
    Filter the <done> from <all-tasks> where <status> = "done".
    Filter the <active> from <all-tasks> where <status> = "in-progress".
    Filter the <pending> from <all-tasks> where <status> = "pending".

    (* Compute statistics *)
    Compute the <done-count: length> from <done>.
    Compute the <progress-count: length> from <active>.
    Compute the <pending-count: length> from <pending>.
    Compute the <total-count: length> from <all-tasks>.

    (* Styled headings are bindings — filters do not apply to literals *)
    Create the <heading> with "TASK DASHBOARD".
    Create the <active-heading> with "In Progress".
    Create the <pending-heading> with "Pending".
    Create the <done-heading> with "Completed".

    (* Render dashboard with statistics — Render, not Log, so the
       compositor rewrites only the lines that changed *)
    Transform the <output> from the <template: dashboard.screen>.
    Render the <output> to the <console>.

    Return an <OK: status> for the <render>.
}

(* Complete a task - triggers reactive update *)
(Complete Task: TaskCompleted Handler) {
    Extract the <task-id> from the <event: taskId>.

    Retrieve the <task> from the <task-repository> where <id> = <task-id>.
    Transform the <completed-task> from the <task> with { status: "done" }.
    Store the <completed-task> into the <task-repository>.

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
```text
╔════════════════════════════════════════════════════════════╗
║ {{ <heading> | bold | color: "cyan" }}
╚════════════════════════════════════════════════════════════╝

Terminal: {{ <terminal: columns> }}×{{ <terminal: rows> }} | Color: {{ <terminal: supports_color> }}

📊 Statistics:
  ✓ Done:        {{ <done-count> | color: "green" }}
  ◷ In Progress: {{ <progress-count> | color: "yellow" }}
  ○ Pending:     {{ <pending-count> | color: "blue" }}
  ━━━━━━━━━━━━━
    Total:       {{ <total-count> | bold }}

🔄 {{ <active-heading> | bold | color: "yellow" }}
{{ for each <task> in <active> { }}    [{{ <task: id> }}] {{ <task: title> | bold }} ({{ <task: priority> | color: "magenta" }})
{{ } }}
📋 {{ <pending-heading> | bold | color: "blue" }}
{{ for each <task> in <pending> { }}    [{{ <task: id> }}] {{ <task: title> }} ({{ <task: priority> | dim }})
{{ } }}
✅ {{ <done-heading> | bold | color: "green" }}
{{ for each <task> in <done> { }}    [{{ <task: id> }}] {{ <task: title> | dim | strikethrough }}
{{ } }}
────────────────────────────────────────────────────────────
Last updated: reactively on data changes
```

Two things to notice. Everything that is *only* text — the box drawing, the
labels, the rule — is static text outside any block; a block containing nothing
but a literal (`{{ "Pending" }}`) does not parse. And the in-progress loop
ranges over `<active>`, the binding the handler made, not over a name the
template invents.

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

## 47.10 Best Practices

### 47.10.1 Responsive Design

Choosing a layout is a branch, and branches belong in the feature set, not in
the template. Read the width from the `terminal` object there and render the
template that fits. `match` is the construct to reach for: guards would each
try to bind `view` and immutability rejects the second one, whereas only one
`case` of a `match` ever runs.

```aro
(Refresh View: layout-repository Observer) {
    Extract the <cols> from the <terminal: columns>.
    Compute the <wide> from <cols> > 120.
    Compute the <medium> from <cols> > 80.

    match <wide> {
        case true  { Transform the <view> from the <template: wide.screen>. }
        case false {
            match <medium> {
                case true  { Transform the <view> from the <template: medium.screen>. }
                case false { Transform the <view> from the <template: narrow.screen>. }
            }
        }
    }

    Render the <view> to the <console>.
    Return an <OK: status> for the <refresh>.
}
```

All three branches bind the same name, so the compositor treats them as one
section (Section 47.6.3) and swaps the layout in place.

### 47.10.2 Graceful Degradation

You rarely need to check `supports_color` at all: when the terminal cannot
display colour, the runtime strips the escape codes, so a styled template
degrades to plain text on its own. Where the difference is the *content* rather
than the styling — Unicode box drawing against ASCII — pick it in the feature
set, the same way as a layout:

```aro
Extract the <unicode> from the <terminal: encoding>.
Compute the <utf8> from <unicode> == "UTF-8".
match <utf8> {
    case true  { Create the <marks> with "✓ ✗ ★ ▶ ◀". }
    case false { Create the <marks> with "* X > <". }
}
```

The `terminal` object exposes `rows`, `columns`, `width`, `height`,
`supports_color`, `supports_true_color`, `is_tty` and `encoding` — that is the
whole set, so capability tests are written against `encoding`, not against a
`supports_unicode` field.

### 47.10.3 Efficient Re-Rendering

`Clear` + `Log` redraws the whole screen every time, and that is the flicker
the section compositor exists to avoid. Prefer `Render`: it diffs the section
against what is already on screen and rewrites only the lines that changed.
`Clear` belongs once, in `Application-Start`, as Section 47.6.2 explains —
inside an observer it throws away the compositor's map of where every section
lives.

```aro
(* Good: Render diffs the section, no clearing *)
(Dashboard Watch: data-repository Observer) {
    Retrieve the <data> from the <data-repository>.
    Transform the <view> from the <template: dashboard.screen>.
    Render the <view> to the <console>.
    Return an <OK: status> for the <render>.
}

(* Also good: Update specific line without clearing *)
(Status Watch: status-repository Observer) {
    (* Don't clear - just update status line *)
    Retrieve the <status> from the <status-repository>.
    Log "Status: ${status}" to the <console>.
    Return an <OK: status> for the <status-line>.
}
```

### 47.10.4 Testing Terminal UIs

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

## 47.11 Platform Support

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

## 47.12 Summary

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
| Color Filter | `{{ <text> | color: "name" }}` | `{{ <error-line> | color: "red" }}` |
| Style Filter | `{{ <text> | style }}` | `{{ <heading> | bold }}` |
| Template Loop | `{{ for each <x> in <xs> { }} … {{ } }}` | Section 47.3.3 |
| Terminal Object | `{{ <terminal: property> }}` | `{{ <terminal: columns> }}` |
| Clear Screen | `Clear the <screen> for the <terminal>.` | once, at startup — Section 47.6.2 |
| Render Section | `Render the <name> to the <console>.` | `name` is the section ID |
| Prompt Input | `Prompt the <input> from the <terminal>.` | - |
| Select Menu | `Select the <choice> from the <options>.` | - |

The Watch pattern is ARO's key innovation: by triggering on actual changes rather than polling, your terminal UIs are both highly responsive and efficient. Combined with template styling and capability detection, you can build professional terminal applications that adapt to any environment.

## What's Next

- **Chapter 44**: The template engine these screens are written in
- **Appendix A**: Complete Action Reference
- **Examples**: `Examples/TerminalSimpleMenu`, `Examples/TerminalTaskManager`,
  `Examples/TerminalSystemMonitor` and `Examples/TerminalUI` are working applications

For more details, see [ARO-0083](../../Proposals/ARO-0083-terminal-ui.md), the Terminal UI proposal.

---

*Next: Chapter 48 — Git Actions*
