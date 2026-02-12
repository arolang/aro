# Chapter 15: Publishing Plugins

> *"The purpose of software engineering is to control complexity, not to create it."*
> — Pamela Zave

You've written a plugin, tested it thoroughly, and it works beautifully. Now comes the final step: sharing it with the world. This chapter covers everything from repository structure to documentation standards, versioning strategies to community engagement. Publishing well is an act of respect—for your users, for your future self, and for the ARO ecosystem you're helping to build.

## 15.1 Repository Structure

A well-organized repository makes your plugin approachable. Users can find what they need quickly, contributors can understand the codebase, and automated tools can do their job.

### The Standard Layout

```
my-plugin/
├── README.md              # First thing users see
├── LICENSE                # Legal terms
├── CHANGELOG.md           # Version history
├── CONTRIBUTING.md        # How to contribute
├── plugin.yaml            # ARO manifest
├── src/                   # Source code
│   └── ...
├── tests/                 # Test files
│   ├── unit/
│   └── integration/
├── examples/              # Usage examples
│   └── basic-usage.aro
├── docs/                  # Additional documentation
│   └── api.md
└── .github/               # GitHub-specific files
    ├── workflows/
    │   └── test.yml
    └── ISSUE_TEMPLATE/
```

### The README

Your README is your plugin's front door. It should answer:

1. **What**: What does this plugin do?
2. **Why**: Why would someone use it?
3. **How**: How do I install and use it?

A template:

```markdown
# plugin-name

Brief description of what the plugin does and why it's useful.

## Installation

```bash
aro add github.com/username/plugin-name
```

## Quick Start

```aro
(* Example usage *)
<Call> the <result> from the <my-plugin: action> with { arg: "value" }.
```

## Features

- Feature one
- Feature two
- Feature three

## Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `timeout` | number | 30 | Request timeout in seconds |

## Actions

### actionName

Description of what the action does.

**Arguments:**
- `arg1` (string, required): Description
- `arg2` (number, optional): Description

**Returns:**
```json
{
  "result": "value"
}
```

**Example:**
```aro
<Call> the <result> from the <my-plugin: actionName> with {
    arg1: "value"
}.
```

## Requirements

- ARO >= 0.9.0
- (Any external dependencies)

## License

MIT License - see LICENSE file
```

### The CHANGELOG

Track every meaningful change:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- New feature in progress

## [1.2.0] - 2024-12-20

### Added
- New `validatePhone` action with international format support
- Locale parameter for all validation actions

### Changed
- Improved error messages with specific validation failure reasons

### Fixed
- Email validation now correctly handles plus-addressing (user+tag@domain.com)

## [1.1.0] - 2024-11-15

### Added
- `validateURL` action
- Custom regex patterns via `pattern` argument

### Changed
- Default timeout increased from 10s to 30s

## [1.0.0] - 2024-10-01

### Added
- Initial release
- `validateEmail` action
- `validatePassword` action with strength checking
```

## 15.2 Versioning Strategy

Version numbers communicate compatibility. ARO plugins use [Semantic Versioning](https://semver.org/):

```
MAJOR.MINOR.PATCH

1.2.3
│ │ └── Patch: bug fixes, no API changes
│ └──── Minor: new features, backward compatible
└────── Major: breaking changes
```

### When to Bump Versions

**Patch (1.0.0 → 1.0.1):**
- Bug fixes
- Performance improvements
- Documentation updates
- Internal refactoring (no API changes)

**Minor (1.0.0 → 1.1.0):**
- New actions added
- New optional arguments
- New configuration options
- Deprecation warnings (not removals)

**Major (1.0.0 → 2.0.0):**
- Removed actions or arguments
- Changed argument types or semantics
- Changed return value structure
- Changed error codes or messages (if code depends on them)

### Pre-release Versions

Use pre-release suffixes for unstable versions:

```
1.0.0-alpha.1    # Very early, expect changes
1.0.0-beta.1     # Feature complete, testing
1.0.0-rc.1       # Release candidate
```

### ARO Version Compatibility

Declare which ARO versions your plugin supports:

```yaml
# plugin.yaml
aro-version: ">=0.9.0 <2.0.0"
```

Common patterns:
- `>=0.9.0`: Works with 0.9.0 and all future versions
- `>=0.9.0 <1.0.0`: Works only with 0.9.x versions
- `^0.9.0`: Works with 0.9.x (equivalent to >=0.9.0 <0.10.0)
- `~0.9.0`: Works with 0.9.x patch releases (equivalent to >=0.9.0 <0.10.0)

## 15.3 Documentation Standards

Good documentation has layers—quick reference for experts, detailed guides for learners.

### API Documentation

Document every action thoroughly:

```markdown
## Actions

### validateEmail

Validates an email address according to RFC 5322 standards.

**Syntax:**
```aro
<Call> the <result> from the <validation: validateEmail> with {
    email: <email-string>,
    allowPlusAddressing: true,
    allowSubdomains: true
}.
```

