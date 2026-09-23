# Markdown Renderer Example

This example demonstrates how to install and use a Python plugin for Markdown processing.

## Plugin Used

- **plugin-python-markdown**: A Python plugin for Markdown processing
  - Repository: https://github.com/arolang/plugin-python-markdown

## Actions Provided

| Action | Description | Output |
|--------|-------------|--------|
| `to-html` | Convert Markdown to HTML | `{ html: "...", input_length: N, output_length: N }` |
| `extract-links` | Extract all links | `{ links: [...], count: N }` |
| `extract-headings` | Extract document structure | `{ headings: [...], count: N }` |
| `word-count` | Count words, chars, lines | `{ words: N, characters: N, lines: N }` |

## Installation

Install the plugin using the ARO package manager:

```bash
cd Examples/MarkdownRenderer
aro add https://github.com/arolang/plugin-python-markdown.git
```

## Requirements

- Python 3.9 or later

## Building a standalone binary

`aro run` uses the Python on this machine, and that is fine while you are
developing here. `aro build` is a different promise: it produces one file you
can copy to another machine. A Python plugin cannot keep that promise on its
own, so the default build declines rather than hand you a binary that dies at
someone else's startup:

```console
$ aro build ./Examples/MarkdownRenderer
Error: Python plugin(s) 'plugin-python-markdown' cannot be embedded in a standalone binary.
  It needs a CPython interpreter and its standard library, which this build
  resolves from the machine it runs on:
    interpreter: /opt/homebrew/bin/python3
    library:     /opt/homebrew/.../Python
    stdlib:      /opt/homebrew/.../lib/python3.12
  ...
```

Point the build at a CPython it can carry, and it builds:

```bash
ARO_STATIC_PYTHON=/opt/cpython-static aro build ./Examples/MarkdownRenderer
```

```console
Embedding CPython 3.12 from /opt/cpython-static
  Python 3.12 standard library: 615 files, 35.1 MB
Built: ./Examples/MarkdownRenderer/MarkdownRenderer
```

The interpreter is linked in and the standard library lands in
`aro-python3.12/` beside the executable; copy both and it runs anywhere. The
distribution has to be one with a real static `libpython3.12.a` — a
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
download, or CPython configured `--disable-shared`. Homebrew and python.org do
not qualify, and the build says so instead of linking the dynamic library their
`libpython.a` symlink points at.

Two ways out if you do not have one:

```bash
aro build --dynamic ./Examples/MarkdownRenderer   # keeps the dependency, names it
ARO_ALLOW_EMBEDDED_PYTHON=1 aro build ./Examples/MarkdownRenderer  # you own the target's Python
```

See [GitLab #856](https://github.com/arolang/aro/issues/856) and the
[Plugin Guide](../../Book/ThePluginGuide/Chapter03-UsingPlugins.md).

## Expected Output

```
=== Markdown Renderer Demo ===

1. Converting Markdown to HTML...
   <h1>Welcome to ARO</h1>
   <p>This is a <strong>bold</strong> statement...</p>
   ...

2. Extracting links...
   Found links: 2
   [{"text": "ARO Repository", "url": "https://github.com/arolang/aro"}, ...]

3. Extracting headings...
   Document structure:
   [{"level": 1, "text": "Welcome to ARO"}, {"level": 2, "text": "Features"}, ...]

4. Word count statistics...
   Words: 42
   Characters: 320
   Lines: 18

Markdown processing completed!
```

## Use Cases

- Documentation processing
- Blog post rendering
- Static site generation
- Content analysis
