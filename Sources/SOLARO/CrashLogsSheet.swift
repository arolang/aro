// ============================================================
// CrashLogsSheet.swift
// SOLARO — Help → View Crash Logs… (#275)
// ============================================================
//
// A list of what SOLARO captured, and three things to do with
// each: reveal it, file it, delete it. The submission step shows
// the exact issue text before anything is sent — an upload the
// user hasn't read is an upload they didn't consent to.

import SwiftUI
import AppKit

struct CrashLogsSheet: View {
    @State private var store = CrashReportStore()
    @State private var selection: CrashReport.ID?
    @State private var submitting: CrashReport?
    @State private var confirmDiscardAll = false
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SolaroColor.divider)
            if store.reports.isEmpty {
                emptyState
            } else {
                HSplitView {
                    list.frame(minWidth: 240, idealWidth: 280)
                    detail.frame(minWidth: 380)
                }
            }
            Divider().background(SolaroColor.divider)
            footer
        }
        .frame(width: 820, height: 560)
        .background(SolaroColor.backdrop)
        .onAppear {
            store.reload()
            store.markSeen()
            selection = store.reports.first?.id
        }
        .sheet(item: $submitting) { report in
            CrashSubmitSheet(report: report) { submitting = nil }
        }
    }

    private var selectedReport: CrashReport? {
        store.reports.first { $0.id == selection }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "ant.fill")
                .foregroundStyle(SolaroColor.stateError)
            Text("CRASH LOGS")
                .font(SolaroFont.sectionTitle)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
            Spacer()
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-read the crashes folder")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private var emptyState: some View {
        VStack(spacing: SolaroSpace.s) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text("No crash logs.")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("SOLARO writes one here if it ever takes a fatal signal.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(store.reports, selection: $selection) { report in
            VStack(alignment: .leading, spacing: 2) {
                Text(report.signalName)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(CrashReport.displayFormatter.string(from: report.date))
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                if let version = report.version {
                    Text("v\(version)")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(report.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let report = selectedReport {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SolaroSpace.s) {
                    Text(report.fileName)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([report.url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .font(SolaroFont.caption)
                    }
                    .buttonStyle(.borderless)
                    Button {
                        submitting = report
                    } label: {
                        Label("Submit to GitLab", systemImage: "paperplane")
                            .font(SolaroFont.caption)
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        store.discard(report)
                        selection = store.reports.first?.id
                    } label: {
                        Label("Discard", systemImage: "trash")
                            .font(SolaroFont.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, SolaroSpace.m)
                .padding(.vertical, SolaroSpace.s)
                Divider().background(SolaroColor.divider)
                ScrollView {
                    Text(report.text)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SolaroSpace.m)
                }
            }
        } else {
            Text("Select a crash log.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                confirmDiscardAll = true
            } label: {
                Text("Discard all")
            }
            .disabled(store.reports.isEmpty)
            .confirmationDialog(
                "Delete all \(store.reports.count) crash logs?",
                isPresented: $confirmDiscardAll,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    store.discardAll()
                    selection = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They are only on this Mac — nothing was uploaded, so this cannot be undone.")
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(SolaroSpace.m)
    }
}

// MARK: - Window host

/// The Help menu is a `Commands` tree with nowhere to hang a
/// sheet, so the viewer opens as its own window — same pattern as
/// `BookWindow`. One instance, reused.
@MainActor
final class CrashLogsWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: CrashLogsSheet(onClose: { CrashLogsWindow.close() }))
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 820, height: 560))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Crash Logs"
        w.center()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { _ in CrashLogsWindow.window = nil }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

// MARK: - Submission confirmation

/// Shows the exact issue text, then files it. Two outcomes are
/// possible and both are honest about what happened: `glab` filed
/// it (here's the URL), or `glab` isn't available and the web form
/// opens pre-filled for the user to submit themselves.
private struct CrashSubmitSheet: View {
    let report: CrashReport
    let onClose: () -> Void

    @State private var note = ""
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var filedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            Text("Submit this crash to GitLab")
                .font(SolaroFont.bodyBold)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("Filed against \(CrashSubmission.projectPath) on \(CrashSubmission.host). Nothing is sent until you press Submit.")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)

            Text("What were you doing? (optional)")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            TextEditor(text: $note)
                .font(SolaroFont.monoCaption)
                .frame(height: 60)
                .scrollContentBackground(.hidden)
                .background(SolaroColor.surface)

            Text("This is exactly what will be posted:")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textSecondary)
            ScrollView {
                Text(CrashSubmission.composeBody(for: report, note: note))
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SolaroSpace.s)
            }
            .frame(height: 200)
            .background(SolaroColor.surface)

            if let resultMessage {
                Text(resultMessage)
                    .font(SolaroFont.caption)
                    .foregroundStyle(filedURL == nil
                                     ? SolaroColor.stateError
                                     : SolaroColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let filedURL {
                    Button("Open issue") {
                        NSWorkspace.shared.open(filedURL)
                    }
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isSubmitting ? "Submitting…" : "Submit") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || filedURL != nil)
            }
        }
        .padding(SolaroSpace.l)
        .frame(width: 620)
        .background(SolaroColor.backdrop)
    }

    private func submit() {
        isSubmitting = true
        resultMessage = nil
        let snapshot = note
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                CrashSubmission.submitViaCLI(report: report, note: snapshot)
            }.value
            await MainActor.run {
                isSubmitting = false
                switch outcome {
                case .filed(let url):
                    filedURL = url
                    resultMessage = "Filed as \(url.lastPathComponent)."
                case .failed(let message):
                    resultMessage = "glab could not file it: \(message)"
                case .unavailable:
                    // No CLI — hand the same text to the web form
                    // rather than dropping the report on the floor.
                    if let url = CrashSubmission.newIssueURL(for: report, note: snapshot) {
                        NSWorkspace.shared.open(url)
                        resultMessage = "glab isn't installed — opened the GitLab issue form with this text pre-filled. Press Submit there."
                    } else {
                        resultMessage = "glab isn't installed and the issue URL could not be composed."
                    }
                }
            }
        }
    }
}
