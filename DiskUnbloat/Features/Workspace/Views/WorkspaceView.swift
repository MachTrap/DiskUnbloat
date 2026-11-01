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
        GeometryReader { geometry in phaseContent(windowWidth: geometry.size.width) }
        .frame(maxWidth: .infinity,maxHeight: .infinity)
        .navigationTitle(model.phase == .exploring ? model.explorer.current?.name ?? "DiskUnbloat" : "DiskUnbloat")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.phase)
        .sheet(isPresented: $cleanup.showBasket) { CleanupReviewView(model: cleanup, canClean: model.canClean, performCleanup: model.performCleanup) }
        .sheet(isPresented: $scan.showIssues) { issuesSheet }
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
        .onChange(of: model.settings.largeGB) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.cacheAgeDays) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.ageDays) { model.explorer.scheduleRefresh() }
        .onChange(of: model.phase) { old, new in updateWindow(for: new, previous: old) }
        .onChange(of: window) { _, window in
            guard let window else { return }
            updateWindow(for: model.phase, initial: true)
        }
    }
    @ViewBuilder private func phaseContent(windowWidth: CGFloat) -> some View {
            switch model.phase {
            case .choosing:
                LocationSelectionView(model: model.location, authorization: model.authorization, scan: scan, busy: model.restoringLocation, choose: model.chooseLocation, target: model.scanTarget, restore: model.restore, drop: model.acceptDrop)
            case .scanning, .preparingResults:
                ScanningView(model: scan, preparing: model.phase == .preparingResults, cancel: model.cancel, issues: { scan.showIssues = true })
            case .exploring:
                ExplorerView(model: model.explorer, windowWidth: windowWidth, scan: scan, canClean: model.canClean, basketCount: cleanup.basket.count, basketBytes: cleanup.basket.reduce(0) { $0 + $1.node.displaySize }, queuedPaths: cleanup.basket.map { $0.node.path }, newScan: model.chooseAnotherLocation, rescan: model.startScan, refreshFolder: model.refreshFolder, review: { cleanup.showBasket = true }, issues: { scan.showIssues = true }, preview: model.preview, reveal: model.reveal, addToBasket: model.addToBasket, addSelection: model.addSelectionToBasket)
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
                if scan.refreshNode != nil { Button("Return to map", action: model.returnToPreviousMap).buttonStyle(.glassProminent) }
                else if cancelled { Button("View partial map", action: model.viewPartialMap).buttonStyle(.glassProminent).accessibilityIdentifier("viewPartialMap") }
            }
        }.padding(30).frame(maxWidth: .infinity,maxHeight: .infinity).accessibilityIdentifier(cancelled ? "cancelledScreen" : "failedScreen")
    }
    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unavailable locations").font(.title2.bold())
            Text("These locations weren’t fully read. Their complete sizes are unknown; the map still includes known bytes. Showing up to 500 issues.").foregroundStyle(.secondary)
            List(scan.issues, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { scan.showIssues = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(minWidth: 380, maxWidth: 650, minHeight: 320, maxHeight: 500)
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
