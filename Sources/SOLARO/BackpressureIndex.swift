// ============================================================
// BackpressureIndex.swift
// SOLARO — wire buffer occupancy on the canvas (#444)
// ============================================================
//
// The runtime's `BoundedChannel` parks a producer when its
// consumer falls behind. That is backpressure working correctly,
// and until now it was invisible: a pipeline spending most of its
// time with a producer parked looked, from the canvas, identical
// to one that never waited.
//
// This reads the runtime's samples and keys them by binding name
// so a wire can ask "how full is the buffer I represent". Wires
// thicken and go amber when their stage is the one holding
// everything else up, which makes a bottleneck point at itself
// instead of having to be hunted for.
//
// Sampling is off until the canvas asks for it — `enable()` on the
// monitor is what turns the runtime's bookkeeping on at all.

import Foundation
import SwiftUI
import ARORuntime

@MainActor
@Observable
final class BackpressureIndex {
    /// Latest reading per binding name (lowercased).
    private(set) var samples: [String: BackpressureSample] = [:]
    /// True while the canvas is showing live pressure.
    private(set) var isSampling = false

    private var timer: Timer?

    /// Start polling. The runtime keeps the numbers behind a lock,
    /// so this is a dictionary copy every interval, not a stream.
    func start(interval: TimeInterval = 0.5) {
        guard !isSampling else { return }
        BackpressureMonitor.shared.reset()
        BackpressureMonitor.shared.enable()
        isSampling = true
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isSampling = false
        BackpressureMonitor.shared.disable()
        samples = [:]
    }

    func refresh() {
        var next: [String: BackpressureSample] = [:]
        for sample in BackpressureMonitor.shared.snapshot() {
            let key = sample.label.lowercased()
            // Several channels can share a binding name across
            // feature sets; the tightest one is the one worth
            // drawing, since it's what stalls the wire.
            if let existing = next[key], existing.fill >= sample.fill { continue }
            next[key] = sample
        }
        samples = next
    }

    /// Reading for the value a wire carries, if the runtime has one.
    func sample(forBinding binding: String?) -> BackpressureSample? {
        guard let binding, !binding.isEmpty else { return nil }
        return samples[binding.lowercased()]
    }

    /// Every reading, tightest first — what the deploy rail lists.
    var ranked: [BackpressureSample] {
        samples.values.sorted {
            if $0.fill != $1.fill { return $0.fill > $1.fill }
            return $0.label < $1.label
        }
    }

    /// Stages currently holding their producers back.
    var bottlenecks: [BackpressureSample] {
        ranked.filter(\.isBackpressured)
    }
}

// MARK: - Deploy-rail panel

/// Per-wire backpressure bars. Lives in the deploy rail next to
/// the other run-time readouts.
struct BackpressureRailView: View {
    @Bindable var index: BackpressureIndex

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.xs) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(SolaroColor.accent)
                Text("BACKPRESSURE")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                Spacer()
            }
            if !index.isSampling {
                Text("Run the project to sample stream buffers.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else if index.ranked.isEmpty {
                Text("No streamed stages in this run.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
            } else {
                ForEach(index.ranked, id: \.label) { sample in
                    bar(sample)
                }
            }
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
    }

    private func bar(_ sample: BackpressureSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(sample.label)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(sample.depth)/\(sample.capacity)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(SolaroColor.divider)
                        .frame(height: 5)
                    Rectangle()
                        .fill(BackpressureStyle.color(for: sample))
                        .frame(width: max(2, geo.size.width * sample.fill), height: 5)
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            if sample.stallCount > 0 {
                // The number that matters for "why is this slow":
                // how long producers actually sat parked here.
                Text(String(format: "parked %.2fs over %d stalls",
                            sample.stalledSeconds, sample.stallCount))
                    .font(SolaroFont.caption)
                    .foregroundStyle(sample.isBackpressured
                                     ? SolaroColor.roleExport
                                     : SolaroColor.textTertiary)
            }
        }
    }
}

/// Shared mapping from a reading to how it's drawn, so the rail
/// bars and the canvas wires can't drift apart.
enum BackpressureStyle {
    /// Amber once the stage is actually holding producers back;
    /// a buffer that merely filled and drained stays neutral, or
    /// every fast pipeline would look like a problem.
    static func color(for sample: BackpressureSample) -> Color {
        if sample.isBackpressured { return SolaroColor.roleExport }
        if sample.fill >= 0.5 { return SolaroColor.accent }
        return SolaroColor.roleOwn
    }

    /// Extra stroke width for a wire carrying this much pressure —
    /// 0 at empty, +3pt at full.
    static func extraWidth(for sample: BackpressureSample) -> CGFloat {
        CGFloat(sample.fill) * 3
    }
}