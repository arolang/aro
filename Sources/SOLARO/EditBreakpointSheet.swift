// ============================================================
// EditBreakpointSheet.swift
// SOLARO — "Edit Breakpoint…" sheet (issue #259)
// ============================================================
//
// Reached by right-clicking (or Control-clicking) a gutter breakpoint
// marker. Lets the user refine a plain per-line breakpoint into either
// a *conditional* breakpoint (pauses only when an expression is truthy)
// or a *logpoint* (logs a message with `{variableName}` interpolation
// and does NOT pause). The chosen refinement is persisted in the file's
// `LayoutSidecar.breakpointConfigs` and forwarded to `aro debug` when a
// debug session starts.

import SwiftUI

struct EditBreakpointSheet: View {
    /// 1-indexed source line this sheet edits.
    let line: Int
    /// Whether the line currently carries a breakpoint marker. Saving
    /// always ensures one exists (editing implies intent to keep it).
    let hasBreakpoint: Bool
    let onSave: (LayoutSidecar.BreakpointConfig) -> Void
    let onCancel: () -> Void

    @State private var kind: LayoutSidecar.BreakpointConfig.Kind
    @State private var condition: String
    @State private var logMessage: String

    init(line: Int,
         config: LayoutSidecar.BreakpointConfig,
         hasBreakpoint: Bool,
         onSave: @escaping (LayoutSidecar.BreakpointConfig) -> Void,
         onCancel: @escaping () -> Void) {
        self.line = line
        self.hasBreakpoint = hasBreakpoint
        self.onSave = onSave
        self.onCancel = onCancel
        _kind = State(initialValue: config.kind)
        _condition = State(initialValue: config.condition ?? "")
        _logMessage = State(initialValue: config.logMessage ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Breakpoint — line \(line)")
                .font(.headline)

            Picker("Mode", selection: $kind) {
                Text("Breakpoint").tag(LayoutSidecar.BreakpointConfig.Kind.regular)
                Text("Logpoint").tag(LayoutSidecar.BreakpointConfig.Kind.logpoint)
            }
            .pickerStyle(.segmented)

            switch kind {
            case .regular:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Condition")
                        .font(.subheadline).bold()
                    TextField("e.g. <user: id> == 530", text: $condition)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Pauses only when this ARO expression is truthy at "
                         + "line \(line). Leave empty for an unconditional "
                         + "breakpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .logpoint:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log Message")
                        .font(.subheadline).bold()
                    TextField("e.g. reached with count={count}", text: $logMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("Logs to the console without pausing. Wrap a "
                         + "variable name in braces — {name} — to interpolate "
                         + "its current value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(makeConfig()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// A logpoint needs a message; a conditional breakpoint is always
    /// valid (an empty condition just means "unconditional").
    private var isValid: Bool {
        switch kind {
        case .regular: return true
        case .logpoint:
            return !logMessage.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func makeConfig() -> LayoutSidecar.BreakpointConfig {
        let trimmedCondition = condition.trimmingCharacters(in: .whitespaces)
        let trimmedMessage = logMessage.trimmingCharacters(in: .whitespaces)
        return LayoutSidecar.BreakpointConfig(
            kind: kind,
            condition: trimmedCondition.isEmpty ? nil : trimmedCondition,
            logMessage: trimmedMessage.isEmpty ? nil : trimmedMessage
        )
    }
}
