// ============================================================
// FileSystemServiceTests.swift
// ARO Runtime - File System Service Unit Tests
// ARO-0036: Native File and Directory Operations
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - FileInfo Tests

@Suite("FileInfo Tests")
struct FileInfoTests {

    @Test("FileInfo creation with all fields")
    func testFileInfoCreation() {
        let now = Date()
        let info = FileInfo(
            name: "test.txt",
            path: "/Users/test/test.txt",
            size: 1024,
            isFile: true,
            isDirectory: false,
            created: now,
            modified: now,
            accessed: now,
            permissions: "rw-r--r--"
        )

        #expect(info.name == "test.txt")
        #expect(info.path == "/Users/test/test.txt")
        #expect(info.size == 1024)
        #expect(info.isFile == true)
        #expect(info.isDirectory == false)
        #expect(info.permissions == "rw-r--r--")
    }

    @Test("FileInfo for directory")
    func testFileInfoDirectory() {
        let info = FileInfo(
            name: "src",
            path: "/Users/test/src",
            size: 0,
            isFile: false,
            isDirectory: true,
            created: nil,
            modified: nil,
            accessed: nil,
            permissions: "rwxr-xr-x"
        )

        #expect(info.name == "src")
        #expect(info.isFile == false)
        #expect(info.isDirectory == true)
        #expect(info.size == 0)
    }

    @Test("FileInfo toDictionary conversion")
    func testFileInfoToDictionary() {
        let now = Date()
        let info = FileInfo(
            name: "file.txt",
            path: "/path/to/file.txt",
            size: 512,
            isFile: true,
            isDirectory: false,
            created: now,
            modified: now,
            accessed: now,
            permissions: "rw-r--r--"
        )

        let dict = info.toDictionary()

        #expect((dict["name"] as? String) == "file.txt")
        #expect((dict["path"] as? String) == "/path/to/file.txt")
        #expect((dict["size"] as? Int) == 512)
        #expect((dict["isFile"] as? Bool) == true)
        #expect((dict["isDirectory"] as? Bool) == false)
        #expect((dict["permissions"] as? String) == "rw-r--r--")
    }

    @Test("FileInfo equality")
    func testFileInfoEquality() {
        let now = Date()
        let info1 = FileInfo(
            name: "test.txt",
            path: "/test.txt",
            size: 100,
            isFile: true,
            isDirectory: false,
            created: now,
            modified: now,
            accessed: now,
            permissions: "rw-"
        )
        let info2 = FileInfo(
            name: "test.txt",
            path: "/test.txt",
            size: 100,
            isFile: true,
            isDirectory: false,
            created: now,
            modified: now,
            accessed: now,
            permissions: "rw-"
        )

        #expect(info1 == info2)
    }
}

// MARK: - FileSystemError Tests

@Suite("FileSystemError Tests")
struct FileSystemErrorTests {

    @Test("FileNotFound error description")
    func testFileNotFoundDescription() {
        let error = FileSystemError.fileNotFound("/missing/file.txt")
        #expect(error.description == "File not found: /missing/file.txt")
    }

    @Test("DirectoryNotFound error description")
    func testDirectoryNotFoundDescription() {
        let error = FileSystemError.directoryNotFound("/missing/dir")
        #expect(error.description == "Directory not found: /missing/dir")
    }

    @Test("PathNotFound error description")
    func testPathNotFoundDescription() {
        let error = FileSystemError.pathNotFound("/unknown/path")
        #expect(error.description == "Path not found: /unknown/path")
    }

    @Test("ReadError description")
    func testReadErrorDescription() {
        let error = FileSystemError.readError("/file.txt", "Permission denied")
        #expect(error.description == "Error reading /file.txt: Permission denied")
    }

    @Test("WriteError description")
    func testWriteErrorDescription() {
        let error = FileSystemError.writeError("/file.txt", "Disk full")
        #expect(error.description == "Error writing /file.txt: Disk full")
    }

    @Test("DeleteError description")
    func testDeleteErrorDescription() {
        let error = FileSystemError.deleteError("/file.txt", "In use")
        #expect(error.description == "Error deleting /file.txt: In use")
    }

