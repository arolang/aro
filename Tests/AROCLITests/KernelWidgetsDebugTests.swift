// ============================================================
// KernelWidgetsDebugTests.swift
// AROCLI — kernel comm/ipywidgets + DAP subset (ARO-0091)
// ============================================================
//
// Both layers are transport-free by construction (the kernel
// server injects publish/read/write/evaluate), so everything here
// runs without a socket.

#if !os(Windows)
import Testing
import Foundation
@testable import AROCLI

@Suite("Kernel widgets (comm protocol)")
struct KernelCommTests {

    /// A registry with captured publishes and a dictionary-backed
    /// variable store.
    private final class Harness: @unchecked Sendable {
        let registry = KernelCommRegistry()
        var published: [(type: String, content: [String: Any])] = []
        var variables: [String: Any] = [:]

        init() {
            registry.publish = { [weak self] type, content in
                self?.published.append((type, content))
            }
            registry.readVariable = { [weak self] name in self?.variables[name] }
            registry.writeVariable = { [weak self] name, value in
                self?.variables[name] = value
            }
        }
    }

    @Test(":widget slider opens the three models and displays the view")
    func sliderCreation() {
        let harness = Harness()
        let error = harness.registry.runWidgetCommand(":widget slider <volume> 0 11")
        #expect(error == nil)

        let commOpens = harness.published.filter { $0.type == "comm_open" }
        let displays = harness.published.filter { $0.type == "display_data" }
        #expect(commOpens.count == 3)   // layout + style + slider
        #expect(displays.count == 1)

        // The slider model carries the ipywidgets vocabulary and the
        // binding's bounds.
        let sliderOpen = commOpens.first { open in
            let data = open.content["data"] as? [String: Any]
            let state = data?["state"] as? [String: Any]
            return state?["_model_name"] as? String == "IntSliderModel"
        }
        let state = ((sliderOpen?.content["data"] as? [String: Any])?["state"] as? [String: Any])
        #expect(state?["min"] as? Int == 0)
        #expect(state?["max"] as? Int == 11)
        #expect(state?["_model_module"] as? String == "@jupyter-widgets/controls")
        #expect((state?["layout"] as? String)?.hasPrefix("IPY_MODEL_") == true)

        // The bound variable was seeded.
        #expect(harness.variables["volume"] as? Int == 0)

        // The display references the slider's model id.
        let view = (displays.first?.content["data"] as? [String: Any])?[
            "application/vnd.jupyter.widget-view+json"] as? [String: Any]
        #expect(view?["model_id"] as? String == sliderOpen?.content["comm_id"] as? String)
    }

    @Test("A frontend update writes the bound session variable")
    func frontendUpdateWritesVariable() throws {
        let harness = Harness()
        _ = harness.registry.runWidgetCommand(":widget slider <volume> 0 11")
        let sliderID = try #require(harness.published
            .filter { $0.type == "comm_open" }
            .first { open in
                let state = (open.content["data"] as? [String: Any])?["state"] as? [String: Any]
                return state?["_model_name"] as? String == "IntSliderModel"
            }?.content["comm_id"] as? String)

        harness.registry.handleCommMsg(content: [
            "comm_id": sliderID,
            "data": ["method": "update", "state": ["value": 7]],
        ])
        #expect((harness.variables["volume"] as? NSNumber)?.intValue == 7)
    }

    @Test("An ARO-side change pushes an update to the control")
    func sessionChangeSyncsWidget() {
        let harness = Harness()
        _ = harness.registry.runWidgetCommand(":widget slider <volume> 0 11")
        harness.published.removeAll()

        harness.variables["volume"] = 9
        harness.registry.syncWidgetsFromSession()

        let update = harness.published.first { $0.type == "comm_msg" }
        let state = (update?.content["data"] as? [String: Any])?["state"] as? [String: Any]
        #expect(state?["value"] as? Int == 9)

        // Unchanged value → no chatter.
        harness.published.removeAll()
        harness.registry.syncWidgetsFromSession()
        #expect(harness.published.isEmpty)
    }

    @Test("comm_info lists open comms; close removes them")
    func commLifecycle() {
        let harness = Harness()
        harness.registry.handleCommOpen(content: [
            "comm_id": "c1", "target_name": "jupyter.widget",
            "data": ["state": [String: Any]()],
        ])
        var info = harness.registry.commInfo(targetFilter: nil)
        #expect((info["comms"] as? [String: Any])?.keys.contains("c1") == true)

        harness.registry.handleCommClose(content: ["comm_id": "c1"])
        info = harness.registry.commInfo(targetFilter: nil)
        #expect((info["comms"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Bad :widget syntax answers with usage, not silence")
    func badSyntax() {
        let harness = Harness()
        #expect(harness.registry.runWidgetCommand(":widget") != nil)
        #expect(harness.registry.runWidgetCommand(":widget slider") != nil)
        #expect(harness.registry.runWidgetCommand(":widget dial <x>") != nil)
    }
}

