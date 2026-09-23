// ============================================================
// PromptDriftTests.swift
// AROAsk — the shipped prompt still matches the code (GitLab #880)
// ============================================================
//
// `Train/release/aro_system_prompt.txt` is 323 lines, names specific tools,
// shows worked ARO, and is copied into the model directory at packaging time
// so it ships to HuggingFace. Nothing tested it. A tool rename, a qualifier
// that stops existing, or an example the parser no longer accepts reached
// users inside a model download.
//
// That is not hypothetical. `Scripts/check-doc-examples.py` exists because
// thirteen invented verbs were being presented as built-ins in the
// documentation (GitLab #834), and the system prompt is documentation with a
// shorter path to the model than any of it.
//
// These assertions are cheap and they fail loudly, which is the whole point:
// drift should be a red build rather than a discovery.

import Testing
import Foundation
@testable import AROAsk
@testable import AROParser

@Suite("System prompt drift (#880)")
struct PromptDriftTests {

    /// The shipped prompt, if this checkout has it. A package built without
    /// `Train/` is not a failure — there is simply nothing to check.
    private func shippedPrompt() -> String? {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("Train/release/aro_system_prompt.txt")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try? String(contentsOf: candidate, encoding: .utf8)
            }
        }
        return nil
    }

    private var registeredToolNames: Set<String> {
        Set(ToolPromptCatalogue.builtIns.keys)
    }

    /// Tool names the prompt states as fact, outside the generated
    /// catalogue. After #867 the catalogue is generated and cannot drift;
    /// the prose around it still can, and it is where `search_knowledge`
    /// hid.
    @Test("Every tool the prompt names in prose is registered")
    func prosePromptNamesRealTools() throws {
        guard let prompt = shippedPrompt() else { return }

        // Identifier-shaped words that look like tool names: lowercase with
        // an underscore. Narrow on purpose — a check that fires on ordinary
        // prose is the noise #823 is about.
        let pattern = #"\b([a-z]+(?:_[a-z]+)+)\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(prompt.startIndex..., in: prompt)

        // Words that are identifier-shaped but are not tools: ARO framework
        // variables, file names, and the wrapper prefixes the prompt warns
        // the model *not* to use.
        let notTools: Set<String> = [
            "aro_mcp_", "mcp_", "no_think", "tool_call", "aro_system_prompt",
            "openapi_yaml", "main_aro", "business_activity", "feature_set",
            "aro_coder",
        ]

        var unknown: Set<String> = []
        for match in regex.matches(in: prompt, range: range) {
            guard let r = Range(match.range(at: 1), in: prompt) else { continue }
            let word = String(prompt[r])
            if notTools.contains(word) { continue }
            // The prompt shows `aro_mcp_aro_check` and friends as WRONG —
            // the wrapper prefixes it tells the model never to use. A
            // counter-example is not a claim that the tool exists.
            if word.hasPrefix("aro_mcp_") || word.hasPrefix("mcp_")
                || word.hasPrefix("functions_") { continue }
            // Only judge words that look like our tools: they all start with
            // a verb we use, or the aro_ prefix.
            let looksLikeATool = word.hasPrefix("aro_")
                || word.hasPrefix("read_") || word.hasPrefix("write_")
                || word.hasPrefix("edit_") || word.hasPrefix("list_")
                || word.hasPrefix("search_") || word.hasPrefix("create_")
                || word.hasPrefix("generate_") || word.hasPrefix("parse_")
                || word.hasPrefix("run_")
            guard looksLikeATool else { continue }
            if !registeredToolNames.contains(word) { unknown.insert(word) }
        }

        #expect(unknown.isEmpty,
                "the shipped prompt names tools that are not registered: \(unknown.sorted())")
    }

    /// The prompt is the corpus the model is trained on. A block the parser
    /// rejects teaches syntax the language does not have — GitLab #834's
    /// failure, with a shorter path to the model.
    @Test("Every Compute qualifier the prompt shows exists")
    func promptQualifiersExist() throws {
        guard let prompt = shippedPrompt() else { return }

        let pattern =
            #"(?i)\b(?:Compute|Calculate|Derive)\s+(?:the\s+)?<[A-Za-z0-9_-]+:\s*([A-Za-z][A-Za-z0-9|.-]*)\s*>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(prompt.startIndex..., in: prompt)

        var unknown: Set<String> = []
        for match in regex.matches(in: prompt, range: range) {
            guard let r = Range(match.range(at: 1), in: prompt) else { continue }
            let qualifier = String(prompt[r])
            // Namespaced and chained qualifiers resolve at run time; `aro
            // check` accepts them and so must this.
            if qualifier.contains(".") || qualifier.contains("|") { continue }
            if ComputeQualifierCatalog.isUncheckable(qualifier) { continue }
            if !ComputeQualifierCatalog.isBuiltIn(qualifier) { unknown.insert(qualifier) }
        }

        #expect(unknown.isEmpty,
                "the shipped prompt teaches qualifiers ARO does not have: \(unknown.sorted())")
    }

    /// After #867 the catalogue is generated into this section, so the
    /// section has to still be there for the substitution to find.
    @Test("The prompt still has the section the catalogue replaces")
    func promptHasTheToolSection() {
        guard let prompt = shippedPrompt() else { return }
        #expect(prompt.contains(ToolPromptCatalogue.sectionHeader),
                "the generated catalogue has nowhere to go — it would be appended instead")
    }

    /// Substituting into the real shipped prompt must leave one list, not
    /// two that disagree.
    @Test("Substitution into the shipped prompt leaves one tool list")
    func substitutionWorksOnTheRealPrompt() {
        guard let prompt = shippedPrompt() else { return }
        let tool = AskToolDescriptor(name: "read_file", description: "Read.",
                                     parameters: .object([:]), riskLevel: .readonly) { _ in "" }
        let out = ToolPromptCatalogue.substituted(into: prompt, tools: [tool])
        #expect(out.components(separatedBy: ToolPromptCatalogue.sectionHeader).count - 1 == 1)
        // The sections after the tool list must survive.
        #expect(out.contains("THE STANDARD WORKFLOW"))
    }
}
