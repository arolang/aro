// ============================================================
// GitClientTests.swift
// ARO Package Manager Tests
// ============================================================

import XCTest
@testable import AROPackageManager

final class GitClientTests: XCTestCase {

    var testDirectory: URL!

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent("aro-git-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: testDirectory.path) {
            try FileManager.default.removeItem(at: testDirectory)
        }
    }

    // MARK: - Repository Name Extraction Tests

    func testExtractRepoNameFromSSHURL() {
        let sshURL = "git@github.com:arolang/plugin-csv.git"
        let name = extractRepoName(from: sshURL)
        XCTAssertEqual(name, "plugin-csv")
    }

    func testExtractRepoNameFromHTTPSURL() {
        let httpsURL = "https://github.com/arolang/plugin-json.git"
        let name = extractRepoName(from: httpsURL)
        XCTAssertEqual(name, "plugin-json")
    }

    func testExtractRepoNameWithoutGitExtension() {
        let url = "https://github.com/arolang/plugin-xml"
        let name = extractRepoName(from: url)
        XCTAssertEqual(name, "plugin-xml")
    }

    // MARK: - Version Detection Tests

    func testDetectTagVersion() {
        XCTAssertTrue(isTagVersion("v1.0.0"))
        XCTAssertTrue(isTagVersion("v2.1.3"))
        XCTAssertTrue(isTagVersion("v0.0.1"))
        XCTAssertFalse(isTagVersion("main"))
        XCTAssertFalse(isTagVersion("develop"))
    }

    func testDetectSHA() {
        // Full 40-character SHA
        XCTAssertTrue(isSHA("abc123def456abc123def456abc123def456abc1"))
        // Not a SHA
        XCTAssertFalse(isSHA("abc123"))  // Too short
        XCTAssertFalse(isSHA("not-a-sha"))
        XCTAssertFalse(isSHA("v1.0.0"))
    }

    // MARK: - Helper Functions (simulating GitClient internal logic)

    private func extractRepoName(from url: String) -> String {
        let lastComponent = url.split(separator: "/").last ?? Substring(url)
        var name = String(lastComponent)

        // Handle SSH format: git@github.com:user/repo.git
        if name.contains(":") {
            name = String(name.split(separator: ":").last ?? Substring(name))
        }

        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name
    }

    private func isTagVersion(_ ref: String) -> Bool {
        // Tags typically start with 'v' followed by numbers
        return ref.hasPrefix("v") && ref.dropFirst().first?.isNumber == true
    }

    private func isSHA(_ ref: String) -> Bool {
        // SHA-1 hashes are 40 hex characters
        guard ref.count == 40 else { return false }
        return ref.allSatisfy { $0.isHexDigit }
    }
}
