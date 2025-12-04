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
git clone https://github.com/KrisSimon/aro.git
cd aro/Editor/intellij-aro

# Build the plugin
./gradlew buildPlugin

# The plugin ZIP is at: build/distributions/aro-language-1.0.0.zip
```

Then install from disk (see above).

---

## Building from Source

### Prerequisites

- **JDK 17** or later (JDK 21 recommended)
- **Gradle 8.x** (wrapper included)
- **IntelliJ IDEA** 2023.3 or later (for testing)

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
│       │   └── com/krissimon/aro/
│       │       ├── AROTextMateBundleProvider.java   # TextMate bundle provider
│       │       └── AROTemplateContextType.java      # Live template context
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

The plugin works with all JetBrains IDEs based on IntelliJ Platform 2023.3+:

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

- [ARO Language Website](https://krissimon.github.io/aro/)
- [GitHub Repository](https://github.com/KrisSimon/aro)
- [Language Proposals](https://github.com/KrisSimon/aro/tree/main/Proposals)
- [ARO-0030: IDE Integration Proposal](https://github.com/KrisSimon/aro/blob/main/Proposals/ARO-0030-ide-integration.md)

## License

MIT License
