// ============================================================
// GitCommitOverlay.swift
// SOLARO — commit changed files from the status bar.
// ============================================================
//
// Opened from the status bar's "N changed" chip. Shows the file
// list, fires `aro ask` to suggest a commit message from the
// diff, and lets the user edit / overwrite before pressing
// Commit. If `aro ask` fails or returns nothing useful, the
// message field stays empty for manual entry.

import SwiftUI
import Foundation
import AppKit

/// Transparent `NSViewRepresentable` whose only job is to walk up
/// to the hosting `NSWindow` and add `.resizable` to its style
/// mask. SwiftUI presents sheets as non-resizable by default on
/// macOS, so a sheet's `.frame(min/ideal/max)` only determines its
/// initial size — the user can't drag the edge. Embedding this
/// helper in the sheet's body restores Finder-style edge dragging.
private struct ResizableSheetEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            // Sheets default to `[.titled, .docModalWindow]`. Adding
            // `.resizable` brings back the resize-from-edge gesture.
            // We never *remove* style bits, just add `.resizable`,
            // so any future macOS changes flow through unchanged.
            window.styleMask.insert(.resizable)
            window.isMovableByWindowBackground = false
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
@Observable
final class GitCommitModel {
    var message: String = ""
    var suggestion: String = ""
    var isSuggesting: Bool = false
    var suggestionFailed: Bool = false
    var suggestionError: String?

    /// Stderr from the last failed commit, surfaced to the user
    /// so they can read e.g. "nothing to commit" or hook errors.
    var commitError: String?
    var isCommitting: Bool = false

    private var askProcess: Process?

    /// Spawn `aro ask` with the diff as context. The first non-
    /// blank, non-trivial line we get back is treated as the
    /// commit subject; the rest becomes the body. We bail out on
    /// 30s with `suggestionFailed = true` so the user can type
    /// their own message.
    func requestSuggestion(diff: String, in project: Project) {
        cancelSuggestion()
        suggestion = ""
        suggestionFailed = false
        suggestionError = nil
        isSuggesting = true

        let prompt = Self.buildPrompt(diff: diff)
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        var args: [String]
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            args = ["aro", "ask", "--yes", "--no-think", prompt]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            args = ["ask", "--yes", "--no-think", prompt]
        }
        task.arguments = args
        task.currentDirectoryURL = project.rootPath

        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.terminationHandler = { [weak self] proc in
            let stdout = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let outText = ConsoleProcess.stripANSI(
                String(data: stdout, encoding: .utf8) ?? ""
            )
            let errText = String(data: stderr, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSuggesting = false
                self.askProcess = nil
                guard proc.terminationStatus == 0 else {
                    self.suggestionFailed = true
                    self.suggestionError = errText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return
                }
                let cleaned = Self.cleanSuggestion(outText)
                guard !cleaned.isEmpty else {
                    self.suggestionFailed = true
                    self.suggestionError =
                        "`aro ask` returned an empty message."
                    return
                }
                self.suggestion = cleaned
                // Only fill the editor when the user hasn't typed
                // anything yet — otherwise we'd clobber their work.
                if self.message
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                {
                    self.message = cleaned
                }
            }
        }

