// ============================================================
// LearningCourseTests.swift
// SOLARO — first-run Learning-notebook offer (Swift Testing)
// ============================================================
//
// Everything here is offline: the pure pieces that decide which
// ref gets fetched, which URL is built, where the course lands,
// and whether a copy is already installed. The network walk
// itself is not exercised — a test that hits api.github.com would
// fail on a plane.

import Testing
import Foundation
@testable import SOLARO

@Suite("Learning course")
struct LearningCourseTests {

    // MARK: - version → tag

    @Test("A release version maps to the bare tag upstream uses")
    func releaseVersionMapsToTag() {
        #expect(LearningCourse.releaseTag(forVersion: "0.11.2") == "0.11.2")
        #expect(LearningCourse.releaseTag(forVersion: "0.11.6") == "0.11.6")
        // Whitespace from a stamped build file is trimmed.
        #expect(LearningCourse.releaseTag(forVersion: " 0.11.2\n") == "0.11.2")
    }

    @Test("A v-prefixed version loses the v — upstream tags are bare")
    func vPrefixIsDropped() {
        #expect(LearningCourse.releaseTag(forVersion: "v0.11.2") == "0.11.2")
        #expect(LearningCourse.releaseTag(forVersion: "V0.2.2-beta.10") == "0.2.2-beta.10")
    }

    @Test("Un-stamped builds have no tag")
    func unstampedBuildsHaveNoTag() {
        #expect(LearningCourse.releaseTag(forVersion: "dev") == nil)
        #expect(LearningCourse.releaseTag(forVersion: "unknown") == nil)
        #expect(LearningCourse.releaseTag(forVersion: "") == nil)
        #expect(LearningCourse.releaseTag(forVersion: "0.11.2-dirty") == nil)
    }

    @Test("The download ref is the tag, or main when there is none")
    func refFallsBackToMain() {
        #expect(LearningCourse.ref(forVersion: "0.11.2") == "0.11.2")
        #expect(LearningCourse.ref(forVersion: "dev") == LearningCourse.fallbackRef)
        #expect(LearningCourse.isFallbackRef(LearningCourse.ref(forVersion: "dev")))
        #expect(!LearningCourse.isFallbackRef(LearningCourse.ref(forVersion: "0.11.2")))
    }

    // MARK: - URLs

    @Test("The listing URL pins the Contents API to the release tag")
    func listingURLPinsTheTag() {
        let url = LearningCourse.listingURL(ref: "0.11.2")
        #expect(url.absoluteString
            == "https://api.github.com/repos/arolang/aro/contents/Learning?ref=0.11.2")
    }

    @Test("Sub-directories get their own listing URL")
    func listingURLForSubdirectory() {
        let url = LearningCourse.listingURL(ref: "0.11.2", path: "Learning/data")
        #expect(url.absoluteString
            == "https://api.github.com/repos/arolang/aro/contents/Learning/data?ref=0.11.2")
    }

    @Test("Repository paths are rebased onto the local mirror")
    func repositoryPathsAreRebased() {
        #expect(LearningCourse
            .relativePath(fromRepositoryPath: "Learning/01-hello-aro.repl")
            == "01-hello-aro.repl")
        #expect(LearningCourse
            .relativePath(fromRepositoryPath: "Learning/data/menu.yaml")
            == "data/menu.yaml")
        // Nothing to strip — left alone rather than mangled.
        #expect(LearningCourse.relativePath(fromRepositoryPath: "README.md")
            == "README.md")
    }

    // MARK: - Destination

    @Test("The course installs into Documents when there is one")
    func destinationPrefersDocuments() {
        let documents = URL(fileURLWithPath: "/Users/someone/Documents")
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        let destination = LearningCourse.destinationDirectory(
            documentsDirectory: documents,
            applicationSupportDirectory: support)
        #expect(destination.path == "/Users/someone/Documents/ARO Learning")
    }

    @Test("Without a Documents directory it falls back to Application Support")
    func destinationFallsBackToApplicationSupport() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        let destination = LearningCourse.destinationDirectory(
            documentsDirectory: nil,
            applicationSupportDirectory: support)
        #expect(destination.path
            == "/Users/someone/Library/Application Support/SOLARO/ARO Learning")
    }

    @Test("With neither, it still names a path rather than crashing")
    func destinationAlwaysResolves() {
        let destination = LearningCourse.destinationDirectory(
            documentsDirectory: nil, applicationSupportDirectory: nil)
        #expect(destination.lastPathComponent == LearningCourse.folderName)
        #expect(destination.deletingLastPathComponent().lastPathComponent == "Documents")
    }

    // MARK: - Already installed

    @Test("A directory of notebooks reads as installed")
    func notebooksReadAsInstalled() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["02-values-and-literals.repl", "01-hello-aro.repl", "README.md"] {
            try Data("{}".utf8)
                .write(to: root.appendingPathComponent(name))
        }
        #expect(LearningCourse.isInstalled(at: root))
        #expect(LearningCourse.installedNotebooks(at: root)
            == ["01-hello-aro.repl", "02-values-and-literals.repl"])
    }

    @Test("A missing or notebook-free directory is not an install")
    func emptyDirectoryIsNotAnInstall() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!LearningCourse.isInstalled(at: root))
        // A stray README on its own is not the course either — an
        // empty shell must not lock the user out of downloading it.
        try Data("hi".utf8).write(to: root.appendingPathComponent("README.md"))
        #expect(!LearningCourse.isInstalled(at: root))
        #expect(!LearningCourse.isInstalled(
            at: root.appendingPathComponent("nope")))
    }

    // MARK: - When to ask

    @Test("The offer only appears on a launch with no prior state")
    func promptsOnlyOnAFirstLaunch() {
        #expect(LearningCourse.shouldPromptOnLaunch(
            answered: false, hasRecentProjects: false, isInstalled: false))
    }

    @Test("Answering it once — either way — retires the prompt")
    func answeringRetiresThePrompt() {
        #expect(!LearningCourse.shouldPromptOnLaunch(
            answered: true, hasRecentProjects: false, isInstalled: false))
    }

    @Test("An existing user is not onboarded again")
    func existingStateSuppressesThePrompt() {
        #expect(!LearningCourse.shouldPromptOnLaunch(
            answered: false, hasRecentProjects: true, isInstalled: false))
        #expect(!LearningCourse.shouldPromptOnLaunch(
            answered: false, hasRecentProjects: false, isInstalled: true))
    }

    // MARK: - Store

    @MainActor
    @Test("A store over an existing copy starts installed and idle")
    func storeSeesAnExistingCopy() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(LearningCourse.folderName)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: destination.appendingPathComponent(LearningCourse.openingNotebook))

        let store = LearningCourseStore(destination: destination)
        #expect(store.isInstalled)
        #expect(store.installedNotebooks == [LearningCourse.openingNotebook])
        #expect(store.phase == .idle)
        #expect(!store.isDownloading)
        #expect(store.lastRef == nil)
    }

    @MainActor
    @Test("A store over an empty destination offers a download")
    func storeSeesNoCopy() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningCourseStore(
            destination: root.appendingPathComponent(LearningCourse.folderName))
        #expect(!store.isInstalled)
        #expect(store.installedNotebooks.isEmpty)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-learning-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }
}
