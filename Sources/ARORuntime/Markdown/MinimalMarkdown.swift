// ============================================================
// MinimalMarkdown.swift
// ARO Runtime — built-in Markdown → HTML helper
// ============================================================
//
// Tiny CommonMark subset shared by:
//   - the `markdown` qualifier on the Compute action
//   - the `| markdown` template filter
//
// Supported:
//   - blank-line-separated paragraphs (wrapped in <p>)
//   - ATX headings  # … ######
//   - fenced code blocks ```…```
//   - inline **bold**, *italic*, _italic_, `code`, [text](url)
// Everything else is HTML-escaped and rendered as a paragraph. Plug in
// a richer renderer via a Swift or Rust plugin if you outgrow this.

import Foundation

public enum MinimalMarkdown {

    /// Render `source` as HTML.
    public static func toHTML(_ source: String) -> String {
        // Split into blocks separated by blank lines, but keep fenced
        // code blocks intact even when they contain blank lines.
        var blocks: [String] = []
        var buf: [String] = []
        var inFence = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                buf.append(line)
                inFence.toggle()
                continue
            }
            if !inFence && line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !buf.isEmpty {
                    blocks.append(buf.joined(separator: "\n"))
                    buf.removeAll()
                }
            } else {
                buf.append(line)
            }
        }
        if !buf.isEmpty { blocks.append(buf.joined(separator: "\n")) }
        return blocks.map(renderBlock).joined(separator: "\n")
    }

    // MARK: - Block-level

    private static func renderBlock(_ block: String) -> String {
        let trimmed = block.trimmingCharacters(in: .whitespaces)

        // Fenced code block
        if trimmed.hasPrefix("```") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
            var inner = lines
            if !inner.isEmpty { inner.removeFirst() }
            if let last = inner.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inner.removeLast()
            }
            return "<pre><code>\(escape(inner.joined(separator: "\n")))</code></pre>"
        }

        // ATX heading
        if trimmed.range(of: #"^(#{1,6})\s+(.*)$"#, options: .regularExpression) != nil {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let body = trimmed.drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
            return "<h\(level)>\(renderInline(body))</h\(level)>"
        }

        // Default: paragraph; collapse soft line breaks to spaces.
        let collapsed = block.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "<p>\(renderInline(collapsed))</p>"
    }

    // MARK: - Inline

    private static func renderInline(_ source: String) -> String {
        var s = escape(source)
        // Inline code first so its contents aren't further processed
        s = regexReplace(s, pattern: "`([^`]+)`", template: "<code>$1</code>")
        // Links [text](url)
        s = regexReplace(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, template: "<a href=\"$2\">$1</a>")
        // Bold **text** before italic so ** isn't eaten as two *
        s = regexReplace(s, pattern: #"\*\*([^*]+)\*\*"#, template: "<strong>$1</strong>")
        // Italic *text* and _text_
        s = regexReplace(s, pattern: #"\*([^*]+)\*"#, template: "<em>$1</em>")
        s = regexReplace(s, pattern: #"_([^_]+)_"#, template: "<em>$1</em>")
        return s
    }

    // MARK: - Helpers

    private static func regexReplace(_ s: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}
