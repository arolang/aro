# Contributing to ARO

Thanks for your interest in contributing to ARO! We welcome contributions of all kinds.

## What Can You Contribute?

Anything that makes ARO better! This includes new features, bug fixes, documentation improvements, website updates, examples, tutorials, show & tell projects, language proposals, and ideas. Whether it's a typo fix or a major feature, all contributions are appreciated.

## AI-Assisted Contributions

Using AI tools (like Claude, GitHub Copilot, etc.) to help write code or documentation is totally fine. Just make sure you understand and review what you're submitting.

## Getting Started

```bash
swift build              # Build the project
swift test               # Run all tests
aro run ./Examples/HelloWorld   # Try an example
```

## Making Changes

1. Fork the repository and create a branch
2. Keep your changes focused and atomic
3. Run `swift test` before submitting
4. All types should be `Sendable` for Swift 6.2 concurrency

## Pull Requests

- Write a clear description of what your PR does
- Link any related issues
- Add tests for new features

## Need Help?

Open an issue at [github.com/KrisSimon/ARO-Lang/issues](https://github.com/KrisSimon/ARO-Lang/issues)
