import Foundation
import Observation
import AppKit
import DiskCore

enum WorkspacePhase: Equatable {
    case choosing, scanning, preparingResults, exploring, cancelled
    case failed(String)
}

/// Coordinates feature lifetimes; feature-specific state and behavior belong to child view models.
@MainActor @Observable final class WorkspaceViewModel {
    let location: LocationSelectionViewModel
    let diagnostics = DiagnosticsLog()
    private(set) var phase: WorkspacePhase = .choosing
    let authorization: AuthorizationStore
    let settings: SettingsViewModel
    let scan: ScanViewModel
    let explorer: ExplorerViewModel
    let cleanup: CleanupViewModel
    let queue: CleanupQueueModel
    let duplicates: DuplicatesViewModel
    let developerTools: DeveloperToolsViewModel
    @ObservationIgnored private let filePresentation: any FilePresenting
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    private(set) var restoringLocation = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The Full Disk Access gate that precedes the run task; `waitForScan` awaits both.
    @ObservationIgnored private var startPipeline: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    private(set) var selectingItems = false
    private var shuttingDown = false
    var message: String?
    var previewURL: URL?
    @ObservationIgnored private let fullDiskAccess: any FullDiskAccessChecking
    @ObservationIgnored private let openFullDiskAccessPane: () -> Void
    /// The pre-scan Full Disk Access offer: macOS refuses other applications' app data
    /// (and protected libraries) to every app without the grant, silently, so the offer
    /// must appear when the scan begins — not as an afterthought in the issue list.
    var showFullDiskAccessOffer = false
    @ObservationIgnored private var offerPreservingCleanupReport = false
    @ObservationIgnored private var awaitingFullDiskAccessGrant = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(
        authorization: AuthorizationStore = AuthorizationStore(),
        coordinator: any ScanServing = ScanCoordinator(),
        cleanupService: any CleanupServing = CleanupService(),
        settings: SettingsViewModel = SettingsViewModel(),
        filePresentation: any FilePresenting = FilePresentationService(),
        fullDiskAccess: any FullDiskAccessChecking = SystemFullDiskAccessProbe(),
        openFullDiskAccessPane: @escaping () -> Void = { FullDiskAccessSettings.open() },
        catalog: LocationCatalog = LocationCatalog(),
        storage: ScanSessionStore = ScanSessionStore(),
        defaults: UserDefaults = .standard,
        toolRunner: any ToolCommandRunning = ProcessToolRunner()
    ) {
        location = LocationSelectionViewModel(catalog: catalog)
        self.authorization = authorization
        self.settings = settings
        self.filePresentation = filePresentation
        self.fullDiskAccess = fullDiskAccess
        self.openFullDiskAccessPane = openFullDiskAccessPane
        scan = ScanViewModel(coordinator: coordinator, storage: storage)
        scan.diagnostics = diagnostics
        scan.homePaths = [canonicalURL(catalog.home).path]
        explorer = ExplorerViewModel(settings: settings, userCacheRoot: location.catalog.home.appendingPathComponent("Library/Caches"), defaults: defaults)
        cleanup = CleanupViewModel(service: cleanupService, homePath: catalog.home.path, diagnostics: CleanupDiagnosticsService())
        // The queue is the one source of hidden map paths: every queue mutation (manual
        // picks, quick-select, refresh invalidations) is forwarded to the explorer from
        // the model, never through a view-side relay like `.onChange` on a big array,
        // which silently never fires for large payloads.
        cleanup.basketDidUpdate = { [explorer] entries in
            Task { await explorer.updateHiddenPaths(entries.map { $0.node.path }) }
        }
        queue = CleanupQueueModel(cleanup: cleanup)
        developerTools = DeveloperToolsViewModel(runner: toolRunner)
        duplicates = DuplicatesViewModel(defaults: defaults)
        duplicates.context = { [unowned self] in
            guard canClean, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return nil }
            return DuplicatesViewModel.Context(
                index: index, roots: scan.roots, home: canonicalURL(location.catalog.home).path,
                unusedDays: scan.options.longUnusedDays, inspectPackages: scan.options.inspectPackages)
        }
        developerTools.context = { [unowned self] in
            scan.index.map { (index: $0, home: canonicalURL(location.catalog.home).path) }
        }
        // After a tool cleaned its cache, rescan the first affected location in scope.
        developerTools.didRun = { [unowned self] paths in
            Task {
                let home = canonicalURL(location.catalog.home).path
                for relative in paths {
                    if let node = await scan.index?.node(path: home + "/" + relative) { refreshFolder(node); return }
                }
            }
        }
        duplicates.apply = { [unowned self] entries, context, isCurrent in
            await cleanup.commitReviewedDuplicates(entries, roots: context.roots, index: context.index, isCurrent: isCurrent)
        }
    }

    var isBusy: Bool { scan.scanning || phase == .preparingResults || cleanup.cleaning || restoringLocation }

    var canClean: Bool {
        phase == .exploring && !scan.scanning && !cleanup.cleaning && scan.snapshot != nil && scan.snapshot?.cancelled == false
    }

    func waitForScan() async {
        // The FDA gate runs before the run task exists; wait out the whole pipeline.
        await startPipeline?.value
        await scanTask?.value
    }

    func waitForCleanup() async { await cleanupTask?.value }

    func shutdown() async {
        shuttingDown = true
        duplicates.cancel()
        stopWaitingForFullDiskAccess()
        locationTask?.cancel()
        selectionTask?.cancel()
        await selectionTask?.value
        await duplicates.waitForWork()
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

    /// The pre-scan offer's settings action: the pane opens, the pending scan waits, and
    /// returning to the app with the grant in place resumes it automatically.
    func openFullDiskAccessSettings() {
        diagnostics.record("consent", "Full Disk Access offer: opened settings")
        showFullDiskAccessOffer = false
        awaitingFullDiskAccessGrant = true
        openFullDiskAccessPane()
        observeActivationForFullDiskAccess()
    }

    /// The user declined Full Disk Access; the scan proceeds and the preflight raises
    /// the remaining folder/media consents one at a time before enumerating.
    func continueWithoutFullDiskAccess() {
        diagnostics.record("consent", "Full Disk Access offer: continued without it")
        showFullDiskAccessOffer = false
        stopWaitingForFullDiskAccess()
        let preserving = offerPreservingCleanupReport
        offerPreservingCleanupReport = false
        scan.consentPolicy = .minimal
        startPipeline = Task {
            guard await ensureMinimalFolderGrant() else { return }
            launchScan(preservingCleanupReport: preserving)
        }
    }

    /// Without Full Disk Access, the user's own folder choice is the consent for its
    /// contents (macOS shows no dialog for a folder picked in the open panel). When the
    /// planned roots touch the home folder and no live grant covers them, ask once for
    /// their common parent. Returns false when the user declines or picks too little.
    private func ensureMinimalFolderGrant() async -> Bool {
        let roots = scan.plannedRoots
        guard let target = Self.folderGrantTarget(roots: roots, home: location.catalog.home),
              !roots.allSatisfy({ authorization.authorizedURL(for: $0) != nil }) else { return true }
        // A remembered pick that covers the scope restores silently: the picker (and the
        // media consent its sidebar can raise) appears once, not on every scan.
        if let covering = authorization.coveringLocation(for: roots), (try? await authorization.restore(covering)) != nil,
           roots.allSatisfy({ authorization.authorizedURL(for: $0) != nil }) {
            diagnostics.record("consent", "Restored the remembered folder grant")
            return true
        }
        diagnostics.record("consent", "Asked for a folder grant on \(target.lastPathComponent)")
        do {
            guard try authorization.choose(suggestedLocation: target, message: L10n.text(
                "To scan without Full Disk Access, allow DiskUnbloat to read this folder. Choose Open to continue.")) != nil
            else { diagnostics.record("consent", "Folder grant declined"); return false }
        } catch { message = L10n.format("Couldn’t open that location. %@", error.diagnosticDescription); return false }
        guard roots.allSatisfy({ authorization.authorizedURL(for: $0) != nil }) else {
            message = L10n.text("The chosen folder doesn’t cover everything this scan needs. Choose the suggested folder to continue.")
            return false
        }
        return true
    }

    /// The folder whose grant covers `roots` when they touch the home folder: the home
    /// itself when every root is inside it, otherwise the common ancestor of the roots.
    /// `nil` when no root is inside or above the home (nothing there is consent-gated).
    static func folderGrantTarget(roots: [URL], home: URL) -> URL? {
        let homePath = canonicalURL(home).path
        let paths = roots.map { canonicalURL($0).path }
        guard paths.contains(where: { $0.isWithin(homePath) || homePath.isWithin($0) }) else { return nil }
        if paths.allSatisfy({ $0.isWithin(homePath) }) { return URL(fileURLWithPath: homePath, isDirectory: true) }
        var common = paths[0].split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: "/" + common.joined(separator: "/"), isDirectory: true)
    }

    /// The user dismissed the offer without deciding; nothing starts.
    func cancelFullDiskAccessOffer() {
        diagnostics.record("consent", "Full Disk Access offer: dismissed")
        showFullDiskAccessOffer = false
        stopWaitingForFullDiskAccess()
        offerPreservingCleanupReport = false
    }

    /// While the user is in System Settings granting Full Disk Access, the pending scan
    /// waits; returning to the app with the grant in place resumes it automatically.
    private func observeActivationForFullDiskAccess() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.resumePendingScanAfterFullDiskAccess() }
        }
    }

    private func resumePendingScanAfterFullDiskAccess() async {
        guard awaitingFullDiskAccessGrant, !shuttingDown else { return }
        let granted = await fullDiskAccess.isGranted()
        guard awaitingFullDiskAccessGrant, !shuttingDown else { return }
        if granted {
            stopWaitingForFullDiskAccess()
            let preserving = offerPreservingCleanupReport
            offerPreservingCleanupReport = false
            scan.consentPolicy = .fullDiskAccess
            launchScan(preservingCleanupReport: preserving)
        }
        // Still missing: stay quiet — the next explicit scan attempt re-offers.
    }

    private func stopWaitingForFullDiskAccess() {
        awaitingFullDiskAccessGrant = false
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

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

    /// Help-menu intents: the report is built from the live trail and handed to the user.
    func diagnosticsReport() async -> String { diagnostics.report(fullDiskAccess: await fullDiskAccess.isGranted()) }
    func copyDiagnostics() { Task { DiagnosticsExport.copy(await diagnosticsReport()); message = L10n.text("Diagnostics copied to the clipboard.") } }
    func saveDiagnostics() { Task { DiagnosticsExport.save(await diagnosticsReport()) } }

    private func startScan(preservingCleanupReport: Bool) {
        guard !cleanup.cleaning, !shuttingDown, !restoringLocation, !showFullDiskAccessOffer else { return }
        // Full Disk Access is the one decision that covers every folder and media consent
        // the preflight could raise, so it is asked first and alone. The scan waits for
        // the user's answer: with the grant present nothing else prompts at all; without
        // it, the preflight raises the remaining consents in order before enumerating.
        // Exploration rescans skip the offer — the user already answered it this session.
        let pipelineTask = Task {
            let granted = await fullDiskAccess.isGranted()
            guard !Task.isCancelled, !shuttingDown else { return }
            if granted {
                scan.consentPolicy = .fullDiskAccess
                launchScan(preservingCleanupReport: preservingCleanupReport)
            } else if !scan.scanning {
                if phase == .exploring {
                    // The user already answered the offer this session: rescans stay minimal.
                    scan.consentPolicy = .minimal
                    launchScan(preservingCleanupReport: preservingCleanupReport)
                } else {
                    offerPreservingCleanupReport = preservingCleanupReport
                    showFullDiskAccessOffer = true
                }
            }
        }
        startPipeline = pipelineTask
    }

    private func launchScan(preservingCleanupReport: Bool) {
        guard let request = scan.prepare() else { return }
        duplicates.cancel()
        phase = .scanning
        explorer.reset()
        cleanup.reset(preservingReport: preservingCleanupReport)
        queue.reset()
        scanTask = Task {
            await duplicates.waitForWork()
            // Access without consent fails with a TCC denial even while metadata stays
            // readable — a silently failed remembered-location restore makes the scan fail
            // before its first row with no dialog to answer. When a stored location covers
            // the scope, restore it (headlessly, from the narrowest covering bookmark)
            // before the doomed enumeration runs; where TCC still needs consent, the
            // preflight probes bring the prompts up front. A picker is never shown here;
            // an unrepairable scope lands on the failed screen whose Reauthorize access
            // button presents the picker explicitly.
            _ = await ensureGrant(for: request)
            authorization.retainOnly(request.roots)
            do {
                try await scan.run(request)
                let db = scan.index
                // The underlying refusal (e.g. a macOS Files-and-Folders denial) is fetched
                // before the nil check so the else-branch can compose it into the message.
                let issueDetail = await db?.issues().first.map { "\($0.path): \(L10n.text($0.message))" }
                let hasRoot = await db?.node(1) != nil
                // Cancelled before the first row (e.g. while macOS consent dialogs were
                // pending): nothing was read, so this is not a failed location.
                if !hasRoot, scan.cancellationRequested { phase = .choosing; return }
                guard let db, hasRoot else {
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
                await explorer.attach(db, options: request.options, grouped: scan.isGroupScan, roots: request.roots)
                queue.attach(IndexCleanupQueueProvider(index: db, inspectPackages: request.options.inspectPackages))
                cleanup.showQueue = true
                phase = .exploring
                recordHistory(index: db, roots: request.roots)
                // Volume scans also account for the space they could not reach.
                if request.extraRoots.isEmpty, scan.snapshot?.cancelled != true {
                    let known = await db.node(1)?.knownSize(for: .allocated) ?? 0
                    explorer.setUnreached(await VolumeSpaceService.unreached(root: request.root, knownBytes: known, unreadableLocations: scan.issues.count))
                }
            } catch { phase = .failed(L10n.format("Couldn’t start the scan. %@", error.diagnosticDescription)) }
        }
    }

    /// Growth compares against the newest earlier scan of the same scope; then this scan
    /// joins the history (unless the user turned it off). Cancelled scans are never kept.
    private func recordHistory(index: ScanIndex, roots: [URL]) {
        let key = ScanHistorySnapshot.rootKey(roots)
        let store = settings.history
        explorer.setHistory(dates: store.dates(rootKey: key)) { store.load(rootKey: key, date: $0) }
        guard settings.keepScanHistory, scan.snapshot?.cancelled != true else { return }
        let partial = scan.snapshot?.complete == false
        Task.detached(priority: .utility) {
            if let snapshot = await index.historySnapshot(roots: roots, partial: partial) { try? store.save(snapshot) }
        }
    }

    func refreshFolder(_ node: FileNode) {
        guard !isBusy, !shuttingDown, phase == .exploring else { return }
        // The synthetic group root stands for the whole scan; refreshing it reruns every location.
        if node.isGroupRoot { startScan(preservingCleanupReport: true); return }
        guard let request = scan.prepareRefresh(node) else { return }
        duplicates.cancel()
        explorer.suspendQueries(); phase = .scanning
        scanTask = Task {
            await duplicates.waitForWork()
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
    /// supported way back — macOS permission denials are only replaceable by the user's
    /// own choice, never by an entitlement.
    func reauthorize() {
        guard !isBusy else { return }
        guard let root = scan.root.map(canonicalURL) else { return }
        chooseSuggested(root)
    }

    /// Consent and Unix-permission refusals both surface as `opendir` failures while
    /// metadata (lstat) reads survive everywhere, so root readability needs real
    /// directory opens, not just identity reads.
    private func isReadableRoot(_ url: URL) -> Bool {
        let canonical = canonicalURL(url)
        guard (try? FileIdentity.read(canonical)) != nil else { return false }
        return (try? canonical.resourceValues(forKeys: [.isPackageKey])) != nil
    }

    /// Restores a covering stored bookmark headlessly when the scan scope is
    /// home-rooted (or `/`) but cannot be opened yet. Returns nothing — whether or not
    /// it could repair the scope, the scan runs and an unrepairable scope fails later
    /// on the failed screen with its recorded issue and the manual Reauthorize access
    /// button. The most specific covering bookmark wins over the broad volume-root
    /// bookmark, whose breadth would also swallow unrelated consents into the restore
    /// decision.
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
        duplicates.cancel()
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
            await explorer.attach(index, options: scan.options, grouped: scan.isGroupScan, roots: scan.roots)
            // Cancelled results stay opt-in: the queue panel does not open itself here.
            queue.attach(IndexCleanupQueueProvider(index: index, inspectPackages: scan.options.inspectPackages))
            phase = .exploring
        }
    }

    func addSelectionToBasket() { explorer.normalizedSelection.forEach(addToBasket) }

    private struct EstimateKey: Equatable { let index: ObjectIdentifier; let revision: UInt64; let unusedDays: Int; let inspectPackages: Bool }
    @ObservationIgnored private var estimateCache: (key: EstimateKey, values: [AutoSelectionLevel: AutoSelectionPreview])?

    /// Normalized per-level estimates for the quick-select picker. Computed once per index
    /// revision and long-unused threshold, so the panel can ask after every queue change.
    func selectionEstimates() async -> [AutoSelectionLevel: AutoSelectionPreview] {
        guard canClean, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return [:] }
        let key = EstimateKey(index: ObjectIdentifier(index), revision: await index.revision,
                              unusedDays: scan.options.longUnusedDays, inspectPackages: scan.options.inspectPackages)
        if let cached = estimateCache, cached.key == key { return cached.values }
        let values = await index.autoSelectionEstimates(
            home: location.catalog.home.path, unusedDays: key.unusedDays, inspectPackages: key.inspectPackages)
        guard !Task.isCancelled, scan.index === index else { return [:] }
        estimateCache = (key, values)
        return values
    }

    /// Computes one level's recommendation without touching the queue, so the level's
    /// warning can state an honest estimate before anything is selected. Posts a notice
    /// and returns nil when the scan holds nothing for this level.
    func previewSelection(_ level: AutoSelectionLevel) async -> AutoSelectionPreview? {
        guard canClean, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return nil }
        let result = await index.autoSelectionCandidates(
            home: location.catalog.home.path, level: level,
            unusedDays: scan.options.longUnusedDays, inspectPackages: scan.options.inspectPackages)
        guard !Task.isCancelled, scan.index === index else { return nil }
        guard !result.isEmpty else {
            message = L10n.text("Nothing recommended in this scan.")
            return nil
        }
        return AutoSelectionPreview(result)
    }

    /// Selects one level's recommendation into the deletion queue. The proposal passes the
    /// same safety checks as manual selection; refused items are reported, never forced.
    func selectItems(_ level: AutoSelectionLevel) {
        guard canClean, !selectingItems, !shuttingDown, !scan.roots.isEmpty, let index = scan.index else { return }
        selectingItems = true
        selectionTask = Task {
            defer { selectingItems = false }
            let result = await index.autoSelectionCandidates(
                home: location.catalog.home.path, level: level,
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
        // Selecting a partially queued folder may be refused (a running application's
        // cache among the queued children); the click then clears that nested selection
        // instead of dead-ending, with the refusal still stated in the alert.
        if let reason = cleanup.addOrClear(node, roots: scan.roots) { message = reason }
    }

    /// Remove the queue entries covering a node: its exact entry, entries below it, or
    /// the selected folder above it.
    func deselect(_ node: FileNode) {
        guard canClean else { return }
        cleanup.deselect(node)
    }

    func performCleanup(_ mode: CleanupMode) {
        guard canClean, !scan.roots.isEmpty, let index = scan.index, let items = cleanup.begin() else { return }
        duplicates.cancel()
        diagnostics.record("cleanup", "Started \(mode == .permanent ? "permanent deletion" : "move to Trash") of \(items.count) entries")
        cleanupTask = Task {
            await duplicates.waitForWork()
            let succeeded = await cleanup.execute(items, roots: scan.roots, index: index, mode: mode)
            let results = cleanup.results
            diagnostics.record("cleanup", "Finished: \(results.filter(\.succeeded).count) succeeded, \(results.filter { !$0.succeeded }.count) failed or refused")
            if succeeded {
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
    func openTrash() { filePresentation.openTrash() }
    func preview(_ node: FileNode) { previewURL = node.url }
}
