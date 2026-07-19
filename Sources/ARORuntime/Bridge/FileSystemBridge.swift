// ============================================================
// FileSystemBridge.swift
// ARORuntime - C-callable File System Interface
// ============================================================
//
// Owns the C-ABI bridge for file/directory operations, including the
// ARO-0036 extended file operations (stat, extended list, copy, move,
// append) and their glob/entry helpers.
// Extracted from ServiceBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

#if !os(Windows)

// MARK: - File System Bridge

/// Read a file
/// - Parameters:
///   - path: File path (C string)
///   - outLength: Pointer to store content length
/// - Returns: File content (caller must free with free())
@_cdecl("aro_file_read")
public func aro_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let content = try String(contentsOfFile: pathStr, encoding: .utf8)
        outLength?.pointee = content.utf8.count
        return strdup(content)
    } catch {
        print("[ARO] File read error: \(error)")
        return nil
    }
}

/// Write a file
/// - Parameters:
///   - path: File path (C string)
///   - content: File content (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_write")
public func aro_file_write(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    do {
        try contentStr.write(toFile: pathStr, atomically: true, encoding: .utf8)
        return 0
    } catch {
        print("[ARO] File write error: \(error)")
        return -1
    }
}

/// Check if file exists
/// - Parameter path: File path (C string)
/// - Returns: 1 if exists, 0 if not
@_cdecl("aro_file_exists")
public func aro_file_exists(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }
    return FileManager.default.fileExists(atPath: pathStr) ? 1 : 0
}

/// Delete a file
/// - Parameter path: File path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_delete")
public func aro_file_delete(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.removeItem(atPath: pathStr)
        return 0
    } catch {
        print("[ARO] File delete error: \(error)")
        return -1
    }
}

/// Create a directory
/// - Parameters:
///   - path: Directory path (C string)
///   - recursive: Create intermediate directories
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_directory_create")
public func aro_directory_create(
    _ path: UnsafePointer<CChar>?,
    _ recursive: Int32
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.createDirectory(
            atPath: pathStr,
            withIntermediateDirectories: recursive != 0,
            attributes: nil
        )
        return 0
    } catch {
        print("[ARO] Directory create error: \(error)")
        return -1
    }
}

/// List directory contents
/// - Parameters:
///   - path: Directory path (C string)
///   - outCount: Pointer to store entry count
/// - Returns: Array of C strings (caller must free each string and the array)
@_cdecl("aro_directory_list")
public func aro_directory_list(
    _ path: UnsafePointer<CChar>?,
    _ outCount: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: pathStr)
        outCount?.pointee = entries.count

        let result = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: entries.count)
        for (i, entry) in entries.enumerated() {
            result[i] = strdup(entry)
        }
        return result
    } catch {
        print("[ARO] Directory list error: \(error)")
        return nil
    }
}

// MARK: - ARO-0036 Extended File Operations

/// Get file stats as JSON string
/// - Parameters:
///   - path: File path (C string)
///   - outLength: Pointer to store JSON length
/// - Returns: JSON string with file stats (caller must free with free())
@_cdecl("aro_file_stat")
public func aro_file_stat(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let url = URL(fileURLWithPath: pathStr)
        let attributes = try FileManager.default.attributesOfItem(atPath: pathStr)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let size = (attributes[.size] as? Int) ?? 0
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date
        let posixPermissions = attributes[.posixPermissions] as? Int

        // Format permissions
        let permChars = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        var permissions = ""
        if let perm = posixPermissions {
            let owner = (perm >> 6) & 0o7
            let group = (perm >> 3) & 0o7
            let other = perm & 0o7
            permissions = permChars[owner] + permChars[group] + permChars[other]
        }

        // Build JSON response
        var json: [String: Any] = [
            "name": url.lastPathComponent,
            "path": url.path,
            "size": size,
            "isFile": !isDirectory,
            "isDirectory": isDirectory
        ]

        let dateFormatter = ISO8601DateFormatter()
        if let c = created {
            json["created"] = dateFormatter.string(from: c)
        }
        if let m = modified {
            json["modified"] = dateFormatter.string(from: m)
        }
        if !permissions.isEmpty {
            json["permissions"] = permissions
        }

        // try? is acceptable: the dictionary is built above from JSON-safe
        // primitives (strings/numbers), so serialization cannot realistically
        // fail; on failure we fall through to the nil return, which callers
        // already treat as "stat unavailable".
        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            outLength?.pointee = jsonStr.utf8.count
            return strdup(jsonStr)
        }
    } catch {
        print("[ARO] File stat error: \(error)")
    }
    return nil
}