    @Test("ListError description")
    func testListErrorDescription() {
        let error = FileSystemError.listError("/dir", "Not accessible")
        #expect(error.description == "Error listing /dir: Not accessible")
    }

    @Test("CreateDirectoryError description")
    func testCreateDirectoryErrorDescription() {
        let error = FileSystemError.createDirectoryError("/new/dir", "Parent not exists")
        #expect(error.description == "Error creating directory /new/dir: Parent not exists")
    }

    @Test("PermissionDenied description")
    func testPermissionDeniedDescription() {
        let error = FileSystemError.permissionDenied("/protected/file")
        #expect(error.description == "Permission denied: /protected/file")
    }

    @Test("CopyError description")
    func testCopyErrorDescription() {
        let error = FileSystemError.copyError("/src", "/dst", "Source not found")
        #expect(error.description == "Error copying /src to /dst: Source not found")
    }

    @Test("MoveError description")
    func testMoveErrorDescription() {
        let error = FileSystemError.moveError("/old", "/new", "Cross-device link")
        #expect(error.description == "Error moving /old to /new: Cross-device link")
    }

    @Test("StatError description")
    func testStatErrorDescription() {
        let error = FileSystemError.statError("/file.txt", "Not accessible")
        #expect(error.description == "Error getting stats for /file.txt: Not accessible")
    }
}

// MARK: - AROFileSystemService Integration Tests

@Suite("AROFileSystemService Integration Tests")
struct AROFileSystemServiceIntegrationTests {

    /// Create a temporary directory for a test
    private static func createTempDir() throws -> String {
        let tempDir = NSTemporaryDirectory() + "ARO-FileTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Clean up a temporary directory
    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("Service exists method for existing file")
    func testExistsForExistingFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/exists_test.txt"
        FileManager.default.createFile(atPath: testFile, contents: "test".data(using: .utf8))

        #expect(service.exists(path: testFile) == true)
    }

    @Test("Service exists method for non-existing file")
    func testExistsForNonExistingFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/non_existent.txt"

