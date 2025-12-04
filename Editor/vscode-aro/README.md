# ARO Language Support for Visual Studio Code

Language support for **ARO** (Action Result Object) - a declarative programming language for expressing business features.

## Features

### Syntax Highlighting

Full syntax highlighting for ARO code including:
- **Feature set declarations** - Blue feature names, purple business activities
- **Actions** - Orange action verbs (`<Extract>`, `<Create>`, `<Return>`, etc.)
- **Results and Objects** - Green results, cyan objects
- **Prepositions** - Yellow (`from`, `to`, `with`, `for`)
- **Articles** - Gray (`the`, `a`, `an`)
- **Literals** - Brown strings, magenta numbers
- **Comments** - Gray/italic `(* ... *)`

### Code Snippets

Quick snippets for common ARO patterns. Type the prefix and press Tab:

| Prefix | Description |
|--------|-------------|
| `featureset` | Create a feature set |
| `appstart` | Application-Start entry point |
| `appendsuccess` | Application-End: Success handler |
| `appenderror` | Application-End: Error handler |
| `httphandler` | HTTP route handler |
| `eventhandler` | Event handler |
| `test` | BDD test feature set |
| `extract` | Extract action |
| `retrieve` | Retrieve action |
| `create` | Create action |
| `compute` | Compute action |
| `returnok` | Return OK status |
| `emit` | Emit event |
| `given` | Test Given |
| `when` | Test When |
| `then` | Test Then |
| `keepalive` | Keepalive action |

### Bracket Matching

Automatic matching for:
- `{ }` - Feature set bodies
- `( )` - Feature set declarations
- `< >` - Actions, results, objects
- `" "` - String literals

### Comment Toggling

- Block comments: `(* ... *)`
- Use `Ctrl+Shift+A` (Windows/Linux) or `Cmd+Shift+A` (Mac) to toggle block comments

### Code Folding

Fold feature set bodies for better navigation in large files.

## Installation

### From VS Code Marketplace

1. Open VS Code
2. Go to Extensions (Ctrl+Shift+X)
3. Search for "ARO Language"
4. Click Install

### Manual Installation

```bash
# Clone the repository
git clone https://github.com/krissimon/aro.git
cd aro/Editor/vscode-aro

# Install as local extension
code --install-extension .
```

### From VSIX Package

```bash
code --install-extension aro-language-1.0.0.vsix
```

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

## File Association

The extension automatically associates with:
- `*.aro` - ARO source files

## Related Links

- [ARO Language Website](https://krissimon.github.io/aro/)
- [GitHub Repository](https://github.com/krissimon/aro)
- [Language Proposals](https://github.com/krissimon/aro/tree/main/Proposals)

## License

MIT License
