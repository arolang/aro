// ============================================================
// WatchesSection.swift
// SOLARO — debugger watch expressions (#258)
// ============================================================
//
// Persistent list of identifier names the user is interested in.
// Each row evaluates against `controller.pauseSymbols`, which is
// populated both by the live debugger and by LiveValueIndex
// reading the recorded events file. v1 supports bare identifier
// lookup only; full expression evaluation (e.g. `<a> + <b>`)
// can be a phase-2 follow-up tracked in the issue.

import SwiftUI

@MainActor
@Observable
final class WatchesStore {
    private(set) var names: [String] = []
    private let defaultsKey = "solaro.watches"

    init() {
        if let arr = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            names = arr
        }
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !names.contains(trimmed) else { return }
        names.append(trimmed)
        persist()
    }

    func remove(_ name: String) {
        names.removeAll { $0 == name }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(names, forKey: defaultsKey)
    }
}

struct WatchesSection: View {
    @Bindable var controller: WorkspaceController
    @Bindable var store: WatchesStore

    @State private var newName: String = ""
    @FocusState private var newNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack {
                Text("WATCHES")
                    .font(SolaroFont.sectionTitle)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.textSecondary)
                Spacer()
                Text("\(store.names.count)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            ForEach(store.names, id: \.self) { name in
                row(name)
            }
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(SolaroColor.textTertiary)
                TextField("add a binding…", text: $newName)
                    .textFieldStyle(.plain)
                    .font(SolaroFont.mono)
                    .focused($newNameFocused)
                    .onSubmit {
                        store.add(newName)
                        newName = ""
                        newNameFocused = true
                    }
            }
            .padding(SolaroSpace.s)
            .background(SolaroColor.backdrop)
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
        .padding(.top, SolaroSpace.s)
    }

    private func row(_ name: String) -> some View {
        let symbol = controller.pauseSymbols[name]
        return HStack(alignment: .top, spacing: SolaroSpace.xs) {
            Image(systemName: symbol == nil ? "circle.dotted" : "diamond.fill")
                .foregroundStyle(symbol == nil
                                 ? SolaroColor.textTertiary
                                 : SolaroColor.accent)
                .font(.system(size: 11))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(name)
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.textPrimary)
                    Spacer()
                    Button {
                        store.remove(name)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(SolaroColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                if let symbol {
                    Text(symbol.value)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .textSelection(.enabled)
                    Text(symbol.typeName)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else {
                    Text("(no value yet — run or step the debugger)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
            }
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }
}
