// ============================================================
// BuildOptionsTests.swift
// SOLARO — what `aro build` is asked for (GitLab #763)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Build options", .serialized)
struct BuildOptionsTests {

    @Test func defaultsToAStaticUnoptimisedBuild() {
        let options = BuildOptions()
        // Static is the CLI's own default and the one that matches what
        // people expect of "build me a binary": one file to copy.
        #expect(options.arguments == ["--static"])
    }

    @Test func optimizeIsAppended() {
        let options = BuildOptions(optimize: true, linkage: .static)
        #expect(options.arguments == ["--static", "--optimize"])
    }

    @Test func dynamicLinkingPassesItsOwnFlag() {
        let options = BuildOptions(optimize: false, linkage: .dynamic)
        #expect(options.arguments == ["--dynamic"])
    }

    @Test func theEchoedCommandIsTheOneThatRuns() {
        // The console echo doubles as something the user can paste into
        // a terminal, so it has to be the real invocation.
        let options = BuildOptions(optimize: true, linkage: .dynamic)
        #expect(options.commandLine(projectName: "UserService")
                == "$ aro build UserService --dynamic --optimize")
    }

    @Test func everyLinkageHasAFlagAndADescription() {
        for linkage in BuildLinkage.allCases {
            #expect(linkage.flag == "--\(linkage.rawValue)")
            #expect(!linkage.displayName.isEmpty)
            #expect(!linkage.detail.isEmpty)
        }
    }

    @Test func choicesAreRememberedBetweenBuilds() {
        let defaults = UserDefaults.standard
        let previousOptimize = defaults.object(
            forKey: SolaroPrefs.buildOptimize.rawValue)
        let previousLinkage = defaults.object(
            forKey: SolaroPrefs.buildLinkage.rawValue)
        defer {
            defaults.set(previousOptimize,
                         forKey: SolaroPrefs.buildOptimize.rawValue)
            defaults.set(previousLinkage,
                         forKey: SolaroPrefs.buildLinkage.rawValue)
        }

        BuildOptions(optimize: true, linkage: .dynamic).remember()
        // So the second build is one Return press.
        #expect(BuildOptions.remembered()
                == BuildOptions(optimize: true, linkage: .dynamic))
    }

    @Test func buildAndCheckDoNotTailAnEventStream() {
        // Neither runs the program, so there is nothing to light up on
        // the canvas and no stale record to reopen.
        #expect(!ConsoleProcess.Mode.build(BuildOptions()).producesEvents)
        #expect(!ConsoleProcess.Mode.check.producesEvents)
        #expect(ConsoleProcess.Mode.run.producesEvents)
        #expect(ConsoleProcess.Mode.debug.producesEvents)
        #expect(ConsoleProcess.Mode.test(filter: nil).producesEvents)
    }
}
