// ============================================================
// ParseAction.swift
// ARO Runtime - HTML Parse Action for Structured Data Extraction
// ============================================================

import Foundation
import Kanna
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

        default:
            throw ActionError.runtimeError("Unknown parse type: \(parseType). Valid types: links, content, text")
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

}
