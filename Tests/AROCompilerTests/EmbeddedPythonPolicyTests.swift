// ============================================================
// EmbeddedPythonPolicyTests.swift
// AROCompiler — whether a Python plugin may be baked in (#856, #608)
// ============================================================

import Testing
import Foundation
@testable import AROCompiler

@Suite("Embedded Python policy")
struct EmbeddedPythonPolicyTests {

    private let machinePython = (executable: "/usr/bin/python3",
                                 libraryPath: "/usr/lib/libpython3.12.dylib",
                                 stdlibPath: "/usr/lib/python3.12")

    private var embeddable: StaticPythonDistribution.Location {
        .found(StaticPythonDistribution(
            archivePath: "/d/lib/libpython3.12.a",
            stdlibPath: "/d/lib/python3.12",
            version: "3.12", root: "/d"))
    }

    private func decide(
        plugins: [String] = ["markdown"],
        linkMode: EmbeddedPythonPolicy.LinkMode = .staticLink,
        distribution: StaticPythonDistribution.Location = .absent,
        override: Bool = false
    ) -> EmbeddedPythonPolicy.Decision {
        EmbeddedPythonPolicy.decide(
            plugins: plugins, linkMode: linkMode, distribution: distribution,
            buildMachinePython: machinePython, overrideEnabled: override)
    }

    @Test func noPythonPluginsIsNotADecision() {
        #expect(decide(plugins: []) == .notApplicable)
    }

    // MARK: - The case this feature adds

    @Test func anEmbeddableDistributionMakesTheStaticBuildSucceed() {
        guard case .embedStatically(let dist) =
                decide(distribution: embeddable)
        else { Issue.record("expected embedStatically"); return }
        #expect(dist.version == "3.12")
    }

    @Test func anEmbeddableDistributionIsUsedForDynamicBuildsToo() {
        // Carrying its own interpreter is strictly better than
        // borrowing the machine's, whichever way the binary is linked.
        guard case .embedStatically = decide(linkMode: .dynamicLink,
                                             distribution: embeddable)
        else { Issue.record("expected embedStatically"); return }
    }

    // MARK: - The #608 behaviour, preserved

    @Test func aStaticBuildWithoutADistributionIsRefused() {
        guard case .refuse(let why) = decide() else {
            Issue.record("expected refuse"); return
        }
        // The refusal has to be actionable: it names the paths the
        // binary would have carried, and what to provide instead.
        #expect(why.contains("/usr/lib/python3.12"))
        #expect(why.contains(StaticPythonDistribution.environmentVariable))
        #expect(why.contains("--disable-shared"))
        // And it warns about the exact decoy that motivated all this.
        #expect(why.contains("symlink"))
    }

    @Test func aDynamicBuildWarnsAndProceeds() {
        guard case .buildWithWarning(let why) = decide(linkMode: .dynamicLink)
        else { Issue.record("expected buildWithWarning"); return }
        #expect(why.contains("NOT standalone"))
        #expect(why.contains("/usr/bin/python3"))
    }

    @Test func theOverrideBuildsButStillSaysWhatItCosts() {
        guard case .buildWithWarning(let why) = decide(override: true)
        else { Issue.record("expected buildWithWarning"); return }
        #expect(why.contains(EmbeddedPythonPolicy.overrideEnvironmentVariable))
        #expect(why.contains("NOT standalone"))
    }

    // MARK: - Reporting a rejected distribution

    @Test func aRejectedDistributionIsExplainedInTheRefusal() {
        // Somebody set ARO_STATIC_PYTHON and it did not work. Saying
        // only "cannot embed" would leave them staring at a variable
        // that looks correct.
        let rejected = StaticPythonDistribution.Location.rejected(
            .archiveIsDynamic(path: "/d/lib/libpython3.12.a"))
        guard case .refuse(let why) = decide(distribution: rejected) else {
            Issue.record("expected refuse"); return
        }
        #expect(why.contains(StaticPythonDistribution.environmentVariable))
        #expect(why.contains("/d/lib/libpython3.12.a"))
    }

    @Test func everyPluginIsNamedAndTheOrderIsStable() {
        guard case .refuse(let why) =
                decide(plugins: ["zeta", "alpha"]) else {
            Issue.record("expected refuse"); return
        }
        // Sorted, so the message does not change between builds.
        #expect(why.contains("'alpha', 'zeta'"))
    }

    @Test func aMachineWithNoPythonAtAllSaysSo() {
        let decision = EmbeddedPythonPolicy.decide(
            plugins: ["markdown"], linkMode: .staticLink,
            distribution: .absent, buildMachinePython: nil,
            overrideEnabled: false)
        guard case .refuse(let why) = decision else {
            Issue.record("expected refuse"); return
        }
        #expect(why.contains("no python3 was"))
    }
}
