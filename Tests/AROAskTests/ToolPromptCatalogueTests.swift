// ============================================================
// ToolPromptCatalogueTests.swift
// AROAsk — the tool list is generated, and cannot drift (GitLab #867)
// ============================================================
//
// The point of generating the catalogue is that it cannot disagree with the
// registry. These tests are the guard on the one place that still can: the
// copy table, which is keyed by name and so can go stale in both directions —
// a new tool with no entry, and a deleted tool whose entry lingers.
//
// That pair of assertions is what stands in for the compiler check a protocol
// conformance would have given.

import Testing
import Foundation
@testable import AROAsk

@Suite("Generated tool catalogue (#867)")
struct ToolPromptCatalogueTests {

    private func tool(_ name: String, _ description: String = "Does a thing.",
                      schema: ToolParameterSchema = ToolParameterSchema([])) -> AskToolDescriptor {
        AskToolDescriptor(name: name, description: description, schema: schema) { _ in "" }
    }

    /// Exactly the registrations `AskSession.prepare` makes before any MCP
    /// server is attached — the set the copy table is supposed to cover.
    private func builtInTools() -> [AskToolDescriptor] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let pathGuard = PathGuard(root: root)
        return FileTools.all(guard: pathGuard)
            + [ShellTool.tool(guard: pathGuard)]
            + AROTools.all(guard: pathGuard)
            + ProposalTools.all(cwd: root)
            + [KnowledgeTool.aroKnowledge()]
            + ProjectTools.all(guard: pathGuard)
            + [SearchTool.searchProject(
                store: VectorStore(storeURL: root.appendingPathComponent("index.json")),
                embedder: HashingEmbedder())]
    }

    @Test("Every built-in tool has prompt copy")
    func everyToolIsDocumented() {
        let undocumented = builtInTools()
            .map(\.name)
            .filter { ToolPromptCatalogue.builtIns[$0] == nil }
        #expect(undocumented.isEmpty,
                "tools with no entry in ToolPromptCatalogue.builtIns: \(undocumented)")
    }

    /// The other direction, which is the one a table gets wrong silently: a
    /// tool is deleted and its entry stays, so the prompt goes on describing
    /// something that no longer exists — the exact failure #867 is about.
    @Test("Every entry in the copy table names a tool that exists")
    func noStaleEntries() {
        let registered = Set(builtInTools().map(\.name))
        let stale = ToolPromptCatalogue.builtIns.keys.filter { !registered.contains($0) }.sorted()
        #expect(stale.isEmpty,
                "copy for tools that are not registered: \(stale)")
    }

    @Test("The rendered catalogue lists every tool it was given")
    func rendersEveryTool() {
        let block = ToolPromptCatalogue.render(builtInTools())
        for name in builtInTools().map(\.name) {
            #expect(block.contains(name), "'\(name)' missing from the rendered catalogue")
        }
    }

    /// The substitution replaces the shipped section rather than adding a
    /// second one. Two lists that disagree is worse than one that is wrong,
    /// because the model has no way to tell which is current.
    @Test("Substitution replaces the section, leaving one list")
    func substitutionLeavesOneList() {
        let prompt = """
        SOME EARLIER SECTION:
          things

        AVAILABLE TOOLS (name(arguments) — purpose):
          read_file(path)      read a file
          deleted_tool(x)      a tool that no longer exists

        THE STANDARD WORKFLOW for changing a project:
          1. read_file
        """
        let out = ToolPromptCatalogue.substituted(into: prompt, tools: [tool("read_file")])
        #expect(out.components(separatedBy: "AVAILABLE TOOLS").count - 1 == 1)
        #expect(!out.contains("deleted_tool"))
        #expect(out.contains("THE STANDARD WORKFLOW"))
        #expect(out.contains("SOME EARLIER SECTION"))
    }

    /// A user's own `aro_system_prompt.txt` has no such section. It must
    /// still get a true list rather than none.
    @Test("A prompt with no tool section gets the block appended")
    func promptWithoutSectionGetsBlock() {
        let out = ToolPromptCatalogue.substituted(into: "You are a helper.",
                                                  tools: [tool("read_file")])
        #expect(out.contains("You are a helper."))
        #expect(out.contains("AVAILABLE TOOLS"))
        #expect(out.contains("read_file"))
    }

    /// The names come from a server at runtime, so they can appear in no
    /// hand-written list. Being told about them is the whole reason this is
    /// generated per request rather than baked in.
    @Test("A tool with no copy still appears, under Other")
    func mcpToolsAreListed() {
        let block = ToolPromptCatalogue.render([tool("mcp_weather_lookup")])
        #expect(block.contains("mcp_weather_lookup"))
        #expect(block.contains(ToolPromptGroup.other))
    }

    @Test("The signature is derived from the schema, required arguments first")
    func signatureShape() {
        let t = tool("grep", schema: ToolParameterSchema([
            .optional("glob", .string, "filter"),
            .required("pattern", .string, "regex"),
            .optional("path", .string, "where"),
        ]))
        #expect(t.promptSignature == "grep(pattern, glob?, path?)")
    }

    @Test("A tool with no parameters renders as name()")
    func emptySignature() {
        #expect(tool("list_actions").promptSignature == "list_actions()")
    }

    /// A mandatory tool states its requirement, and — the part a static
    /// prompt could not do — the requirement disappears with the tool.
    @Test("An always-queried tool states the requirement only while attached")
    func alwaysQueriedRequirement() {
        let mandatory = AskToolDescriptor(
            name: "aro_check", description: "Check.",
            schema: ToolParameterSchema([]), riskLevel: .readonly,
            promptGroup: ToolPromptGroup.toolchain, alwaysQueried: true) { _ in "" }
        #expect(ToolPromptCatalogue.render([mandatory]).contains("must have called: aro_check"))
        #expect(!ToolPromptCatalogue.render([tool("read_file")]).contains("must have called"))
    }
}