@Suite("Kernel debug adapter (DAP subset)")
struct KernelDebugAdapterTests {

    private func makeAdapter(
        session: REPLSession = REPLSession(suppressLogPrefix: true),
        evaluator: @escaping (String) -> String? = { _ in nil }
    ) -> (KernelDebugAdapter, REPLSession) {
        (KernelDebugAdapter(session: session, evaluator: evaluator), session)
    }

    @Test("inspectVariables lists the session's variables")
    func inspectVariables() async throws {
        let (adapter, session) = makeAdapter()
        _ = try await session.executeStatement("Compute the <answer> from 42.")

        let reply = adapter.handle(["seq": 1, "command": "inspectVariables"])
        #expect(reply["success"] as? Bool == true)
        let variables = (reply["body"] as? [String: Any])?["variables"] as? [[String: Any]]
        let answer = variables?.first { $0["name"] as? String == "answer" }
        #expect(answer != nil)
        #expect(answer?["value"] as? String == "42")
        #expect(answer?["type"] as? String == "Int")
    }

    @Test("dumpCell writes the cell at the Murmur2-predicted path")
    func dumpCell() throws {
        let (adapter, _) = makeAdapter()
        let code = "Compute the <x> from 1."
        let reply = adapter.handle([
            "seq": 2, "command": "dumpCell", "arguments": ["code": code],
        ])
        let path = try #require(
            (reply["body"] as? [String: Any])?["sourcePath"] as? String)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(path == adapter.cellPath(for: code))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == code)
    }

    @Test("setBreakpoints answers verified: false with the reason")
    func honestBreakpoints() {
        let (adapter, _) = makeAdapter()
        let reply = adapter.handle([
            "seq": 3, "command": "setBreakpoints",
            "arguments": ["breakpoints": [["line": 2], ["line": 5]]],
        ])
        let answered = (reply["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]]
        #expect(answered?.count == 2)
        #expect(answered?.allSatisfy { ($0["verified"] as? Bool) == false } == true)
        #expect((answered?.first?["message"] as? String)?.isEmpty == false)
    }

    @Test("evaluate goes through the injected evaluator")
    func evaluate() {
        let (adapter, _) = makeAdapter(evaluator: { expression in
            expression == "6 * 7" ? "42" : nil
        })
        let good = adapter.handle([
            "seq": 4, "command": "evaluate", "arguments": ["expression": "6 * 7"],
        ])
        #expect((good["body"] as? [String: Any])?["result"] as? String == "42")

        let bad = adapter.handle([
            "seq": 5, "command": "evaluate", "arguments": ["expression": "nope"],
        ])
        #expect(bad["success"] as? Bool == false)
    }

    @Test("debugInfo names the hash scheme the paths actually use")
    func debugInfo() {
        let (adapter, _) = makeAdapter()
        let reply = adapter.handle(["seq": 6, "command": "debugInfo"])
        let body = reply["body"] as? [String: Any]
        #expect(body?["hashMethod"] as? String == "Murmur2")
        let prefix = body?["tmpFilePrefix"] as? String ?? ""
        let suffix = body?["tmpFileSuffix"] as? String ?? ""
        let seed = body?["hashSeed"] as? Int ?? -1

        // The predicted path composes exactly from these three parts.
        let code = "Log \"x\" to the <console>."
        let expected = prefix
            + String(KernelDebugAdapter.murmur2(Array(code.utf8), seed: UInt32(seed)))
            + suffix
        #expect(adapter.cellPath(for: code) == expected)
    }

    @Test("Murmur2 is deterministic and input-sensitive")
    func murmurProperties() {
        let a = KernelDebugAdapter.murmur2(Array("hello".utf8), seed: 1)
        let b = KernelDebugAdapter.murmur2(Array("hello".utf8), seed: 1)
        let c = KernelDebugAdapter.murmur2(Array("hello!".utf8), seed: 1)
        let d = KernelDebugAdapter.murmur2(Array("hello".utf8), seed: 2)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}
#endif
