import SwiftUI
import DiskCore

struct ScanningView: View {
    let model: ScanViewModel
    let preparing: Bool
    let cancel: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in content(compact: geometry.size.height < 720) }
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 16 : 26) {
            Spacer()
            ScanMosaic(active: scenePhase == .active && !reduceMotion).frame(width: 300, height: 230).scaleEffect(compact ? 0.7 : 1).frame(height: compact ? 155 : 230).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(model.cancellationRequested ? "Finishing partial results" : preparing ? "A clearer picture is almost ready." : "Finding your space.")
                    .font(.system(size: compact ? 27 : 32, weight: .semibold, design: .rounded))
                Text((model.refreshNode?.url ?? model.root)?.lastPathComponent ?? "Selected disk").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                scanStat("Files", (max(0, (model.snapshot?.items ?? 0) - (model.snapshot?.folders ?? 0))).formatted())
                scanStat("Folders", (model.snapshot?.folders ?? 0).formatted())
                scanStat("Discovered", sizeText(model.snapshot?.bytes ?? 0))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    scanStat("Elapsed", Duration.seconds(Int(context.date.timeIntervalSince(model.startedAt ?? context.date))).formatted(.time(pattern: .minuteSecond)))
                }
            }.padding(.vertical, 12)
            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    ForEach(Array(ScanStage.allCases.enumerated()), id: \.element) { index, stage in
                        let active = preparing ? stage == .preparingMap : stage == model.stage
                        HStack(spacing: 6) {
                            Image(systemName: active ? "circle.inset.filled" : index < stageIndex ? "checkmark.circle.fill" : "circle")
                            Text(L10n.text(stage.rawValue))
                        }.font(.caption).foregroundStyle(active ? Color.teal : .secondary)
                    }
                }
                Text(model.snapshot?.currentFolder ?? model.root?.path ?? "")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 650)
                if let errors = model.snapshot?.errors, errors > 0 { Label("\(errors) locations unavailable · results will be marked partial", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            if !preparing {
                Button(model.cancellationRequested ? "Cancelling…" : "Cancel scan", action: cancel)
                    .buttonStyle(.glass).disabled(model.cancellationRequested || model.committingRefresh).accessibilityIdentifier("cancelScan")
            }
            Spacer()
            Text("Reading metadata, never file contents. Some locations may be protected by macOS.").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24).accessibilityElement(children: .contain).accessibilityIdentifier("scanningScreen")
    }
    private var stageIndex: Int { preparing ? 2 : ScanStage.allCases.firstIndex(of: model.stage) ?? 0 }
    private func scanStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 5) { Text(value).font(.title2.weight(.medium)).monospacedDigit().contentTransition(.numericText()); Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct ScanMosaic: View {
    let active: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var started = Date()
    private let rects: [CGRect] = [CGRect(x: 8,y: 8,width: 120,height: 214), CGRect(x: 136,y: 8,width: 156,height: 100), CGRect(x: 136,y: 116,width: 72,height: 106), CGRect(x: 216,y: 116,width: 76,height: 60), CGRect(x: 216,y: 184,width: 76,height: 38)]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            let time = active ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, _ in
                for (index, rect) in rects.enumerated() {
                    let phase = sin(time * 1.4 - Double(index) * 0.7)
                    let assembly = active ? min(1, max(0, (timeline.date.timeIntervalSince(started) - Double(index) * 0.08) / 0.65)) : 1
                    let shifted = rect.offsetBy(dx: (1 - assembly) * (index.isMultiple(of: 2) ? -24 : 24), dy: active ? phase * 3 + (1 - assembly) * 18 : 0)
                    let path = Path(roundedRect: shifted, cornerRadius: 12)
                    let colors: [Color] = [.teal, .cyan, .indigo, .mint, .blue]
                    if reduceTransparency { context.fill(path, with: .color(colors[index])) }
                    else { context.fill(path, with: .linearGradient(Gradient(colors: [colors[index].opacity((0.75 + phase * 0.12) * assembly), colors[index].opacity(0.3)]), startPoint: shifted.origin, endPoint: CGPoint(x: shifted.maxX, y: shifted.maxY))) }
                    context.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
            }
        }
        .phaseAnimator(active ? [false, true] : [false]) { content, phase in
            content.scaleEffect(phase ? 1.015 : 1)
        } animation: { _ in .easeInOut(duration: 2) }
    }
}
