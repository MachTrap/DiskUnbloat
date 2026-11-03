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
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    private(set) var selectingItems = false
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
        cleanup = CleanupViewModel(service: cleanupService, diagnostics: CleanupDiagnosticsService())
        // The queue is the one source of hidden map paths: every queue mutation (manual
        // picks, quick-select, refresh invalidations) is forwarded to the explorer from
        // the model, never through a view-side relay like `.onChange` on a big array,
        // which silently never fires for large payloads.
        cleanup.basketDidUpdate = { [explorer] entries in
            Task { await explorer.updateHiddenPaths(entries.map { $0.node.path }) }
        }
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
        selectionTask?.cancel()
        await selectionTask?.value
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
            // The sandbox denies openings without an active security-scope grant even
            // while metadata stays readable — a silently failed grant activation makes
            // the scan fail before its first row with no dialog to answer. When a stored
            // bookmark covers the scope, restore it (headlessly, from the narrowest
            // covering bookmark) before the doomed enumeration runs. A picker is never
            // shown here; an unrepairable scope lands on the failed screen whose
            // Reauthorize access button presents the picker explicitly.
            _ = await ensureGrant(for: request)
            authorization.retainOnly(request.roots)
            do {
                try await scan.run(request)
                let db = scan.index
                // The underlying refusal (e.g. a macOS Files-and-Folders denial) is fetched
                // before the nil check so the else-branch can compose it into the message.
                let issueDetail = await db?.issues().first.map { "\($0.path): \(L10n.text($0.message))" }
                guard let db, await db.node(1) != nil else {
                    phase = .failed(issueDetail.map {
                        L10n.format("The selected location couldn’t be read. %@", $0)
                    } ?? L10n.text("The selected location couldn’t be read. Check its permissions or choose another folder."))
                    return
                }
                if scan.snapshot?.cancelled == true { phase = .cancelled; return }
                if request.extraRoots.isEmpty == false {
                    // Grouped scans fail only when every listed location was unreadable.
                    var probe = FileQuery(); probe.parentID = 1; probe.limit = 1
                    guard !(await db.query(probe)).isEmpty else {
                        let groupDetail = await db.issues().first.map { "\($0.path): \(L10n.text($0.message))" }
                        phase = .failed(groupDetail.map {
                            L10n.format("None of these locations could be read. %@", $0)
                        } ?? L10n.text("None of these locations could be read. Check their permissions or scan individual folders."))
                        return
                    }
                }
                phase = .preparingResults
                scan.stage = .preparingMap
                await explorer.attach(db, options: request.options, grouped: scan.isGroupScan)
                queue.attach(IndexCleanupQueueProvider(index: db, inspectPackages: request.options.inspectPackages))
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
                    // Queue changes reach the explorer's hidden state deterministically
                    // before the map presentation restores, so the restored selection
                    // reflects exactly what is still selectable.
                    await explorer.updateHiddenPaths(cleanup.basket.map { $0.node.path })
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

    /// Recovery after a failed attempt: macOS may have recorded a permission denial
    /// (a Files-and-Folders "Don't Allow" from the upfront consent dialogs), and
    /// repeating the same scan can never revive a denied scope. Presenting the system
    /// picker at the same location generates fresh user-selected access, which is the
    /// one sandbox-correct way back — no entitlements are available for this.
    func reauthorize() {
        guard !isBusy else { return }
        guard let root = scan.root.map(canonicalURL) else { return }
        chooseSuggested(root)
    }

    /// The sandbox denies openings (and URL resource-value reads) without an active
    /// security-scope grant while metadata (lstat) stays readable everywhere, so both
    /// checks must pass for the scan to be worth starting.
    private func isReadableRoot(_ url: URL) -> Bool {
        let canonical = canonicalURL(url)
        guard (try? FileIdentity.read(canonical)) != nil else { return false }
        return (try? canonical.resourceValues(forKeys: [.isPackageKey])) != nil
    }

    /// Restores a covering stored grant headlessly when the scan scope is home-rooted
    /// (or `/`) but cannot be opened yet. Returns nothing — whether or not it could
    /// repair the grants, the scan runs and an unrepairable scope fails later on the
    /// failed screen with its recorded issue and the manual Reauthorize access button.
    /// The most specific covering bookmark wins over the broad volume-root grant, whose
    /// activation does not reliably extend the sandbox into protected home data.
    private func ensureGrant(for request: ScanRequest) async {
        let canonicalRoots = request.roots.map(canonicalURL)
        let homePath = location.catalog.home.path
        // Other scopes always scan through a path-granted root: nothing to repair here,
        // and this keeps hosted fixture scans away from real bookmarks.
        guard canonicalRoots.allSatisfy({ $0.path == "/" || $0.path.isWithin(homePath) }) else { return }
        guard !canonicalRoots.allSatisfy({ isReadableRoot($0) }) else { return }
        guard let covering = authorization.coveringLocation(for: canonicalRoots) else { return }
        do { _ = try await authorization.restore(covering) } catch { return }
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
            if let saved = authorization.coveringLocation(for: [target.url]) {
                runRestoring {
                    do {
                        let url = try await self.authorization.restore(saved)
                        guard !Task.isCancelled else { return }
                        if let url = self.authorization.authorizedURL(for: target.url) {
                            self.restoringLocation = false; self.beginScan(with: url); return
                        }
                        self.restoringLocation = false
                        self.chooseSuggested(target.url)
                    } catch {
                        // The covering bookmark didn't activate; renew through the picker at the location.
                        guard !Task.isCancelled else { return }
                        self.restoringLocation = false
                        self.message = L10n.format("Choose the location again to renew access. %@", error.diagnosticDescription)
                        self.chooseSuggested(target.url)
                    }
                }
            } else { chooseSuggested(target.url) }
            return
        }
        // Grouped quick actions scan several known locations; the home grant covers them all.
        let covered = target.roots.allSatisfy { authorization.authorizedURL(for: $0) != nil }
        if covered { startGrouped(target); return }
        if let saved = authorization.coveringLocation(for: target.roots) {
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

    /// Computes one tier's recommendation without touching the queue, so the tier-2
    /// warning can state an honest estimate before anything is selected. Posts a notice
    /// and returns nil when the scan holds nothing for this tier.
    func previewSelection(_ tier: AutoSelectionTier) async -> AutoSelectionPreview? {
        guard canClean, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return nil }
        let result = await index.autoSelectionCandidates(
            home: location.catalog.home.path, tier: tier,
            unusedDays: scan.options.longUnusedDays, inspectPackages: scan.options.inspectPackages)
        guard !Task.isCancelled, scan.index === index else { return nil }
        guard !result.isEmpty else {
            message = L10n.text("Nothing recommended in this scan.")
            return nil
        }
        return AutoSelectionPreview(result)
    }

    /// Selects one tier's recommendation into the deletion queue. The proposal passes the
    /// same safety checks as manual selection; refused items are reported, never forced.
    func selectItems(_ tier: AutoSelectionTier) {
        guard canClean, !selectingItems, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return }
        selectingItems = true
        selectionTask = Task {
            defer { selectingItems = false }
            let result = await index.autoSelectionCandidates(
                home: location.catalog.home.path, tier: tier,
                unusedDays: scan.options.longUnusedDays, inspectPackages: scan.options.inspectPackages)
            guard !Task.isCancelled, canClean, scan.index === index, !cleanup.cleaning else { return }
            if result.isEmpty {
                message = L10n.text("Nothing recommended in this scan.")
                return
            }
            let outcome = cleanup.applyAutoSelection(result, roots: scan.roots)
            if outcome.skipped > 0 {
                message = L10n.count("%lld items were skipped by safety checks.", outcome.skipped)
            }
        }
    }

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
                // The map is stale after removals: rerun the scan of the same scope on the
                // spot — the deletion report survives the scan — and land back on the
                // updated map instead of sending the user to the location chooser to
                // repeat the whole process by hand. `prepare()` reruns exactly this scope
                // (the combined group scope for grouped scans), and the fresh map keeps
                // every invariant the full scan already enforces.
                startScan(preservingCleanupReport: true)
                cleanup.showReport = true
            }
        }
    }

    func reveal(_ node: FileNode) { filePresentation.reveal(node) }
    func preview(_ node: FileNode) { previewURL = node.url }
}
