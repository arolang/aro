// ============================================================
// KernelComms.swift
// aro kernel — Jupyter comm protocol + ipywidgets (ARO-0091)
// ============================================================
//
// Comms are Jupyter's side channel: the front-end and the kernel
// open named channels (`comm_open`), exchange `comm_msg`, and the
// widget system (`@jupyter-widgets`) is built entirely on top of
// them. This file implements the comm registry and the widget
// subset ARO serves: **sliders and text fields bound to session
// variables**.
//
//   :widget slider <variable> [min] [max] [step]
//   :widget text <variable>
//
// creates the widget models (ipywidgets 8 vocabulary: a
// LayoutModel, a style model, and the control model referencing
// both), publishes them as `comm_open`s plus a `display_data`
// carrying `application/vnd.jupyter.widget-view+json`, and binds
// the control to the named session variable. Dragging the slider
// sends `comm_msg update` — the kernel writes the variable, so the
// next cell computes with the new value. When a cell changes the
// variable from the ARO side, the kernel pushes an update back, so
// the control follows the session.
//
// Everything here is transport-free — the kernel server injects
// `publish` — so the logic is testable without a socket.

#if !os(Windows)
import Foundation

final class KernelCommRegistry: @unchecked Sendable {

    /// One open comm. `targetName` is what the peer asked for;
    /// widgets use "jupyter.widget".
    struct Comm {
        let id: String
        let targetName: String
        /// Widget model state, kept so `request_state` can answer
        /// and `comm_info` can enumerate.
        var state: [String: Any]
    }

    /// A control bound to a session variable.
    struct BoundWidget {
        let commID: String
        let variable: String
        /// "value"'s last known state, to detect ARO-side changes.
        var lastValue: Any?
    }

    private let lock = NSLock()
    private var comms: [String: Comm] = [:]
    private var widgets: [String: BoundWidget] = [:]   // keyed by comm id

    /// Injected by the kernel server: publish one iopub message of
    /// `type` with `content` (parented to the current request).
    var publish: (_ type: String, _ content: [String: Any]) -> Void = { _, _ in }
    /// Injected: read/write session variables.
    var readVariable: (_ name: String) -> Any? = { _ in nil }
    var writeVariable: (_ name: String, _ value: Any) -> Void = { _, _ in }

    // MARK: - Peer-driven comm lifecycle

    func handleCommOpen(content: [String: Any]) {
        guard let id = content["comm_id"] as? String else { return }
        let target = content["target_name"] as? String ?? ""
        let data = content["data"] as? [String: Any] ?? [:]
        lock.withLock {
            comms[id] = Comm(id: id, targetName: target,
                             state: data["state"] as? [String: Any] ?? [:])
        }
    }

    func handleCommMsg(content: [String: Any]) {
        guard let id = content["comm_id"] as? String,
              let data = content["data"] as? [String: Any] else { return }
        let method = data["method"] as? String

        switch method {
        case "update":
            guard let state = data["state"] as? [String: Any] else { return }
            applyUpdate(commID: id, state: state)
        case "request_state":
            let state = lock.withLock { comms[id]?.state } ?? [:]
            publish("comm_msg", [
                "comm_id": id,
                "data": ["method": "update", "state": state, "buffer_paths": [Any]()],
            ])
        default:
            break
        }
    }

    func handleCommClose(content: [String: Any]) {
        guard let id = content["comm_id"] as? String else { return }
        lock.withLock {
            comms.removeValue(forKey: id)
            widgets.removeValue(forKey: id)
        }
    }

    /// `comm_info_reply` payload.
    func commInfo(targetFilter: String?) -> [String: Any] {
        let snapshot = lock.withLock { comms }
        var result: [String: Any] = [:]
        for (id, comm) in snapshot {
            if let targetFilter, comm.targetName != targetFilter { continue }
            result[id] = ["target_name": comm.targetName]
        }
        return ["status": "ok", "comms": result]
    }

    private func applyUpdate(commID: String, state: [String: Any]) {
        let variable: String? = lock.withLock {
            guard var comm = comms[commID] else { return nil }
            for (key, value) in state { comm.state[key] = value }
            comms[commID] = comm
            if var widget = widgets[commID], let value = state["value"] {
                widget.lastValue = value
                widgets[commID] = widget
                return widget.variable
            }
            return nil
        }
        if let variable, let value = state["value"] {
            writeVariable(variable, value)
        }
    }

    // MARK: - Kernel-created widgets (`:widget …`)

