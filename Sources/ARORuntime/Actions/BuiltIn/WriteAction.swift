// ============================================================
// WriteAction.swift
// ARO Runtime - Write: a value to a file, in the format its name implies
// ============================================================

import Foundation
import AROParser

/// Writes data to a file with automatic format detection (ARO-0040)
/// The file extension determines the output format:
/// - .json: JSON
/// - .yaml/.yml: YAML
/// - .xml: XML (root element = variable name)
/// - .toml: TOML
/// - .csv: CSV
/// - .tsv: TSV
/// - .md: Markdown table
/// - .html: HTML table
/// - .txt: key=value format
/// - .sql: INSERT statements
/// - .obj/unknown: Binary (pass-through)
public struct WriteAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["write"]
    public static let validPrepositions: Set<Preposition> = [.to, .into]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Handle <url: ...> pattern for HTTP POST (ARO-0052)
        if object.base == "url", let specifier = object.pathSpecifier {
            let urlString: String
            if let resolvedURL: String = context.resolve(specifier) {
                urlString = resolvedURL
            } else {
                urlString = specifier
            }
            return try await writeToURL(urlString, result: result, context: context)
        }

        // Get file path - handle <file: path-variable> pattern
        let path: String
        if object.base == "file", let specifier = object.pathSpecifier {
            // Pattern: <file: path-variable> - resolve the specifier as the path
            if let resolvedPath: String = context.resolve(specifier) {
                path = resolvedPath
            } else {
                // Use specifier as literal path
                path = specifier
            }
        } else if let resolvedPath: String = context.resolve(object.base) {
            // Pattern: <path-variable> - resolve base as path
            path = resolvedPath
        } else {
            // Use object base as literal path
            path = object.base
        }

        // An unread request body goes to the file chunk by chunk (GitLab #477):
        // the size of the upload never becomes the size of a buffer, and the
        // destination appears only once the last chunk has landed.
        if let body = context.resolveAny(result.base) as? any UnreadBody {
            let statement = "Write the <\(result.base)> to the <\(object.fullName)>"
            let chunks = try body.chunkStream(consumer: statement)
            let written = try await StreamingFileWriter.write(chunks, to: path)
            MetricsCollector.shared.recordBodyStreamed(bytes: written)
            return [
                "path": path,
                "bytes": written,
                "streamed": true,
            ] as [String: any Sendable]
        }

        // Resolve format: explicit qualifier wins over extension detection,
        // and `raw` forces a string pass-through (issue #197).
        let isRaw = result.specifiers.contains(where: { FileFormat.isRawQualifier($0) })
        let explicitFormat = result.specifiers.lazy.compactMap { FileFormat.fromQualifier($0) }.first
        let format = explicitFormat ?? FileFormat.detect(from: path)

        // Get format options from "with" clause (ARO-0040)
        // Options can include: delimiter, header, quote, encoding
        var formatOptions: [String: any Sendable] = [:]
        let configDict = resolveWithConfig(context)
        if !configDict.isEmpty {
            // Check for format options in the with-clause
            if let delimiter = configDict["delimiter"] as? String {
                formatOptions["delimiter"] = delimiter
            }
            if let header = configDict["header"] as? Bool {
                formatOptions["header"] = header
            }
            if let quote = configDict["quote"] as? String {
                formatOptions["quote"] = quote
            }
            if let encoding = configDict["encoding"] as? String {
                formatOptions["encoding"] = encoding
            }
        }

        // Get data to write - prefer resolveAny to get structured data,
        // only fall back to string if no structured data available
        let content: String
        if let value = context.resolveAny(result.base) {
            if isRaw {
                // `raw` qualifier: write the value's string form unchanged,
                // bypassing any serialiser (issue #197).
                content = (value as? String) ?? String(describing: value)
            } else if format == .binary, let strValue = value as? String {
                // Binary format pass-through for plain strings
                content = strValue
            } else {
                // Serialize structured data to the detected format
                content = FormatSerializer.serialize(value, format: format, variableName: result.base, options: formatOptions)
            }
        } else {
            content = ""
        }

        // Try file service
        if let fileService = context.service(FileSystemService.self) {
            try await fileService.write(path: path, content: content)
            return WriteResult(path: path, success: true)
        }

        throw ActionError.missingService("FileSystemService")
    }

    // MARK: - URL Support (ARO-0052)

    /// Write content to a URL via HTTP POST
    private func writeToURL(
        _ urlString: String,
        result: ResultDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        #if !os(Windows)
        // Get or create HTTP client
        let httpClient: URLSessionHTTPClient
        if let existingClient = context.service(URLSessionHTTPClient.self) {
            httpClient = existingClient
        } else {
            let newClient = URLSessionHTTPClient()
            context.register(newClient)
            httpClient = newClient
        }

        // Extract options from with { ... } clause
        var headers: [String: String] = [:]
        var timeout: TimeInterval? = nil
        var contentType: String? = nil

        let config = resolveWithConfig(context)
        if !config.isEmpty {
            // Extract headers
            if let headersValue = config["headers"] {
                if let headersDict = headersValue as? [String: String] {
                    headers = headersDict
                } else if let headersDict = headersValue as? [String: any Sendable] {
                    for (key, value) in headersDict {
                        headers[key] = String(describing: value)
                    }
                }
            }

            // Extract timeout
            if let t = config["timeout"] as? Int {
                timeout = TimeInterval(t)
            } else if let t = config["timeout"] as? Double {
                timeout = t
            }

            // Extract content-type override
            if let ct = config["content-type"] as? String {
                contentType = ct
            }
        }

        // Validate URL
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
            throw ActionError.invalidURL(urlString)
        }

        // Get data to write
        guard let value = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Serialize data to JSON for POST body (default for dictionaries/arrays)
        let bodyData: Data
        let effectiveContentType: String

        if let data = value as? Data {
            bodyData = data
            effectiveContentType = contentType ?? "application/octet-stream"
        } else if let string = value as? String {
            bodyData = string.data(using: .utf8) ?? Data()
            effectiveContentType = contentType ?? "text/plain"
        } else if let dict = value as? [String: any Sendable] {
            // Convert Sendable dict to Any for JSON serialization
            var anyDict: [String: Any] = [:]
            for (key, val) in dict {
                anyDict[key] = val
            }
            do {
                bodyData = try JSONSerialization.data(withJSONObject: anyDict)
            } catch {
                FileHandle.standardError.write(Data("[WriteAction] Warning: dict serialization failed: \(error.localizedDescription)\n".utf8))
                bodyData = Data()
            }
            effectiveContentType = contentType ?? "application/json"
        } else if let array = value as? [any Sendable] {
            // Convert Sendable array to Any for JSON serialization
            let anyArray = array.map { $0 as Any }
            do {
                bodyData = try JSONSerialization.data(withJSONObject: anyArray)
            } catch {
                FileHandle.standardError.write(Data("[WriteAction] Warning: array serialization failed: \(error.localizedDescription)\n".utf8))
                bodyData = Data()
            }
            effectiveContentType = contentType ?? "application/json"
        } else {
            // Try to serialize any other value
            bodyData = String(describing: value).data(using: .utf8) ?? Data()
            effectiveContentType = contentType ?? "text/plain"
        }

        // Set Content-Type header if not already set
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = effectiveContentType
        }

        // Perform POST request
        let response = try await httpClient.post(url: urlString, headers: headers, body: bodyData, timeout: timeout)

        // Return response information
        return URLWriteResult(
            url: urlString,
            statusCode: response.statusCode,
            success: response.statusCode >= 200 && response.statusCode < 300,
            body: response.bodyString
        )
        #else
        throw ActionError.unsupportedPlatform("HTTP client")
        #endif
    }
}

/// Result of writing to a URL
public struct URLWriteResult: Sendable {
    public let url: String
    public let statusCode: Int
    public let success: Bool
    public let body: String?

    public init(url: String, statusCode: Int, success: Bool, body: String?) {
        self.url = url
        self.statusCode = statusCode
        self.success = success
        self.body = body
    }
}

/// Result of a write operation
public struct WriteResult: Sendable, Equatable {
    public let path: String
    public let success: Bool
}