        #expect(service.exists(path: testFile) == false)
    }

    @Test("Service existsWithType for file")
    func testExistsWithTypeForFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/type_test.txt"
        FileManager.default.createFile(atPath: testFile, contents: "test".data(using: .utf8))

        let (exists, isDirectory) = service.existsWithType(path: testFile)
        #expect(exists == true)
        #expect(isDirectory == false)
    }

    @Test("Service existsWithType for directory")
    func testExistsWithTypeForDirectory() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testDir = tempDir + "/subdir"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let (exists, isDirectory) = service.existsWithType(path: testDir)
        #expect(exists == true)
        #expect(isDirectory == true)
    }

    @Test("Service write and read file")
    func testWriteAndRead() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/readwrite.txt"
        let content = "Hello, ARO!"

        try await service.write(path: testFile, content: content)
        let readContent = try await service.read(path: testFile)

        #expect(readContent == content)
    }

    @Test("Service append to file")
    func testAppend() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/append.txt"

        try await service.write(path: testFile, content: "Line 1")
        try await service.append(path: testFile, content: "\nLine 2")

        let content = try await service.read(path: testFile)
        #expect(content == "Line 1\nLine 2")
    }

    @Test("Service createDirectory")
    func testCreateDirectory() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let newDir = tempDir + "/new/nested/directory"

        try await service.createDirectory(path: newDir)

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: newDir, isDirectory: &isDir)
        #expect(exists == true)
        #expect(isDir.boolValue == true)
    }

    @Test("Service copy file")
    func testCopyFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let srcFile = tempDir + "/copy_src.txt"
        let dstFile = tempDir + "/copy_dst.txt"
        let content = "Copy me!"

        try await service.write(path: srcFile, content: content)
        try await service.copy(source: srcFile, destination: dstFile)

        // Both files should exist
        #expect(service.exists(path: srcFile) == true)
        #expect(service.exists(path: dstFile) == true)

        // Content should be the same
        let copiedContent = try await service.read(path: dstFile)
        #expect(copiedContent == content)
    }

    @Test("Service move file")
    func testMoveFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let srcFile = tempDir + "/move_src.txt"
        let dstFile = tempDir + "/move_dst.txt"
        let content = "Move me!"

        try await service.write(path: srcFile, content: content)
        try await service.move(source: srcFile, destination: dstFile)

        // Source should not exist, destination should
        #expect(service.exists(path: srcFile) == false)
        #expect(service.exists(path: dstFile) == true)

        // Content should be preserved
        let movedContent = try await service.read(path: dstFile)
        #expect(movedContent == content)
    }

    @Test("Service stat file")
    func testStatFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/stat_test.txt"
        let content = "Test content for stat"

        try await service.write(path: testFile, content: content)
        let info = try await service.stat(path: testFile)

        #expect(info.name == "stat_test.txt")
        #expect(info.isFile == true)
        #expect(info.isDirectory == false)
        #expect(info.size == content.utf8.count)
    }

    @Test("Service stat directory")
    func testStatDirectory() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testDir = tempDir + "/stat_dir"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let info = try await service.stat(path: testDir)

        #expect(info.name == "stat_dir")
        #expect(info.isFile == false)
        #expect(info.isDirectory == true)
    }

    @Test("Service list directory")
    func testListDirectory() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testDir = tempDir + "/list_test"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        // Create some files
        try await service.write(path: testDir + "/file1.txt", content: "content1")
        try await service.write(path: testDir + "/file2.txt", content: "content2")
        try await service.write(path: testDir + "/file3.aro", content: "aro content")

        let entries = try await service.list(directory: testDir, pattern: nil, recursive: false)

        #expect(entries.count == 3)
    }

    @Test("Service list with pattern")
    func testListWithPattern() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testDir = tempDir + "/pattern_test"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        // Create files with different extensions
        try await service.write(path: testDir + "/code.swift", content: "swift")
        try await service.write(path: testDir + "/code.aro", content: "aro")
        try await service.write(path: testDir + "/data.json", content: "{}")

        let aroFiles = try await service.list(directory: testDir, pattern: "*.aro", recursive: false)

        #expect(aroFiles.count == 1)
        #expect(aroFiles.first?.name == "code.aro")
    }

    @Test("Service list recursive")
    func testListRecursive() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testDir = tempDir + "/recursive_test"
        let subDir = testDir + "/subdir"

        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)

        try await service.write(path: testDir + "/root.txt", content: "root")
        try await service.write(path: subDir + "/nested.txt", content: "nested")

        let allEntries = try await service.list(directory: testDir, pattern: "*.txt", recursive: true)

        #expect(allEntries.count == 2)
    }

    @Test("Service delete file")
    func testDeleteFile() async throws {
        let tempDir = try Self.createTempDir()
        defer { Self.cleanup(tempDir) }

        let service = AROFileSystemService()
        let testFile = tempDir + "/delete_test.txt"

        try await service.write(path: testFile, content: "delete me")
        #expect(service.exists(path: testFile) == true)

        try await service.delete(path: testFile)
        #expect(service.exists(path: testFile) == false)
    }
}

// MARK: - Glob Pattern Matching Tests

@Suite("Glob Pattern Matching Tests")
struct GlobPatternMatchingTests {

    @Test("Match simple asterisk pattern")
    func testAsteriskPattern() async throws {
        let service = AROFileSystemService()
        let testDir = NSTemporaryDirectory() + "glob-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        try await service.write(path: testDir + "/test1.txt", content: "a")
        try await service.write(path: testDir + "/test2.txt", content: "b")
        try await service.write(path: testDir + "/other.json", content: "{}")

        let txtFiles = try await service.list(directory: testDir, pattern: "*.txt", recursive: false)
        #expect(txtFiles.count == 2)
    }

    @Test("Match question mark pattern")
    func testQuestionMarkPattern() async throws {
        let service = AROFileSystemService()
        let testDir = NSTemporaryDirectory() + "glob-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        try await service.write(path: testDir + "/file1.txt", content: "a")
        try await service.write(path: testDir + "/file2.txt", content: "b")
        try await service.write(path: testDir + "/file10.txt", content: "c")

        let singleDigitFiles = try await service.list(directory: testDir, pattern: "file?.txt", recursive: false)
        #expect(singleDigitFiles.count == 2)
    }
}
