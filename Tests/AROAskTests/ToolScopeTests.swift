// ============================================================
// ToolScopeTests.swift
// AROAsk — which tools a request is given (GitLab #875)
// ============================================================
//
// Withholding a tool takes a capability away, so the test that matters most
// is the one showing that by default nothing is withheld at all.

import Testing
import Foundation
@testable import AROAsk

@Suite("Tool scope (#875)")
struct ToolScopeTests {

    private func tool(_ name: String, _ risk: AskToolRiskLevel) -> AskToolDescriptor {
        AskToolDescriptor(name: name, description: "x.",
                          parameters: .object([:]), riskLevel: risk) { _ in "" }
    }

    private var everything: [AskToolDescriptor] {
        [tool("read_file", .readonly), tool("grep", .readonly),
         tool("write_file", .modify), tool("edit_file", .modify),
         tool("run_shell", .execute)]
    }

    /// The default path must be exactly what it was. Narrow is the point:
    /// when in doubt, attach.
    @Test("By default every tool is attached")
    func defaultAttachesEverything() {
        let scope = ToolScope.apply(to: everything, situation: .init())
        #expect(scope.attached.count == everything.count)
        #expect(scope.withheld.isEmpty)
    }

    /// A tool the approver will refuse is not a capability — it is a round
    /// the model spends planning a write, asking, and being denied.
    @Test("Read-only withholds what would be refused anyway")
    func readOnlyWithholdsWritesAndExecutes() {
        let scope = ToolScope.apply(to: everything, situation: .init(readOnly: true))
        #expect(scope.attached.map(\.name).sorted() == ["grep", "read_file"])
        #expect(scope.withheld == ["edit_file", "run_shell", "write_file"])
    }

    /// The risk tier the approval policy already reads is the test — no
    /// second list of names to keep in step with the first.
    @Test("The risk tier decides, not a list of names")
    func riskTierIsTheTest() {
        let odd = [tool("mcp_weather", .readonly), tool("mcp_deploy", .execute)]
        let scope = ToolScope.apply(to: odd, situation: .init(readOnly: true))
        #expect(scope.attached.map(\.name) == ["mcp_weather"])
        #expect(scope.withheld == ["mcp_deploy"])
    }

    /// A model that finds no way to write should know it is a policy, so it
    /// answers with what to change instead of hunting for a missing tool.
    @Test("Withholding is said, not silent")
    func withholdingIsAnnounced() {
        #expect(ToolScope.withheldNotice([]) == nil)
        let notice = ToolScope.withheldNotice(["write_file", "run_shell"])
        #expect(notice?.contains("read-only") == true)
        #expect(notice?.contains("write_file") == true)
        #expect(notice?.contains("Describe the change") == true)
    }

    @Test("A read-only session's catalogue lists only what it has")
    func catalogueMatchesTheScope() {
        let scope = ToolScope.apply(to: everything, situation: .init(readOnly: true))
        let block = ToolPromptCatalogue.render(scope.attached)
        #expect(block.contains("read_file"))
        #expect(!block.contains("write_file"))
        #expect(!block.contains("run_shell"))
    }
}
