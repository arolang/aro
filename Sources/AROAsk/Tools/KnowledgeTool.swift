// AROAsk - the aro_knowledge tool: ask how ARO does things

import Foundation

/// Lets the model ask the knowledge base a question mid-conversation —
/// "how do I fix an unhandled event?", "are qualifiers open-ended?" — and
/// get the curated idiom instead of inventing one. Offline, deterministic,
/// read-only; the same entries the /fix loop injects into repair prompts.
public enum KnowledgeTool {

    public static func aroKnowledge() -> AskToolDescriptor {
        AskToolDescriptor(
            name: "aro_knowledge",
            description: """
            Ask how ARO does something (knowledge base). Use BEFORE fixing a \
            diagnostic or writing unfamiliar syntax: covers event handlers, \
            unused variables, Compute qualifiers, statement shape, iteration, \
            immutability, cross-file visibility, error philosophy.
            """,
            schema: ToolParameterSchema([
                .required("question", .string, "The question, e.g. \"how do I fix an unhandled event warning?\""),
            ])
        ) { args in
            let question = try args.requireString("question")
            let hits = AROKnowledgeBase.lookup(question)
            guard !hits.isEmpty else {
                return """
                No knowledge-base entry matches. Topics covered: \
                \(AROKnowledgeBase.entries.map(\.id).joined(separator: ", ")). \
                For anything else, consult the proposals via the proposal tools.
                """
            }
            return hits.map { "[\($0.id)]\n\($0.answer)" }.joined(separator: "\n\n")
        }
    }
}
