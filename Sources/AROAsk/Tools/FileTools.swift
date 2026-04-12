// AROAsk - built-in file manipulation tools

import Foundation

public enum FileTools {

    // MARK: - read_file

    public static func readFile(guard pg: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "read_file",
            description: "Read a file and return its contents with line numbers. Supports optional offset and limit to read a specific range of lines.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path (relative to working directory or absolute)")
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("Line number to start reading from (1-based). Defaults to 1.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of lines to return. Defaults to all remaining lines.")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("'path' is required")
            }
            let url = try pg.resolve(path)
            let filePath = url.path

            guard FileManager.default.fileExists(atPath: filePath) else {
                throw AskToolError.executionFailed("File not found: \(path)")
            }
            guard FileManager.default.isReadableFile(atPath: filePath) else {
                throw AskToolError.executionFailed("File not readable: \(path)")
            }

            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")

            let offset = max((args["offset"]?.intValue ?? 1), 1)
            let startIndex = offset - 1 // convert to 0-based

            guard startIndex < allLines.count else {
                return "(empty — offset \(offset) is beyond end of file which has \(allLines.count) lines)"
            }

            let remaining = allLines[startIndex...]
            let lines: ArraySlice<String>
            if let limit = args["limit"]?.intValue, limit > 0 {
                lines = remaining.prefix(limit)
            } else {
                lines = remaining[remaining.startIndex...]
            }

            var result = ""
            for (i, line) in lines.enumerated() {
                let lineNum = startIndex + i + 1
                result += "\(lineNum)\t\(line)\n"
            }
            return result
        }
    }

    // MARK: - write_file

    public static func writeFile(guard pg: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "write_file",
            description: "Create or overwrite a file with the given content.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path (relative to working directory or absolute)")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("The content to write to the file")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            requiresApproval: true
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("'path' is required")
            }
            guard let content = args["content"]?.stringValue else {
                throw AskToolError.invalidArguments("'content' is required")
            }
            let url = try pg.resolve(path)

            // Create parent directories if needed
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            try content.write(to: url, atomically: true, encoding: .utf8)
            let bytes = content.utf8.count
            return "Wrote \(bytes) bytes to \(path)"
        }
    }

    // MARK: - edit_file

    public static func editFile(guard pg: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "edit_file",
            description: "Perform an exact string replacement in a file. The old_string must appear exactly once in the file; the call fails if it is not found or appears more than once.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path (relative to working directory or absolute)")
                    ]),
                    "old_string": .object([
                        "type": .string("string"),
                        "description": .string("The exact text to find and replace (must be unique in the file)")
                    ]),
                    "new_string": .object([
                        "type": .string("string"),
                        "description": .string("The replacement text")
                    ])
                ]),
                "required": .array([.string("path"), .string("old_string"), .string("new_string")])
            ]),
            requiresApproval: true
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("'path' is required")
            }
            guard let oldString = args["old_string"]?.stringValue else {
                throw AskToolError.invalidArguments("'old_string' is required")
            }
            guard let newString = args["new_string"]?.stringValue else {
                throw AskToolError.invalidArguments("'new_string' is required")
            }
            let url = try pg.resolve(path)
            let filePath = url.path

            guard FileManager.default.fileExists(atPath: filePath) else {
                throw AskToolError.executionFailed("File not found: \(path)")
            }

            let content = try String(contentsOfFile: filePath, encoding: .utf8)

            let occurrences = content.components(separatedBy: oldString).count - 1
            if occurrences == 0 {
                throw AskToolError.executionFailed("old_string not found in \(path)")
            }
            if occurrences > 1 {
                throw AskToolError.executionFailed(
                    "old_string appears \(occurrences) times in \(path) — must be unique. Provide more surrounding context."
                )
            }

            let updated = content.replacingOccurrences(of: oldString, with: newString)
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return "Applied edit to \(path)"
        }
    }

    // MARK: - list_dir

    public static func listDir(guard pg: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "list_dir",
            description: "List the contents of a directory. Directories are marked with a trailing /.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Directory path (relative to working directory or absolute). Defaults to '.'")
                    ])
                ]),
                "required": .array([])
            ])
        ) { args in
            let path = args["path"]?.stringValue ?? "."
            let url = try pg.resolve(path)
            let dirPath = url.path

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDir),
                  isDir.boolValue else {
                throw AskToolError.executionFailed("Not a directory: \(path)")
            }

            let entries = try FileManager.default.contentsOfDirectory(atPath: dirPath)
            let sorted = entries.sorted()

            var result = ""
            for entry in sorted {
                let entryPath = url.appendingPathComponent(entry).path
                var entryIsDir: ObjCBool = false
                FileManager.default.fileExists(atPath: entryPath, isDirectory: &entryIsDir)
                if entryIsDir.boolValue {
                    result += "\(entry)/\n"
                } else {
                    result += "\(entry)\n"
                }
            }
            return result.isEmpty ? "(empty directory)" : result
        }
    }

    // MARK: - grep

    public static func grep(guard pg: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "grep",
            description: "Search for a regex pattern across files in a directory. Returns matching lines with file paths and line numbers, capped at 200 matches.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object([
                        "type": .string("string"),
                        "description": .string("Regular expression pattern to search for")
                    ]),
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File or directory to search in (relative to working directory or absolute). Defaults to '.'")
                    ]),
                    "glob": .object([
                        "type": .string("string"),
                        "description": .string("Glob pattern to filter files (e.g. '*.swift', '*.aro')")
                    ])
                ]),
                "required": .array([.string("pattern")])
            ])
        ) { args in
            guard let pattern = args["pattern"]?.stringValue else {
                throw AskToolError.invalidArguments("'pattern' is required")
            }
            let path = args["path"]?.stringValue ?? "."
            let globFilter = args["glob"]?.stringValue
            let url = try pg.resolve(path)

            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                throw AskToolError.invalidArguments("Invalid regex: \(error.localizedDescription)")
            }

            let maxMatches = 200
            var matches: [String] = []

            // Collect files to search
            let files = collectFiles(at: url, glob: globFilter)

            for fileURL in files {
                if matches.count >= maxMatches { break }

                guard let content = try? String(contentsOfFile: fileURL.path, encoding: .utf8) else {
                    continue
                }

                let lines = content.components(separatedBy: "\n")
                let relativePath = fileURL.path.hasPrefix(pg.root.path)
                    ? String(fileURL.path.dropFirst(pg.root.path.count + 1))
                    : fileURL.path

                for (index, line) in lines.enumerated() {
                    if matches.count >= maxMatches { break }
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        matches.append("\(relativePath):\(index + 1):\(line)")
                    }
                }
            }

            if matches.isEmpty {
                return "No matches found."
            }
            var result = matches.joined(separator: "\n")
            if matches.count >= maxMatches {
                result += "\n\n(results capped at \(maxMatches) matches)"
            }
            return result
        }
    }

    // MARK: - all(guard:)

    public static func all(guard pg: PathGuard) -> [AskToolDescriptor] {
        [
            readFile(guard: pg),
            writeFile(guard: pg),
            editFile(guard: pg),
            listDir(guard: pg),
            grep(guard: pg),
        ]
    }

    // MARK: - Private helpers

    private static func collectFiles(at url: URL, glob: String?) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }

        // Single file
        if !isDir.boolValue {
            if let glob = glob {
                return matchesGlob(url.lastPathComponent, pattern: glob) ? [url] : []
            }
            return [url]
        }

        // Directory: enumerate recursively
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            if let glob = glob {
                guard matchesGlob(fileURL.lastPathComponent, pattern: glob) else { continue }
            }
            result.append(fileURL)
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func matchesGlob(_ filename: String, pattern: String) -> Bool {
        // Convert simple glob to regex: * -> .*, ? -> ., escape dots
        var regexPattern = "^"
        for char in pattern {
            switch char {
            case "*": regexPattern += ".*"
            case "?": regexPattern += "."
            case ".": regexPattern += "\\."
            default: regexPattern += String(char)
            }
        }
        regexPattern += "$"
        return filename.range(of: regexPattern, options: .regularExpression) != nil
    }
}
