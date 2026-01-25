# Chapter 2: Project Setup

*"A journey of a thousand pages begins with a single directory."*

---

## What We Will Learn

- How to install the ARO CLI
- The structure of an ARO application
- Why we organize code into multiple files
- Creating our project directory

---

## 2.1 Installing ARO

ARO applications are built and run using the `aro` command-line tool. Installation depends on your platform.

**macOS (Homebrew):**

```bash
brew install arolang/tap/aro
```

**From Source:**

```bash
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
# The binary is at .build/release/aro
```

**Docker:**

```bash
docker pull ghcr.io/arolang/aro-runtime
```

Verify your installation:

```bash
aro --version
```

You should see a version number. If you see an error, check the [ARO installation guide](https://github.com/arolang/aro#installation).

---

## 2.2 The Architectural Decision

Before writing code, let us consider how to organize our project.

**Our Choice:** A directory with multiple `.aro` files, each containing related feature sets.

**Alternative Considered:** We could put everything in a single file. For a 200-line application, this would work. However, as projects grow, single files become unwieldy. More importantly, multiple files help us organize code by responsibility: one file for crawling, one for link processing, one for storage.

**Why This Approach:** ARO automatically discovers all `.aro` files in a directory. There are no imports to manage. Each file can focus on one aspect of the application, making the code easier to navigate and modify. When we later add features—say, rate limiting or caching—we can add new files without touching existing ones.

---

## 2.3 ARO Application Structure

An ARO application is a **directory** containing `.aro` files. Here is the structure we will build:

```
web-crawler/
├── main.aro          # Application entry point
├── crawler.aro       # Page fetching and parsing
├── links.aro         # Link extraction and filtering
└── storage.aro       # File saving
```

Key rules about ARO applications:

1. **Automatic Discovery.** All `.aro` files in the directory are compiled together. No imports needed.

2. **Single Entry Point.** Exactly one `Application-Start` feature set must exist. This is where execution begins.

3. **Global Feature Sets.** All feature sets are visible to each other through events. A feature set in `storage.aro` can emit an event that a handler in `crawler.aro` receives.

4. **No File Hierarchy.** ARO does not support subdirectories for `.aro` files. Everything lives at the top level.

---

## 2.4 Creating the Project

Let us create our project directory:

```bash
mkdir web-crawler
cd web-crawler
```

Create empty files for our four modules:

```bash
touch main.aro crawler.aro links.aro storage.aro
```

Create an output directory for crawled pages:

```bash
mkdir output
```

Your directory should now look like this:

```
web-crawler/
├── main.aro
├── crawler.aro
├── links.aro
├── storage.aro
└── output/
```

---

## 2.5 Verifying the Setup

Let us add a minimal program to verify everything works. Open `main.aro` and add:

```aro
(Application-Start: Web Crawler) {
    <Log> "Hello from ARO!" to the <console>.
    <Return> an <OK: status> for the <startup>.
}
```

This is the simplest possible ARO application. It defines an `Application-Start` feature set that logs a message and returns successfully.

Run it:

```bash
aro run .
```

You should see:

```
Hello from ARO!
```

If you see this message, your ARO installation is working and your project is ready.

---

## 2.6 What ARO Does Well Here

**Zero Configuration.** We created a directory, added a `.aro` file, and ran it. No build files, no package manifests, no configuration. ARO's convention-over-configuration approach gets you started quickly.

**Clear Entry Point.** The `Application-Start` feature set is self-documenting. Anyone opening this project knows immediately where execution begins.

---

## 2.7 What Could Be Better

**No Package Management.** If we wanted to use someone else's ARO code, we would have to copy-paste it into our directory. A package manager would let us share and reuse code.

**No Dependency Handling.** Related to the above, there is no way to declare that our project depends on specific versions of external code.

---

## Chapter Recap

- ARO applications are directories containing `.aro` files
- All files are automatically discovered; no imports needed
- Exactly one `Application-Start` feature set is required
- We created a four-file project structure organized by responsibility
- The `aro run .` command compiles and executes the application

---

*Next: Chapter 3 - The Entry Point*