/// List directory with pattern and recursive options, returns JSON
/// - Parameters:
///   - path: Directory path (C string)
///   - pattern: Glob pattern (C string, nullable)
///   - recursive: 1 for recursive, 0 for non-recursive
///   - outLength: Pointer to store JSON length
/// - Returns: JSON array of file entries (caller must free with free())
@_cdecl("aro_directory_list_extended")
public func aro_directory_list_extended(
    _ path: UnsafePointer<CChar>?,
    _ pattern: UnsafePointer<CChar>?,
    _ recursive: Int32,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    let patternStr = pattern.map { String(cString: $0) }
    let isRecursive = recursive != 0
    let fm = FileManager.default

    do {
        var entries: [[String: Any]] = []
        let directoryURL = URL(fileURLWithPath: pathStr)
        let dateFormatter = ISO8601DateFormatter()

        if isRecursive {
            let enumerator = fm.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: []
            )

            while let url = enumerator?.nextObject() as? URL {
                if matchesGlobPattern(url.lastPathComponent, pattern: patternStr) {
                    if let entry = fileEntryDict(for: url, dateFormatter: dateFormatter) {
                        entries.append(entry)
                    }
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

            for url in contents {
                if matchesGlobPattern(url.lastPathComponent, pattern: patternStr) {
                    if let entry = fileEntryDict(for: url, dateFormatter: dateFormatter) {
                        entries.append(entry)
                    }
                }
            }
        }

        // try? is acceptable: entries are dictionaries of JSON-safe primitives
        // built by fileEntryDict, so serialization cannot realistically fail;
        // on failure we fall through to the nil return, which callers already
        // treat as "listing unavailable".
        if let jsonData = try? JSONSerialization.data(withJSONObject: entries),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            outLength?.pointee = jsonStr.utf8.count
            return strdup(jsonStr)
        }
    } catch {
        print("[ARO] Directory list extended error: \(error)")
    }
    return nil
}

/// Check if path exists with type info
/// - Parameters:
///   - path: Path to check (C string)
///   - outIsDirectory: Pointer to store 1 if directory, 0 if file
/// - Returns: 1 if exists, 0 if not
@_cdecl("aro_file_exists_with_type")
public func aro_file_exists_with_type(
    _ path: UnsafePointer<CChar>?,
    _ outIsDirectory: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }

    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: pathStr, isDirectory: &isDir)
    outIsDirectory?.pointee = isDir.boolValue ? 1 : 0
    return exists ? 1 : 0
}

/// Copy file or directory
/// - Parameters:
///   - source: Source path (C string)
///   - destination: Destination path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_copy")
public func aro_file_copy(
    _ source: UnsafePointer<CChar>?,
    _ destination: UnsafePointer<CChar>?
) -> Int32 {
    guard let srcStr = source.map({ String(cString: $0) }),
          let dstStr = destination.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default

    do {
        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: dstStr)
        let destDir = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fm.fileExists(atPath: dstStr) {
            try fm.removeItem(atPath: dstStr)
        }

        try fm.copyItem(atPath: srcStr, toPath: dstStr)
        return 0
    } catch {
        print("[ARO] File copy error: \(error)")
        return -1
    }
}

/// Move file or directory
/// - Parameters:
///   - source: Source path (C string)
///   - destination: Destination path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_move")
public func aro_file_move(
    _ source: UnsafePointer<CChar>?,
    _ destination: UnsafePointer<CChar>?
) -> Int32 {
    guard let srcStr = source.map({ String(cString: $0) }),
          let dstStr = destination.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default

    do {
        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: dstStr)
        let destDir = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fm.fileExists(atPath: dstStr) {
            try fm.removeItem(atPath: dstStr)
        }

        try fm.moveItem(atPath: srcStr, toPath: dstStr)
        return 0
    } catch {
        print("[ARO] File move error: \(error)")
        return -1
    }
}

