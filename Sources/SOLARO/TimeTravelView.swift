// ============================================================
// TimeTravelView.swift
// SOLARO — time-travel scrubber UI (Phase 3)
// ============================================================
//
// Reads a JSONL debug log via `TimeTravelReader` and presents the
// pauses as a scrubbable list. Matches wireframe note 8467 figure
// 11 at the data level; the full timeline-ribbon visual lands when
// the Path primitive ships (#232).

import Foundation
import SwiftCrossUI

struct TimeTravelView: View {
    @State var records: [TimeTravelRecord] = []
    @State var cursor: Int = 0
    @State var loadedFrom: String?
    @State var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time travel").font(.system(.headline))
            if records.isEmpty {
                Text(error ?? "No recording loaded.").foregroundColor(.gray)
            } else {
                Text("\(records.count) records · cursor at \(cursor + 1) / \(records.count)")
                    .foregroundColor(.gray)
                HStack(spacing: 8) {
                    Button("◀") { stepBack() }
                    Button("▶") { stepForward() }
                    Button("⏮") { cursor = 0 }
                    Button("⏭") { cursor = max(records.count - 1, 0) }
                }
                if cursor < records.count {
                    recordDetail(records[cursor])
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func recordDetail(_ rec: TimeTravelRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("[\(String(format: "%.3f", rec.time))s] \(rec.kind.rawValue)")
                .font(.system(.subheadline))
            if let fs = rec.featureSet {
                Text("feature set: \(fs)").foregroundColor(.gray)
            }
            if let line = rec.line, let file = rec.file {
                Text("at \(file):\(line)").foregroundColor(.gray)
            }
            if let stmt = rec.statement {
                Text(stmt)
            }
            if !rec.symbols.isEmpty {
                Text("bindings (\(rec.symbols.count))").foregroundColor(.gray).padding(.top, 4)
                ForEach(rec.symbols, id: \.name) { sym in
                    Text("  <\(sym.name)> : \(sym.typeName) = \(sym.value)")
                        .foregroundColor(.gray)
                }
            }
        }
    }

    /// Replace the loaded records — called by the caller after
    /// asking the user to pick a `.jsonl` file.
    mutating func setRecords(_ records: [TimeTravelRecord], source: String) {
        self.records = records
        self.cursor = 0
        self.loadedFrom = source
        self.error = nil
    }

    private func stepBack() {
        cursor = max(cursor - 1, 0)
    }

    private func stepForward() {
        cursor = min(cursor + 1, max(records.count - 1, 0))
    }
}
