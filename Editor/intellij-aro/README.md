# ARO Language Support for IntelliJ IDEA

Language support for **ARO** (Action Result Object) - a declarative programming language for expressing business features.

## Features

### Syntax Highlighting

Full TextMate-based syntax highlighting for ARO code including:
- **Feature set declarations** - Blue feature names, purple business activities
- **Actions** - Orange action verbs (`<Extract>`, `<Create>`, `<Return>`, etc.)
- **Results and Objects** - Green results, cyan objects
- **Prepositions** - Yellow (`from`, `to`, `with`, `for`)
- **Articles** - Gray (`the`, `a`, `an`)
- **Literals** - Brown strings, magenta numbers
- **Comments** - Gray/italic `(* ... *)`

### Live Templates (Code Snippets)

Quick templates for common ARO patterns. Type the abbreviation and press Tab:

| Abbreviation | Description |
|--------------|-------------|
| `fs` | Create a feature set |
| `appstart` | Application-Start entry point |
| `appendsuccess` | Application-End: Success handler |
| `appenderror` | Application-End: Error handler |
| `http` | HTTP route handler |
| `event` | Event handler |
| `test` | BDD test feature set |
| `extract` | Extract action |
| `retrieve` | Retrieve action |
| `create` | Create action |
| `compute` | Compute action |
| `returnok` | Return OK status |
| `returncreated` | Return Created status |
| `log` | Log action |
| `emit` | Emit event |
| `keepalive` | Keepalive action |
| `given` | Test Given |
| `when` | Test When |
| `then` | Test Then |
| `comment` | Block comment |

### File Association

Automatically associates `.aro` files with ARO language support.

## Installation

### From JetBrains Marketplace

1. Open Settings/Preferences
2. Go to Plugins
3. Search for "ARO Language"
4. Click Install
5. Restart the IDE

### Manual Installation

```bash
# Clone the repository
git clone https://github.com/krissimon/aro.git
cd aro/Editor/intellij-aro

# Build the plugin
./gradlew buildPlugin

# The plugin ZIP will be in build/distributions/
```

Then install from disk:
1. Open Settings/Preferences > Plugins
2. Click gear icon > "Install Plugin from Disk..."
3. Select the built `.zip` file
4. Restart the IDE

## Building

Requirements:
- JDK 17 or later
- Gradle 8.x

```bash
# Build
./gradlew build

# Build plugin distribution
./gradlew buildPlugin

# Run in development IDE
./gradlew runIde
```

## Supported IDEs

- IntelliJ IDEA (Community and Ultimate)
- WebStorm
- PyCharm
- PhpStorm
- RubyMine
- CLion
- GoLand
- Rider
- Android Studio

## Usage

Create a file with the `.aro` extension and start writing ARO code:

```aro
(* Entry point *)
(Application-Start: My Service) {
    <Log> the <startup: message> for the <console> with "Starting...".
    <Start> the <http-server> on <port> with 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* HTTP route handler *)
(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(* Test *)
(add-numbers-test: Calculator Test) {
    <Given> the <a> with 5.
    <Given> the <b> with 3.
    <When> the <sum> from the <add-numbers>.
    <Then> the <sum> with 8.
}
```

## Related Links

- [ARO Language Website](https://krissimon.github.io/aro/)
- [GitHub Repository](https://github.com/krissimon/aro)
- [Language Proposals](https://github.com/krissimon/aro/tree/main/Proposals)

## License

MIT License
