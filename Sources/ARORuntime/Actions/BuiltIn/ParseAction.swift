// ============================================================
// ParseAction.swift
// ARO Runtime - HTML Parse Action for Structured Data Extraction
// ============================================================

import Foundation
import SwiftSoup
import AROParser

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

        // Resolve input - support property access via specifiers (e.g., <event-data: html>)
        let input: String = try context.resolveWithSpecifiers(object.base, specifiers: object.specifiers)

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
        let doc = try SwiftSoup.parse(html)
        let links = try doc.select("a[href]")
        return try links.array().compactMap { try $0.attr("href") }
    }

    /// Extract text content with title
    private func parseHtmlContent(_ html: String) throws -> [String: any Sendable] {
        let doc = try SwiftSoup.parse(html)

        let title = try doc.select("title").first()?.text() ?? ""

        var content = ""
        if let main = try doc.select("main").first() {
            content = try main.text()
        } else if let article = try doc.select("article").first() {
            content = try article.text()
        } else if let body = try doc.select("body").first() {
            content = try body.text()
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
        let doc = try SwiftSoup.parse(html)
        let elements = try doc.select(selector)
        return try elements.array().map { try $0.text() }
    }

    // MARK: - Markdown Conversion

    /// Extract HTML content and convert to Markdown
    private func parseHtmlToMarkdown(_ html: String) throws -> [String: any Sendable] {
        let doc = try SwiftSoup.parse(html)

        let title = (try doc.select("title").first()?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Find main content area
        var contentElement: Element?
        if let main = try doc.select("main").first() {
            contentElement = main
        } else if let article = try doc.select("article").first() {
            contentElement = article
        } else if let body = try doc.select("body").first() {
            contentElement = body
        }

        var markdown: String
        if let element = contentElement {
            markdown = try convertElementToMarkdown(element)
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
    private func convertElementToMarkdown(_ element: Element, listDepth: Int = 0) throws -> String {
        let tagName = element.tagName().lowercased()

        switch tagName {
        // Headings
        case "h1":
            return "# \(try getInlineMarkdown(element))\n\n"
        case "h2":
            return "## \(try getInlineMarkdown(element))\n\n"
        case "h3":
            return "### \(try getInlineMarkdown(element))\n\n"
        case "h4":
            return "#### \(try getInlineMarkdown(element))\n\n"
        case "h5":
            return "##### \(try getInlineMarkdown(element))\n\n"
        case "h6":
            return "###### \(try getInlineMarkdown(element))\n\n"

        // Paragraphs and line breaks
        case "p":
            let content = try getInlineMarkdown(element)
            return content.isEmpty ? "" : "\(content)\n\n"
        case "br":
            return "\n"
        case "hr":
            return "\n---\n\n"

        // Inline formatting (handled by getInlineMarkdown, but support standalone)
        case "strong", "b":
            return "**\(try getInlineMarkdown(element))**"
        case "em", "i":
            return "*\(try getInlineMarkdown(element))*"
        case "code":
            return "`\(try element.text())`"
        case "del", "s", "strike":
            return "~~\(try getInlineMarkdown(element))~~"

        // Links and images
        case "a":
            let href = try element.attr("href")
            let text = try getInlineMarkdown(element)
            return "[\(text)](\(escapeMarkdownUrl(href)))"
        case "img":
            let src = try element.attr("src")
            let alt = try element.attr("alt")
            return "![\(escapeMarkdownText(alt))](\(escapeMarkdownUrl(src)))"

        // Code blocks
        case "pre":
            let codeElement = try element.select("code").first() ?? element
            let lang = try extractLanguageClass(codeElement)
            let code = try codeElement.text()
            return "\n```\(lang)\n\(code)\n```\n\n"

        // Blockquotes
        case "blockquote":
            var content = try getChildrenMarkdown(element, listDepth: listDepth)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Fallback to element text if no children extracted
            if content.isEmpty {
                content = (try? element.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let lines = content.components(separatedBy: "\n")
            return lines.map { "> \($0)" }.joined(separator: "\n") + "\n\n"

        // Lists
        case "ul":
            return try convertUnorderedList(element, depth: listDepth) + "\n"
        case "ol":
            return try convertOrderedList(element, depth: listDepth) + "\n"

        // Tables
        case "table":
            return try convertTable(element) + "\n\n"

        // Container elements - process children
        case "div", "span", "section", "article", "main", "header", "footer", "nav", "aside",
             "figure", "figcaption", "details", "summary", "address":
            return try getChildrenMarkdown(element, listDepth: listDepth)

        // Ignored elements
        case "script", "style", "noscript", "template", "iframe", "svg", "canvas":
            return ""

        // Definition lists
        case "dl":
            return try convertDefinitionList(element)
        case "dt":
            return "**\(try getInlineMarkdown(element))**\n"
        case "dd":
            return ": \(try getInlineMarkdown(element))\n\n"

        // Text nodes (handled separately)
        case "#text":
            return try element.text()

        default:
            // Unknown tags - extract children or text
            return try getChildrenMarkdown(element, listDepth: listDepth)
        }
    }

    /// Get markdown for all children of an element
    private func getChildrenMarkdown(_ element: Element, listDepth: Int = 0) throws -> String {
        var result = ""
        for child in element.children().array() {
            result += try convertElementToMarkdown(child, listDepth: listDepth)
        }
        // Also handle text nodes
        for node in element.textNodes() {
            let text = normalizeWhitespace(node.text())
            if !text.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                result += text
            }
        }
        return result
    }

    /// Get inline markdown (text with inline formatting)
    private func getInlineMarkdown(_ element: Element) throws -> String {
        var result = ""

        // Process child nodes
        for child in element.children().array() {
            let tagName = child.tagName().lowercased()
            switch tagName {
            case "strong", "b":
                let inner = try getInlineMarkdown(child)
                if !inner.isEmpty {
                    result += "**\(inner)**"
                }
            case "em", "i":
                let inner = try getInlineMarkdown(child)
                if !inner.isEmpty {
                    result += "*\(inner)*"
                }
            case "code":
                let code = try child.text()
                if !code.isEmpty {
                    result += "`\(code)`"
                }
            case "del", "s", "strike":
                let inner = try getInlineMarkdown(child)
                if !inner.isEmpty {
                    result += "~~\(inner)~~"
                }
            case "a":
                let href = try child.attr("href")
                let text = try getInlineMarkdown(child)
                if !text.isEmpty && !href.isEmpty {
                    result += "[\(text)](\(escapeMarkdownUrl(href)))"
                } else if !text.isEmpty {
                    result += text
                }
            case "img":
                let src = try child.attr("src")
                let alt = try child.attr("alt")
                if !src.isEmpty {
                    result += "![\(escapeMarkdownText(alt))](\(escapeMarkdownUrl(src)))"
                }
            case "br":
                result += "\n"
            case "span":
                result += try getInlineMarkdown(child)
            default:
                // Normalize whitespace in text from other elements
                let text = normalizeWhitespace(try child.text())
                result += text
            }
        }

        // Handle text nodes directly under this element
        for node in element.textNodes() {
            result += normalizeWhitespace(node.text())
        }

        // If no content was found, try element's text directly
        if result.isEmpty {
            result = normalizeWhitespace(try element.text())
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Normalize whitespace: collapse multiple spaces/newlines into single space
    private func normalizeWhitespace(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Extract language class from code element (e.g., "language-swift" -> "swift")
    private func extractLanguageClass(_ element: Element) throws -> String {
        guard let className = try? element.className() else { return "" }
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
    private func convertUnorderedList(_ element: Element, depth: Int = 0) throws -> String {
        var result = ""
        let prefix = String(repeating: "  ", count: depth)

        // SwiftSoup doesn't support :scope, so we check parent directly
        for li in try element.select("li").array() {
            // Only process direct children of this list
            if li.parent() === element {
                let content = try getListItemContent(li, depth: depth)
                result += "\(prefix)- \(content)\n"
            }
        }

        return result
    }

    /// Convert ordered list to Markdown
    private func convertOrderedList(_ element: Element, depth: Int = 0) throws -> String {
        var result = ""
        let prefix = String(repeating: "  ", count: depth)
        var index = 1

        // SwiftSoup doesn't support :scope, so we check parent directly
        for li in try element.select("li").array() {
            // Only process direct children of this list
            if li.parent() === element {
                let content = try getListItemContent(li, depth: depth)
                result += "\(prefix)\(index). \(content)\n"
                index += 1
            }
        }

        return result
    }

    /// Get list item content, handling nested lists
    private func getListItemContent(_ li: Element, depth: Int) throws -> String {
        var content = ""

        // Get inline text content (excluding nested lists)
        for child in li.children().array() {
            let tagName = child.tagName().lowercased()
            switch tagName {
            case "ul":
                // Nested unordered list
                content += "\n" + (try convertUnorderedList(child, depth: depth + 1))
            case "ol":
                // Nested ordered list
                content += "\n" + (try convertOrderedList(child, depth: depth + 1))
            case "p":
                // Paragraph in list item
                content += try getInlineMarkdown(child)
            default:
                // Inline element
                content += try getInlineMarkdown(child)
            }
        }

        // Handle text nodes
        for node in li.textNodes() {
            content += normalizeWhitespace(node.text())
        }

        return content.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Table Conversion

    /// Convert HTML table to Markdown table
    private func convertTable(_ element: Element) throws -> String {
        var headerRow: [String] = []
        var bodyRows: [[String]] = []

        // Extract header rows from thead
        if let thead = try element.select("thead").first() {
            for tr in try thead.select("tr").array() {
                var row: [String] = []
                for th in try tr.select("th").array() {
                    row.append(try escapeTableCell(getInlineMarkdown(th)))
                }
                if !row.isEmpty {
                    headerRow = row
                    break // Only use first header row
                }
            }
        }

        // Extract body rows
        let tbody = try element.select("tbody").first() ?? element
        for tr in try tbody.select("tr").array() {
            var row: [String] = []
            // Handle both th and td cells
            for cell in try tr.select("th, td").array() {
                row.append(try escapeTableCell(getInlineMarkdown(cell)))
            }
            if !row.isEmpty {
                // If no header yet and this row has th cells, use as header
                if headerRow.isEmpty && (try? tr.select("th").first()) != nil {
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
    private func convertDefinitionList(_ element: Element) throws -> String {
        var result = ""
        for child in element.children().array() {
            let tagName = child.tagName().lowercased()
            switch tagName {
            case "dt":
                result += "**\(try getInlineMarkdown(child))**\n"
            case "dd":
                result += ": \(try getInlineMarkdown(child))\n\n"
            default:
                break
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
