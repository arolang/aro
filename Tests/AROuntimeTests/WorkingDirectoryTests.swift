// ============================================================
// WorkingDirectoryTests.swift
// ARORuntime — where a relative path resolves from (GitLab #758)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

@Suite("Working directory", .serialized)
struct WorkingDirectoryTests {

    @Test func defaultsToTheProcessDirectory() {
        // Nothing set: `aro run` and every other caller behave exactly
        // as they did, because the process's own cwd is the answer.
        AROWorkingDirectory.setProcessDefault(nil)
        #expect(AROWorkingDirectory.base
                == FileManager.default.currentDirectoryPath)
    }

    @Test func aRelativePathResolvesAgainstTheBase() {
        AROWorkingDirectory.setProcessDefault("/projects/demo")
        defer { AROWorkingDirectory.setProcessDefault(nil) }
        #expect(AROWorkingDirectory.resolve("output/report.csv")
                == "/projects/demo/output/report.csv")
        #expect(AROWorkingDirectory.resolve("./notes.md")
                == "/projects/demo/./notes.md")
    }

    @Test func anAbsolutePathIsLeftAlone() {
        AROWorkingDirectory.setProcessDefault("/projects/demo")
        defer { AROWorkingDirectory.setProcessDefault(nil) }
        // A program that names /tmp/out.csv means /tmp/out.csv wherever
        // it runs; rebasing that would be a different bug.
        #expect(AROWorkingDirectory.resolve("/tmp/out.csv") == "/tmp/out.csv")
    }

    @Test func aTildePathExpandsToTheHomeDirectory() {
        AROWorkingDirectory.setProcessDefault("/projects/demo")
        defer { AROWorkingDirectory.setProcessDefault(nil) }
        let resolved = AROWorkingDirectory.resolve("~/notes.md")
        #expect(resolved.hasSuffix("/notes.md"))
        #expect(!resolved.contains("/projects/demo"))
        #expect(!resolved.hasPrefix("~"))
    }

    @Test func theScopedValueWinsOverTheProcessDefault() async {
        AROWorkingDirectory.setProcessDefault("/projects/fallback")
        defer { AROWorkingDirectory.setProcessDefault(nil) }

        await AROWorkingDirectory.$current.withValue("/projects/scoped") {
            #expect(AROWorkingDirectory.base == "/projects/scoped")
        }
        // And it is gone again outside the scope.
        #expect(AROWorkingDirectory.base == "/projects/fallback")
    }

    @Test func twoConcurrentRunsDoNotShareADirectory() async {
        // This is the reason for the task-local rather than another
        // process-global: two SOLARO windows running two projects used
        // to fight over one `chdir`.
        async let first: String = AROWorkingDirectory.$current
            .withValue("/projects/one") {
                try? await Task.sleep(for: .milliseconds(50))
                return AROWorkingDirectory.base
            }
        async let second: String = AROWorkingDirectory.$current
            .withValue("/projects/two") {
                return AROWorkingDirectory.base
            }
        let (a, b) = await (first, second)
        #expect(a == "/projects/one")
        #expect(b == "/projects/two")
    }

    @Test func aChildTaskInheritsTheDirectory() async {
        // Everything `application.run()` starts — the HTTP server's own
        // child tasks included — has to see it.
        let seen: String = await AROWorkingDirectory.$current
            .withValue("/projects/inherited") {
                await withTaskGroup(of: String.self) { group in
                    group.addTask { AROWorkingDirectory.base }
                    return await group.next() ?? ""
                }
            }
        #expect(seen == "/projects/inherited")
    }

    @Test func settingTheDefaultReturnsWhatItReplaced() {
        AROWorkingDirectory.setProcessDefault(nil)
        let previous = AROWorkingDirectory.setProcessDefault("/a")
        #expect(previous == nil)
        let second = AROWorkingDirectory.setProcessDefault("/b")
        #expect(second == "/a")
        AROWorkingDirectory.setProcessDefault(nil)
    }
}
