# Installation

This guide covers installing ARO on macOS, Linux, and Windows, including the requirements for native compilation.

## Quick Install

### macOS (Homebrew)

```bash
brew tap arolang/aro
brew install aro
```

### Linux

```bash
curl -L https://github.com/arolang/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
sudo mv libARORuntime.a /usr/local/lib/
```

### Windows

Download the latest release from [GitHub Releases](https://github.com/arolang/aro/releases):
1. Extract `aro-windows-amd64.zip`
2. Add the extracted directory to your PATH

## Detailed Installation

### What's Included

Each ARO release includes:
- `aro` (or `aro.exe` on Windows) - The ARO CLI
- `libARORuntime.a` - Static runtime library (required for native compilation)

### Installation Modes

ARO has two execution modes with different requirements:

| Mode | Command | Requirements |
|------|---------|--------------|
| **Interpreter** | `aro run ./MyApp` | Just the `aro` binary |
| **Native Compilation** | `aro build ./MyApp` | Additional toolchain (see below) |

---

## Interpreter Mode (aro run)

The interpreter mode requires only the `aro` binary. It executes ARO programs directly without compilation.

### macOS
No additional dependencies. The `aro` binary is self-contained.

### Linux
No additional dependencies. The `aro` binary is self-contained.

### Windows
Requires Swift runtime DLLs in PATH. These are installed automatically with Swift for Windows.

If you see DLL errors, install [Swift for Windows](https://www.swift.org/download/) to get the runtime DLLs.

---

## Native Compilation (aro build)

Native compilation produces standalone executables that don't require ARO or Swift to be installed on the target system. This requires additional toolchain components.

### macOS

#### Requirements
- **LLVM** (provides `llc` for LLVM IR to object file compilation)
- **Xcode Command Line Tools** (provides the system linker)

#### Installation

```bash
# Install LLVM via Homebrew
brew install llvm

# Verify installation
/opt/homebrew/opt/llvm/bin/llc --version
```

The ARO linker automatically finds LLVM in standard Homebrew locations.

#### Verification

```bash
# Test native compilation
mkdir -p HelloWorld
echo '(Application-Start: Hello) {
    <Log> the <message> for the <console> with "Hello from native binary!".
    <Return> an <OK: status> for the <startup>.
}' > HelloWorld/main.aro

aro build ./HelloWorld
./HelloWorld/HelloWorld
```

### Linux

#### Requirements
- **LLVM 14** (provides `llc` for LLVM IR compilation)
- **Clang 14** (used as the linker)
- **Swift runtime libraries** (linked into the binary)

#### Installation (Ubuntu/Debian)

```bash
# Install LLVM and Clang
sudo apt-get update
sudo apt-get install -y llvm-14 clang-14

# Install Swift (if not already installed)
# Download from https://swift.org/download/
# Or use swiftly: https://github.com/swift-server/swiftly

# Verify installation
llc-14 --version
clang-14 --version
```

#### Installation (Fedora/RHEL)

```bash
sudo dnf install llvm clang
```

#### Swift Runtime Libraries

The Swift runtime libraries must be available for linking. If you installed Swift from swift.org, they're typically at:
- `/usr/lib/swift/linux/`
- `/usr/share/swift/usr/lib/swift/linux/`

#### Verification

```bash
# Test native compilation
aro build ./HelloWorld
./HelloWorld/HelloWorld
```

### Windows

#### Requirements
- **LLVM** (provides `clang.exe` for LLVM IR compilation)
- **Visual Studio** or **Build Tools for Visual Studio** (provides MSVC linker)
- **Windows SDK** (provides UCRT and Windows API libraries)
- **Swift for Windows** (provides Swift runtime DLLs)

#### Installation

1. **Install Visual Studio Build Tools**

   Download from [Visual Studio Downloads](https://visualstudio.microsoft.com/downloads/) and select:
   - "Desktop development with C++" workload
   - Windows SDK (usually selected by default)

   Or install via winget:
   ```powershell
   winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
   ```

2. **Install LLVM**

   Download from [LLVM Releases](https://github.com/llvm/llvm-project/releases) or:
   ```powershell
   winget install LLVM.LLVM
   ```

   Ensure `C:\Program Files\LLVM\bin` is in your PATH.

3. **Install Swift for Windows**

   Download from [Swift.org Downloads](https://www.swift.org/download/).

   The installer adds Swift to PATH and sets up environment variables.

4. **Verify Installation**

   ```powershell
   # Check LLVM
   clang --version

   # Check Swift
   swift --version

   # Check Visual Studio (from Developer Command Prompt)
   cl
   ```

#### Environment Variables

The following environment variables are used by ARO's linker (usually set automatically by installers):

| Variable | Purpose | Example |
|----------|---------|---------|
| `SDKROOT` | Swift SDK location | `C:\Users\...\Swift\Platforms\...\Windows.sdk\` |
| `PATH` | Must include Swift runtime DLLs | `...\Swift\Runtimes\...\usr\bin` |

#### Verification

```powershell
# Test native compilation
aro build .\HelloWorld
.\HelloWorld\HelloWorld.exe
```

---

## Build from Source

### Prerequisites (All Platforms)
- **Swift 6.2** or later
- **Git**

### macOS

```bash
# Xcode 16.3+ includes Swift 6.2
xcode-select --install

git clone https://github.com/arolang/aro.git
cd aro
swift build -c release

# Binary at .build/release/aro
# Runtime library at .build/release/libARORuntime.a
```

### Linux

```bash
# Install Swift from https://swift.org/download/
# Or use swiftly: curl -L https://swift-server.github.io/swiftly/swiftly-install.sh | bash

git clone https://github.com/arolang/aro.git
cd aro
swift build -c release

# Binary at .build/release/aro
# Runtime library at .build/release/libARORuntime.a
```

### Windows

```powershell
# Install Swift from https://swift.org/download/

git clone https://github.com/arolang/aro.git
cd aro
swift build -c release

# Binary at .build\release\aro.exe
# Runtime library at .build\release\libARORuntime.a
```

---

## Troubleshooting

### macOS: "llc not found"

Install LLVM:
```bash
brew install llvm
```

If ARO still can't find it, the binary is at `/opt/homebrew/opt/llvm/bin/llc`.

### macOS: Gatekeeper Warning

Official releases are code-signed and notarized. If building from source:
```bash
xattr -d com.apple.quarantine /usr/local/bin/aro
```

### Linux: "swiftrt.o not found"

Ensure Swift is properly installed and the runtime libraries are at `/usr/lib/swift/linux/` or `/usr/share/swift/usr/lib/swift/linux/`.

### Linux: Linker hangs or times out

This can happen with older versions of `swiftc`. ARO uses `clang` as the linker on Linux to avoid this issue. Ensure `clang-14` is installed.

### Windows: "ACCESS_VIOLATION" when running compiled binary

This usually means Swift runtime DLLs aren't in PATH. Ensure Swift for Windows is installed and the runtime bin directory is in PATH:
```
C:\Users\<user>\AppData\Local\Programs\Swift\Runtimes\<version>\usr\bin
```

### Windows: "cannot open input file 'ucrt.lib'"

Install Windows SDK via Visual Studio Installer:
1. Open Visual Studio Installer
2. Modify your installation
3. Ensure "Windows SDK" is selected under Individual Components

### Windows: "unresolved external symbol"

Ensure Visual Studio Build Tools are installed with the C++ workload. The MSVC libraries (vcruntime, msvcrt) are required for linking.

---

## IDE Integration

For the best development experience, install the ARO language extensions:

- **Visual Studio Code**: Search for "ARO Language" in Extensions
- **IntelliJ/WebStorm**: Search for "ARO Language" in Plugins

See [IDE Integration](IDE-Integration) for more details.

---

## Next Steps

- [Getting Started](Getting-Started) - Write your first ARO program
- [Language Guide](https://github.com/arolang/aro/releases/latest/download/ARO-Language-Guide.pdf) - Complete language reference
- [Examples](https://github.com/arolang/aro/tree/main/Examples) - Working example applications
