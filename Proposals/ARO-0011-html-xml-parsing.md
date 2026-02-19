# ARO-0011: HTML/XML Parsing

* Proposal: ARO-0011
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004

## Abstract

This proposal introduces the `<ParseHtml>` action for extracting structured data from HTML content. Using specifiers, developers can extract links, page content, or text elements from HTML strings retrieved via HTTP requests or read from files.

## Introduction

Web applications frequently need to process HTML content:

```
+------------------+     +------------------+     +------------------+
|   HTTP Request   |     |    ParseHtml     |     | Structured Data  |
|  Request ...   | --> |  ParseHtml ... | --> |  links, content  |
+------------------+     +------------------+     +------------------+
```

Common use cases include:
- Web scraping and crawling
- Content extraction from external sources
- Link discovery and validation
- Document processing pipelines

Without built-in HTML parsing, developers must rely on external services or plugins. The `<ParseHtml>` action provides a clean, declarative approach to HTML extraction that integrates naturally with ARO's Action-Result-Object syntax.

---

## 1. ParseHtml Action

### 1.1 Syntax

```aro
(* Extract all links from HTML *)
ParseHtml the <links: links> from the <html>.

(* Extract page content with title *)
ParseHtml the <content-result: content> from the <html>.

(* Extract text from body or specific selector *)
ParseHtml the <text-content: text> from the <html>.
```

### 1.2 Action Specification

```
+------------------+----------------------------------------+
| Property         | Value                                  |
+------------------+----------------------------------------+
| Action           | ParseHtml                              |
| Verbs            | parsehtml                              |
| Semantic Role    | OWN (Internal to Internal)             |
| Prepositions     | from                                   |
+------------------+----------------------------------------+
```

### 1.3 Specifiers

The result specifier determines what data is extracted from the HTML:

```
+------------------+-------------------+----------------------------------------+
| Specifier        | Returns           | Description                            |
+------------------+-------------------+----------------------------------------+
| links            | [String]          | All href values from <a> tags          |
| content          | {title, content}  | Page title and cleaned body text       |
| text             | [String]          | Text content from body (default)       |
| markdown         | {title, markdown} | Page title and body as Markdown        |
+------------------+-------------------+----------------------------------------+
```

### 1.4 Result Structures

#### Links Specifier

Returns an array of strings containing all `href` attribute values:

```aro
ParseHtml the <links: links> from the <html>.
(* Result: ["/about", "/contact", "https://external.com"] *)
```

#### Content Specifier

Returns a dictionary with `title` and `content` fields:

```aro
ParseHtml the <result: content> from the <html>.
Extract the <title> from the <result: title>.
Extract the <body-text> from the <result: content>.
```

The content is extracted in priority order:
1. `<main>` element if present
2. `<article>` element if present
3. `<body>` element as fallback

Whitespace is normalized and empty segments removed.

#### Text Specifier

Returns an array of text strings from the document body:

```aro
ParseHtml the <paragraphs: text> from the <html>.
```

#### Markdown Specifier

Returns a dictionary with `title` and `markdown` fields. The HTML body is converted to properly formatted Markdown, preserving document structure:

```aro
ParseHtml the <result: markdown> from the <html>.
Extract the <title> from the <result: title>.
Extract the <md-content> from the <result: markdown>.
```

Supported HTML to Markdown conversions:

```
+-------------------+-------------------------+
| HTML Element      | Markdown Output         |
+-------------------+-------------------------+
| <h1> to <h6>      | # to ######             |
| <p>               | Double newlines         |
| <a href="...">    | [text](url)             |
| <img src="...">   | ![alt](src)             |
| <strong>, <b>     | **bold**                |
| <em>, <i>         | *italic*                |
| <code>            | `inline code`           |
| <pre><code>       | ```lang\ncode\n```      |
| <blockquote>      | > quoted text           |
| <ul><li>          | - list item             |
| <ol><li>          | 1. numbered item        |
| <table>           | Markdown table          |
| <hr>              | ---                     |
| <del>, <s>        | ~~strikethrough~~       |
+-------------------+-------------------------+
```

Content is extracted in priority order (same as content specifier):
1. `<main>` element if present
2. `<article>` element if present
3. `<body>` element as fallback

Script, style, and other non-content elements are automatically ignored.

---

## 2. Examples

### 2.1 Web Crawler Link Extraction

