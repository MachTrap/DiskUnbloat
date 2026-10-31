import Foundation
import Observation
import DiskCore

enum WorkspacePhase: Equatable {
    case choosing, scanning, preparingResults, exploring, cancelled
    case failed(String)
}

/// Coordinates feature lifetimes; feature-specific state and behavior belong to child view models.
@MainActor @Observable final class WorkspaceViewModel {
    let location = LocationSelectionViewModel()
    private(set) var phase: WorkspacePhase = .choosing
    let authorization: AuthorizationStore
    let settings: SettingsViewModel
    let scan: ScanViewModel
    let explorer: ExplorerViewModel
    let cleanup: CleanupViewModel
    @ObservationIgnored private let filePresentation: any FilePresenting
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    private(set) var restoringLocation = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    private var shuttingDown = false
    var message: String?
    var previewURL: URL?

    init(
        authorization: AuthorizationStore = AuthorizationStore(),
        coordinator: any ScanServing = ScanCoordinator(),
        cleanupService: any CleanupServing = CleanupService(),
        settings: SettingsViewModel = SettingsViewModel(),
        filePresentation: any FilePresenting = FilePresentationService()
    ) {
        self.authorization = authorization
        self.settings = settings
        self.filePresentation = filePresentation
        scan = ScanViewModel(coordinator: coordinator)
        explorer = ExplorerViewModel(settings: settings, userCacheRoot: location.catalog.home.appendingPathComponent("Library/Caches"))
        cleanup = CleanupViewModel(service: cleanupService)
    }

    var isBusy: Bool { scan.scanning || phase == .preparingResults || cleanup.cleaning || restoringLocation }

    var canClean: Bool {
        phase == .exploring && !scan.scanning && !cleanup.cleaning && scan.snapshot != nil && scan.snapshot?.cancelled == false
    }

    func waitForScan() async { await scanTask?.value }

    func shutdown() async {
        shuttingDown = true
        locationTask?.cancel()
        await cleanupTask?.value
        await scan.cancel()
        await scanTask?.value
        explorer.reset()
        await scan.discardIndex()
        authorization.release()
    }

    func loadSample() {
        guard !isBusy else { return }
        do { scan.pendingRoot = try SampleData.create(); startScan() }
        catch { message = error.localizedDescription }
    }

    func chooseLocation() {
        guard !isBusy else { return }
        do {
            if let url = try authorization.choose() { scan.pendingRoot = url; startScan() }
        } catch { message = L10n.format("Couldn’t access the selected folder. %@", error.diagnosticDescription) }
    }

    func restore(_ location: SavedLocation) {
        guard !isBusy else { return }
        restoringLocation = true
        locationTask = Task {
            defer { restoringLocation = false }
            do {
                let url = try await authorization.restore(location)
                guard !Task.isCancelled else { return }
                scan.pendingRoot = url
                restoringLocation = false
                startScan()
            } catch {
                guard !Task.isCancelled else { return }
                message = L10n.format("Choose the location again to renew access. %@", error.diagnosticDescription)
            }
        }
    }

    func startScan() { startScan(preservingCleanupReport: false) }

    private func startScan(preservingCleanupReport: Bool) {
        guard !cleanup.cleaning, !shuttingDown, !restoringLocation, let request = scan.prepare() else { return }
        phase = .scanning
        explorer.reset()
        cleanup.reset(preservingReport: preservingCleanupReport)
        scanTask = Task {
            authorization.retainOnly(request.root)
            do {
                try await scan.run(request)
                guard let index = scan.index, await index.node(1) != nil else {
                    phase = .failed(L10n.text("The selected location couldn’t be read. Check its permissions or choose another folder."))
                    return
                }
                if scan.snapshot?.cancelled == true { phase = .cancelled; return }
                phase = .preparingResults
                scan.stage = .preparingMap
                await explorer.attach(index, options: request.options)
                phase = .exploring
            } catch { phase = .failed(L10n.format("Couldn’t start the scan. %@", error.diagnosticDescription)) }
        }
    }

