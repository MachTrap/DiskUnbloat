import SwiftUI
import QuickLook
import AppKit
import DiskCore

struct WorkspaceView: View {
    @Bindable var model: WorkspaceViewModel
    @Bindable private var scan: ScanViewModel
    @Bindable private var cleanup: CleanupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var window: NSWindow?
    @State private var savedContentSize: CGSize?

    init(model: WorkspaceViewModel) { self.model = model; scan = model.scan; cleanup = model.cleanup }
    var body: some View {
        GeometryReader { _ in phaseContent }
        .frame(maxWidth: .infinity,maxHeight: .infinity)
        .navigationTitle(model.phase == .exploring ? model.explorer.current?.name ?? "DiskUnbloat" : "DiskUnbloat")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.phase)
        .sheet(isPresented: $cleanup.showReport) { CleanupReportView(results: cleanup.results, mode: cleanup.lastRunMode, bytes: cleanup.lastRunBytes, openTrash: model.openTrash) { cleanup.showReport = false } }
        .sheet(isPresented: $scan.showIssues) { issuesSheet }
        .sheet(item: duplicateReview) { presentation in
            DuplicateReviewView(model: model.duplicates, reveal: model.reveal)
                .onAppear { model.duplicates.reviewDidAppear(presentation.id) }
                .onDisappear { model.duplicates.reviewDidDisappear(presentation.id) }
        }
        .safeAreaInset(edge: .bottom) {
            if let warning = model.authorization.bookmarkWarning {
                Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 8).frame(maxWidth: .infinity,alignment: .leading).background(.bar)
            }
        }
        .quickLookPreview($model.previewURL)
        .background(WindowCapture { window = $0 })
        .alert("DiskUnbloat", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .alert("Full Disk Access is off", isPresented: $model.showFullDiskAccessOffer) {
            Button("Open Full Disk Access settings", action: model.openFullDiskAccessSettings)
                .accessibilityIdentifier("fullDiskAccessOfferOpen")
            Button("Continue without it") { model.continueWithoutFullDiskAccess() }
            Button("Cancel", role: .cancel) { model.cancelFullDiskAccessOffer() }
        } message: {
            Text("Full Disk Access covers every protected folder at once — other applications’ data, media libraries, mail. Without it, macOS asks about each folder separately during the scan, and other applications’ data stays hidden regardless. If the switch is already on but access still fails, remove DiskUnbloat from the list and add it again: the grant is bound to the exact build.")
        }
        .onChange(of: model.settings.largeGB) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.cacheAgeDays) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.ageDays) { model.explorer.scheduleRefresh() }
        .onChange(of: model.phase) { old, new in updateWindow(for: new, previous: old) }
        .onChange(of: window) { _, newValue in
            guard newValue != nil else { return }
            updateWindow(for: model.phase, initial: true)
        }
    }
    private var duplicateReview: Binding<DuplicatesViewModel.Presentation?> {
        Binding(get: { model.duplicates.presentation }, set: { if $0 == nil { model.duplicates.dismissReview() } })
    }

    @ViewBuilder private var phaseContent: some View {
            switch model.phase {
            case .choosing:
                LocationSelectionView(model: model.location, authorization: model.authorization, scan: scan, busy: model.restoringLocation, choose: model.chooseLocation, target: model.scanTarget, restore: model.restore, drop: model.acceptDrop)
            case .scanning, .preparingResults:
                ScanningView(model: scan, preparing: model.phase == .preparingResults, cancel: model.cancel, issues: { scan.showIssues = true })
            case .exploring:
                ExplorerView(model: model.explorer, queue: model.queue, duplicates: model.duplicates, developerTools: model.developerTools, scan: scan, canClean: model.canClean, queuedPaths: cleanup.basket.map { $0.node.path }, membership: { model.cleanup.membership($0) }, newScan: model.chooseAnotherLocation, rescan: model.startScan, refreshFolder: model.refreshFolder, issues: { scan.showIssues = true }, preview: model.preview, reveal: model.reveal, selectForCleanup: model.addToBasket, deselectFromCleanup: model.deselect, addSelection: model.addSelectionToBasket, performCleanup: model.performCleanup, selecting: model.selectingItems, selectLevel: model.selectItems, previewLevel: model.previewSelection, levelEstimates: model.selectionEstimates, highlight: { model.explorer.select($0.id) })
            case .cancelled: outcome(cancelled: true, message: "The scan stopped with partial results. You can explore what was read, but cleanup will stay disabled.")
            case .failed(let error): outcome(cancelled: false, message: error)
            }
        
    }
    private func outcome(cancelled: Bool, message: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: cancelled ? "pause.circle" : "exclamationmark.triangle").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(cancelled ? .teal : .orange)
            Text(cancelled ? "Stopped, with a little perspective." : "This scan couldn’t finish.").font(.system(size: 30,weight: .semibold,design: .rounded))
            Text(L10n.text(message)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560).textSelection(.enabled)
            HStack(spacing: 12) {
                Button("Choose another location", action: model.chooseAnotherLocation).buttonStyle(.glass)
                Button("Retry", action: model.retry).buttonStyle(.glass)
                if !cancelled {
                    // macOS permission denials persist until fresh user-selected access is
                    // denied; the picker at the same location is the supported fix.
                    Button("Reauthorize access", action: model.reauthorize).buttonStyle(.glassProminent).accessibilityIdentifier("reauthorizeFailed")
                }
                if scan.refreshNode != nil { Button("Return to map", action: model.returnToPreviousMap).buttonStyle(.glassProminent) }
                else if cancelled { Button("View partial map", action: model.viewPartialMap).buttonStyle(.glassProminent).accessibilityIdentifier("viewPartialMap") }
            }
        }.padding(30).frame(maxWidth: .infinity,maxHeight: .infinity).accessibilityIdentifier(cancelled ? "cancelledScreen" : "failedScreen")
    }
    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unavailable locations").font(.title2.bold())
            if scan.protectedFoldersRefused {
                Label {
                    Text("Some of these are protected by macOS against every app: other applications' app data and protected libraries. No dialog is offered for reading them; to measure these folders too, allow DiskUnbloat under Full Disk Access. Unmeasured folders still appear with their known size.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Text("These locations weren’t fully read. Their complete sizes are unknown; the map still includes known bytes. Showing up to 500 issues.").font(.caption).foregroundStyle(.secondary)
            List(scan.issueGroups) { group in
                // Small groups open; big protection groups stay folded to a count.
                DisclosureGroup {
                    ForEach(group.paths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.isProtection ? "lock.shield" : "exclamationmark.triangle")
                            .foregroundStyle(group.isProtection ? Color.secondary : Color.orange)
                        Text(group.message).font(.callout).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(L10n.count("%lld locations", group.paths.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityIdentifier("issueGroup")
            }
            .frame(minHeight: 180)
            HStack {
                if scan.protectedFoldersRefused {
                    Button("Open Full Disk Access settings") { FullDiskAccessSettings.open() }
                        .accessibilityIdentifier("openFullDiskAccess")
                }
                Spacer()
                Button("Done") { scan.showIssues = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 460, maxWidth: 680, minHeight: 340, maxHeight: 620)
    }
}

/// Phase-aware window geometry: chooser and scan screens live in a compact window, and
/// entering results restores the remembered full size (960 × 640 at minimum). Fullscreen
/// frames are never touched.
enum WindowLayout {
    static let compactSize = CGSize(width: 660, height: 640)
    static let compactMinimum = CGSize(width: 600, height: 560)
    static let fullMinimum = CGSize(width: 960, height: 640)
    static func isCompact(_ phase: WorkspacePhase) -> Bool {
        switch phase { case .choosing, .scanning, .preparingResults: return true; default: return false }
    }
    /// The full window returns at the remembered size, never smaller than the current frame
    /// (the user may have enlarged it during the scan) or the 960 × 640 minimum.
    static func restoredSize(remembered: CGSize, current: CGSize) -> CGSize {
        CGSize(
            width: max(remembered.width, max(current.width, fullMinimum.width)),
            height: max(remembered.height, max(current.height, fullMinimum.height)))
    }
    static func isClose(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}

private struct WindowCapture: NSViewRepresentable {
    let accept: @MainActor (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowInterestView {
        let view = WindowInterestView()
        view.accept = accept
        return view
    }
    func updateNSView(_ view: WindowInterestView, context: Context) { view.accept = accept }
    final class WindowInterestView: NSView {
        var accept: (@MainActor (NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { accept?(window) }
    }
}

extension WorkspaceView {
    fileprivate func updateWindow(for phase: WorkspacePhase, previous: WorkspacePhase? = nil, initial: Bool = false) {
        guard let window else { return }
        let compact = WindowLayout.isCompact(phase)
        guard !window.styleMask.contains(.fullScreen) else { return }
        if compact { window.contentMinSize = WindowLayout.compactMinimum }
        let size = window.contentRect(forFrameRect: window.frame).size
        if compact {
            if initial || (previous.map { !WindowLayout.isCompact($0) } ?? false) {
                if !initial { savedContentSize = size }
                if !WindowLayout.isClose(size, WindowLayout.compactSize) {
                    setWindowContentSize(WindowLayout.compactSize, animated: !initial && !reduceMotion)
                }
            }
        } else if let previous, WindowLayout.isCompact(previous) {
            let target = WindowLayout.restoredSize(remembered: savedContentSize ?? .zero, current: size)
            savedContentSize = nil
            let enforceMinimum = { window.contentMinSize = WindowLayout.fullMinimum }
            if WindowLayout.isClose(size, target) { enforceMinimum() }
            else { setWindowContentSize(target, animated: !reduceMotion, then: enforceMinimum) }
        } else {
            window.contentMinSize = WindowLayout.fullMinimum
        }
    }

    /// Centers the content on the window's current center, clamped to the visible screen.
    private func setWindowContentSize(_ target: CGSize, animated: Bool, then: (() -> Void)? = nil) {
        guard let window else { return }
        let contentRect = window.contentRect(forFrameRect: window.frame)
        var newRect = contentRect
        newRect.size = target
        newRect.origin.x += (contentRect.width - target.width) / 2
        newRect.origin.y += (contentRect.height - target.height) / 2
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            newRect.origin.x = min(max(newRect.origin.x, visible.minX), visible.maxX - target.width)
            newRect.origin.y = min(max(newRect.origin.y, visible.minY), visible.maxY - target.height)
        }
        let frame = window.frameRect(forContentRect: newRect)
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.24
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }, completionHandler: then ?? {})
        } else {
            window.setFrame(frame, display: true)
            then?()
        }
    }
}