```aro
(Extract Links: ExtractLinks Handler) {
    Extract the <html> from the <event-data: html>.

    (* Parse HTML and extract all anchor hrefs *)
    ParseHtml the <links: links> from the <html>.
    Compute the <link-count: count> from the <links>.
    Log "Found links:" to the <console>.
    Log <link-count> to the <console>.

    (* Process each link *)
    parallel for each <url> in <links> {
        Emit a <ProcessUrl: event> with { url: <url> }.
    }

    Return an <OK: status> for the <extraction>.
}
```

### 2.2 Content Extraction for Search Indexing

```aro
(Index Page: CrawlPage Handler) {
    Extract the <url> from the <event-data: url>.
    Request the <html> from the <url>.

    (* Extract structured content *)
    ParseHtml the <content-result: content> from the <html>.
    Extract the <title> from the <content-result: title>.
    Extract the <body-text> from the <content-result: content>.

    (* Store for indexing *)
    Create the <document> with {
        url: <url>,
        title: <title>,
        content: <body-text>
    }.
    Store the <document> into the <search-index>.

    Return an <OK: status> for the <indexing>.
}
```

### 2.3 Combining with HTTP Requests

```aro
(Fetch and Parse: API Handler) {
    (* Fetch HTML from remote URL *)
    Request the <html> from "https://example.com/page".

    (* Extract links and content in sequence *)
    ParseHtml the <links: links> from the <html>.
    ParseHtml the <page-data: content> from the <html>.

    Return an <OK: status> with {
        links: <links>,
        title: <page-data: title>,
        content: <page-data: content>
    }.
}
```

### 2.4 Converting HTML to Markdown

```aro
(Save Article: SaveArticle Handler) {
    Extract the <url> from the <event-data: url>.
    Request the <html> from the <url>.

    (* Convert HTML to structured Markdown *)
    ParseHtml the <result: markdown> from the <html>.
    Extract the <title> from the <result: title>.
    Extract the <markdown-content> from the <result: markdown>.

    (* Create file with frontmatter *)
    Compute the <url-hash: hash> from the <url>.
    Create the <file-path> with "./output/${<url-hash>}.md".
    Create the <file-content> with "# ${<title>}\n\n**Source:** ${<url>}\n\n${<markdown-content>}".

    Write the <file-content> to the <file: file-path>.

    Return an <OK: status> for the <save>.
}
```

This is useful for:
- Archiving web content in a readable format
- Converting documentation for offline use
- Creating markdown copies of articles and pages
- Content migration pipelines

---

## 3. Implementation Notes

### 3.1 CSS Selector Support

The `<ParseHtml>` action uses CSS selectors internally:
- `links`: Selects `a[href]` elements
- `content`: Selects `title`, `main`, `article`, or `body`
- `text`: Selects `body` by default
- `markdown`: Recursively traverses `main`, `article`, or `body` with element-aware conversion

### 3.2 Error Handling

Following ARO's error philosophy, malformed HTML that cannot be parsed results in a runtime error with a descriptive message:

```
Runtime error: Failed to parse HTML in ParseHtml action
```

### 3.3 Encoding

HTML content is assumed to be UTF-8 encoded. The parser handles common HTML entities and normalizes whitespace in text extraction.

---

## 4. Future Considerations

### 4.1 Custom CSS Selectors

A future enhancement could allow custom selectors via expression:

```aro
(* Hypothetical future syntax *)
ParseHtml the <headers: text> from the <html> using "h1, h2, h3".
```

### 4.2 XML Parsing Variant

A `<ParseXml>` action could provide similar functionality for XML documents with XPath support:

```aro
(* Hypothetical future syntax *)
<ParseXml> the <items: nodes> from the <xml> using "//item/name".
```

### 4.3 Attribute Extraction

Future specifiers could extract specific attributes:

```aro
(* Hypothetical future syntax *)
ParseHtml the <images: src> from the <html>.  (* Extract img src values *)
ParseHtml the <forms: action> from the <html>.  (* Extract form actions *)
```

---

## 5. Relationship to Other Proposals

- **ARO-0004 (Actions)**: ParseHtml follows the standard action pattern with OWN semantic role
- **ARO-0008 (I/O Services)**: Complements the `<Request>` action for web content retrieval
- **ARO-0040 (Format-Aware I/O)**: Similar pattern of specifier-based data extraction

---

## References

- ARO Web Crawler Demo: Real-world usage of `<ParseHtml>` action
- Kanna Library: Underlying HTML/XML parsing implementation (Swift)
