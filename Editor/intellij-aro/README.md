# ARO Language Support for IntelliJ IDEA

Language support for **ARO** (Action Result Object) - a declarative programming language for expressing business features.

## Features

### Syntax Highlighting

Elegant, semantic syntax highlighting that works beautifully on both light and dark themes. Actions are colored by their **semantic role**:

**Actions by Role:**
- **REQUEST** (External → Internal) - **Blue/Cyan**: `<Extract>`, `<Retrieve>`, `<Fetch>`, `<Read>`, `<Accept>`
- **OWN** (Internal → Internal) - **Purple/Violet**: `<Compute>`, `<Validate>`, `<Compare>`, `<Create>`, `<Transform>`, `<Filter>`
- **RESPONSE** (Internal → External) - **Orange/Red**: `<Return>`, `<Throw>`
- **EXPORT** (Persistence/Export) - **Green/Teal**: `<Publish>`, `<Store>`, `<Log>`, `<Send>`, `<Emit>`, `<Write>`
- **LIFECYCLE** (System Management) - **Cyan**: `<Start>`, `<Stop>`, `<Keepalive>`, `<Watch>`, `<Configure>`
- **TEST** (BDD Testing) - **Yellow/Gold**: `<Given>`, `<When>`, `<Then>`, `<Assert>`

**Other Elements:**
- **Feature set declarations** - Blue feature names, purple business activities
- **Results** - Green (`<result>`, `<user>`, `<data>`)
- **Objects** - Magenta (after prepositions: `<user-repository>`, `<application>`)
- **Prepositions** - Pink (`from`, `to`, `with`, `for`, `where`)
- **Articles** - Subtle gray (`the`, `a`, `an`)
- **Literals** - String and number values
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

### Language Server Protocol (LSP)

The plugin includes LSP support for advanced IDE features:
- Real-time diagnostics (errors and warnings)
- Hover information (types, documentation)
- Go to definition
- Find references
- Code completion
- Document symbols/structure view

---

## Configuration

### ARO Language Server Path

The plugin requires the **ARO CLI** to be installed for LSP features. By default, it looks for `aro` in your system PATH.

#### Configure Custom Path

**Via Settings UI (Recommended)**

1. Open **Settings/Preferences** (`Ctrl+Alt+S` / `Cmd+,`)
2. Navigate to **Tools** → **ARO Language**
3. Click **Browse...** to select the ARO binary
4. Optionally enable **Debug logging**
5. Click **Apply**
6. The language server will restart when you open the next `.aro` file

**Settings Panel Features:**
- **ARO Binary Path** - Full path to the ARO executable
- **Enable debug logging** - Enable verbose LSP communication logs
- Path validation (automatically checks if the binary is valid)

### Installing ARO CLI

If you don't have the ARO CLI installed:

```bash
# Clone the ARO repository
git clone https://github.com/arolang/aro.git
cd aro

# Build the CLI
swift build -c release

# The binary is at: .build/release/aro
# Configure the plugin to use this path in Settings
```

Or add to PATH:
```bash
# Copy to a directory in your PATH
sudo cp .build/release/aro /usr/local/bin/

# Then the plugin will find it automatically
```

### Troubleshooting Configuration

**Language Server fails to start**

If you see a notification like "ARO Language Server not found":

1. Click **"Open Settings"** in the notification
2. Or manually open **Settings** → **Tools** → **ARO Language**
3. Browse to select a valid ARO binary
4. Click **Apply**
5. Verify the binary works: `aro --version` in terminal

**Server not found in PATH**

If you installed ARO in a custom location:

1. Get the full path: `which aro` (macOS/Linux) or `where aro` (Windows)
2. Open **Settings** → **Tools** → **ARO Language**
3. Enter the full path in **ARO Binary Path**
4. Click **Apply**

**Path validation**

The plugin validates paths asynchronously by running `aro --version`. Features:
- **Async validation**: Validation runs in the background without blocking the UI
- **Validation button**: Click "Validate Path" to test your configured binary
- **Result caching**: Validation results are cached to avoid repeated checks
- **Visual feedback**: Green checkmark (✓) for valid paths, red X (✗) for errors

Ensure your binary:
- Exists and is executable
- Is the ARO CLI (not a different binary)
- Outputs "aro version X.Y.Z" format when run with `--version`
- You have permission to execute it

### Security

