// ============================================================
// ToolPromptCatalogue.swift
// AROAsk - the tool list in the prompt, generated from the registry
// ============================================================
//
// GitLab #867. `aro_system_prompt.txt` carried a hand-written list of
// seventeen tools, and nothing checked it against `ToolRegistry`. Rename a
// tool, drop one, add one, and the prompt went on describing the old set —
// and because the prompt is copied into the model directory at packaging
// time, a stale copy shipped to HuggingFace and outlived the release that
// introduced it.
//
// Worse: `aro ask` bridges MCP servers, whose tool names are not known until
// the server answers. Those could never appear in a hand-written list at all,
// so the model was being told about a fixed subset of what it actually had.
//
// The list is generated per request from the tools actually attached. The
// prompt keeps the section it always had — same header, same shape, so a
// model fine-tuned on that prompt sees the input distribution it was trained
// on — and the contents become true.

import Foundation

/// The headings tools are grouped under, in the order they render.
///
/// A tool whose group is not listed here renders after these in
/// first-appearance order, so adding a group is never a silent omission.
public enum ToolPromptGroup {
    public static let files = "Files"
    public static let project = "Project"
    public static let toolchain = "ARO toolchain"
    public static let reference = "Language reference"
    public static let scaffolding = "Scaffolding and generation"
    public static let shell = "Shell"
    public static let other = "Other"

    static let order = [files, project, toolchain, reference, scaffolding, shell, other]
}

/// Renders the tool catalogue the model is shown.
public enum ToolPromptCatalogue {

    /// Prompt-facing copy for the built-in tools, in one place.
    ///
    /// One table rather than an annotation on each tool, for the reason the
    /// reference implementation gives: the whole prompt-facing copy can then
    /// be read and edited together, which is how you notice that two tools
    /// describe themselves the same way.
    ///
    /// The cost of a table is that it can go stale in both directions — a new
    /// tool with no entry, a deleted tool whose entry lingers — so
    /// `ToolPromptCatalogueTests` asserts both. That is the test standing in
    /// for the compiler check a protocol conformance would have given.
    static let builtIns: [String: (group: String, hint: String?)] = [
        "read_file": (ToolPromptGroup.files, nil),
        "write_file": (ToolPromptGroup.files, nil),
        "edit_file": (ToolPromptGroup.files,
                      "old_string must appear exactly once in the file, or the edit is refused."),
        "list_dir": (ToolPromptGroup.files, nil),
        "grep": (ToolPromptGroup.files,
                 "Capped at 200 matches — narrow with glob rather than expecting the rest."),

        "search_project": (ToolPromptGroup.project,
                           "Semantic, not literal. Use grep when you know the exact string."),

        "aro_check": (ToolPromptGroup.toolchain, nil),   // alwaysQueried, see below
        "aro_run": (ToolPromptGroup.toolchain, nil),
        "aro_build": (ToolPromptGroup.toolchain, nil),
        "aro_test": (ToolPromptGroup.toolchain, nil),
        "parse_aro": (ToolPromptGroup.toolchain, nil),

        "list_actions": (ToolPromptGroup.reference,
                         "The live set — prefer it over recalling a verb."),
        "list_proposals": (ToolPromptGroup.reference, nil),
        "read_proposal": (ToolPromptGroup.reference, nil),
        "aro_knowledge": (ToolPromptGroup.reference,
                          "The bundled language reference — cheaper than reading a proposal."),

        "create_plugin": (ToolPromptGroup.scaffolding, nil),
        "write_openapi": (ToolPromptGroup.scaffolding, nil),
        "generate_docs": (ToolPromptGroup.scaffolding, nil),

        "run_shell": (ToolPromptGroup.shell,
                      "Last resort: prefer a dedicated tool wherever one exists."),
    ]

