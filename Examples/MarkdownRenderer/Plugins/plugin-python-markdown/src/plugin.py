"""
ARO Plugin - Python Markdown Processor

This plugin provides Markdown processing functionality for ARO.
It implements the ARO Python plugin interface.
"""

import json
import re
from typing import Any, Dict, List


def aro_plugin_info() -> Dict[str, Any]:
    """Return plugin metadata."""
    return {
        "name": "plugin-python-markdown",
        "version": "1.0.0",
        "actions": ["to-html", "extract-links", "extract-headings", "word-count"]
    }


def aro_action_to_html(input_json: str) -> str:
    """Convert Markdown to HTML."""
    params = json.loads(input_json)
    markdown = params.get("data", params.get("object", ""))

    html = markdown_to_html(markdown)

    return json.dumps({
        "html": html,
        "input_length": len(markdown),
        "output_length": len(html)
    })


def aro_action_extract_links(input_json: str) -> str:
    """Extract all links from Markdown text."""
    params = json.loads(input_json)
    markdown = params.get("data", params.get("object", ""))

    links = extract_links(markdown)

    return json.dumps({
        "links": links,
        "count": len(links)
    })


def aro_action_extract_headings(input_json: str) -> str:
    """Extract all headings from Markdown text."""
    params = json.loads(input_json)
    markdown = params.get("data", params.get("object", ""))

    headings = extract_headings(markdown)

    return json.dumps({
        "headings": headings,
        "count": len(headings)
    })


def aro_action_word_count(input_json: str) -> str:
    """Count words, characters, and lines in Markdown text."""
    params = json.loads(input_json)
    markdown = params.get("data", params.get("object", ""))

    # Remove Markdown syntax for accurate word count
    plain_text = strip_markdown(markdown)

    words = len(plain_text.split())
    chars = len(plain_text)
    chars_no_spaces = len(plain_text.replace(" ", "").replace("\n", ""))
    lines = len(markdown.split("\n"))

    return json.dumps({
        "words": words,
        "characters": chars,
        "characters_no_spaces": chars_no_spaces,
        "lines": lines
    })


# MARK: - Markdown Processing Functions

def markdown_to_html(markdown: str) -> str:
    """Convert Markdown to HTML (simple implementation)."""
    html = markdown

    # Headers
    html = re.sub(r'^######\s+(.+)$', r'<h6>\1</h6>', html, flags=re.MULTILINE)
    html = re.sub(r'^#####\s+(.+)$', r'<h5>\1</h5>', html, flags=re.MULTILINE)
    html = re.sub(r'^####\s+(.+)$', r'<h4>\1</h4>', html, flags=re.MULTILINE)
    html = re.sub(r'^###\s+(.+)$', r'<h3>\1</h3>', html, flags=re.MULTILINE)
    html = re.sub(r'^##\s+(.+)$', r'<h2>\1</h2>', html, flags=re.MULTILINE)
    html = re.sub(r'^#\s+(.+)$', r'<h1>\1</h1>', html, flags=re.MULTILINE)

    # Bold and italic
    html = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', html)
    html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html)
    html = re.sub(r'\*(.+?)\*', r'<em>\1</em>', html)

    # Links
    html = re.sub(r'\[(.+?)\]\((.+?)\)', r'<a href="\2">\1</a>', html)

    # Images
    html = re.sub(r'!\[(.+?)\]\((.+?)\)', r'<img src="\2" alt="\1">', html)

    # Code blocks
    html = re.sub(r'```(\w*)\n(.*?)\n```', r'<pre><code class="\1">\2</code></pre>',
                  html, flags=re.DOTALL)

    # Inline code
    html = re.sub(r'`(.+?)`', r'<code>\1</code>', html)

    # Horizontal rules
    html = re.sub(r'^---+$', r'<hr>', html, flags=re.MULTILINE)

    # Unordered lists
    html = re.sub(r'^[\*\-]\s+(.+)$', r'<li>\1</li>', html, flags=re.MULTILINE)

    # Ordered lists
    html = re.sub(r'^\d+\.\s+(.+)$', r'<li>\1</li>', html, flags=re.MULTILINE)

    # Paragraphs (simple approach - wrap non-tag lines)
    lines = html.split('\n')
    processed = []
    for line in lines:
        line = line.strip()
        if line and not line.startswith('<'):
            processed.append(f'<p>{line}</p>')
        else:
            processed.append(line)
    html = '\n'.join(processed)

    return html


def extract_links(markdown: str) -> List[Dict[str, str]]:
    """Extract all links from Markdown text."""
    pattern = r'\[(.+?)\]\((.+?)\)'
    matches = re.findall(pattern, markdown)

    links = []
    for text, url in matches:
        links.append({
            "text": text,
            "url": url
        })

    return links


def extract_headings(markdown: str) -> List[Dict[str, Any]]:
    """Extract all headings from Markdown text."""
    pattern = r'^(#{1,6})\s+(.+)$'
    matches = re.finditer(pattern, markdown, re.MULTILINE)

    headings = []
    for match in matches:
        level = len(match.group(1))
        text = match.group(2).strip()
        headings.append({
            "level": level,
            "text": text
        })

    return headings


def strip_markdown(markdown: str) -> str:
    """Remove Markdown syntax to get plain text."""
    text = markdown

    # Remove headers
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)

    # Remove bold/italic
    text = re.sub(r'\*{1,3}(.+?)\*{1,3}', r'\1', text)

    # Remove links, keep text
    text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)

    # Remove images
    text = re.sub(r'!\[.+?\]\(.+?\)', '', text)

    # Remove code blocks
    text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)

    # Remove inline code
    text = re.sub(r'`(.+?)`', r'\1', text)

    # Remove horizontal rules
    text = re.sub(r'^---+$', '', text, flags=re.MULTILINE)

    # Remove list markers
    text = re.sub(r'^[\*\-]\s+', '', text, flags=re.MULTILINE)
    text = re.sub(r'^\d+\.\s+', '', text, flags=re.MULTILINE)

    return text.strip()


# For testing
if __name__ == "__main__":
    test_md = """
# Hello World

This is a **bold** and *italic* example.

## Links

Check out [ARO](https://github.com/arolang/aro) for more info.

### Code

```python
print("Hello, World!")
```
"""

    print("Plugin Info:")
    print(json.dumps(aro_plugin_info(), indent=2))

    print("\n\nTo HTML:")
    result = aro_action_to_html(json.dumps({"data": test_md}))
    print(json.dumps(json.loads(result), indent=2))

    print("\n\nExtract Links:")
    result = aro_action_extract_links(json.dumps({"data": test_md}))
    print(json.dumps(json.loads(result), indent=2))

    print("\n\nExtract Headings:")
    result = aro_action_extract_headings(json.dumps({"data": test_md}))
    print(json.dumps(json.loads(result), indent=2))

    print("\n\nWord Count:")
    result = aro_action_word_count(json.dumps({"data": test_md}))
    print(json.dumps(json.loads(result), indent=2))
