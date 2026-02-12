# plugin-swift-hello

A simple Swift plugin for ARO that provides greeting functionality.

## Installation

```bash
aro add git@github.com:arolang/plugin-swift-hello.git
```

## Actions

### Greet

Generates a personalized greeting.

**Input:**
- `name` (string, optional): Name to greet. Defaults to "World".

**Output:**
- `message`: The greeting message
- `timestamp`: ISO8601 timestamp
- `plugin`: Plugin name

### Farewell

Generates a goodbye message.

**Input:**
- `name` (string, optional): Name to say goodbye to. Defaults to "World".

**Output:**
- `message`: The farewell message
- `timestamp`: ISO8601 timestamp
- `plugin`: Plugin name

## Feature Sets

This plugin also provides ARO feature sets in `features/greetings.aro`:

- **Greet User**: Say hello to someone
- **Farewell User**: Say goodbye to someone

## License

MIT
