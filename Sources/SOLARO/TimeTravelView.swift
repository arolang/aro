// ============================================================
// TimeTravelView.swift
// SOLARO — JSONL event-log scrubber (Phase 11)
// ============================================================
//
// Wireframe target: note 8467 figure 11 (time-travel view).
//
// Reads the most recent `.solaro/events.jsonl` recorded by
// `aro debug --record` (#229 Phase 4) and shows it as a
// scrubbable timeline with a synchronized record detail panel.

import SwiftUI

struct TimeTravelView: View {
    let project: Project
    let onClose: () -> Void

    @State private var records: [TimeTravelRecord] = []
    @State private var currentIndex: Int = 0
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            content
        }
        .frame(width: 720, height: 540)
        .background(SolaroColor.surface)
        .onAppear(perform: load)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Time travel")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(events_jsonl_path)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reload", action: load)
            Button("Close") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(SolaroSpace.m)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            empty(
                icon: "exclamationmark.triangle",
                title: "Could not read events.",
                subtitle: loadError
            )
        } else if records.isEmpty {
            empty(
                icon: "clock.arrow.circlepath",
                title: "No recorded events yet.",
                subtitle: "Run `aro debug --record \(project.rootPath.lastPathComponent)` to populate this view."
            )
        } else {
            HStack(spacing: 0) {
                timelineList
                Divider().background(SolaroColor.divider)
                detailPane
            }
        }
    }

    private var timelineList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { currentIndex },
                set: { if let i = $0 { currentIndex = i } }
            )) {
                ForEach(records.indices, id: \.self) { i in
                    TimelineRow(record: records[i])
                        .tag(i)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            scrubber
        }
        .frame(width: 320)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(currentIndex) },
                    set: { currentIndex = Int($0) }
                ),
                in: 0...Double(max(records.count - 1, 0)),
                step: 1
            )
            HStack {
                Text("frame \(currentIndex + 1) / \(records.count)")
                Spacer()
                Text(timeLabel(records[currentIndex].time))
            }
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(SolaroSpace.s)
        .background(SolaroColor.surfaceRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(SolaroColor.divider).frame(height: 1)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        let record = records[currentIndex]
        ScrollView {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: kindIcon(record.kind))
                        .foregroundStyle(kindColor(record.kind))
                    Text(record.kind.rawValue.uppercased())
                        .font(SolaroFont.sectionTitle)
                        .tracking(2)
                        .foregroundStyle(kindColor(record.kind))
                }
                if let stmt = record.statement {
                    Text(stmt)
                        .font(SolaroFont.mono)
                        .foregroundStyle(SolaroColor.textPrimary)
                }
                metadataLine(label: "feature set", value: record.featureSet)
                metadataLine(label: "file", value: record.file)
                metadataLine(label: "line", value: record.line.map(String.init))
                metadataLine(label: "verb", value: record.verb)
                metadataLine(label: "reason", value: record.reason)
                if !record.symbols.isEmpty {
                    Text("SYMBOLS")
                        .font(SolaroFont.sectionTitle)
                        .tracking(2)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .padding(.top, SolaroSpace.s)
                    ForEach(record.symbols.indices, id: \.self) { i in
                        let s = record.symbols[i]
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.name)
                                .font(SolaroFont.mono)
                                .foregroundStyle(SolaroColor.accent)
                            Text(":")
                                .font(SolaroFont.mono)
                                .foregroundStyle(SolaroColor.textTertiary)
                            Text(s.typeName)
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textSecondary)
                            Text("=")
                                .font(SolaroFont.monoCaption)
                                .foregroundStyle(SolaroColor.textTertiary)
                            Text(s.value)
                                .font(SolaroFont.mono)
                                .foregroundStyle(SolaroColor.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(SolaroSpace.m)
        }
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(spacing: 6) {
                Text(label)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    private func empty(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: SolaroSpace.s) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(title)
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text(subtitle)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SolaroSpace.l)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        let url = events_jsonl_url
        do {
            records = try TimeTravelReader.load(from: url)
            currentIndex = 0
            loadError = nil
        } catch {
            records = []
            loadError = error.localizedDescription
        }
    }

    private var events_jsonl_url: URL {
        project.rootPath
            .appendingPathComponent(".solaro/events.jsonl")
    }

    private var events_jsonl_path: String {
        events_jsonl_url.path
    }

    private func timeLabel(_ seconds: Double) -> String {
        let ms = Int(seconds * 1000)
        return String(format: "%6dms", ms)
    }

    private func kindIcon(_ kind: TimeTravelRecord.Kind) -> String {
        switch kind {
        case .pause: return "pause.fill"
        case .event: return "antenna.radiowaves.left.and.right"
        case .error: return "xmark.octagon.fill"
        case .end:   return "checkmark.square"
        }
    }

    private func kindColor(_ kind: TimeTravelRecord.Kind) -> Color {
        switch kind {
        case .pause: return SolaroColor.accent
        case .event: return SolaroColor.roleExport
        case .error: return SolaroColor.stateError
        case .end:   return SolaroColor.stateOK
        }
    }
}

private struct TimelineRow: View {
    let record: TimeTravelRecord

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(kindColor).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.featureSet ?? record.kind.rawValue)
                    .font(SolaroFont.body)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                if let stmt = record.statement {
                    Text(stmt)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                        .lineLimit(1)
                } else if let reason = record.reason {
                    Text(reason)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(String(format: "%4dms", Int(record.time * 1000)))
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .padding(.vertical, 2)
    }

    private var kindColor: Color {
        switch record.kind {
        case .pause: return SolaroColor.accent
        case .event: return SolaroColor.roleExport
        case .error: return SolaroColor.stateError
        case .end:   return SolaroColor.stateOK
        }
    }
}
