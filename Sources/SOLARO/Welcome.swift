// ============================================================
// Welcome.swift
// SOLARO — first-launch welcome screen (ADR-008)
// ============================================================
//
// Phase 1 stub: minimal SwiftUI welcome screen so the platform
// pivot compiles. Phase 3 adds the wireframe styling, NSOpenPanel
// integration, and the recent-projects tile grid.

import SwiftUI

struct WelcomeView: View {
    let runtimeVersion: String
    let onOpen: (Project) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("SOLARO")
                .font(.system(size: 48, weight: .light, design: .default))
            Text("canvas-first IDE for ARO  ·  runtime \(runtimeVersion)")
                .foregroundStyle(.secondary)
            Text("welcome screen — Phase 3")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
    }
}
