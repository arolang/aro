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

---

## Installation

### From VS Code Marketplace

1. Open VS Code
2. Go to Extensions (`Ctrl+Shift+X` / `Cmd+Shift+X`)
3. Search for "ARO Language"
4. Click **Install**

Or install via command line:
```bash
code --install-extension krissimon.aro-language
```

### Install from VSIX Package

If you have a pre-built `.vsix` file:
```bash
code --install-extension aro-language-1.0.0.vsix
```

### Install from Source (Development)

```bash
# Clone the repository
git clone https://github.com/KrisSimon/aro.git
cd aro/Editor/vscode-aro

# Install in VS Code directly from folder
code --install-extension .
```

---

## Building from Source

### Prerequisites

- **Node.js** 18.x or later
- **npm** 9.x or later
- **VS Code** 1.74.0 or later

### Build Steps

```bash
# Navigate to the extension directory
cd Editor/vscode-aro

# Install dependencies
npm install

# Compile TypeScript (if applicable)
npm run compile

# Package as VSIX
npx vsce package

# This creates: aro-language-1.0.0.vsix
```

### Development Mode

To run the extension in development mode with hot reload:

1. Open the `Editor/vscode-aro` folder in VS Code
2. Press `F5` to launch the Extension Development Host
3. Open any `.aro` file to test syntax highlighting and snippets
4. Make changes to grammar or snippets
5. Reload the Extension Development Host (`Ctrl+R` / `Cmd+R`)

### Project Structure

```
vscode-aro/
├── package.json              # Extension manifest
├── language-configuration.json   # Bracket matching, comments
├── syntaxes/
│   └── aro.tmLanguage.json   # TextMate grammar for highlighting
├── snippets/
│   └── aro.code-snippets     # Code snippets
└── README.md                 # This file
```

### Testing the Grammar

1. Open VS Code with the extension loaded
2. Open Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`)
3. Run "Developer: Inspect Editor Tokens and Scopes"
4. Click on tokens in an `.aro` file to verify scopes

---

## Publishing

### To VS Code Marketplace

```bash
# Login to Visual Studio Marketplace
npx vsce login krissimon

# Publish
npx vsce publish
```

### To Open VSX Registry

```bash
npx ovsx publish -p <token>
```

---

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

---

## Troubleshooting

### Syntax highlighting not working

1. Ensure the file has `.aro` extension
2. Check that the extension is enabled
3. Reload VS Code (`Ctrl+Shift+P` > "Developer: Reload Window")

### Snippets not appearing

1. Start typing the snippet prefix (e.g., `featureset`)
2. Press `Ctrl+Space` to trigger IntelliSense
3. Select the snippet and press `Tab`

---

## Related Links

- [ARO Language Website](https://krissimon.github.io/aro/)
- [GitHub Repository](https://github.com/KrisSimon/aro)
- [Language Proposals](https://github.com/KrisSimon/aro/tree/main/Proposals)
- [ARO-0030: IDE Integration Proposal](https://github.com/KrisSimon/aro/blob/main/Proposals/ARO-0030-ide-integration.md)

## License

MIT License