/// Append content to file
/// - Parameters:
///   - path: File path (C string)
///   - content: Content to append (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_append")
public func aro_file_append(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default
    let url = URL(fileURLWithPath: pathStr)

    do {
        if fm.fileExists(atPath: pathStr) {
            let handle = try FileHandle(forWritingTo: url)
            // try? is acceptable: best-effort cleanup — a close failure after a
            // successful write has nothing actionable for the caller.
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = contentStr.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            // Create parent directory if needed
            let parentDir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try contentStr.write(to: url, atomically: true, encoding: .utf8)
        }
        return 0
    } catch {
        print("[ARO] File append error: \(error)")
        return -1
    }
}

/// Helper: Check if filename matches glob pattern
private func matchesGlobPattern(_ name: String, pattern: String?) -> Bool {
    guard let pattern = pattern, !pattern.isEmpty else {
        return true
    }

    // Convert glob pattern to regex
    var regex = "^"
    for char in pattern {
        switch char {
        case "*": regex += ".*"
        case "?": regex += "."
        case ".": regex += "\\."
        case "[", "]": regex += String(char)
        default: regex += String(char)
        }
    }
    regex += "$"

    // The pattern is machine-built from the glob above, so compilation should
    // never fail — but if it does, every file would silently stop matching.
    // Log the broken pattern instead of hiding it.
    do {
        let compiled = try RegexCache.shared.regex(regex, options: .caseInsensitive)
        return compiled.firstMatch(
            in: name,
            options: [],
            range: NSRange(name.startIndex..., in: name)
        ) != nil
    } catch {
        FileHandle.standardError.write(Data("[ServiceBridge] Warning: glob pattern '\(pattern)' produced invalid regex '\(regex)', treating as no-match: \(error)\n".utf8))
        return false
    }
}

/// Helper: Create file entry dictionary for JSON serialization
private func fileEntryDict(for url: URL, dateFormatter: ISO8601DateFormatter) -> [String: Any]? {
    // try? is acceptable: a file can legitimately vanish between directory
    // enumeration and this stat (TOCTOU race); skipping the entry by returning
    // nil is the intended behavior for concurrent file-system churn.
    guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]) else {
        return nil
    }

    let isDirectory = resourceValues.isDirectory ?? false
    var entry: [String: Any] = [
        "name": url.lastPathComponent,
        "path": url.path,
        "size": resourceValues.fileSize ?? 0,
        "isFile": !isDirectory,
        "isDirectory": isDirectory
    ]

    if let created = resourceValues.creationDate {
        entry["created"] = dateFormatter.string(from: created)
    }
    if let modified = resourceValues.contentModificationDate {
        entry["modified"] = dateFormatter.string(from: modified)
    }

    return entry
}

#else  // os(Windows)

// MARK: - File System Stubs (Windows)
// Note: Basic file operations use Foundation and should work on Windows.
// These stubs are for API consistency.

/// Read a file (Windows - uses Foundation)
@_cdecl("aro_file_read")
public func aro_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let content = try String(contentsOfFile: pathStr, encoding: .utf8)
        outLength?.pointee = content.utf8.count
        return strdup(content)
    } catch {
        return nil
    }
}

/// Write a file (Windows - uses Foundation)
@_cdecl("aro_file_write")
public func aro_file_write(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    do {
        try contentStr.write(toFile: pathStr, atomically: true, encoding: .utf8)
        return 0
    } catch {
        return -1
    }
}

/// Check if file exists (Windows - uses Foundation)
@_cdecl("aro_file_exists")
public func aro_file_exists(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }
    return FileManager.default.fileExists(atPath: pathStr) ? 1 : 0
}

/// Delete a file (Windows - uses Foundation)
@_cdecl("aro_file_delete")
public func aro_file_delete(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.removeItem(atPath: pathStr)
        return 0
    } catch {
        return -1
    }
}

/// Create a directory (Windows - uses Foundation)
@_cdecl("aro_directory_create")
public func aro_directory_create(
    _ path: UnsafePointer<CChar>?,
    _ recursive: Int32
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.createDirectory(
            atPath: pathStr,
            withIntermediateDirectories: recursive != 0,
            attributes: nil
        )
        return 0
    } catch {
        return -1
    }
}

/// List directory contents (Windows - uses Foundation)
@_cdecl("aro_directory_list")
public func aro_directory_list(
    _ path: UnsafePointer<CChar>?,
    _ outCount: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: pathStr)
        outCount?.pointee = entries.count

        let result = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: entries.count)
        for (i, entry) in entries.enumerated() {
            result[i] = strdup(entry)
        }
        return result
    } catch {
        return nil
    }
}

#endif  // !os(Windows)
