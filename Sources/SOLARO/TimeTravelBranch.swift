// ============================================================
// TimeTravelBranch.swift
// SOLARO — time-travel "branch & edit" UI (#447)
// ============================================================
//
// The scrubber (TimeTravelView) is read-only replay. This adds the
// wireframe-fig-11 "Branch & edit (⌥)" affordance: pick a symbol at the
// current tick, give it a new value, and re-run the feature set from that tick
// onward in an isolated sandbox (ARORuntime's TraceReplayEngine). The forked
// trace renders as a sibling rail so the user can compare it against the
// original timeline.

import SwiftUI
import ARORuntime

// MARK: - Branch & edit sheet

/// Lets the user pick one symbol from a recorded tick and override its value,
/// then kick off a downstream replay. Pure value editing — the actual replay
/// runs in the parent so the sheet can dismiss immediately.
struct BranchEditSheet: View {
    let record: TimeTravelRecord
    /// (symbolName, newRawValue) — the parent seeds + replays from this tick.
    let onReplay: (String, String) -> Void
    let onCancel: () -> Void

    @State private var selectedSymbol: String = ""
    @State private var newValue: String = ""

    private var editableSymbols: [TimeTravelRecord.Symbol] {
        // Repositories (rows-backed) aren't scalar-editable; hide them.
        record.symbols.filter { $0.records == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Branch & edit")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text("Override a value at this tick and replay the rest of the feature set in a sandbox.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if editableSymbols.isEmpty {
                Text("No scalar symbols to branch at this tick.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                Picker("Symbol", selection: $selectedSymbol) {
                    ForEach(editableSymbols, id: \.name) { s in
                        Text("\(s.name)  =  \(s.value)").tag(s.name)
                    }
                }
                .onChange(of: selectedSymbol) { _, name in
                    newValue = editableSymbols.first { $0.name == name }?.value ?? ""
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("New value")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                    TextField("value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(SolaroFont.mono)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Replay downstream") {
                    onReplay(selectedSymbol, newValue)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedSymbol.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 420)
        .background(SolaroColor.surface)
        .onAppear {
            if selectedSymbol.isEmpty, let first = editableSymbols.first {
                selectedSymbol = first.name
                newValue = first.value
            }
        }
    }
}

// MARK: - Forked sibling rail

/// Renders a forked replay as a compact sibling rail: one row per replayed
/// statement, with each row's freshest symbol values. Rows whose values
/// diverge from the original recorded run are tinted so the branch's effect is
/// visible at a glance.
struct ForkedRailView: View {
    let fork: TraceReplayEngine.Fork
    /// The mutated (symbol, value) so the header can describe the branch.
    let branchedSymbol: String
    let branchedValue: String
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(SolaroColor.roleExport)
                Text("FORK")
                    .font(SolaroFont.sectionTitle)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.roleExport)
                Text("\(branchedSymbol) = \(branchedValue)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear the fork")
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 6)

            if let error = fork.error {
                Text("Replay error: \(error)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
                    .padding(.horizontal, SolaroSpace.s)
                    .padding(.bottom, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fork.steps.indices, id: \.self) { i in
                        forkStepRow(fork.steps[i])
                    }
                    if let summary = fork.responseSummary {
                        Text("→ \(summary)")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.stateOK)
                            .padding(.horizontal, SolaroSpace.s)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, SolaroSpace.s)
            }
            .frame(maxHeight: 150)
        }
        .background(SolaroColor.surfaceRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(SolaroColor.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private func forkStepRow(_ step: FeatureSetExecutor.ReplayStep) -> some View {
        let scalars = step.symbols.filter { $0.records == nil }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(step.line >= 0 ? "L\(step.line)" : "•")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(width: 34, alignment: .trailing)
            Text(step.verb)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.accent)
                .frame(width: 64, alignment: .leading)
            Text(scalars.map { "\($0.name)=\($0.valuePreview)" }.joined(separator: "  "))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, 1)
    }
}
