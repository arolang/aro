// ============================================================
// MetricsCharts.swift
// SOLARO — Swift Charts views for the metrics panel
// ============================================================
//
// Four small charts that the AppKit MetricsAppKitPanel hosts via
// `NSHostingController` with `sizingOptions = []`. Each chart has
// a fixed `.frame(width:height:)` so the NSHostingView's intrinsic
// size never changes — avoiding the macOS 26
// `SplitViewChildController.hostingView(_:didUpdateMinSize:…)`
// constraint-update assertion that took us out earlier.

import SwiftUI
import Charts

/// One sample in the rolling history kept by the panel. The panel
/// owns the ring buffer; charts just read whichever points are
/// passed in.
struct MetricsHistoryPoint: Identifiable, Equatable {
    let id: Int
    let timeOffsetSec: Double
    let callsPerSec: Double
    let cpuPercent: Double
    let residentMB: Double
}

// MARK: - Sparklines

struct ThroughputSparkline: View {
    let samples: [MetricsHistoryPoint]

    var body: some View {
        Chart(samples) { p in
            AreaMark(
                x: .value("t", p.timeOffsetSec),
                y: .value("c/s", p.callsPerSec)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [SolaroColor.accent.opacity(0.35),
                             SolaroColor.accent.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("t", p.timeOffsetSec),
                y: .value("c/s", p.callsPerSec)
            )
            .foregroundStyle(SolaroColor.accent)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(SolaroColor.surfaceRaised.opacity(0.001))
        }
        .frame(width: 300, height: 56)
    }
}

struct CPUSparkline: View {
    let samples: [MetricsHistoryPoint]

    var body: some View {
        Chart(samples) { p in
            LineMark(
                x: .value("t", p.timeOffsetSec),
                y: .value("cpu%", p.cpuPercent)
            )
            .foregroundStyle(SolaroColor.stateWarn)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 300, height: 36)
    }
}

struct MemorySparkline: View {
    let samples: [MetricsHistoryPoint]

    var body: some View {
        Chart(samples) { p in
            AreaMark(
                x: .value("t", p.timeOffsetSec),
                y: .value("mb", p.residentMB)
            )
            .foregroundStyle(SolaroColor.roleOwn.opacity(0.25))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("t", p.timeOffsetSec),
                y: .value("mb", p.residentMB)
            )
            .foregroundStyle(SolaroColor.roleOwn)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 300, height: 36)
    }
}

// MARK: - Per-feature-set bars

struct FeatureSetBars: View {
    let bars: [Bar]

    struct Bar: Identifiable, Equatable {
        let id: String
        let count: Int
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("count", bar.count),
                y: .value("name", bar.id)
            )
            .foregroundStyle(SolaroColor.accent.gradient)
            .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            // Show feature-set name labels on the leading edge so
            // bars remain readable even when names are long.
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
        }
        .frame(width: 300, height: 132)
    }
}
