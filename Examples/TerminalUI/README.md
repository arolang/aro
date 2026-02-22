# Terminal UI Examples

Examples demonstrating ARO's Terminal UI capabilities (ARO-0052).

## Overview

ARO provides template-based terminal UI capabilities, allowing you to build beautiful, responsive terminal applications using natural language syntax.

**Key Features:**
- **Template-First**: Define UIs in `.screen` template files
- **Responsive**: Automatically adapts to terminal dimensions
- **Declarative**: Describe appearance, not ANSI codes
- **Interactive**: Built-in support for keyboard input, menus, and prompts

## Examples

### 1. TaskManager

An interactive task management application with live updates.

**Features:**
- Live-updating dashboard using `Watch` action
- Color-coded status indicators
- Responsive table layout
- Keyboard shortcuts for adding, completing, and deleting tasks

**Run:**
```bash
aro run Examples/TerminalUI/TaskManager
```

**Commands:**
- `a` - Add new task
- `c` - Mark task complete
- `d` - Delete task
- `q` - Quit

### 2. SystemMonitor

A real-time system monitoring dashboard.

**Features:**
- Live metrics updated every second
- Progress bars for CPU, memory, disk usage
- Responsive layout (two-column for wide terminals, single column for narrow)
- Panel-based layout system

**Run:**
```bash
aro run Examples/TerminalUI/SystemMonitor
```

**Controls:**
- `Ctrl+C` - Exit

### 3. SimpleMenu

An interactive menu selection system.

**Features:**
- `Select` action for menu navigation
- Multiple template screens
- Color-coded status messages
- Simple navigation with arrow keys

**Run:**
```bash
aro run Examples/TerminalUI/SimpleMenu
```

**Controls:**
- Arrow keys - Navigate menu
- Enter - Select option

## Template Capabilities

### Terminal System Object

Access terminal properties in templates:

```aro
{{ terminal.rows }}         (* Terminal height *)
{{ terminal.columns }}      (* Terminal width *)
{{ terminal.supports_color }}
```

### Styling Directives

```aro
{{ color red }}            (* Foreground color *)
{{ bg blue }}              (* Background color *)
{{ bold }}                 (* Bold text *)
{{ reset }}                (* Reset all styles *)
```

### Widgets

```aro
{{ box border="rounded" title="Status" }}
  Content here
{{ endbox }}

{{ progress value=0.75 width=40 }}

{{ table headers=["Name", "Status"] }}
  ...
{{ endtable }}
```

### Layout

```aro
{{ panel orientation="horizontal" }}
  {{ section width="50%" }}
    Left panel
  {{ endsection }}
  {{ section width="50%" }}
    Right panel
  {{ endsection }}
{{ endpanel }}
```

## Actions

### Watch - Live Updates

Renders a template repeatedly at specified intervals:

```aro
Watch the <dashboard> from "monitor.screen"
      with <metrics>
      every 1 second
      to the <terminal>.
```

### Render - One-Time Display

Renders a template once:

```aro
Render the <view> from "welcome.screen"
       to the <terminal>.
```

### Prompt - User Input

Gets text input from the user:

```aro
Prompt the <name> with "Enter name: " from the <terminal>.
```

### Select - Menu Selection

Interactive menu selection:

```aro
Select the <choice> from <options>
       with "Choose an option:"
       from the <terminal>.
```

## See Also

- [ARO-0052 Proposal](../../Proposals/ARO-0052-terminal-ui.md) - Full specification
- [ARO-0050 Template Engine](../../Proposals/ARO-0050-template-engine.md) - Template syntax reference
