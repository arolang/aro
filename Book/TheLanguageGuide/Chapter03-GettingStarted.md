# Chapter 3: Getting Started

*"The best way to learn a language is to write something."*

---

## 3.1 Installation

ARO is implemented in Swift and distributed as a command-line tool. The implementation requires Swift 6.2 or later, which means you will need macOS 14 or a recent Linux distribution with Swift installed. On macOS, Xcode 16 provides everything you need. On Linux, you can install Swift from swift.org.

The simplest way to get ARO is to build it from source. Clone the repository and run Swift Package Manager's build command. For development work, a debug build is sufficient and compiles faster. For running applications you intend to deploy, a release build with optimizations produces a significantly smaller and faster binary.

After building, you will find the `aro` executable in the `.build` directory. To use it conveniently from any directory, add this location to your shell's PATH environment variable. Once configured, running `aro --help` should display the available subcommands, confirming that the installation was successful.

The ARO command-line tool provides four primary subcommands. The `run` command compiles and executes an application in a single step, which is what you will use most during development. The `check` command validates source files without running them, useful for catching errors before execution. The `build` command compiles an application to a native binary for deployment. The `compile` command produces intermediate output for tooling integration.

---

## 3.2 Your First Application

ARO applications are directories, not single files. This might seem unusual if you are accustomed to languages where a single source file can be a complete program. The directory-based approach exists because ARO applications typically consist of multiple feature sets spread across several files, and the runtime automatically discovers and loads all of them.

To create an application, start by making a directory. The name you choose becomes the application name. Inside this directory, create a file named `main.aro` that contains your application's entry point.

Every ARO application must have exactly one `Application-Start` feature set. This is where execution begins. The runtime looks for this specific feature set name and executes it when the application launches. Having zero entry points is an error because there would be nothing to run. Having multiple entry points is also an error because the runtime would not know which one to execute first.

A minimal entry point creates a value, does something with it, and returns a status indicating success. The `Create` action produces a new value and binds it to a name. The `Log` action writes output to the console. The `Return` action signals completion. Every feature set should end with a Return action to indicate whether it completed successfully or encountered a problem.

The second part of a feature set declaration, after the colon, is called the business activity. This is a descriptive label that explains what the feature set represents in business terms. For an entry point, common choices include "Entry Point," "Application," "System Initialization," or something more domain-specific like "Order Processing System."

When you run your application using the `aro run` command followed by the path to your application directory, the runtime discovers all ARO source files, compiles them, identifies the entry point, and executes it. If everything works correctly, you see your output and the application terminates. If something goes wrong, you see an error message explaining what happened and where.

---

## 3.3 Understanding Application Structure

The directory-based organization reflects how ARO applications are intended to be structured. A typical application has a main file containing the entry point and lifecycle handlers, plus additional files containing feature sets organized by domain or purpose.

The runtime automatically discovers all files with the `.aro` extension in the application directory. You do not need import statements or explicit file references. When the runtime starts, it scans the directory, parses each file, validates the combined set of feature sets, and registers them with the event bus. This means you can add new feature sets simply by creating new files, and they become available immediately.

The automatic discovery has an important implication: all feature sets are globally visible within an application. A feature set in one file can emit an event that triggers a feature set in another file without any explicit connection between them. This loose coupling is intentional. It allows you to organize code however makes sense for your project without worrying about dependency graphs between files.

There is one constraint on this freedom: exactly one `Application-Start` must exist across all files. The runtime enforces this during startup and reports an error if the constraint is violated. Similarly, you can have at most one `Application-End: Success` for handling graceful shutdown and at most one `Application-End: Error` for handling crash scenarios. See Chapter 10 for complete lifecycle details.

For applications that expose HTTP APIs, you will typically include an `openapi.yaml` file in the application directory. This file defines the API contract using the OpenAPI specification. When present, the runtime uses it to configure HTTP routing, matching incoming requests to feature sets based on operation identifiers defined in the contract. Without this file, no HTTP server starts. This is deliberate: ARO follows a contract-first approach where the API specification drives the implementation rather than the other way around.

---

## 3.4 The Command-Line Interface

The `aro run` command is your primary tool during development. It takes a path to an application directory, compiles all source files, validates the application structure, and executes the entry point. The process is designed to be fast enough that you can iterate quickly, making changes and rerunning to see the effects.

