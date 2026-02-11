// ============================================================
// MarkdownPlugin.swift
// ARO Plugin - Markdown Processing Service
// ============================================================
//
// Provides Markdown processing functionality.
//
// Usage in ARO:
//   <Call> the <result> from the <markdown-plugin: tohtml> with { data: "..." }.
//   <Call> the <result> from the <markdown-plugin: headings> with { data: "..." }.
//   <Call> the <result> from the <markdown-plugin: wordcount> with { data: "..." }.

import Foundation

// MARK: - Plugin Initialization

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "markdown-plugin", "symbol": "markdown_plugin_call", "methods": ["tohtml", "headings", "wordcount"]}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

// MARK: - Service Implementation

@_cdecl("markdown_plugin_call")
public func markdownPluginCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse arguments
    var args: [String: Any] = [:]
    if let data = argsJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    guard let markdown = args["data"] as? String else {
        resultPtr.pointee = strdup("{\"error\": \"Missing 'data' field\"}")
        return 1
    }

    let result: [String: Any]

    switch method.lowercased() {
    case "tohtml", "to-html":
        result = markdownToHTML(markdown)

    case "headings", "extract-headings":
        result = extractHeadings(markdown)

    case "links", "extract-links":
        result = extractLinks(markdown)

    case "wordcount", "word-count":
        result = wordCount(markdown)

    default:
        let errorJSON = "{\"error\": \"Unknown method: \(method)\"}"
        resultPtr.pointee = strdup(errorJSON)
        return 1
    }

    // Serialize result to JSON
    if let data = try? JSONSerialization.data(withJSONObject: result),
       let json = String(data: data, encoding: .utf8) {
        resultPtr.pointee = strdup(json)
        return 0
    }

    resultPtr.pointee = strdup("{\"error\": \"Failed to serialize result\"}")
    return 1
}

// MARK: - Markdown Functions

private func markdownToHTML(_ markdown: String) -> [String: Any] {
    var html = markdown

    // Headers
    html = html.replacingOccurrences(of: "(?m)^### (.+)$",
                                     with: "<h3>$1</h3>",
                                     options: .regularExpression)
    html = html.replacingOccurrences(of: "(?m)^## (.+)$",
                                     with: "<h2>$1</h2>",
                                     options: .regularExpression)
    html = html.replacingOccurrences(of: "(?m)^# (.+)$",
                                     with: "<h1>$1</h1>",
                                     options: .regularExpression)

    // Bold and italic
    html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*",
                                     with: "<strong>$1</strong>",
                                     options: .regularExpression)
    html = html.replacingOccurrences(of: "\\*(.+?)\\*",
                                     with: "<em>$1</em>",
                                     options: .regularExpression)

    // Links
    html = html.replacingOccurrences(of: "\\[(.+?)\\]\\((.+?)\\)",
                                     with: "<a href=\"$2\">$1</a>",
                                     options: .regularExpression)

    // Inline code
    html = html.replacingOccurrences(of: "`(.+?)`",
                                     with: "<code>$1</code>",
                                     options: .regularExpression)

    return [
        "html": html,
        "input_length": markdown.count,
        "output_length": html.count
    ]
}

private func extractHeadings(_ markdown: String) -> [String: Any] {
    var headings: [[String: Any]] = []

    let pattern = "(?m)^(#{1,6}) (.+)$"
    if let regex = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(markdown.startIndex..., in: markdown)
        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            if let match = match {
                let hashRange = Range(match.range(at: 1), in: markdown)!
                let textRange = Range(match.range(at: 2), in: markdown)!
                let level = markdown[hashRange].count
                let text = String(markdown[textRange])
                headings.append(["level": level, "text": text])
            }
        }
    }

    return [
        "headings": headings,
        "count": headings.count
    ]
}

private func extractLinks(_ markdown: String) -> [String: Any] {
    var links: [[String: String]] = []

    let pattern = "\\[(.+?)\\]\\((.+?)\\)"
    if let regex = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(markdown.startIndex..., in: markdown)
        regex.enumerateMatches(in: markdown, range: range) { match, _, _ in
            if let match = match {
                let textRange = Range(match.range(at: 1), in: markdown)!
                let urlRange = Range(match.range(at: 2), in: markdown)!
                let text = String(markdown[textRange])
                let url = String(markdown[urlRange])
                links.append(["text": text, "url": url])
            }
        }
    }

    return [
        "links": links,
        "count": links.count
    ]
}

private func wordCount(_ markdown: String) -> [String: Any] {
    // Strip markdown syntax for accurate word count
    var text = markdown

    // Remove headers
    text = text.replacingOccurrences(of: "(?m)^#{1,6} ",
                                     with: "",
                                     options: .regularExpression)
    // Remove bold/italic
    text = text.replacingOccurrences(of: "\\*+(.+?)\\*+",
                                     with: "$1",
                                     options: .regularExpression)
    // Remove links, keep text
    text = text.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)",
                                     with: "$1",
                                     options: .regularExpression)
    // Remove inline code backticks
    text = text.replacingOccurrences(of: "`(.+?)`",
                                     with: "$1",
                                     options: .regularExpression)

    let words = text.split(whereSeparator: { $0.isWhitespace }).count
    let chars = text.count
    let charsNoSpaces = text.filter { !$0.isWhitespace }.count
    let lines = markdown.components(separatedBy: "\n").count

    return [
        "words": words,
        "characters": chars,
        "characters_no_spaces": charsNoSpaces,
        "lines": lines
    ]
}
