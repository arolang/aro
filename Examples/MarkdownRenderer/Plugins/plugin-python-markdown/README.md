# plugin-python-markdown

A Python plugin for ARO that provides Markdown processing functionality.

## Installation

```bash
aro add git@github.com:arolang/plugin-python-markdown.git
```

## Requirements

- Python 3.9 or later
- No external dependencies (uses only Python standard library)

## Actions

### to-html

Converts Markdown text to HTML.

**Input:**
- `data` (string): Markdown text to convert

**Output:**
- `html`: The generated HTML
- `input_length`: Length of input Markdown
- `output_length`: Length of output HTML

### extract-links

Extracts all links from Markdown text.

**Input:**
- `data` (string): Markdown text to analyze

**Output:**
- `links`: Array of objects with `text` and `url` fields
- `count`: Number of links found

### extract-headings

Extracts all headings from Markdown text.

**Input:**
- `data` (string): Markdown text to analyze

**Output:**
- `headings`: Array of objects with `level` and `text` fields
- `count`: Number of headings found

### word-count

Counts words, characters, and lines in Markdown text.

**Input:**
- `data` (string): Markdown text to analyze

**Output:**
- `words`: Word count
- `characters`: Character count (including spaces)
- `characters_no_spaces`: Character count (excluding spaces)
- `lines`: Line count

## Example Usage in ARO

```aro
(* Convert Markdown to HTML *)
(Convert Markdown: Document Processing) {
    <Extract> the <markdown> from the <request: body>.
    <ToHtml> the <html> with <markdown>.
    <Return> an <OK: status> with <html>.
}

(* Analyze document structure *)
(Analyze Document: Document Processing) {
    <Extract> the <content> from the <document: content>.
    <ExtractHeadings> the <headings> with <content>.
    <ExtractLinks> the <links> with <content>.
    <WordCount> the <stats> with <content>.
    <Create> the <analysis> with {
        "headings": <headings>,
        "links": <links>,
        "stats": <stats>
    }.
    <Return> an <OK: status> with <analysis>.
}
```

## Testing

```bash
python3 src/plugin.py
```

## License

MIT
