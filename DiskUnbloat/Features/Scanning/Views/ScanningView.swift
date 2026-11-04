import SwiftUI
import DiskCore

struct ScanningView: View {
    let model: ScanViewModel
    let preparing: Bool
    let cancel: () -> Void
    let issues: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in content(compact: geometry.size.height < 720) }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 16 : 26) {
            Spacer()
            ScanMosaic(active: scenePhase == .active && !reduceMotion).scaleEffect(compact ? 0.7 : 1).frame(height: ScanMosaic.size.height * (compact ? 0.7 : 1)).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(model.cancellationRequested ? "Finishing partial results" : preparing ? "A clearer picture is almost ready." : "Scanning in progress.")
                    .font(.system(size: compact ? 27 : 32, weight: .semibold, design: .rounded))
                    .contentTransition(.opacity)
                Text((model.refreshNode?.url ?? model.root)?.lastPathComponent ?? "Selected disk").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                if let percent = model.progressPercent { scanStat("Progress", "≈ \(percent)%") }
                scanStat("Files", (max(0, (model.snapshot?.items ?? 0) - (model.snapshot?.folders ?? 0))).formatted())
                scanStat("Folders", (model.snapshot?.folders ?? 0).formatted())
                scanStat("Discovered", sizeText(model.snapshot?.bytes ?? 0))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    scanStat("Elapsed", Duration.seconds(Int(context.date.timeIntervalSince(model.startedAt ?? context.date))).formatted(.time(pattern: .minuteSecond)))
                }
            }.padding(.vertical, 12)
            if let percent = model.progressPercent {
                VStack(spacing: 5) {
                    ProgressView(value: Double(percent), total: 100).frame(width: compact ? 220 : 320)
                        .animation(motion(.smooth(duration: 0.5)), value: percent)
                    Text("Approximate share of this volume's used data read so far").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    ForEach(Array(ScanStage.allCases.enumerated()), id: \.element) { index, stage in
                        let active = preparing ? stage == .preparingMap : stage == model.stage
                        HStack(spacing: 6) {
                            Image(systemName: active ? "circle.inset.filled" : index < stageIndex ? "checkmark.circle.fill" : "circle")
                                .contentTransition(.symbolEffect(.replace))
                                .symbolEffect(.pulse, options: .repeating, isActive: active && !reduceMotion)
                            Text(L10n.text(stage.rawValue))
                        }.font(.caption).foregroundStyle(active ? Color.teal : .secondary)
                    }
                }
                .animation(motion(.snappy(duration: 0.3)), value: stageIndex)
                Text(model.snapshot?.currentFolder ?? model.root?.path ?? "")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 650)
                if let errors = model.snapshot?.errors, errors > 0 {
                    Button(action: issues) {
                        Label(L10n.count("%lld locations unavailable · view list", errors), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }.buttonStyle(.plain).accessibilityIdentifier("scanIssues")
                }
            }
            if !preparing {
                Button(model.cancellationRequested ? "Cancelling…" : "Cancel scan", action: cancel)
                    .buttonStyle(.glass).disabled(model.cancellationRequested || model.committingRefresh).accessibilityIdentifier("cancelScan")
            }
            Spacer()
            Text("Reading metadata, never file contents. Some locations may be protected by macOS.").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24).accessibilityElement(children: .contain).accessibilityIdentifier("scanningScreen")
        .animation(motion(.easeInOut(duration: 0.3)), value: preparing)
    }
    /// Value transitions follow real updates, so they are skipped entirely under Reduce Motion.
    private func motion(_ animation: Animation) -> Animation? { reduceMotion ? nil : animation }
    private var stageIndex: Int { preparing ? 2 : ScanStage.allCases.firstIndex(of: model.stage) ?? 0 }
    private func scanStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 5) { Text(value).font(.title2.weight(.medium)).monospacedDigit().contentTransition(.numericText()).animation(motion(.snappy(duration: 0.35)), value: value); Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary) }
    }
}
