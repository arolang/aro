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
        VStack(spacing: SolaroSpace.xl) {
            Text("SOLARO")
                .font(SolaroFont.wordmark)
                .foregroundStyle(SolaroColor.textPrimary)
                .tracking(8)
            Text("canvas-first IDE for ARO  ·  runtime \(runtimeVersion)")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
            Text("welcome screen — Phase 3")
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .solaroBackdrop()
    }
}