    func refreshFolder(_ node: FileNode) {
        guard !isBusy, !shuttingDown, phase == .exploring, let request = scan.prepareRefresh(node) else { return }
        explorer.suspendQueries(); phase = .scanning
        scanTask = Task {
            do {
                if try await scan.runRefresh(request, node: node) {
                    let count = cleanup.invalidate(overlapping: node.path)
                    if count > 0 { message = L10n.text("Refreshed items were removed from cleanup review. Review their current contents again.") }
                    phase = .preparingResults; scan.stage = .preparingMap
                    await explorer.restoreAfterRefresh()
                    scan.finishRefresh(restorePrevious: false); phase = .exploring
                } else { phase = .cancelled }
            } catch { phase = .failed(L10n.format("The folder refresh failed. Previous results are unchanged. %@", L10n.text(error.localizedDescription))) }
        }
    }

    func returnToPreviousMap() {
        guard scan.refreshNode != nil, !isBusy else { return }
        scan.finishRefresh(restorePrevious: true); phase = .exploring
    }

    func retry() {
        if let node = scan.refreshNode {
            scan.finishRefresh(restorePrevious: true); phase = .exploring; refreshFolder(node)
        } else { startScan() }
    }

    func openLocations(_ urls: [URL]) -> Bool {
        guard !isBusy else { message = L10n.text("A scan or cleanup is in progress. Try opening the folder again when it finishes."); return false }
        do {
            let url = try location.directory(from: urls)
            do { scan.pendingRoot = try authorization.acceptSelection(url); startScan() }
            catch { chooseSuggested(url) }
            return true
        } catch {
            let failure = error as NSError
            if urls.count == 1, let url = urls.first, url.isFileURL,
               failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileReadNoPermission.rawValue {
                chooseSuggested(url); return true
            }
            message = error.localizedDescription; return false
        }
    }

    func chooseAnotherLocation() {
        guard !isBusy else { return }
        phase = .choosing
    }

    func scanTarget(_ target: ScanTarget) {
        guard !isBusy else { return }
        if let url = authorization.authorizedURL(for: target.url) { scan.pendingRoot = url; startScan(); return }
        if let saved = authorization.locations.first(where: { target.url.path == $0.name || target.url.path.hasPrefix($0.name + "/") }) {
            restoringLocation = true
            locationTask = Task {
                defer { restoringLocation = false }
                do {
                    _ = try await authorization.restore(saved)
                    guard !Task.isCancelled else { return }
                    if let url = authorization.authorizedURL(for: target.url) {
                        scan.pendingRoot = url; restoringLocation = false; startScan(); return
                    }
                } catch { /* Renew through the system picker at the requested location. */ }
                guard !Task.isCancelled else { return }
                restoringLocation = false
                chooseSuggested(target.url)
            }
        } else { chooseSuggested(target.url) }
    }

    private func chooseSuggested(_ url: URL) {
        do {
            if let chosen = try authorization.choose(suggestedLocation: url) { scan.pendingRoot = chosen; startScan() }
        } catch { message = L10n.format("Couldn’t open that location. %@", error.diagnosticDescription) }
    }

    func acceptDrop(_ urls: [URL]) -> Bool { openLocations(urls) }

    func viewPartialMap() {
        guard phase == .cancelled, let index = scan.index else { return }
        phase = .preparingResults; scan.stage = .preparingMap
        scanTask = Task { await explorer.attach(index, options: scan.options); phase = .exploring }
    }

    func addSelectionToBasket() { explorer.normalizedSelection.forEach(addToBasket) }

    func cancel() { scan.requestCancellation(); Task { await scan.cancel() } }

    func addToBasket(_ node: FileNode) {
        guard canClean, let root = scan.root else { return }
        if let reason = cleanup.add(node, root: root) { message = reason }
    }

    func performCleanup(_ mode: CleanupMode) {
        guard canClean, let root = scan.root, let index = scan.index, let items = cleanup.begin() else { return }
        cleanupTask = Task {
            if await cleanup.execute(items, root: root, index: index, mode: mode) {
                // Recompute hard-link ownership throughout the scope after any successful removal.
                startScan(preservingCleanupReport: true)
            }
        }
    }

    func reveal(_ node: FileNode) { filePresentation.reveal(node) }
    func preview(_ node: FileNode) { previewURL = node.url }
}
