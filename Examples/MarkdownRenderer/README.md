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
