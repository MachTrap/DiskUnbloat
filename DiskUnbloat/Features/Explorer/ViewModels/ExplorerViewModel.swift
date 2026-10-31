import Foundation
import CoreGraphics
import Observation
import DiskCore

enum ExplorerScope: String, CaseIterable, Identifiable {
    case current = "Current folder", entireScan = "Entire scan"
    var id: Self { self }
}

/// Everything that affects the browser summary, rows, legend, and statistics for one state.
/// Deliberately excludes the running-application cache exclusions, so candidate/suggestion
/// results (which depend on them) are never cached.
private struct ResultsKey: Hashable {
    let revision: UInt64
    let currentID: Int64
    let metric: SizeMetric
    let inspectPackages: Bool
    let drawerTab: AnalysisTab
    let scope: ExplorerScope
    let search: String
    let minimumGB: Double
    let olderDays: Int
    let extensionFilter: String
    let hiddenPaths: [String]
    let sortName: Bool
    let ascending: Bool
}
private struct CachedResults {
    let summary: SizeSummary
    let rows: [FileNode]
    let legend: [FileCategory]
    let statistics: [CategorySummary]
}

@MainActor @Observable final class ExplorerViewModel {
    private let settings: SettingsViewModel
    private let activity: any ApplicationActivityProviding
    let homePath: String?
    var candidateRule: CleanupRule = .large
    private let cacheRootPath: String?
    @ObservationIgnored private var index: ScanIndex?
    /// Grouped scans put several locations under one synthetic root; filter scope then
    /// spans the union of all listed locations instead of one path prefix.
    @ObservationIgnored private var groupScan = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var nodesByID: [Int64: FileNode] = [:]
    @ObservationIgnored private var sceneCache: [String: MapScene] = [:]
    @ObservationIgnored private var sceneCacheOrder: [String] = []
    @ObservationIgnored private var resultsCache: [ResultsKey: CachedResults] = [:]
    @ObservationIgnored private var resultsCacheOrder: [ResultsKey] = []
    private var queryGeneration = 0
    private var options = ScanOptions()
    var drawerHeight: CGFloat = 190
    var drawerTab: AnalysisTab = .files
    var categories: [CategorySummary] = []
    private(set) var legendCategories: [FileCategory] = []
    var rows: [FileNode] = []
    var scene = MapScene()
    var selectionIDs: Set<Int64> = [] { didSet { if selectionIDs.isEmpty { showDetails = false } } }
    var selection: Int64? {
        get { selectionIDs.count == 1 ? selectionIDs.first : nil }
        set { selectionIDs = newValue.map { [$0] } ?? [] }
    }
    var selected: FileNode? { selection.flatMap { nodesByID[$0] } }
    var selectedNodes: [FileNode] { selectionIDs.compactMap { nodesByID[$0] } }
    var normalizedSelection: [FileNode] {
        CleanupPlan(root: URL(fileURLWithPath: "/"), items: selectedNodes, mode: .trash).items
    }
    var selectionBytes: Int64 { normalizedSelection.reduce(0) { $0 + $1.knownSize(for: metric) } }
    var current: FileNode?
    var breadcrumbs: [FileNode] = []
    var back: [Int64] = []
    var forward: [Int64] = []
    var search = ""
    var scope: ExplorerScope = .current
    var suggestion: Suggestion?
    var minimumGB = 0.0
    var olderDays = 0
    var extensionFilter = ""
    var metric: SizeMetric = .allocated
    var highlightedCategory: FileCategory?
    var sortName = false
    var ascending = false
    var showFiles = false
    var showDetails = false
    var page = 0
    let pageSize = 250
    var totalRows = 0
    var isLoading = false
    var fitRevision = 0
    var searchRequested = 0
    /// Paths queued for deletion; they disappear from the map and browser until removed.
    private(set) var hiddenPaths: [String] = []
    /// Candidate paths the user excluded from deletion suggestions this session.
    private(set) var excludedCandidatePaths: [String] = []
    var isCandidateFilterActive: Bool { drawerTab == .candidates || suggestion != nil }
    var largeThresholdGB: Double { settings.largeGB }
    var candidateAgeDays: Int { candidateRule.isCache ? settings.cacheAgeDays : settings.ageDays }
    var hasFilters: Bool { !search.isEmpty || suggestion != nil || minimumGB > 0 || olderDays > 0 || !extensionFilter.isEmpty }
    var pageCount: Int { max(1, (totalRows + pageSize - 1) / pageSize) }
    var availableCategories: [FileCategory] {
        let present = Set(legendCategories)
        return FileCategory.allCases.filter { present.contains($0) }
    }