    /// Whether a cell is a widget command this registry owns.
    static func isWidgetCommand(_ code: String) -> Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":widget")
    }

    /// Execute a `:widget` cell. Returns an error string for bad
    /// syntax, nil on success (the widget arrives via iopub).
    func runWidgetCommand(_ code: String) -> String? {
        let words = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        // words[0] == ":widget"
        guard words.count >= 2 else { return Self.usage }

        switch words[1] {
        case "slider":
            guard words.count >= 3 else { return Self.usage }
            let variable = trimIdentifier(words[2])
            let minimum = words.count > 3 ? Int(words[3]) ?? 0 : 0
            let maximum = words.count > 4 ? Int(words[4]) ?? 100 : 100
            let step = words.count > 5 ? Int(words[5]) ?? 1 : 1
            createSlider(variable: variable, min: minimum, max: maximum, step: step)
            return nil
        case "text":
            guard words.count >= 3 else { return Self.usage }
            createText(variable: trimIdentifier(words[2]))
            return nil
        case "list":
            let snapshot = lock.withLock { widgets }
            if snapshot.isEmpty {
                publishNote("No widgets in this session.\n")
            } else {
                for (id, widget) in snapshot {
                    publishNote("<\(widget.variable)> — comm \(id)\n")
                }
            }
            return nil
        default:
            return Self.usage
        }
    }

    static let usage = """
    Usage:
      :widget slider <variable> [min] [max] [step]
      :widget text <variable>
      :widget list
    The control binds to the session variable — dragging it updates \
    the variable, and a cell that changes the variable moves the control.
    """

    private func trimIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    private func publishNote(_ text: String) {
        publish("stream", ["name": "stdout", "text": text])
    }

    /// After a cell runs, push ARO-side variable changes into the
    /// controls so they follow the session.
    func syncWidgetsFromSession() {
        let snapshot = lock.withLock { widgets }
        for (commID, widget) in snapshot {
            guard let current = readVariable(widget.variable) else { continue }
            let changed: Bool
            switch (current, widget.lastValue) {
            case (let a as Int, let b as Int):       changed = a != b
            case (let a as Double, let b as Double): changed = a != b
            case (let a as String, let b as String): changed = a != b
            case (_, nil):                            changed = true
            default:                                  changed = true
            }
            guard changed else { continue }
            lock.withLock {
                comms[commID]?.state["value"] = current
                widgets[commID]?.lastValue = current
            }
            publish("comm_msg", [
                "comm_id": commID,
                "data": ["method": "update",
                         "state": ["value": current],
                         "buffer_paths": [Any]()],
            ])
        }
    }

    // MARK: - Model construction (ipywidgets 8)

    private func createSlider(variable: String, min: Int, max: Int, step: Int) {
        let initial = (readVariable(variable) as? Int) ?? min
        writeVariable(variable, initial)

        let layoutID = openModel(name: "LayoutModel", module: "@jupyter-widgets/base",
                                 version: "2.0.0", state: [:])
        let styleID = openModel(name: "SliderStyleModel", module: "@jupyter-widgets/controls",
                                version: "2.0.0",
                                state: ["description_width": ""])
        let sliderID = openModel(
            name: "IntSliderModel", module: "@jupyter-widgets/controls", version: "2.0.0",
            viewName: "IntSliderView",
            state: [
                "description": "<\(variable)>",
                "value": initial, "min": min, "max": max, "step": step,
                "orientation": "horizontal", "readout": true,
                "readout_format": "d", "continuous_update": true,
                "disabled": false,
                "layout": "IPY_MODEL_\(layoutID)",
                "style": "IPY_MODEL_\(styleID)",
            ])

        lock.withLock {
            widgets[sliderID] = BoundWidget(commID: sliderID, variable: variable,
                                            lastValue: initial)
        }
        displayWidget(modelID: sliderID)
    }

    private func createText(variable: String) {
        let initial = (readVariable(variable) as? String) ?? ""
        writeVariable(variable, initial)

        let layoutID = openModel(name: "LayoutModel", module: "@jupyter-widgets/base",
                                 version: "2.0.0", state: [:])
        let styleID = openModel(name: "TextStyleModel", module: "@jupyter-widgets/controls",
                                version: "2.0.0",
                                state: ["description_width": ""])
        let textID = openModel(
            name: "TextModel", module: "@jupyter-widgets/controls", version: "2.0.0",
            viewName: "TextView",
            state: [
                "description": "<\(variable)>",
                "value": initial, "disabled": false,
                "continuous_update": true,
                "layout": "IPY_MODEL_\(layoutID)",
                "style": "IPY_MODEL_\(styleID)",
            ])

        lock.withLock {
            widgets[textID] = BoundWidget(commID: textID, variable: variable,
                                          lastValue: initial)
        }
        displayWidget(modelID: textID)
    }

    /// Open one widget model comm and remember its state.
    private func openModel(
        name: String, module: String, version: String,
        viewName: String? = nil,
        state: [String: Any]
    ) -> String {
        let id = UUID().uuidString
        var fullState: [String: Any] = state
        fullState["_model_name"] = name
        fullState["_model_module"] = module
        fullState["_model_module_version"] = version
        if let viewName {
            fullState["_view_name"] = viewName
            fullState["_view_module"] = module
            fullState["_view_module_version"] = version
        } else {
            fullState["_view_name"] = NSNull()
            fullState["_view_module"] = NSNull()
            fullState["_view_module_version"] = ""
        }

        lock.withLock {
            comms[id] = Comm(id: id, targetName: "jupyter.widget", state: fullState)
        }
        publish("comm_open", [
            "comm_id": id,
            "target_name": "jupyter.widget",
            "data": ["state": fullState, "buffer_paths": [Any]()],
        ])
        return id
    }

    private func displayWidget(modelID: String) {
        publish("display_data", [
            "data": [
                "application/vnd.jupyter.widget-view+json": [
                    "version_major": 2, "version_minor": 0,
                    "model_id": modelID,
                ],
                "text/plain": "widget \(modelID)",
            ],
            "metadata": [String: Any](),
        ])
    }
}
#endif