**Arguments:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `email` | string | Yes | - | The email address to validate |
| `allowPlusAddressing` | boolean | No | `true` | Allow user+tag@domain.com format |
| `allowSubdomains` | boolean | No | `true` | Allow user@sub.domain.com |
| `maxLength` | number | No | `254` | Maximum allowed email length |

**Returns:**

```json
{
  "valid": true,
  "normalized": "user@example.com",
  "parts": {
    "local": "user",
    "domain": "example.com"
  }
}
```

Or on validation failure:

```json
{
  "valid": false,
  "errors": [
    {
      "code": "INVALID_DOMAIN",
      "message": "Domain does not have valid MX records"
    }
  ]
}
```

**Error Codes:**

| Code | Description |
|------|-------------|
| `INVALID_FORMAT` | Email doesn't match basic format |
| `INVALID_LOCAL` | Local part contains invalid characters |
| `INVALID_DOMAIN` | Domain is malformed |
| `TOO_LONG` | Email exceeds maximum length |

**Examples:**

Basic validation:
```aro
<Call> the <result> from the <validation: validateEmail> with {
    email: "user@example.com"
}.
<When> <result: valid> is false:
    <Log> "Invalid email: " ++ <result: errors 0 message> to the <console>.
```

Strict validation:
```aro
<Call> the <result> from the <validation: validateEmail> with {
    email: <user-input>,
    allowPlusAddressing: false,
    maxLength: 100
}.
```
```

### Examples Directory

Provide working examples for common use cases:

```
examples/
├── basic-usage.aro           # Minimal example
├── form-validation.aro       # Complete form validation
├── api-integration.aro       # Using with HTTP services
└── advanced-patterns.aro     # Complex scenarios
```

Each example should be runnable:

```aro
(* examples/form-validation.aro *)
(* Complete form validation example *)

(Application-Start: Form Validation Demo) {
    <Log> "Form Validation Demo" to the <console>.
    <Log> "===================" to the <console>.

    (* Sample user registration data *)
    <Create> the <form-data> with {
        email: "user@example.com",
        password: "SecureP@ss123",
        phone: "+1-555-123-4567",
        website: "https://mysite.com"
    }.

    (* Validate each field *)
    <Call> the <email-result> from the <validation: validateEmail> with {
        email: <form-data: email>
    }.
    <Log> "Email: " ++ <form-data: email> ++ " -> " ++
          (if <email-result: valid> then "Valid" else "Invalid")
          to the <console>.

    <Call> the <password-result> from the <validation: validatePassword> with {
        password: <form-data: password>,
        minLength: 8,
        requireUppercase: true,
        requireSpecial: true
    }.
    <Log> "Password: " ++
          (if <password-result: valid> then "Strong" else "Weak")
          to the <console>.

    <Call> the <phone-result> from the <validation: validatePhone> with {
        phone: <form-data: phone>,
        locale: "US"
    }.
    <Log> "Phone: " ++ <form-data: phone> ++ " -> " ++
          (if <phone-result: valid> then "Valid" else "Invalid")
          to the <console>.

    <Call> the <url-result> from the <validation: validateURL> with {
        url: <form-data: website>
    }.
    <Log> "Website: " ++ <form-data: website> ++ " -> " ++
          (if <url-result: valid> then "Valid" else "Invalid")
          to the <console>.

    <Return> an <OK: status> for the <demo>.
}
```

## 15.4 Publishing to Git Repositories

ARO's package manager installs plugins directly from Git repositories.

### Repository Requirements

Your repository must have:
1. A `plugin.yaml` at the root
2. All source files in the declared paths
3. Git tags for versions

### Tagging Releases

Use Git tags for versioning:

```bash
# Create a release
git add .
git commit -m "Release 1.2.0"
git tag -a v1.2.0 -m "Version 1.2.0"
git push origin main --tags

# Users install specific versions
aro add github.com/username/my-plugin@v1.2.0
```

### GitHub Release Workflow

Create releases with release notes:

```yaml
# .github/workflows/release.yml