The plugin validates paths before executing them to ensure security:
- **Command injection prevention**: Paths with suspicious characters (`;`, `|`, `` ` ``, `$`, `<`, `>`) are rejected
- **Path traversal protection**: Paths containing `..` are rejected to prevent directory traversal attacks
- **Canonical path verification**: Paths are resolved to their canonical form to detect traversal attempts
- **Version validation**: Only binaries that output "aro version X.Y.Z" are accepted
- **Executable verification**: Files must exist, be executable, and not be symbolic links to unintended targets

**Important**: Only configure paths to trusted ARO binaries. The plugin executes the binary to validate it.

**Debug logging**

To troubleshoot LSP issues:

1. Open **Settings** → **Tools** → **ARO Language**
2. Enable **Debug logging**
3. Click **Apply**
4. View logs: **Help** → **Show Log in Finder/Explorer** (or `idea.log`)
5. Search for "ARO" to see LSP communication

---

## Installation

### From JetBrains Marketplace

1. Open **Settings/Preferences** (`Ctrl+Alt+S` / `Cmd+,`)
2. Go to **Plugins**
3. Click **Marketplace** tab
4. Search for "ARO Language"
5. Click **Install**
6. Restart the IDE

### Install from Disk

If you have a pre-built plugin ZIP file:

1. Open **Settings/Preferences** (`Ctrl+Alt+S` / `Cmd+,`)
2. Go to **Plugins**
3. Click the gear icon (⚙️) > **Install Plugin from Disk...**
4. Select the `aro-language-1.0.0.zip` file
5. Click **OK** and restart the IDE

### Install from Source

```bash
# Clone the repository
git clone https://github.com/arolang/aro.git
cd aro/Editor/intellij-aro

# Build the plugin
./gradlew buildPlugin

# The plugin ZIP is at: build/distributions/aro-language-1.0.0.zip
```

Then install from disk (see above).

---

## Building from Source

### Prerequisites

- **JDK 17-21** (JDK 21 recommended - JDK 25+ not yet supported by IntelliJ Platform Gradle Plugin)
- **Gradle 8.13** (wrapper included)
- **IntelliJ IDEA** 2024.1 or later (for testing)

On macOS, install Java 21:
```bash
brew install openjdk@21
```

The build uses Java 21 via gradle.properties. If you have a different Java version as default,
the wrapper will use the configured Java 21 path.

### Build Commands

```bash
# Navigate to plugin directory
cd Editor/intellij-aro

# Build the plugin
./gradlew build

# Build plugin distribution (creates ZIP)
./gradlew buildPlugin
# Output: build/distributions/aro-language-1.0.0.zip

# Run plugin in a sandboxed IDE for testing
./gradlew runIde

# Clean build artifacts
./gradlew clean

# Run tests
./gradlew test

# Check for dependency updates
./gradlew dependencyUpdates
```

### Project Structure

```
intellij-aro/
├── build.gradle.kts          # Gradle build configuration
├── settings.gradle.kts       # Gradle settings
├── src/
│   └── main/
│       ├── java/
│       │   └── com/arolang/aro/
│       │       ├── AROTextMateBundleProvider.java   # TextMate bundle provider
│       │       ├── AROTemplateContextType.java      # Live template context
│       │       └── AROLspServerDescriptor.java      # LSP server configuration
│       └── resources/
│           ├── META-INF/
│           │   └── plugin.xml    # Plugin descriptor
│           ├── textmate/
│           │   └── aro.tmLanguage.json   # TextMate grammar
│           └── liveTemplates/
│               └── ARO.xml       # Live templates
└── README.md                 # This file
```

### Development Workflow

1. **Open in IntelliJ IDEA**
   - Open the `intellij-aro` folder as a Gradle project
   - Wait for Gradle sync to complete

2. **Run in Development Mode**
   ```bash
   ./gradlew runIde
   ```
   This launches a sandboxed IntelliJ instance with the plugin installed.

3. **Test Changes**
   - Create or open an `.aro` file
   - Verify syntax highlighting works
   - Test live templates by typing abbreviations

4. **Rebuild After Changes**
   - Modify source files
   - Run `./gradlew buildPlugin`
   - Restart the sandboxed IDE

### Modifying the Grammar

The TextMate grammar is in `src/main/resources/textmate/aro.tmLanguage.json`. To test changes:

1. Edit the grammar file
2. Run `./gradlew runIde`
3. Open an `.aro` file to verify highlighting

### Adding Live Templates

Edit `src/main/resources/liveTemplates/ARO.xml` to add new templates:

```xml
<template name="mytemplate"
          value="&lt;Action&gt; the &lt;$RESULT$&gt;."
          description="My Template">
    <variable name="RESULT" expression="" defaultValue="&quot;result&quot;" alwaysStopAt="true"/>
    <context>
        <option name="ARO" value="true"/>
        <option name="OTHER" value="true"/>
    </context>
</template>
```

---

## Publishing

### To JetBrains Marketplace

1. Create a JetBrains Hub account
2. Generate a Marketplace token
3. Configure credentials:
   ```bash
   export PUBLISH_TOKEN=your_token_here
   ```
4. Publish:
   ```bash
   ./gradlew publishPlugin
   ```

### Signing the Plugin

For signed releases:
```bash
export CERTIFICATE_CHAIN=path/to/chain.crt
export PRIVATE_KEY=path/to/private.pem
export PRIVATE_KEY_PASSWORD=your_password

./gradlew signPlugin
```

---

## Supported IDEs

The plugin works with all JetBrains IDEs based on IntelliJ Platform 2024.1 - 2025.1:

- IntelliJ IDEA (Community and Ultimate)
- WebStorm
- PyCharm
- PhpStorm
- RubyMine
- CLion
- GoLand
- Rider
- Android Studio
- DataGrip
- AppCode

---

## Usage

Create a file with the `.aro` extension and start writing ARO code:

```aro
(* Entry point *)
(Application-Start: My Service) {
    <Log> "Starting..." to the <console>.
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

---

## Troubleshooting

### Syntax highlighting not working

1. Ensure the **TextMate Bundles** plugin is enabled
   - Settings > Plugins > search "TextMate"
2. Verify file has `.aro` extension
3. Invalidate caches: File > Invalidate Caches > Invalidate and Restart

### Live templates not appearing

1. Type the abbreviation (e.g., `fs`)
2. Press `Tab` to expand
3. Or press `Ctrl+J` / `Cmd+J` to see all available templates
4. Check Settings > Editor > Live Templates > ARO

### Plugin not loading

1. Check IDE version is 2023.3 or later
2. Verify TextMate Bundles plugin is installed
3. Check idea.log for errors: Help > Show Log in Finder/Explorer

---

## Related Links

- [ARO Language Website](https://arolang.github.io/aro/)
- [GitHub Repository](https://github.com/arolang/aro)
- [Language Proposals](https://github.com/arolang/aro/tree/main/Proposals)
- [ARO-0030: IDE Integration Proposal](https://github.com/arolang/aro/blob/main/Proposals/ARO-0030-ide-integration.md)

## License

MIT License