    /// A tool with its prompt-facing copy applied.
    ///
    /// A tool with no entry keeps whatever it declared. MCP-bridged tools
    /// have no entry by construction — their names come from a server — and
    /// land under "Other", which is the honest place for them.
    static func documented(_ tool: AskToolDescriptor) -> AskToolDescriptor {
        guard let copy = builtIns[tool.name] else { return tool }
        return tool.withPromptCopy(group: copy.group, hint: copy.hint,
                                   alwaysQueried: alwaysQueried.contains(tool.name))
    }

    /// Tools every turn that writes code must have called before answering.
    ///
    /// The same set `ToolRequirement.checkedTheCode` compels (GitLab #873):
    /// the prompt says it, the catalogue states it as a requirement, and
    /// `tool_choice` enforces it. Three places, one fact — and the
    /// requirement disappears from all three when the tool is not attached.
    static let alwaysQueried: Set<String> = ["aro_check"]

    /// Header of the section in `aro_system_prompt.txt` this replaces.
    ///
    /// Matched on the prefix rather than the whole line: the parenthetical
    /// after it is prose that may be reworded, and a substitution that stops
    /// working because somebody fixed a comma is worse than no substitution.
    static let sectionHeader = "AVAILABLE TOOLS"

    /// The generated block: one line per tool, grouped, with hints.
    public static func render(_ rawTools: [AskToolDescriptor]) -> String {
        guard !rawTools.isEmpty else {
            return "AVAILABLE TOOLS: none are attached to this request."
        }
        let tools = rawTools.map(documented)

        var seen: [String] = []
        var grouped: [String: [AskToolDescriptor]] = [:]
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            if grouped[tool.promptGroup] == nil { seen.append(tool.promptGroup) }
            grouped[tool.promptGroup, default: []].append(tool)
        }
        let groups = ToolPromptGroup.order.filter { grouped[$0] != nil }
            + seen.filter { !ToolPromptGroup.order.contains($0) }

        // Pad to the longest signature so purposes line up, the way the
        // hand-written block did. Capped: one pathological MCP tool with
        // eleven parameters should not push every other line off the right.
        let width = min(44, tools.map { $0.promptSignature.count }.max() ?? 0)

        var lines = ["AVAILABLE TOOLS (name(arguments) — purpose):"]
        for group in groups {
            lines.append("  \(group):")
            for tool in grouped[group] ?? [] {
                let signature = tool.promptSignature
                let padding = String(repeating: " ", count: max(1, width - signature.count + 1))
                lines.append("    \(signature)\(padding)\(firstSentence(of: tool.description))")
                if let hint = tool.promptHint {
                    lines.append("      \(hint)")
                }
            }
        }

        let mandatory = tools.filter(\.alwaysQueried).map(\.name).sorted()
        if !mandatory.isEmpty {
            lines.append("")
            lines.append("  Before answering, every turn that changes or writes code must have "
                       + "called: \(mandatory.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// The system prompt with its tool section replaced by the generated one.
    ///
    /// When the prompt has no such section — a user's own
    /// `aro_system_prompt.txt`, or the baked-in fallback — the block is
    /// appended instead. Either way the model ends up with one true list,
    /// and never with two lists disagreeing.
    public static func substituted(into prompt: String, tools: [AskToolDescriptor]) -> String {
        let block = render(tools)
        let lines = prompt.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(sectionHeader) }) else {
            return prompt.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n"
        }
        // The section runs to the next line that starts in column zero —
        // the tool lines are all indented, so the next unindented line is
        // the next section.
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") { break }
            end += 1
        }
        var out = Array(lines[..<start])
        out.append(contentsOf: block.components(separatedBy: "\n"))
        out.append("")
        out.append(contentsOf: lines[end...])
        return out.joined(separator: "\n")
    }

    /// The first sentence of a description, which is what a one-line
    /// catalogue entry has room for. The rest still reaches the model in
    /// the tool's own schema.
    private static func firstSentence(of description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stop = trimmed.firstIndex(of: ".") else { return trimmed }
        let sentence = String(trimmed[..<stop])
        return sentence.count < 12 ? trimmed : sentence
    }
}
