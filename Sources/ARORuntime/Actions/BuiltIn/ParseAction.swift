// ============================================================
// ParseAction.swift
// ARO Runtime - HTML Parse Action for Structured Data Extraction
// ============================================================

// Kanna requires libxml2 which is not available on Windows
#if !os(Windows)

import Foundation
import Kanna
import AROParser

// Use Kanna's XMLElement to avoid ambiguity with Foundation's NSXMLElement
private typealias KannaXMLElement = Kanna.XMLElement

// MARK: - ParseHtml Action

/// ParseHtml action for extracting structured data from HTML content
///
/// Uses specifier to determine what to extract:
/// - `links`: Extract all href values from anchor tags
/// - `content`: Extract text content (title + body)
/// - `text`: Extract text from CSS selector
///
/// ## Examples
/// ```aro
/// <ParseHtml> the <links: links> from the <html>.
/// <ParseHtml> the <content: content> from the <html>.
/// ```
public struct ParseHtmlAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["parsehtml"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        guard let input: String = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get parse type from specifier
        let parseType = result.specifiers.first ?? "text"

        switch parseType.lowercased() {
        case "links":
            return try parseHtmlLinks(input)

        case "content":
            return try parseHtmlContent(input)

        case "text":
            // Get CSS selector from _expression_ if provided
            let selector: String = context.resolve("_expression_") ?? "body"
            return try parseHtmlText(input, selector: selector)

        case "markdown":
            return try parseHtmlToMarkdown(input)

        default:
            throw ActionError.runtimeError("Unknown parse type: \(parseType). Valid types: links, content, text, markdown")
        }
    }

    // MARK: - HTML Parsing

    /// Extract all href values from anchor tags
    private func parseHtmlLinks(_ html: String) throws -> [String] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw ActionError.runtimeError("Failed to parse HTML")
        }
        return doc.css("a[href]").compactMap { $0["href"] }
    }

    /// Extract text content with title
    private func parseHtmlContent(_ html: String) throws -> [String: any Sendable] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw ActionError.runtimeError("Failed to parse HTML")
        }

        let title = doc.css("title").first?.text ?? ""

        var content = ""
        if let main = doc.css("main").first {
            content = main.text ?? ""
        } else if let article = doc.css("article").first {
            content = article.text ?? ""
        } else if let body = doc.css("body").first {
            content = body.text ?? ""
        }

        // Clean up whitespace
        let cleaned = content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return ["title": title, "content": cleaned]
    }

    /// Extract text from elements matching CSS selector
    private func parseHtmlText(_ html: String, selector: String) throws -> [String] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw ActionError.runtimeError("Failed to parse HTML")
        }
        return doc.css(selector).compactMap { $0.text }
    }

    // MARK: - Markdown Conversion

    /// Extract HTML content and convert to Markdown
    private func parseHtmlToMarkdown(_ html: String) throws -> [String: any Sendable] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw ActionError.runtimeError("Failed to parse HTML")
        }

        let title = doc.css("title").first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Find main content area
        var contentElement: KannaXMLElement?
        if let main = doc.css("main").first {
            contentElement = main
        } else if let article = doc.css("article").first {
            contentElement = article
        } else if let body = doc.css("body").first {
            contentElement = body
        }

        var markdown: String
        if let element = contentElement {
            markdown = convertElementToMarkdown(element)
            markdown = cleanupMarkdown(markdown)
        } else {
            markdown = ""
        }

        return ["title": title, "markdown": markdown]
    }

    /// Clean up markdown output by normalizing whitespace
    private func cleanupMarkdown(_ markdown: String) -> String {
        var result = markdown

        // Normalize line endings
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")

        // Remove trailing whitespace from each line
        let lines = result.components(separatedBy: "\n")
        result = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")

        // Collapse 3+ consecutive blank lines into 2
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Remove blank lines at start and end
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    /// Recursively convert an HTML element to Markdown
    private func convertElementToMarkdown(_ element: KannaXMLElement, listDepth: Int = 0) -> String {
        guard let tagName = element.tagName?.lowercased() else {
            // Text node - return text content directly
            return element.text ?? ""
        }

        switch tagName {
        // Headings
        case "h1":
            return "# \(getInlineMarkdown(element))\n\n"
        case "h2":
            return "## \(getInlineMarkdown(element))\n\n"
        case "h3":
            return "### \(getInlineMarkdown(element))\n\n"
        case "h4":
            return "#### \(getInlineMarkdown(element))\n\n"
        case "h5":
            return "##### \(getInlineMarkdown(element))\n\n"
        case "h6":
            return "###### \(getInlineMarkdown(element))\n\n"

        // Paragraphs and line breaks
        case "p":
            let content = getInlineMarkdown(element)
            return content.isEmpty ? "" : "\(content)\n\n"
        case "br":
            return "\n"
        case "hr":
            return "\n---\n\n"

        // Inline formatting (handled by getInlineMarkdown, but support standalone)
        case "strong", "b":
            return "**\(getInlineMarkdown(element))**"
        case "em", "i":
            return "*\(getInlineMarkdown(element))*"
        case "code":
            return "`\(element.text ?? "")`"
        case "del", "s", "strike":
            return "~~\(getInlineMarkdown(element))~~"

        // Links and images
        case "a":
            let href = element["href"] ?? ""
            let text = getInlineMarkdown(element)
            return "[\(text)](\(escapeMarkdownUrl(href)))"
        case "img":
            let src = element["src"] ?? ""
            let alt = element["alt"] ?? ""
            return "![\(escapeMarkdownText(alt))](\(escapeMarkdownUrl(src)))"

        // Code blocks
        case "pre":
            let codeElement = element.css("code").first ?? element
            let lang = extractLanguageClass(codeElement)
            let code = codeElement.text ?? ""
            return "\n```\(lang)\n\(code)\n```\n\n"

        // Blockquotes
        case "blockquote":
            var content = getChildrenMarkdown(element, listDepth: listDepth)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Fallback to element text if no children extracted
            if content.isEmpty {
                content = element.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let lines = content.components(separatedBy: "\n")
            return lines.map { "> \($0)" }.joined(separator: "\n") + "\n\n"

        // Lists
        case "ul":
            return convertUnorderedList(element, depth: listDepth) + "\n"
        case "ol":
            return convertOrderedList(element, depth: listDepth) + "\n"

        // Tables
        case "table":
            return convertTable(element) + "\n\n"

        // Container elements - process children
        case "div", "span", "section", "article", "main", "header", "footer", "nav", "aside",
             "figure", "figcaption", "details", "summary", "address":
            return getChildrenMarkdown(element, listDepth: listDepth)

        // Ignored elements
        case "script", "style", "noscript", "template", "iframe", "svg", "canvas":
            return ""

        // Definition lists
        case "dl":
            return convertDefinitionList(element)
        case "dt":
            return "**\(getInlineMarkdown(element))**\n"
        case "dd":
            return ": \(getInlineMarkdown(element))\n\n"

        default:
            // Unknown tags - extract children or text
            return getChildrenMarkdown(element, listDepth: listDepth)
        }
    }

    /// Get markdown for all children of an element
    private func getChildrenMarkdown(_ element: KannaXMLElement, listDepth: Int = 0) -> String {
        var result = ""
        for child in element.xpath("child::node()") {
            if let childElement = child as? KannaXMLElement {
                if childElement.tagName != nil {
                    result += convertElementToMarkdown(childElement, listDepth: listDepth)
                } else {
                    // Text node - normalize whitespace
                    let text = normalizeWhitespace(childElement.text ?? "")
                    if !text.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                        result += text
                    }
                }
            }
        }
        return result
    }

    /// Get inline markdown (text with inline formatting)
    private func getInlineMarkdown(_ element: KannaXMLElement) -> String {
        var result = ""
        for child in element.xpath("child::node()") {
            if let childElement = child as? KannaXMLElement {
                if let tagName = childElement.tagName?.lowercased() {
                    switch tagName {
                    case "strong", "b":
                        let inner = getInlineMarkdown(childElement)
                        if !inner.isEmpty {
                            result += "**\(inner)**"
                        }
                    case "em", "i":
                        let inner = getInlineMarkdown(childElement)
                        if !inner.isEmpty {
                            result += "*\(inner)*"
                        }
                    case "code":
                        let code = childElement.text ?? ""
                        if !code.isEmpty {
                            result += "`\(code)`"
                        }
                    case "del", "s", "strike":
                        let inner = getInlineMarkdown(childElement)
                        if !inner.isEmpty {
                            result += "~~\(inner)~~"
                        }
                    case "a":
                        let href = element["href"] ?? childElement["href"] ?? ""
                        let text = getInlineMarkdown(childElement)
                        if !text.isEmpty && !href.isEmpty {
                            result += "[\(text)](\(escapeMarkdownUrl(href)))"
                        } else if !text.isEmpty {
                            result += text
                        }
                    case "img":
                        let src = childElement["src"] ?? ""
                        let alt = childElement["alt"] ?? ""
                        if !src.isEmpty {
                            result += "![\(escapeMarkdownText(alt))](\(escapeMarkdownUrl(src)))"
                        }
                    case "br":
                        result += "\n"
                    case "span":
                        result += getInlineMarkdown(childElement)
                    default:
                        // Normalize whitespace in text from other elements
                        let text = normalizeWhitespace(childElement.text ?? "")
                        result += text
                    }
                } else {
                    // Text node - normalize whitespace
                    let text = normalizeWhitespace(childElement.text ?? "")
                    result += text
                }
            }
        }

        // If no children were found, use element's text directly
        if result.isEmpty {
            result = normalizeWhitespace(element.text ?? "")
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Normalize whitespace: collapse multiple spaces/newlines into single space
    private func normalizeWhitespace(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Extract language class from code element (e.g., "language-swift" -> "swift")
    private func extractLanguageClass(_ element: KannaXMLElement) -> String {
        guard let className = element.className else { return "" }
        let classes = className.split(separator: " ")
        for cls in classes {
            if cls.hasPrefix("language-") {
                return String(cls.dropFirst("language-".count))
            }
            if cls.hasPrefix("lang-") {
                return String(cls.dropFirst("lang-".count))
            }
        }
        return ""
    }

    // MARK: - List Conversion

    /// Convert unordered list to Markdown
    private func convertUnorderedList(_ element: KannaXMLElement, depth: Int = 0) -> String {
        var result = ""
        let prefix = String(repeating: "  ", count: depth)

        for li in element.css(":scope > li") {
            let content = getListItemContent(li, depth: depth)
            result += "\(prefix)- \(content)\n"
        }

        // Fallback if :scope not supported
        if result.isEmpty {
            for li in element.css("li") {
                // Skip nested list items
                if li.parent?.tagName?.lowercased() == element.tagName?.lowercased() {
                    let content = getListItemContent(li, depth: depth)
                    result += "\(prefix)- \(content)\n"
                }
            }
        }

        return result
    }

    /// Convert ordered list to Markdown
    private func convertOrderedList(_ element: KannaXMLElement, depth: Int = 0) -> String {
        var result = ""
        let prefix = String(repeating: "  ", count: depth)
        var index = 1

        for li in element.css(":scope > li") {
            let content = getListItemContent(li, depth: depth)
            result += "\(prefix)\(index). \(content)\n"
            index += 1
        }

        // Fallback if :scope not supported
        if result.isEmpty {
            for li in element.css("li") {
                if li.parent?.tagName?.lowercased() == element.tagName?.lowercased() {
                    let content = getListItemContent(li, depth: depth)
                    result += "\(prefix)\(index). \(content)\n"
                    index += 1
                }
            }
        }

        return result
    }

    /// Get list item content, handling nested lists
    private func getListItemContent(_ li: KannaXMLElement, depth: Int) -> String {
        var content = ""

        // Get inline text content (excluding nested lists)
        for child in li.xpath("child::node()") {
            if let childElement = child as? KannaXMLElement {
                if let tagName = childElement.tagName?.lowercased() {
                    switch tagName {
                    case "ul":
                        // Nested unordered list
                        content += "\n" + convertUnorderedList(childElement, depth: depth + 1)
                    case "ol":
                        // Nested ordered list
                        content += "\n" + convertOrderedList(childElement, depth: depth + 1)
                    case "p":
                        // Paragraph in list item
                        content += getInlineMarkdown(childElement)
                    default:
                        // Inline element
                        content += getInlineMarkdown(childElement)
                    }
                } else {
                    // Text node - normalize whitespace
                    content += normalizeWhitespace(childElement.text ?? "")
                }
            }
        }

        return content.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Table Conversion

    /// Convert HTML table to Markdown table
    private func convertTable(_ element: KannaXMLElement) -> String {
        var headerRow: [String] = []
        var bodyRows: [[String]] = []

        // Extract header rows from thead
        if let thead = element.css("thead").first {
            for tr in thead.css("tr") {
                var row: [String] = []
                for th in tr.css("th") {
                    row.append(escapeTableCell(getInlineMarkdown(th)))
                }
                if !row.isEmpty {
                    headerRow = row
                    break // Only use first header row
                }
            }
        }

        // Extract body rows
        let tbody = element.css("tbody").first ?? element
        for tr in tbody.css("tr") {
            var row: [String] = []
            // Handle both th and td cells
            for cell in tr.css("th, td") {
                row.append(escapeTableCell(getInlineMarkdown(cell)))
            }
            if !row.isEmpty {
                // If no header yet and this row has th cells, use as header
                if headerRow.isEmpty && tr.css("th").first != nil {
                    headerRow = row
                } else {
                    bodyRows.append(row)
                }
            }
        }

        // Determine column count
        let columnCount = max(headerRow.count, bodyRows.map { $0.count }.max() ?? 0)
        guard columnCount > 0 else { return "" }

        // Normalize rows to have same column count
        func normalize(_ row: [String]) -> [String] {
            var normalized = row
            while normalized.count < columnCount {
                normalized.append("")
            }
            return normalized
        }

        // Build markdown table
        var result = ""

        // Header row
        let header = headerRow.isEmpty ? Array(repeating: "", count: columnCount) : normalize(headerRow)
        result += "| " + header.joined(separator: " | ") + " |\n"

        // Separator row
        result += "|" + Array(repeating: "---", count: columnCount).joined(separator: "|") + "|\n"

        // Data rows
        for row in bodyRows {
            let normalizedRow = normalize(row)
            result += "| " + normalizedRow.joined(separator: " | ") + " |\n"
        }

        return result
    }

    /// Escape special characters in table cells
    private func escapeTableCell(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Definition List Conversion

    /// Convert definition list to Markdown
    private func convertDefinitionList(_ element: KannaXMLElement) -> String {
        var result = ""
        for child in element.xpath("child::*") {
            if let tagName = child.tagName?.lowercased() {
                switch tagName {
                case "dt":
                    result += "**\(getInlineMarkdown(child))**\n"
                case "dd":
                    result += ": \(getInlineMarkdown(child))\n\n"
                default:
                    break
                }
            }
        }
        return result
    }

    // MARK: - Escaping Helpers

    /// Escape special characters in Markdown text
    private func escapeMarkdownText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Escape special characters in URLs for Markdown
    private func escapeMarkdownUrl(_ url: String) -> String {
        return url
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }

}

#endif  // !os(Windows)