    init(settings: SettingsViewModel, userCacheRoot: URL? = nil, activity: any ApplicationActivityProviding = ApplicationActivityService()) {
        self.settings = settings; self.activity = activity; cacheRootPath = userCacheRoot?.path
        homePath = userCacheRoot?.deletingLastPathComponent().deletingLastPathComponent().path
    }

    func reset() {
        refreshTask?.cancel(); pageTask?.cancel(); queryGeneration += 1; index = nil; nodesByID = [:]
        sceneCache = [:]; sceneCacheOrder = []; resultsCache = [:]; resultsCacheOrder = []
        rows = []; categories = []; legendCategories = []; drawerTab = .files; scene = MapScene(); current = nil; selectionIDs = []
        breadcrumbs = []; back = []; forward = []; suggestion = nil; page = 0; totalRows = 0
        showFiles = false; showDetails = false; highlightedCategory = nil
        search = ""; minimumGB = 0; olderDays = 0; extensionFilter = ""; scope = .current; isLoading = false
        hiddenPaths = []; excludedCandidatePaths = []
    }

    /// Hides queued deletion items everywhere the explorer queries, and drops their selections.
    func updateHiddenPaths(_ paths: [String]) {
        guard paths != hiddenPaths else { return }
        hiddenPaths = paths
        let hidden = paths
        selectionIDs = selectionIDs.filter { id in
            guard let node = nodesByID[id] else { return true }
            return !hidden.contains { node.path == $0 || node.path.hasPrefix($0 + "/") }
        }
        sceneCache = [:]; sceneCacheOrder = []; resultsCache = [:]; resultsCacheOrder = []
        scheduleRefresh()
    }

    func excludeCandidate(_ node: FileNode) {
        guard !excludedCandidatePaths.contains(where: { node.path == $0 || node.path.hasPrefix($0 + "/") || $0.hasPrefix(node.path + "/") }) else { return }
        excludedCandidatePaths.append(node.path)
        scheduleRefresh()
    }
    func restoreCandidateExclusion(_ path: String) {
        excludedCandidatePaths.removeAll { $0 == path }
        scheduleRefresh()
    }
    func clearCandidateExclusions() {
        guard !excludedCandidatePaths.isEmpty else { return }
        excludedCandidatePaths = []
        scheduleRefresh()
    }

    func attach(_ index: ScanIndex, options: ScanOptions, grouped: Bool = false) async {
        self.index = index; self.options = options; groupScan = grouped
        let root = await index.node(1)
        guard self.index === index else { return }
        current = root
        await loadRows(); await loadBreadcrumbs()
    }

    func suspendQueries() { refreshTask?.cancel(); pageTask?.cancel(); queryGeneration += 1 }

