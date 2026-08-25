// ============================================================
// StreamingFileWriter.swift
// ARO Runtime - Writing a stream to a file (GitLab #477)
// ============================================================
//
// The sink half of a streamed request body: chunks arrive, each
// one is written and released, and the file is only published
// under its real name once the last chunk lands.
//
// The temp-and-rename is not decoration. A streamed upload runs
// while the client is still sending, so a client that vanishes
// half way leaves a half-written file. Writing to a sibling path
// and renaming on success means the destination either does not
// exist or is complete — never a truncated file that looks fine.

import Foundation

public enum StreamingFileWriter {

    /// Write every chunk of `stream` to `path`, returning the byte count.
    ///
    /// Memory cost is one chunk regardless of total size.
    @discardableResult
    public static func write(_ stream: AROStream<Data>, to path: String) async throws -> Int {
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let partial = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).aro-partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw FileSystemError.writeError(path, "could not create a temporary file next to it")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw FileSystemError.writeError(path, error.localizedDescription)
        }

        var written = 0
        do {
            for try await chunk in stream.stream {
                try handle.write(contentsOf: chunk)
                written += chunk.count
            }
            try handle.close()
        } catch {
            try? handle.close()
            // The upload failed; leave nothing behind that looks like a file.
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw FileSystemError.writeError(path, error.localizedDescription)
        }

        return written
    }
}
