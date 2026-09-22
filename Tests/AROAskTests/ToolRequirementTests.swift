// ============================================================
// ToolRequirementTests.swift
// AROAsk — a lookup this turn owes (GitLab #873)
// ============================================================
//
// `tool_choice` takes an option away from the model, so the tests that
// matter most are the ones about when it must NOT be used. Forcing a call
// the turn does not owe does damage a steer never could.

import Testing
import Foundation
@testable import AROAsk

@Suite("Tool requirements (#873)")
struct ToolRequirementTests {

    private let attached: Set<String> = ["read_file", "write_file", "aro_check", "grep"]

    @Test("Writing ARO and not checking it is owed")
    func uncheckedCodeIsOwed() {
        let owed = ToolRequirement.outstanding(
            answer: "```aro\n(Main: App) { }\n```",
            toolCallsMade: ["write_file"],
            wroteAROFile: true,
            attached: attached)
        #expect(owed.map(\.preferred) == ["aro_check"])
        #expect(owed.first?.isCompellable == true)
    }

    /// The requirement names a family, not a call. A run that checked
    /// through `aro_test` has done the work, and demanding the particular
    /// name would spend a generation on a call whose answer it already has.
    @Test("Any call in the family discharges the requirement")
    func familyDischarges() {
        for discharging in ["aro_check", "aro_test", "aro_build", "aro_mcp_aro_check"] {
            let owed = ToolRequirement.outstanding(
                answer: "```aro\n(Main: App) { }\n```",
                toolCallsMade: ["write_file", discharging],
                wroteAROFile: true,
                attached: attached)
            #expect(owed.isEmpty, "\(discharging) should have discharged it")
        }
    }

    /// A requirement that outlives its tool is the drift #867 was about.
    @Test("A requirement whose family is not attached is not owed")
    func requirementFollowsTheTool() {
        let owed = ToolRequirement.outstanding(
            answer: "```aro\n(Main: App) { }\n```",
            toolCallsMade: [],
            wroteAROFile: true,
            attached: ["read_file"])
        #expect(owed.isEmpty)
    }

    @Test("A turn that wrote no ARO owes nothing")
    func noCodeNoRequirement() {
        let owed = ToolRequirement.outstanding(
            answer: "The `when` guard runs the statement only if the condition holds.",
            toolCallsMade: [],
            wroteAROFile: false,
            attached: attached)
        #expect(owed.isEmpty)
    }

    /// Confirmed means read off what the turn produced, never guessed from
    /// the words of the request. Only confirmed requirements may be
    /// compelled — the reference implementation recorded four forced calls
    /// on a vocabulary mis-match, each returning nothing.
    @Test("Only a confirmed requirement may be compelled")
    func onlyConfirmedIsCompellable() {
        #expect(ToolRequirement.checkedTheCode().isCompellable)
        let guessed = ToolRequirement(preferred: "grep", origin: .inferred,
                                      reason: "the request mentioned a pattern")
        #expect(!guessed.isCompellable)
    }

    @Test("Writing a .aro file is what confirms it, not the request's wording")
    func writingAROIsDetectedFromTheCall() {
        #expect(ToolRequirement.wroteARO(tool: "write_file",
                                         argumentsJSON: #"{"path":"main.aro"}"#))
        #expect(ToolRequirement.wroteARO(tool: "edit_file",
                                         argumentsJSON: #"{"path":"src/users.aro"}"#))
        #expect(!ToolRequirement.wroteARO(tool: "write_file",
                                          argumentsJSON: #"{"path":"README.md"}"#))
        #expect(!ToolRequirement.wroteARO(tool: "read_file",
                                          argumentsJSON: #"{"path":"main.aro"}"#))
    }

    /// The prompt says it, the catalogue states it, and `tool_choice`
    /// enforces it. Three places, one fact.
    @Test("The catalogue and the requirement name the same tool")
    func catalogueAgreesWithTheRequirement() {
        #expect(ToolPromptCatalogue.alwaysQueried.contains("aro_check"))
        #expect(ToolRequirement.checkedTheCode().satisfiedBy.contains("aro_check"))
    }

    @Test("A request carries tool_choice in OpenAI's shape")
    func toolChoiceEncoding() throws {
        let request = LMChatRequest(
            model: "m", messages: [], tools: nil, temperature: 0.2,
            stream: false, maxTokens: nil, topP: nil, topK: nil,
            forcedToolCall: "aro_check")
        let text = try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        #expect(text.contains(#""tool_choice""#))
        #expect(text.contains(#""type":"function""#))
        #expect(text.contains(#""name":"aro_check""#))
    }

    /// Backends that cannot express it must see nothing at all, so the
    /// prose instruction in the prompt is what stands.
    @Test("No forced call means no tool_choice on the wire")
    func absentToolChoiceIsOmitted() throws {
        let request = LMChatRequest(
            model: "m", messages: [], tools: nil, temperature: 0.2,
            stream: false, maxTokens: nil, topP: nil, topK: nil, forcedToolCall: nil)
        let text = try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        #expect(!text.contains("tool_choice"))
    }
}