    func restoreAfterRefresh() async {
        guard let index else { return }
        sceneCache = [:]; sceneCacheOrder = []; resultsCache = [:]; resultsCacheOrder = []
        let oldSelection = selectionIDs
        let oldBreadcrumbs = breadcrumbs
        var focus = current.flatMap { _ in current }
        if let id = focus?.id { focus = await index.node(id) }
        if focus == nil {
            for ancestor in oldBreadcrumbs.reversed() {
                if let surviving = await index.node(ancestor.id) { focus = surviving; break }
            }
        }
        if let focus { current = focus } else { current = await index.node(1) }
        var surviving: [FileNode] = []
        for id in oldSelection { if let node = await index.node(id) { surviving.append(node) } }
        var validBack: [Int64] = []; var validForward: [Int64] = []
        for id in back { if await index.node(id) != nil { validBack.append(id) } }
        for id in forward { if await index.node(id) != nil { validForward.append(id) } }
        back = validBack; forward = validForward
        nodesByID = Dictionary(uniqueKeysWithValues: surviving.map { ($0.id,$0) })
        selectionIDs = Set(surviving.map(\.id))
        await loadRows(); await loadBreadcrumbs()
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            await loadRows()
        }
    }

    /// Focused grouping roots span multiple real locations; their subtree scope covers the
    /// whole scan, because every scanned path lives under one of the listed roots.
    private func subtreeScope() -> String? {
        guard scope == .current, let current else { return nil }
        return groupScan && current.isGroupRoot ? nil : current.path
    }

    private func makeQuery() -> FileQuery {
        var q = FileQuery()
        q.inspectPackages = options.inspectPackages; q.metric = metric
        if hasFilters || drawerTab != .files {
            q.leafResults = true
            if scope == .current { q.subtreePath = subtreeScope() }
        } else { q.parentID = current?.id }
        if drawerTab == .candidates || suggestion != nil {
            q.cleanupRule = drawerTab == .candidates ? candidateRule : suggestion?.rule; q.userHome = homePath; q.cacheAgeDays = settings.cacheAgeDays
            q.excludedCandidatePaths = (homePath.map { activity.blockedCachePaths(home: $0) } ?? []) + excludedCandidatePaths
        }
        q.hiddenPaths = hiddenPaths
        q.search = search; q.minimumSize = Int64(max(0, minimumGB) * 1e9)
        q.olderThan = olderDays > 0 ? Date().addingTimeInterval(-Double(olderDays) * 86400) : nil
        q.fileExtension = extensionFilter; q.suggestion = nil; q.cacheRootPath = cacheRootPath
        q.largeThreshold = Int64(max(0.001, settings.largeGB) * 1e9); q.ageDays = settings.ageDays
        q.sortByName = drawerTab == .largest ? false : sortName; q.ascending = drawerTab == .largest ? false : ascending; q.knownSizesOnly = drawerTab == .largest; q.limit = pageSize
        return q
    }

    func loadRows() async {
        guard let index, let current else { return }
        queryGeneration += 1; let generation = queryGeneration
        isLoading = true; page = 0
        let revision = await index.revision
        let browserQuery = makeQuery(); let filtered = hasFilters
        var statsQuery = browserQuery; statsQuery.parentID = nil; statsQuery.leafResults = true; statsQuery.knownSizesOnly = false; statsQuery.cleanupRule = suggestion?.rule
        statsQuery.subtreePath = subtreeScope()
        var mapQuery = browserQuery; mapQuery.cleanupRule = suggestion?.rule; mapQuery.knownSizesOnly = false; mapQuery.parentID = hasFilters ? nil : current.id; mapQuery.leafResults = hasFilters
        mapQuery.subtreePath = hasFilters ? subtreeScope() : nil
        let sceneKey = "\(revision):\(current.id):\(metric.rawValue):\(options.inspectPackages)"
        let cachedScene = filtered ? nil : sceneCache[sceneKey]
        // Candidate/suggestion results depend on the dynamic set of running applications, so
        // they are never cached; everything else is safe to reuse across navigation.
        let cacheable = drawerTab != .candidates && suggestion == nil
        let resultsKey = ResultsKey(revision: revision, currentID: current.id, metric: metric, inspectPackages: options.inspectPackages, drawerTab: drawerTab, scope: scope, search: search, minimumGB: minimumGB, olderDays: olderDays, extensionFilter: extensionFilter, hiddenPaths: hiddenPaths, sortName: sortName, ascending: ascending)
        let cachedResults = cacheable ? resultsCache[resultsKey] : nil

        let resolvedSummary: SizeSummary; let resolvedRows: [FileNode]; let resolvedLegend: [FileCategory]
        let resolvedStatistics: [CategorySummary]; let resolvedScene: MapScene
        if let cached = cachedResults, let cachedScene {
            resolvedSummary = cached.summary; resolvedRows = cached.rows; resolvedLegend = cached.legend
            resolvedStatistics = cached.statistics; resolvedScene = cachedScene
        } else {
            // One actor call produces a consistent snapshot of every result shown.
            let snap = await index.explorerSnapshot(browser: browserQuery, stats: statsQuery, mapQuery: mapQuery, mapRootID: current.id, filtered: filtered, includeStatistics: drawerTab == .types, includeScene: cachedScene == nil)
            guard !Task.isCancelled, snap.revision == revision, generation == queryGeneration, self.index === index else { return }
            if let cached = cachedResults {
                resolvedSummary = cached.summary; resolvedRows = cached.rows; resolvedLegend = cached.legend
                resolvedStatistics = cached.statistics
            } else {
                resolvedSummary = snap.summary; resolvedRows = snap.rows; resolvedLegend = snap.legendCategories
                resolvedStatistics = snap.statistics
                if cacheable {
                    resultsCache[resultsKey] = CachedResults(summary: resolvedSummary, rows: resolvedRows, legend: resolvedLegend, statistics: resolvedStatistics)
                    resultsCacheOrder.removeAll { $0 == resultsKey }; resultsCacheOrder.append(resultsKey)
                    while resultsCacheOrder.count > 8 { resultsCache.removeValue(forKey: resultsCacheOrder.removeFirst()) }
                }
            }
            if let cachedScene {
                resolvedScene = cachedScene
            } else {
                resolvedScene = snap.scene
                if !filtered {
                    sceneCache[sceneKey] = snap.scene; sceneCacheOrder.removeAll { $0 == sceneKey }; sceneCacheOrder.append(sceneKey)
                    while sceneCacheOrder.count > 4 { sceneCache.removeValue(forKey: sceneCacheOrder.removeFirst()) }
                }
            }
        }
        let retainedSelection = selectedNodes
        rows = resolvedRows; scene = resolvedScene; totalRows = resolvedSummary.itemCount; categories = resolvedStatistics; legendCategories = resolvedLegend
        nodesByID = Dictionary(resolvedScene.entries.compactMap(\.node).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for n in resolvedRows + retainedSelection { nodesByID[n.id] = n }
        selectionIDs.formIntersection(nodesByID.keys); isLoading = false
    }

    func changePage(_ delta: Int) {
        guard let index else { return }
        let target = min(max(0, page + delta), pageCount - 1)
        guard target != page else { return }
        pageTask?.cancel()
        page = target
        let generation = queryGeneration
        var q = makeQuery(); q.offset = target * pageSize
        pageTask = Task {
            let revision = await index.revision
            let nodes = await index.query(q)
            let finalRevision = await index.revision
            guard !Task.isCancelled, finalRevision == revision, self.index === index, generation == queryGeneration, page == target else { return }
            let retainedSelection = selectedNodes
            rows = nodes
            nodesByID = Dictionary(scene.entries.compactMap(\.node).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for n in nodes + retainedSelection { nodesByID[n.id] = n }
            selectionIDs.formIntersection(nodesByID.keys)
        }
    }

    func waitForPage() async { await pageTask?.value }

    func select(_ id: Int64?) { selection = id }
    func select(_ entry: MapEntry, extending: Bool) {
        if entry.kind == .aggregate { openAggregate(entry); return }
        guard entry.node != nil else { return }
        if extending {
            if selectionIDs.contains(entry.id) { selectionIDs.remove(entry.id) } else { selectionIDs.insert(entry.id) }
        } else { selectionIDs = [entry.id] }
    }
    func openAggregate(_ entry: MapEntry) {
        guard let index else { return }
        if hasFilters { showFiles = true; return }
        Task {
            if let owner = await index.node(entry.ownerID), self.index === index {
                if owner.id != current?.id { navigate(owner) }
                showFiles = true
            }
        }
    }
    func clearFilters() {
        search = ""; suggestion = nil; minimumGB = 0; olderDays = 0; extensionFilter = ""
        scheduleRefresh()
    }
    func canNavigate(_ node: FileNode) -> Bool {
        node.isDirectory && !node.isSymbolicLink && (!node.isPackage || options.inspectPackages)
    }
    func navigate(_ node: FileNode, record: Bool = true) {
        guard canNavigate(node), node.id != current?.id else { return }
        if record, let current { back.append(current.id); forward = [] }
        current = node; selectionIDs = []; showDetails = false; highlightedCategory = nil
        search = ""; suggestion = nil; minimumGB = 0; olderDays = 0; extensionFilter = ""
        refreshTask?.cancel()
        refreshTask = Task { await loadRows(); await loadBreadcrumbs() }
    }
    func up() { if breadcrumbs.count > 1 { navigate(breadcrumbs[breadcrumbs.count - 2]) } }
    func history(_ backwards: Bool) {
        let id = backwards ? back.popLast() : forward.popLast()
        guard let id, let index else { return }
        if let current { if backwards { forward.append(current.id) } else { back.append(current.id) } }
        Task { if let node = await index.node(id), self.index === index { navigate(node, record: false) } }
    }
    private func loadBreadcrumbs() async {
        guard let index else { return }; let currentID = current?.id
        var chain: [FileNode] = []; var node = current
        while let n = node { chain.insert(n, at: 0); node = if let id = n.parentID { await index.node(id) } else { nil } }
        guard self.index === index, current?.id == currentID else { return }
        breadcrumbs = chain
    }
}

enum AnalysisTab: String, CaseIterable, Identifiable {
    case files = "Files", largest = "Largest", types = "Types", candidates = "Candidates"
    var id: Self { self }
}