name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Plugin
        run: ./build.sh

      - name: Run Tests
        run: ./run-tests.sh

      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          generate_release_notes: true
          files: |
            dist/*.dylib
            dist/*.so
            dist/*.dll
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Private Repositories

For private plugins, users authenticate via Git:

```bash
# SSH authentication (recommended)
aro add git@github.com:company/private-plugin.git

# HTTPS with token
aro add https://token:x-oauth-basic@github.com/company/private-plugin.git
```

## 15.5 Community Guidelines

Building a friendly ecosystem means being a good community member.

### Code of Conduct

Include a CODE_OF_CONDUCT.md:

```markdown
# Code of Conduct

## Our Pledge

We pledge to make participation in our project a harassment-free experience
for everyone, regardless of age, body size, disability, ethnicity, gender
identity, level of experience, nationality, personal appearance, race,
religion, or sexual identity and orientation.

## Our Standards

Examples of behavior that contributes to a positive environment:

* Using welcoming and inclusive language
* Being respectful of differing viewpoints and experiences
* Gracefully accepting constructive criticism
* Focusing on what is best for the community

Examples of unacceptable behavior:

* Trolling, insulting/derogatory comments, and personal attacks
* Public or private harassment
* Publishing others' private information without explicit permission

## Enforcement

Project maintainers are responsible for clarifying the standards of acceptable
behavior and are expected to take appropriate and fair corrective action in
response to any instances of unacceptable behavior.
```

### Contributing Guidelines

Make it easy for others to contribute:

```markdown
# Contributing

Thank you for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR-USERNAME/plugin-name`
3. Create a branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `./run-tests.sh`
6. Commit: `git commit -m "Add your feature"`
7. Push: `git push origin feature/your-feature`
8. Create a Pull Request

## Development Setup

```bash
# Install dependencies
./setup-dev.sh

# Build
./build.sh

# Run tests
./run-tests.sh
```

## Pull Request Guidelines

- Keep changes focused and atomic
- Include tests for new functionality
- Update documentation as needed
- Follow existing code style
- Write clear commit messages

## Reporting Issues

Please include:
- ARO version (`aro --version`)
- Plugin version
- Operating system
- Steps to reproduce
- Expected vs actual behavior
```

### Responding to Issues

Be welcoming and helpful:

```markdown
<!-- Good response template -->

Thanks for reporting this issue!

I can reproduce the problem on [version/platform]. Here's what I found:

[Technical details]

I'll work on a fix. In the meantime, you can work around this by:

[Workaround]

---

<!-- For questions -->

Thanks for your question! Here's how to do that:

[Answer with code example]

Let me know if this helps or if you have follow-up questions.

---

<!-- For feature requests -->

Thanks for the suggestion! This is an interesting idea.

Before implementing, I'd like to understand the use case better:
- What problem are you trying to solve?
- How would you expect this to work in your code?

This will help me design the feature to fit your needs.
```

## 15.6 Maintenance and Long-term Support

Publishing is the beginning, not the end.

### Responding to Security Issues

Handle security responsibly:

1. **Enable security advisories** in your repository settings
2. **Respond quickly** to security reports (within 48 hours)
3. **Coordinate disclosure** - fix before announcing
4. **Issue CVEs** for serious vulnerabilities

Create a SECURITY.md:

```markdown
# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x.x   | :white_check_mark: |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

Please report security vulnerabilities to security@yourproject.dev.

Do NOT create public GitHub issues for security vulnerabilities.

We will acknowledge your report within 48 hours and provide a detailed
response within 7 days indicating next steps.

We ask that you:
- Allow us reasonable time to fix the issue before public disclosure
- Make a good faith effort to avoid privacy violations, data destruction,
  and interruption of services
```

### Deprecation Strategy

When removing features, give users time to migrate:

```yaml
# plugin.yaml - Version 1.3.0
deprecations:
  - action: oldActionName
    message: "Use newActionName instead. Will be removed in 2.0.0"
    replacement: newActionName
```

```markdown
<!-- CHANGELOG -->
## [1.3.0] - 2024-12-20

### Deprecated
- `oldActionName` is deprecated. Use `newActionName` instead.
  Will be removed in version 2.0.0.
```

### Abandonment

If you can no longer maintain a plugin:

1. **Archive the repository** - keeps it available but signals no maintenance
2. **Update README** - add a notice at the top
3. **Transfer ownership** - if someone wants to continue maintaining
4. **Suggest alternatives** - point users to similar plugins

```markdown
# ⚠️ This project is no longer maintained

This plugin is no longer actively maintained. For alternatives, see:
- [plugin-alternative-1](https://github.com/...)
- [plugin-alternative-2](https://github.com/...)

The code remains available under the MIT license.
Feel free to fork if you'd like to continue development.
```

## 15.7 Building Your Reputation

Quality plugins build trust in the ecosystem.

### Quality Signals

Users look for:

- **Active maintenance**: Recent commits, responses to issues
- **Good documentation**: Clear README, examples, API docs
- **Test coverage**: CI badges, test status
- **Community adoption**: Stars, forks, dependent projects
- **Responsive maintainer**: Issue response time, PR reviews

Add badges to your README:

```markdown
[![Tests](https://github.com/user/plugin/actions/workflows/test.yml/badge.svg)](...)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](...)
[![ARO Plugin](https://img.shields.io/badge/ARO-Plugin-blue)](...)
```

### Getting Featured

To increase visibility:

1. **Solve real problems**: Plugins that address common needs get adopted
2. **Document thoroughly**: Good docs make plugins accessible
3. **Engage with the community**: Help others, answer questions
4. **Share on forums**: Announce on ARO community channels
5. **Write tutorials**: Blog posts showing your plugin in action

## Summary

Publishing a plugin is an act of generosity—you're sharing your work to help others solve problems. Do it well:

- **Structure your repository** for discoverability and clarity
- **Version semantically** so users know what to expect
- **Document thoroughly** with examples and API references
- **Test comprehensively** and show your CI status
- **Engage with your community** responsively and respectfully
- **Maintain responsibly** or hand off gracefully

The ARO ecosystem grows stronger with every well-crafted plugin. Your contribution matters—not just the code, but how you share it. A plugin published with care becomes part of something larger: a community of developers helping each other build better software.

Thank you for contributing to the ARO ecosystem.
