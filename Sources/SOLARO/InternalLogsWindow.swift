// ============================================================
// InternalLogsWindow.swift
// SOLARO — combined LSP + Ask traffic viewer (View menu)
// ============================================================
//
// Hosts a standalone NSWindow that renders InternalLogStore as a
// timeline. The top of the sidebar carries category checkboxes
// (LSP / Ask) so the user can mute one channel without losing
// position. Detail pane pretty-prints JSON bodies and leaves
// prompt/response text as-is.

import SwiftUI
import AppKit

@MainActor
final class InternalLogsWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = InternalLogsView(store: InternalLogStore.shared)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 980, height: 640))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Internal Logs"
        w.center()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w, queue: .main
        ) { _ in InternalLogsWindow.window = nil }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct InternalLogsView: View {
    @Bindable var store: InternalLogStore
    @State private var selection: InternalLogStore.Entry.ID?
    @State private var enabledCategories: Set<InternalLogStore.Entry.Category>
        = Set(InternalLogStore.Entry.Category.allCases)

    private var filteredEntries: [InternalLogStore.Entry] {
        store.entries.filter { enabledCategories.contains($0.category) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 380)
            Divider().background(SolaroColor.divider)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SolaroColor.backdrop)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            filterStrip
            Divider().background(SolaroColor.divider)
            listHeader
            Divider().background(SolaroColor.divider)
            list
        }
        .background(SolaroColor.surface)
    }

    private var filterStrip: some View {
        HStack(spacing: SolaroSpace.s) {
            Text("FILTER")
                .font(SolaroFont.sectionTitle)
                .tracking(2)
                .foregroundStyle(SolaroColor.textTertiary)
            ForEach(InternalLogStore.Entry.Category.allCases) { category in
                categoryToggle(category)
            }
            Spacer()
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private func categoryToggle(
        _ category: InternalLogStore.Entry.Category
    ) -> some View {
        let on = enabledCategories.contains(category)
        return Button {
            if on {
                enabledCategories.remove(category)
            } else {
                enabledCategories.insert(category)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? SolaroColor.accent : SolaroColor.textTertiary)
                Text(category.rawValue)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(on ? SolaroColor.textPrimary
                                        : SolaroColor.textTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: SolaroRadius.s)
                    .fill(on ? SolaroColor.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var listHeader: some View {
        HStack {
            Text("\(filteredEntries.count) of \(store.entries.count)")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Button {
                selection = filteredEntries.last?.id
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(SolaroColor.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("Jump to the newest visible entry")
            Button {
                store.clear()
                selection = nil
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(SolaroColor.stateError)
            }
            .buttonStyle(.borderless)
            .help("Clear every entry from both channels")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.xs)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filteredEntries) { entry in
                row(entry)
                    .tag(entry.id)
                    .listRowBackground(
                        entry.id == selection
                            ? SolaroColor.selection
                            : Color.clear
                    )
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .background(SolaroColor.surface)
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: InternalLogStore.Entry) -> some View {
        HStack(alignment: .top, spacing: SolaroSpace.xs) {
            categoryPip(entry.category)
            Image(systemName: icon(for: entry.direction))
                .font(.system(size: 11))
                .foregroundStyle(color(for: entry.direction))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.summary)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func categoryPip(_ category: InternalLogStore.Entry.Category) -> some View {
        Text(category.rawValue)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(SolaroColor.backdrop)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(categoryColor(category))
            )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selection,
           let entry = store.entries.first(where: { $0.id == id })
        {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(entry)
                Divider().background(SolaroColor.divider)
                ScrollView {
                    Text(prettyBody(entry.body))
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SolaroSpace.m)
                }
                .background(SolaroColor.backdrop)
            }
        } else {
            VStack(spacing: SolaroSpace.s) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(SolaroColor.textTertiary)
                Text("Pick a log entry on the left.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SolaroColor.backdrop)
        }
    }

    private func detailHeader(_ entry: InternalLogStore.Entry) -> some View {
        HStack(spacing: SolaroSpace.s) {
            categoryPip(entry.category)
            Image(systemName: icon(for: entry.direction))
                .foregroundStyle(color(for: entry.direction))
            Text(entry.summary)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
            Spacer()
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.m)
        .background(SolaroColor.surface)
    }

    /// Pretty-print JSON bodies; pass anything else through.
    private func prettyBody(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: pretty, encoding: .utf8)
        else { return raw.isEmpty ? "(empty)" : raw }
        return text
    }

    // MARK: - Styling

    private func icon(for d: InternalLogStore.Entry.Direction) -> String {
        switch d {
        case .outbound: return "arrow.up.right.circle.fill"
        case .inbound:  return "arrow.down.left.circle.fill"
        case .info:     return "info.circle"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    private func color(for d: InternalLogStore.Entry.Direction) -> Color {
        switch d {
        case .outbound: return SolaroColor.accent
        case .inbound:  return SolaroColor.stateOK
        case .info:     return SolaroColor.textSecondary
        case .error:    return SolaroColor.stateError
        }
    }

    private func categoryColor(_ c: InternalLogStore.Entry.Category) -> Color {
        switch c {
        case .lsp: return SolaroColor.roleRequest
        case .ask: return SolaroColor.roleOwn
        }
    }
}