The verbose flag adds detailed output showing what the runtime is doing. You can see which files were discovered, how they were parsed, which feature sets were registered, and how events flow during execution. This visibility is invaluable when debugging issues or understanding how an application behaves.

For servers and other long-running applications, you need to use the Keepalive action to prevent the application from terminating after the entry point completes. Without it, the runtime executes the entry point and exits, which is fine for batch processes but not for services that need to wait for incoming requests.

The `aro check` command validates source files without executing them. Think of it as a sophisticated linter that catches not just syntax errors but also semantic issues like undefined variables, duplicate bindings, and type mismatches. The output categorizes issues as errors, which prevent compilation, and warnings, which indicate potential problems but do not block execution.

Running check before run can save time because compilation errors are often easier to understand when presented in isolation rather than mixed with runtime output. Many developers add a check step to their continuous integration pipelines to catch errors before code is merged.

The `aro build` command compiles an application to a native binary. Unlike interpreted execution with `run`, the build command generates LLVM IR from your ARO source, compiles it to machine code, and links the result with the ARO runtime library. The output is a standalone executable that can run on any compatible system without requiring ARO to be installed.

Native compilation is particularly useful for deployment. The resulting binaries start almost instantaneously because there is no parsing or compilation at runtime. The optimize flag enables compiler optimizations that can significantly improve performance for compute-intensive applications.

---

## 3.5 Development Workflow

A typical development session follows a predictable rhythm. You write or modify code in your editor, run the check command to catch obvious errors, then run the application to verify the behavior. When something does not work as expected, you examine the error message, adjust the code, and repeat.

The error messages are designed to be helpful. Parse errors report the file, line number, and character position where parsing failed, along with an explanation of what was expected. Semantic errors explain what semantic rule was violated and often suggest corrections based on similar identifiers in scope. Runtime errors describe what operation could not be completed, expressed in the business terms of your statements rather than implementation details.

Verbose mode becomes particularly useful when debugging event-driven behavior. Because feature sets communicate through events, it can sometimes be unclear why a particular feature set did or did not execute. The verbose output shows every event emission and every handler invocation, making the flow visible.

As your application grows, you will naturally organize feature sets into separate files. Common patterns include grouping by domain (users.aro, orders.aro), by concern (handlers.aro, notifications.aro), or by layer (api.aro, events.aro). The specific organization matters less than consistency. Choose a pattern that makes sense for your team and stick with it.

---

## 3.6 Error Messages and Debugging

ARO prioritizes readable error messages because debugging time is a significant portion of development effort. The goal is for error messages to tell you not just what went wrong but also where and why, with enough context to fix the problem.

Parse errors occur when the source code does not match the grammar. The parser reports the file, line number, and character position where parsing failed, along with a description of what it expected to find. These errors typically indicate typos, missing punctuation, or malformed statements. The statement structure is so regular that once you internalize it, parse errors become rare.

Semantic errors occur when the source code is syntactically valid but violates a semantic rule. Common examples include referencing a variable that was never defined, attempting to rebind a name that is already bound, or using an action with an incompatible preposition. The analyzer tries to provide helpful context, such as listing similar identifiers that might be what you meant.

Runtime errors occur during execution when an operation cannot be completed. These are described in terms of what the statement was trying to accomplish. If a Retrieve action cannot find the requested record, the error message says so using the names from your code, not internal implementation details. This makes runtime errors easier to understand and correlate with specific statements.

When debugging complex issues, the debug flag provides additional internal information. This includes the state of symbol tables, the contents of events, and the sequence of action executions. This level of detail is rarely needed but can be invaluable when tracking down subtle problems.

---

## 3.7 From Here

You now understand how to install ARO, create applications, and use the command-line tools. You have seen the basic structure of an ARO program and understand why applications are directories rather than single files.

The next chapter examines the syntax of statements in detail, explaining each component of the action-result-object pattern. Understanding this pattern deeply is essential because every statement you write follows it. After that, chapter five covers feature sets, exploring how they are triggered, how they communicate through events, and how they form the building blocks of applications.

The best way to proceed is to experiment. Create a small application, add feature sets, emit events, and observe what happens. The language is designed to be discoverable. If you try something that does not work, the error message should guide you toward what does.

---

*Next: Chapter 4 — Anatomy of a Statement*
