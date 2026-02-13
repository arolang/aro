# plugin-aro-auditlog

A pure ARO plugin that provides event handlers for audit logging.

## Overview

This plugin demonstrates how to create a plugin using only ARO files (no native code). It provides event handlers that automatically log domain events when they are emitted by the application.

## Installation

```bash
aro add https://github.com/arolang/plugin-aro-auditlog.git
```

## Provided Event Handlers

| Event Type | Handler Name | Description |
|------------|--------------|-------------|
| `UserCreated` | Log User Events | Logs when a user is created |
| `OrderPlaced` | Log Order Events | Logs when an order is placed |
| `PaymentReceived` | Log Payment Events | Logs when a payment is received |

## Usage

Once installed, the handlers automatically respond to matching events:

```aro
(Application-Start: My App) {
    (* Emit an event - the plugin handler will automatically respond *)
    <Emit> a <UserCreated: event> with {
        user: { id: "123", name: "Alice" }
    }.

    <Return> an <OK: status> for the <startup>.
}
```

**Output:**
```
[Log User Events] [AUDIT] UserCreated: User created
```

## How It Works

1. The plugin's `plugin.yaml` declares it provides `aro-files`
2. When loaded, the `.aro` files in `features/` are compiled
3. Feature sets with business activity `<EventName> Handler` become event handlers
4. When matching events are emitted, the handlers execute automatically

## Plugin Structure

```
plugin-aro-auditlog/
├── plugin.yaml          # Plugin manifest
├── README.md            # This file
└── features/
    └── audit-handlers.aro   # Event handler definitions
```

## Extending

To add handlers for additional event types, edit `features/audit-handlers.aro`:

```aro
(Log Custom Events: MyCustomEvent Handler) {
    <Extract> the <data> from the <event: data>.
    <Log> "[AUDIT] MyCustomEvent received" to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

## License

MIT
