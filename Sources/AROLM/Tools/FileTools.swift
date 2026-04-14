// ============================================================
// FileTools.swift
// AROLM - built-in file manipulation tools
// ============================================================

import Foundation

/// Factory functions returning `LMToolDescriptor`s for file operations.
/// Every tool resolves paths through a `PathGuard` rooted at the session's
/// working directory.
public enum FileTools {

    // MARK: - read_file

    public static func readFile(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path relative to the working directory")
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("1-based starting line (optional)")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of lines to return (optional)")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return LMToolDescriptor(
            name: "read_file",
            description: "Read a file from the working directory. Returns contents prefixed with line numbers.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            let url = try pathGuard.resolve(p)
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let offset = max(1, args["offset"]?.intValue ?? 1)
            let limit = args["limit"]?.intValue ?? lines.count
            let start = offset - 1
            let end = min(lines.count, start + limit)
            guard start <= end else {
                return ""
            }
            var out: [String] = []
            out.reserveCapacity(end - start)
            for i in start..<end {
                out.append("\(i + 1)\t\(lines[i])")
            }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - write_file

    public static func writeFile(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path"), .string("content")])
        ])
        return LMToolDescriptor(
            name: "write_file",
            description: "Create or overwrite a file in the working directory.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            guard let content = args["content"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'content'")
            }
            let url = try pathGuard.resolve(p)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url)
            return "wrote \(content.utf8.count) bytes to \(p)"
        }
    }

    // MARK: - edit_file

    public static func editFile(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "old": .object(["type": .string("string")]),
                "new": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path"), .string("old"), .string("new")])
        ])
        return LMToolDescriptor(
            name: "edit_file",
            description: "Exact-string replacement in a file. Fails if 'old' is not unique.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue,
                  let old = args["old"]?.stringValue,
                  let new = args["new"]?.stringValue else {
                throw LMToolError.invalidArguments("missing path/old/new")
            }
            let url = try pathGuard.resolve(p)
            let text = try String(contentsOf: url, encoding: .utf8)
            let occurrences = text.components(separatedBy: old).count - 1
            guard occurrences > 0 else {
                throw LMToolError.executionFailed("'old' string not found")
            }
            guard occurrences == 1 else {
                throw LMToolError.executionFailed("'old' string matched \(occurrences) times; must be unique")
            }
            let replaced = text.replacingOccurrences(of: old, with: new)
            try Data(replaced.utf8).write(to: url)
            return "edited \(p)"
        }
    }

    // MARK: - list_dir

    public static func listDir(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory path, defaults to working directory")
                ])
            ])
        ])
        return LMToolDescriptor(
            name: "list_dir",
            description: "List the contents of a directory.",
            parameters: params
        ) { args in
            let target: URL
            if let p = args["path"]?.stringValue {
                target = try pathGuard.resolve(p)
            } else {
                target = pathGuard.root
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            let lines: [String] = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir ? "\(url.lastPathComponent)/" : url.lastPathComponent
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - grep

    public static func grep(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object(["type": .string("string")]),
                "path": .object(["type": .string("string")])
            ]),
            "required": .array([.string("pattern")])
        ])
        return LMToolDescriptor(
            name: "grep",
            description: "Search for a regex pattern across files under the working directory.",
            parameters: params
        ) { args in
            guard let pattern = args["pattern"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'pattern'")
            }
            let root = try args["path"]?.stringValue.map { try pathGuard.resolve($0) } ?? pathGuard.root
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            var matches: [String] = []
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard let data = try? Data(contentsOf: item),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for (idx, line) in lines.enumerated() {
                    let lineString = String(line)
                    let range = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
                    if regex.firstMatch(in: lineString, options: [], range: range) != nil {
                        let rel = item.path.replacingOccurrences(of: pathGuard.root.path + "/", with: "")
                        matches.append("\(rel):\(idx + 1):\(lineString)")
                        if matches.count >= 200 { break }
                    }
                }
                if matches.count >= 200 { break }
            }
            return matches.isEmpty ? "no matches" : matches.joined(separator: "\n")
        }
    }

    public static func all(guard pathGuard: PathGuard) -> [LMToolDescriptor] {
        [
            readFile(guard: pathGuard),
            writeFile(guard: pathGuard),
            editFile(guard: pathGuard),
            listDir(guard: pathGuard),
            grep(guard: pathGuard)
        ]
    }
}