        do {
            try task.run()
            askProcess = task
        } catch {
            isSuggesting = false
            suggestionFailed = true
            suggestionError = error.localizedDescription
        }
    }

    func cancelSuggestion() {
        guard let askProcess, askProcess.isRunning else { return }
        askProcess.terminate()
        self.askProcess = nil
        isSuggesting = false
    }

    private static func buildPrompt(diff: String) -> String {
        // Cap the diff so the prompt stays under any local model's
        // context window. Conventional-commits style is what the
        // ARO repo's own commits use, so ask for that.
        let cap = 8000
        let truncated = diff.count > cap
            ? String(diff.prefix(cap)) + "\n…(diff truncated)\n"
            : diff
        return """
        You are writing a single Git commit message for the diff below.
        Format: a Conventional Commits subject line on the first line
        (e.g. `feat(scope): summary`, `fix(scope): summary`, max 72
        chars), then a blank line, then an optional short body. Output
        only the commit message — no prose around it, no fences, no
        "Here's the commit message:" preamble.

        Diff:
        \(truncated)
        """
    }

    /// Trim the model output: drop leading prose, code fences, and
    /// blank prefixes so what's left is the bare commit message.
    private static func cleanSuggestion(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading ```…``` fence if the model wrapped it.
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Drop obvious lead-ins like "Commit message:" / "Here's …".
        let lines = text.components(separatedBy: "\n")
        var firstReal = 0
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("here") || t.hasPrefix("commit message") ||
               t.hasPrefix("sure,") || t.hasPrefix("okay") || t.isEmpty
            {
                firstReal = i + 1
                continue
            }
            break
        }
        let kept = lines.dropFirst(firstReal).joined(separator: "\n")
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GitCommitSheet: View {
    let project: Project
    @Bindable var model: GitCommitModel
    let monitor: GitStatusMonitor
    let onClose: () -> Void

    /// Combined diff for every changed file. Cached so `Re-suggest`
    /// and the "All files" view don't re-hit git on every click.
    @State private var fullDiff: String = ""
    /// Diff currently rendered in the right pane. Equal to
    /// `fullDiff` while no file is selected; otherwise the result
    /// of `git diff HEAD -- <file>`.
    @State private var displayedDiff: String = ""
    @State private var loadingDiff: Bool = true
    /// nil = "All files" view; otherwise an absolute project path
    /// from `GitStatus.files.keys`.
    @State private var selectedFile: String? = nil
    /// Live width of the file-list column. Persisted via @AppStorage
    /// so the user's preferred proportion survives across sessions.
    /// Clamped on read so a wildly out-of-range stored value doesn't
    /// produce a useless layout.
    @AppStorage("solaro.commitSheet.fileListWidth")
    private var storedFileListWidth: Double = 280
    @State private var dragStartWidth: Double? = nil

    private static let fileListMin: Double = 180
    private static let fileListMax: Double = 520

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            header
            Divider()
            splitArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            messageEditor
            errorBanner
            footer
        }
        .padding(SolaroSpace.l)
        // `idealWidth`/`idealHeight` give the sheet a comfortable
        // starting size; min/max widen the resizable envelope. The
        // `ResizableSheetEnabler` hop in the background actually
        // flips the sheet's NSWindow to resizable — without it the
        // user could see the cursor change at the edge but the
        // drag wouldn't take.
        .frame(
            minWidth: 720, idealWidth: 980, maxWidth: .infinity,
            minHeight: 520, idealHeight: 720, maxHeight: .infinity
        )
        .background(ResizableSheetEnabler())
        .background(SolaroColor.surface)
        .task {
            loadingDiff = true
            let text = await monitor.diffAgainstHEAD(in: project)
            fullDiff = text
            displayedDiff = text
            loadingDiff = false
            // Kick off the suggestion right away. The result still
            // arrives async; in the meantime the editor is empty
            // and clearly labelled "(suggesting…)".
            if !text.isEmpty {
                model.requestSuggestion(diff: text, in: project)
            }
        }
        .onDisappear { model.cancelSuggestion() }
    }

    /// Re-fetch the diff scoped to whatever file the user just
    /// picked. `nil` means "back to the combined diff".
    private func selectFile(_ path: String?) {
        selectedFile = path
        if path == nil {
            displayedDiff = fullDiff
            return
        }
        Task {
            let text = await monitor.diffAgainstHEAD(in: project, path: path!)
            displayedDiff = text
        }
    }

    private var header: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(SolaroColor.accent)
            Text("Commit changes")
                .font(SolaroFont.toolbarTitle)
            Text("\(monitor.status.files.count) files")
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    /// File list + diff pane with an explicit, visible drag handle
    /// between them. Replaces SwiftUI's `HSplitView`, whose 1pt
    /// divider was effectively invisible against the sheet's
    /// background and made it look like the proportion was fixed.
    private var splitArea: some View {
        let clamped = min(max(storedFileListWidth,
                              Self.fileListMin), Self.fileListMax)
        return HStack(spacing: 0) {
            fileList
                .frame(width: clamped)
            splitDivider
            diffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Vertical drag handle. 6pt wide hit area with a 1pt visible
    /// rule down the middle; the cursor flips to a horizontal
    /// resize chevron on hover so the affordance is obvious.
    private var splitDivider: some View {
        ZStack {
            Color.clear.frame(width: 6)
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = storedFileListWidth
                    }
                    let proposed = (dragStartWidth ?? storedFileListWidth)
                        + Double(value.translation.width)
                    storedFileListWidth = min(
                        max(proposed, Self.fileListMin),
                        Self.fileListMax
                    )
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                fileRow(label: "All files",
                        statusLetter: nil,
                        statusColor: SolaroColor.textTertiary,
                        path: nil)
                ForEach(monitor.status.files.sorted { $0.key < $1.key },
                        id: \.key) { (path, status) in
                    fileRow(
                        label: relativePath(path),
                        statusLetter: letter(for: status),
                        statusColor: color(for: status),
                        path: path
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SolaroSpace.xs)
        }
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private func fileRow(
        label: String,
        statusLetter: String?,
        statusColor: Color,
        path: String?
    ) -> some View {
        let active = (selectedFile == path)
        return Button {
            selectFile(path)
        } label: {
            HStack(spacing: SolaroSpace.xs) {
                Text(statusLetter ?? " ")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(statusColor)
                    .frame(width: 14, alignment: .leading)
                Text(label)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(active
                        ? SolaroColor.textPrimary
                        : SolaroColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, SolaroSpace.s)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(active
                        ? SolaroColor.selection.opacity(0.6)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var diffPane: some View {
        ScrollView([.horizontal, .vertical]) {
            if loadingDiff {
                ProgressView()
                    .controlSize(.small)
                    .padding()
            } else if displayedDiff.isEmpty {
                Text(selectedFile == nil
                    ? "(no tracked changes — `git diff HEAD` is empty)"
                    : "(no tracked changes for this file)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .padding()
            } else {
                DiffView(text: displayedDiff)
                    .padding(.vertical, SolaroSpace.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SolaroColor.backdrop)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Message")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                if model.isSuggesting {
                    ProgressView()
                        .controlSize(.mini)
                    Text("aro ask is suggesting a message…")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                } else if model.suggestionFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(SolaroColor.stateWarn)
                    Text("aro ask couldn't help — type your own message.")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.stateWarn)
                } else if !model.suggestion.isEmpty {
                    Image(systemName: "sparkles")
                        .foregroundStyle(SolaroColor.accent)
                    Text("suggested by aro ask · edit freely")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                Spacer()
                Button("Re-suggest") {
                    model.requestSuggestion(diff: fullDiff, in: project)
                }
                .controlSize(.small)
                .disabled(model.isSuggesting || fullDiff.isEmpty)
            }
            TextEditor(text: $model.message)
                .font(SolaroFont.mono)
                .foregroundStyle(SolaroColor.textPrimary)
                .scrollContentBackground(.hidden)
                .background(SolaroColor.backdrop)
                .frame(minHeight: 100, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: SolaroRadius.s)
                        .stroke(SolaroColor.divider, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = model.commitError {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(SolaroColor.stateError)
                Text(err)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
                    .textSelection(.enabled)
            }
            .padding(SolaroSpace.s)
            .background(SolaroColor.stateError.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.s))
        }
    }

    private var footer: some View {
        HStack {
            if let err = model.suggestionError, !err.isEmpty,
               model.suggestionFailed
            {
                Text(err)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button {
                commit()
            } label: {
                if model.isCommitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Commit")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
                model.isCommitting ||
                model.message.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }
    }

    private func commit() {
        let trimmed = model.message
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.isCommitting = true
        model.commitError = nil
        Task {
            let err = await monitor.commit(message: trimmed, in: project)
            model.isCommitting = false
            if let err {
                model.commitError = err
            } else {
                onClose()
            }
        }
    }

    private func relativePath(_ absolute: String) -> String {
        let root = project.rootPath.standardizedFileURL.path
        if absolute.hasPrefix(root + "/") {
            return String(absolute.dropFirst(root.count + 1))
        }
        return absolute
    }

    private func letter(for status: GitStatus.FileStatus) -> String {
        switch status {
        case .modified:   return "M"
        case .added:      return "A"
        case .deleted:    return "D"
        case .renamed:    return "R"
        case .untracked:  return "?"
        case .ignored:    return "!"
        case .conflicted: return "U"
        }
    }

    private func color(for status: GitStatus.FileStatus) -> Color {
        switch status {
        case .modified:   return SolaroColor.stateWarn
        case .added:      return SolaroColor.stateOK
        case .deleted:    return SolaroColor.stateError
        case .renamed:    return SolaroColor.accent
        case .untracked:  return SolaroColor.textTertiary
        case .ignored:    return SolaroColor.textTertiary
        case .conflicted: return SolaroColor.stateError
        }
    }
}

// MARK: - Diff renderer (Tower-style)

/// One row in the rendered diff. Either a single content line
/// (with one or both line numbers + tinted background) or a hunk
/// header that spans the gutter.
private struct DiffRow: Identifiable {
    let id: Int
    /// Line number in the pre-image (left gutter). `nil` for
    /// additions and hunk headers.
    let oldNumber: Int?
    /// Line number in the post-image (right gutter). `nil` for
    /// deletions and hunk headers.
    let newNumber: Int?
    let kind: Kind
    /// Content text — for `addition`/`deletion`/`context` this is
    /// the line *without* its leading `+`/`-`/space. For
    /// `hunkHeader` it's the full `@@ … @@` string.
    let text: String

    enum Kind {
        case addition, deletion, context
        case hunkHeader
        case fileHeader
    }
}

/// Renders a unified diff in a two-gutter, code-only style: line
/// numbers down the left (old + new), the actual source text on
/// the right, with full-row tinting on changed lines. Inspired by
/// Tower / GitHub's split-but-unified view — the `+`/`-` prefix
/// from `git diff` is implicit in the row tint and the missing
/// gutter number, so the user just reads the code.
struct DiffView: View {
    let text: String

    var body: some View {
        let rows = Self.parse(text)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                DiffRowView(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Walk the unified-diff text, tracking the current old / new
    /// line counters from each `@@ -A,B +C,D @@` header.
    fileprivate static func parse(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var nextID = 0
        let lines = text.split(separator: "\n",
                               omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            nextID += 1
            if line.hasPrefix("@@") {
                if let (oldStart, newStart) = parseHunk(line) {
                    oldLine = oldStart
                    newLine = newStart
                }
                rows.append(DiffRow(id: nextID,
                                    oldNumber: nil, newNumber: nil,
                                    kind: .hunkHeader, text: line))
                continue
            }
            if Self.isFileHeader(line) {
                rows.append(DiffRow(id: nextID,
                                    oldNumber: nil, newNumber: nil,
                                    kind: .fileHeader, text: line))
                continue
            }
            if line.hasPrefix("+") {
                let body = String(line.dropFirst())
                rows.append(DiffRow(id: nextID,
                                    oldNumber: nil, newNumber: newLine,
                                    kind: .addition, text: body))
                newLine += 1
            } else if line.hasPrefix("-") {
                let body = String(line.dropFirst())
                rows.append(DiffRow(id: nextID,
                                    oldNumber: oldLine, newNumber: nil,
                                    kind: .deletion, text: body))
                oldLine += 1
            } else {
                // Context: leading space or fully blank.
                let body = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(DiffRow(id: nextID,
                                    oldNumber: oldLine, newNumber: newLine,
                                    kind: .context, text: body))
                oldLine += 1
                newLine += 1
            }
        }
        return rows
    }

    /// Parse `@@ -A,B +C,D @@ optional` into the starting old / new
    /// line numbers. Returns nil for malformed headers so the
    /// renderer falls back to its previous counters.
    private static func parseHunk(_ header: String) -> (Int, Int)? {
        // Strip the leading `@@ ` and trailing ` @@ …`.
        let scanner = Scanner(string: header)
        guard scanner.scanString("@@") != nil else { return nil }
        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString("-") != nil,
              let oldStart = scanner.scanInt()
        else { return nil }
        _ = scanner.scanString(",")
        _ = scanner.scanInt()  // length — ignored
        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString("+") != nil,
              let newStart = scanner.scanInt()
        else { return nil }
        return (oldStart, newStart)
    }

    private static func isFileHeader(_ line: String) -> Bool {
        line.hasPrefix("diff --git")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode")
            || line.hasPrefix("similarity index")
            || line.hasPrefix("rename from")
            || line.hasPrefix("rename to")
    }
}

private struct DiffRowView: View {
    let row: DiffRow

    /// Fixed gutter width so column alignment stays solid even
    /// when one side's number is 4 digits and the other is 1. 40pt
    /// per gutter handles up to 99,999.
    private static let gutterWidth: CGFloat = 40

    var body: some View {
        switch row.kind {
        case .hunkHeader:
            // Full-width band, no gutter numbers. Reads like a
            // section divider in the code.
            Text(row.text)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SolaroSpace.s)
                .padding(.vertical, 4)
                .background(SolaroColor.backdrop)

        case .fileHeader:
            // Tower-like file-header banner. Shown only when the
            // diff spans more than one file; for a single-file
            // selection it just sits at the top.
            Text(row.text)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SolaroSpace.s)
                .padding(.vertical, 3)
                .background(SolaroColor.surfaceRaised.opacity(0.6))

        case .addition, .deletion, .context:
            HStack(alignment: .top, spacing: 0) {
                gutter(row.oldNumber, prefix: row.kind == .deletion ? "-" : nil)
                gutter(row.newNumber, prefix: row.kind == .addition ? "+" : nil)
                Text(row.text.isEmpty ? " " : row.text)
                    .font(SolaroFont.mono)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SolaroSpace.s)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(rowBackground)
        }
    }

    private func gutter(_ number: Int?, prefix: String?) -> some View {
        let label: String
        if let prefix, number == nil {
            // Tower shows the leading +/- only on the side that
            // has no number ("the line did not exist here").
            label = prefix
        } else if let number {
            label = "\(number)"
        } else {
            label = ""
        }
        return Text(label)
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
            .frame(width: Self.gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
    }

    private var rowBackground: Color {
        switch row.kind {
        case .addition: return SolaroColor.stateOK.opacity(0.12)
        case .deletion: return SolaroColor.stateError.opacity(0.12)
        default:        return Color.clear
        }
    }
}
