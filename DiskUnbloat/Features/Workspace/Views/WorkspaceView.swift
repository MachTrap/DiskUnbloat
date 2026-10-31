import SwiftUI
import QuickLook
import DiskCore

struct WorkspaceView: View {
    @Bindable var model: WorkspaceViewModel
    @Bindable private var scan: ScanViewModel
    @Bindable private var cleanup: CleanupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .alert("DiskUnbloat", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .onChange(of: model.settings.largeGB) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.cacheAgeDays) { model.explorer.scheduleRefresh() }
        .onChange(of: model.settings.ageDays) { model.explorer.scheduleRefresh() }
    }
    @ViewBuilder private func phaseContent(windowWidth: CGFloat) -> some View {
            switch model.phase {
            case .choosing:
                LocationSelectionView(model: model.location, authorization: model.authorization, scan: scan, busy: model.restoringLocation, choose: model.chooseLocation, target: model.scanTarget, restore: model.restore, sample: model.loadSample, drop: model.acceptDrop)
            case .scanning, .preparingResults:
                ScanningView(model: scan, preparing: model.phase == .preparingResults, cancel: model.cancel)
            case .exploring:
                ExplorerView(model: model.explorer, windowWidth: windowWidth, scan: scan, canClean: model.canClean, basketCount: cleanup.basket.count, basketBytes: cleanup.basket.reduce(0) { $0 + $1.displaySize }, newScan: model.chooseAnotherLocation, rescan: model.startScan, refreshFolder: model.refreshFolder, review: { cleanup.showBasket = true }, issues: { scan.showIssues = true }, preview: model.preview, reveal: model.reveal, addToBasket: model.addToBasket, addSelection: model.addSelectionToBasket)
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
        }.padding(24).frame(width: 650,height: 450)
    }
}
