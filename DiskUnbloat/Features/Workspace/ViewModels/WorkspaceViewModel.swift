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
    let queue: CleanupQueueModel
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
        queue = CleanupQueueModel(cleanup: cleanup)
    }

    var isBusy: Bool { scan.scanning || phase == .preparingResults || cleanup.cleaning || restoringLocation }

    var canClean: Bool {
        phase == .exploring && !scan.scanning && !cleanup.cleaning && scan.snapshot != nil && scan.snapshot?.cancelled == false
    }

    func waitForScan() async { await scanTask?.value }

    func waitForCleanup() async { await cleanupTask?.value }

    func shutdown() async {
        shuttingDown = true
        locationTask?.cancel()
        await cleanupTask?.value
        await scan.cancel()
        await scanTask?.value
        explorer.reset()
        queue.reset()
        await scan.discardIndex()
        authorization.release()
    }

    func chooseLocation() {
        guard !isBusy else { return }
        do {
            if let url = try authorization.choose() { beginScan(with: url) }
        } catch { message = L10n.format("Couldn’t access the selected folder. %@", error.diagnosticDescription) }
    }

    func restore(_ location: SavedLocation) {
        guard !isBusy else { return }
        runRestoring {
            do {
                let url = try await self.authorization.restore(location)
                guard !Task.isCancelled else { return }
                self.restoringLocation = false
                self.beginScan(with: url)
            } catch {
                guard !Task.isCancelled else { return }
                self.message = L10n.format("Choose the location again to renew access. %@", error.diagnosticDescription)
            }
        }
    }

    func startScan() { startScan(preservingCleanupReport: false) }

    /// Queue a resolved URL as the scan root and start scanning it.
    private func beginScan(with url: URL) {
        scan.pendingRoot = url
        startScan()
    }

    /// Run `body` as the restore task while flipping `restoringLocation` for its lifetime.
    private func runRestoring(_ body: @escaping @Sendable @MainActor () async -> Void) {
        restoringLocation = true
        locationTask = Task {
            defer { restoringLocation = false }
            await body()
        }
    }

    private func startScan(preservingCleanupReport: Bool) {
        guard !cleanup.cleaning, !shuttingDown, !restoringLocation, let request = scan.prepare() else { return }
        phase = .scanning
        explorer.reset()
        cleanup.reset(preservingReport: preservingCleanupReport)
        queue.reset()
        scanTask = Task {
            authorization.retainOnly(request.roots)
            do {
                try await scan.run(request)
                guard let index = scan.index, await index.node(1) != nil else {
                    phase = .failed(L10n.text("The selected location couldn’t be read. Check its permissions or choose another folder."))
                    return
                }
                if scan.snapshot?.cancelled == true { phase = .cancelled; return }
                if request.extraRoots.isEmpty == false {
                    // Grouped scans fail only when every listed location was unreadable.
                    var probe = FileQuery(); probe.parentID = 1; probe.limit = 1
                    guard !(await index.query(probe)).isEmpty else {
                        phase = .failed(L10n.text("None of these locations could be read. Check their permissions or scan individual folders."))
                        return
                    }
                }
                phase = .preparingResults
                scan.stage = .preparingMap
                await explorer.attach(index, options: request.options, grouped: scan.isGroupScan)
                queue.attach(IndexCleanupQueueProvider(index: index, inspectPackages: request.options.inspectPackages))
                cleanup.showQueue = true
                phase = .exploring
            } catch { phase = .failed(L10n.format("Couldn’t start the scan. %@", error.diagnosticDescription)) }
        }
    }

    func refreshFolder(_ node: FileNode) {
        guard !isBusy, !shuttingDown, phase == .exploring else { return }
        // The synthetic group root stands for the whole scan; refreshing it reruns every location.
        if node.isGroupRoot { startScan(preservingCleanupReport: true); return }
        guard let request = scan.prepareRefresh(node) else { return }
        explorer.suspendQueries(); phase = .scanning
        scanTask = Task {
            do {
                if try await scan.runRefresh(request, node: node) {
                    let count = cleanup.invalidate(overlapping: node.path)
                    if count > 0 { message = L10n.text("Refreshed items were removed from the cleanup queue. Review their current contents again.") }
                    phase = .preparingResults; scan.stage = .preparingMap
                    await explorer.restoreAfterRefresh()
                    queue.invalidateCaches()
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
            do { beginScan(with: try authorization.acceptSelection(url)) }
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
        guard target.grouped else {
            if let url = authorization.authorizedURL(for: target.url) { beginScan(with: url); return }
            if let saved = authorization.locations.first(where: { target.url.path.isWithin($0.name) }) {
                runRestoring {
                    do {
                        _ = try await self.authorization.restore(saved)
                        guard !Task.isCancelled else { return }
                        if let url = self.authorization.authorizedURL(for: target.url) {
                            self.restoringLocation = false; self.beginScan(with: url); return
                        }
                    } catch { /* Renew through the system picker at the requested location. */ }
                    guard !Task.isCancelled else { return }
                    self.restoringLocation = false
                    self.chooseSuggested(target.url)
                }
            } else { chooseSuggested(target.url) }
            return
        }
        // Grouped quick actions scan several known locations; the home grant covers them all.
        let covered = target.roots.allSatisfy { authorization.authorizedURL(for: $0) != nil }
        if covered { startGrouped(target); return }
        if let saved = authorization.locations.first(where: { saved in target.roots.allSatisfy { $0.path.isWithin(saved.name) } }) {
            runRestoring {
                var renewed = false
                do { _ = try await self.authorization.restore(saved); renewed = true } catch { /* Renew through the system picker instead. */ }
                guard !Task.isCancelled else { return }
                self.restoringLocation = false
                if renewed, target.roots.allSatisfy({ self.authorization.authorizedURL(for: $0) != nil }) { self.startGrouped(target) }
                else { self.chooseGroup(target) }
            }
        } else { chooseGroup(target) }
    }

    private func startGrouped(_ target: ScanTarget) {
        // The scan must never begin from an uncovered location: request the missing rights instead.
        guard target.roots.allSatisfy({ authorization.authorizedURL(for: $0) != nil }) else { chooseGroup(target); return }
        scan.pendingGroup = PendingGroup(title: target.title, roots: target.roots.compactMap { authorization.authorizedURL(for: $0) })
        startScan()
    }

    private func chooseGroup(_ target: ScanTarget) {
        do {
            let granted = try authorization.choose(
                suggestedLocation: location.catalog.home,
                message: L10n.text("Authorize your home folder so every known cache location becomes available."))
            guard granted != nil else { return } // The request was declined, so nothing is scanned.
            // Only scan once every listed location is inside the new grant; re-scope to home otherwise.
            if target.roots.allSatisfy({ authorization.authorizedURL(for: $0) != nil }) {
                startGrouped(target)
            } else {
                message = L10n.text("The chosen folder doesn’t cover every listed location. Choose your home folder to scan all of them.")
            }
        } catch { message = L10n.format("Couldn’t open that location. %@", error.diagnosticDescription) }
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
        scanTask = Task {
            await explorer.attach(index, options: scan.options, grouped: scan.isGroupScan)
            // Cancelled results stay opt-in: the queue panel does not open itself here.
            queue.attach(IndexCleanupQueueProvider(index: index, inspectPackages: scan.options.inspectPackages))
            phase = .exploring
        }
    }

    func addSelectionToBasket() { explorer.normalizedSelection.forEach(addToBasket) }

    func cancel() { scan.requestCancellation(); Task { await scan.cancel() } }

    func addToBasket(_ node: FileNode) {
        guard canClean, !scan.roots.isEmpty else { return }
        if let reason = cleanup.add(node, roots: scan.roots) { message = reason }
    }

    /// Remove the queue entries covering a node: its exact entry, entries below it, or
    /// the selected folder above it.
    func deselect(_ node: FileNode) {
        guard canClean else { return }
        cleanup.deselect(node)
    }

    func performCleanup(_ mode: CleanupMode) {
        guard canClean, !scan.roots.isEmpty, let index = scan.index, let items = cleanup.begin() else { return }
        cleanupTask = Task {
            if await cleanup.execute(items, roots: scan.roots, index: index, mode: mode) {
                // The current map is stale after removals; return to the location chooser
                // instead of re-scanning, dropping the stale index. The deletion report is kept.
                phase = .choosing
                explorer.reset()
                queue.reset()
                cleanup.reset(preservingReport: true)
                cleanup.showReport = true
                await scan.discardIndex()
            }
        }
    }

    func reveal(_ node: FileNode) { filePresentation.reveal(node) }
    func preview(_ node: FileNode) { previewURL = node.url }
}
