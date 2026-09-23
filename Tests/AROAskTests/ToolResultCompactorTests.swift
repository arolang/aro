// ============================================================
// ToolResultCompactorTests.swift
// AROAsk — shrink what was read, keep where it came from (GitLab #868)
// ============================================================

import Testing
import Foundation
@testable import AROAsk

@Suite("Tool result compaction (#868)")
struct ToolResultCompactorTests {

    private func toolMessage(path: String, contents: String) -> AskMessage {
        AskMessage(role: "tool",
                   content: ToolResultEnvelope.file(path: path, contents: contents).encoded(),
                   toolCallId: "call-\(path)")
    }

    private func conversation(bodySize: Int = 4000, count: Int = 3) -> [AskMessage] {
        var msgs: [AskMessage] = [AskMessage(role: "system", content: "prompt")]
        for i in 0..<count {
            msgs.append(AskMessage(role: "assistant", content: nil))
            msgs.append(toolMessage(path: "file\(i).aro",
                                    contents: String(repeating: "x", count: bodySize)))
        }
        return msgs
    }

    /// The one rule the whole design rests on: the body is what may be
    /// taken, the path is what may not. A model that wrote `edit_file`
    /// against a path in round eight must still be able to name it later.
    @Test("Every level keeps the path")
    func provenanceSurvivesEveryLevel() throws {
        for level in ToolResultCompactor.Level.allCases {
            var msgs = conversation()
            _ = ToolResultCompactor.compact(&msgs, to: level, keepingRecent: 0)
            let tools = msgs.filter { $0.role == "tool" }
            for (i, msg) in tools.enumerated() {
                let content = try #require(msg.content)
                let envelope = try #require(ToolResultEnvelope.parse(content))
                #expect(envelope.items.first?.source == "file\(i).aro",
                        "level \(level) lost the path")
            }
        }
    }

    /// An empty body is a claim about the file. A marker is a claim about
    /// the transcript, which is the true one.
    @Test("An elided body says so, rather than reading as an empty file")
    func markerRatherThanEmptiness() throws {
        var msgs = conversation()
        _ = ToolResultCompactor.compact(&msgs, to: .noBodies, keepingRecent: 0)
        let content = try #require(msgs.first { $0.role == "tool" }?.content)
        let visible = ToolResultEnvelope.visible(content)
        #expect(!visible.isEmpty)
        #expect(visible.contains("elided"))
        #expect(visible.contains("file0.aro"))
    }

    @Test("Each level is smaller than the one before")
    func levelsAreOrdered() {
        var sizes: [Int] = []
        for level in ToolResultCompactor.Level.allCases {
            var msgs = conversation()
            _ = ToolResultCompactor.compact(&msgs, to: level, keepingRecent: 0)
            sizes.append(msgs.reduce(0) { $0 + ($1.content?.count ?? 0) })
        }
        #expect(sizes == sizes.sorted(by: >), "levels did not shrink monotonically: \(sizes)")
    }

    /// The model is mid-thought about the last few messages. Compacting the
    /// result it is about to read is how you make it read the file again.
    @Test("Recent results are left alone")
    func recentResultsSurvive() throws {
        var msgs = conversation(count: 4)
        _ = ToolResultCompactor.compact(&msgs, to: .dropped, keepingRecent: 2)
        let last = try #require(msgs.last?.content)
        #expect(ToolResultEnvelope.visible(last).count > 1000)
    }

    /// Replacing a short result with a longer explanation of its absence
    /// would be a loss on both counts.
    @Test("A result smaller than its own marker is untouched")
    func shortResultsAreNotGrown() {
        var msgs: [AskMessage] = [
            AskMessage(role: "tool", content: "ok", toolCallId: "c"),
        ]
        let report = ToolResultCompactor.compact(&msgs, to: .dropped, keepingRecent: 0)
        #expect(report.compacted == 0)
        #expect(msgs[0].content == "ok")
    }

    @Test("Only tool messages are touched")
    func onlyToolMessagesChange() {
        var msgs: [AskMessage] = [
            AskMessage(role: "system", content: String(repeating: "s", count: 5000)),
            AskMessage(role: "user", content: String(repeating: "u", count: 5000)),
            AskMessage(role: "assistant", content: String(repeating: "a", count: 5000)),
        ]
        let before = msgs.map(\.content)
        _ = ToolResultCompactor.compact(&msgs, to: .dropped, keepingRecent: 0)
        #expect(msgs.map(\.content) == before)
    }

    /// An MCP result has no envelope. It must still be compactable — the
    /// marker just cannot name a source.
    @Test("A result with no envelope still compacts")
    func unenvelopedResultsCompact() {
        var msgs: [AskMessage] = [
            AskMessage(role: "tool", content: String(repeating: "x", count: 5000), toolCallId: "c"),
        ]
        let report = ToolResultCompactor.compact(&msgs, to: .noBodies, keepingRecent: 0)
        #expect(report.compacted == 1)
        #expect(msgs[0].content?.contains("earlier output") == true)
    }

    @Test("Compaction stops as soon as the conversation fits")
    func stopsAtTheCheapestStepThatWorks() {
        var msgs = conversation(bodySize: 4000, count: 3)
        let budget = 6000
        let report = ToolResultCompactor.compactUntilFits(
            &msgs,
            fits: { $0.reduce(0) { $0 + ($1.content?.count ?? 0) } < budget },
            keepingRecent: 0)
        #expect(report.didAnything)
        // Truncating three 4000-character bodies to 600 is enough, so the
        // harsher levels should not have run.
        #expect(report.level == .shortBodies)
    }

    @Test("Nothing left to shrink is reported, not looped on")
    func exhaustionIsReported() {
        var msgs: [AskMessage] = [AskMessage(role: "user", content: "short")]
        let report = ToolResultCompactor.compactUntilFits(&msgs, fits: { _ in false })
        #expect(!report.didAnything)
    }
}
