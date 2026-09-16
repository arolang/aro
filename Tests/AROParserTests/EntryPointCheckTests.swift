// ============================================================
// EntryPointCheckTests.swift
// ARO Parser Tests - exactly one Application-Start (GitLab #581)
// ============================================================
//
// `aro check` reported a clean bill of health for an application with no entry
// point, and `aro run` on the same directory failed:
//
//     $ aro check .      ✅ No issues found in 1 file(s)
//     $ aro run .        Runtime error: Entry point not found: 'Application-Start'
//
// CLAUDE.md and ARO-0005 both state the rule as "exactly ONE Application-Start
// (error if 0 or multiple)"; only the loader enforced it, so the tool whose job
// is to catch this before you run was the one tool that missed it.

import Testing
@testable import AROParser

@Suite("Entry point check (GitLab #581)")
struct EntryPointCheckTests {

    private func declaration(
        _ name: String, _ activity: String, group: String = "."
    ) -> EntryPointCheck.Declaration {
        EntryPointCheck.Declaration(name: name, activity: activity, group: group)
    }

    // MARK: - The healthy shape

    @Test("Exactly one entry point is fine")
    func oneIsFine() {
        #expect(EntryPointCheck.classify([
            declaration("Application-Start", "My App"),
            declaration("listUsers", "User API"),
        ]) == .ok)
    }

    // MARK: - None

    @Test("No entry point is reported")
    func noneIsReported() {
        #expect(EntryPointCheck.classify([
            declaration("listUsers", "User API"),
        ]) == .missing(swapped: nil))
    }

    @Test("The swapped header is named, since that is how you get here")
    func swappedHeaderIsNamed() {
        // `(Hash Demo: Application-Start)` instead of
        // `(Application-Start: Hash Demo)`. The two shapes look symmetrical and
        // nothing complained; the issue found five instances in
        // Book/ThePluginGuide alone.
        let result = EntryPointCheck.classify([
            declaration("Hash Demo", "Application-Start"),
        ])
        guard case .missing(let swapped) = result else {
            return #expect(Bool(false), "expected .missing, got \(result)")
        }
        #expect(swapped?.name == "Hash Demo")
    }

    @Test("An application with no feature sets at all is still missing one")
    func emptyIsMissing() {
        #expect(EntryPointCheck.classify([]) == .missing(swapped: nil))
    }

    // MARK: - Several in one application

    @Test("Two entry points in one application is an error")
    func twoInOneApplication() {
        let result = EntryPointCheck.classify([
            declaration("Application-Start", "One"),
            declaration("Application-Start", "Two"),
        ])
        guard case .multiple(let starts) = result else {
            return #expect(Bool(false), "expected .multiple, got \(result)")
        }
        #expect(starts.count == 2)
    }

    @Test("Two in the same subdirectory is still one application")
    func twoInOneSubdirectory() {
        // Grouping is by subdirectory, not by file — two entry points in one
        // application's `sources/` is a real error, not two applications.
        let result = EntryPointCheck.classify([
            declaration("Application-Start", "One", group: "sources"),
            declaration("Application-Start", "Two", group: "sources"),
        ])
        guard case .multiple = result else {
            return #expect(Bool(false), "expected .multiple, got \(result)")
        }
    }

    // MARK: - A directory of applications

    @Test("One entry point per subdirectory is a directory of applications")
    func separateApplications() {
        // `Examples/ModulesExample` is exactly this. `aro run` already tells it
        // apart and names the subdirectory to point at, so the check must too
        // — otherwise it reports an error the author cannot act on.
        #expect(EntryPointCheck.classify([
            declaration("Application-Start", "ModuleA", group: "ModuleA"),
            declaration("Application-Start", "ModuleB", group: "ModuleB"),
            declaration("Application-Start", "Combined", group: "Combined"),
        ]) == .separateApplications(groups: ["Combined", "ModuleA", "ModuleB"]))
    }

    @Test("A mix of grouped and ungrouped entry points is an error, not a directory")
    func mixedGroupingIsAnError() {
        // Two in one group and one in another is not "three applications".
        let result = EntryPointCheck.classify([
            declaration("Application-Start", "One", group: "sources"),
            declaration("Application-Start", "Two", group: "sources"),
            declaration("Application-Start", "Three", group: "other"),
        ])
        guard case .multiple = result else {
            return #expect(Bool(false), "expected .multiple, got \(result)")
        }
    }

    // MARK: - The name the rule is about

    @Test("The entry point name matches what the loader looks for")
    func entryPointName() {
        #expect(EntryPointCheck.entryPointName == "Application-Start")
    }

    @Test("A feature set merely containing the name is not an entry point")
    func nearMissIsNotAnEntryPoint() {
        #expect(EntryPointCheck.classify([
            declaration("Application-Started", "My App"),
            declaration("Application-Start-Up", "My App"),
        ]) == .missing(swapped: nil))
    }
}
