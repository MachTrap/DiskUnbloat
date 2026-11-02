import Foundation
import CoreGraphics
import Observation
import DiskCore

enum ExplorerScope: String, CaseIterable, Identifiable {
    case current = "Current folder", entireScan = "Entire scan"
    var id: Self { self }
}

@MainActor @Observable final class ExplorerViewModel {
    private let settings: SettingsViewModel
    private let activity: any ApplicationActivityProviding
    let homePath: String?
    @ObservationIgnored private var index: ScanIndex?
    /// Grouped scans put several locations under one synthetic root; filter scope then
    /// spans the union of all listed locations instead of one path prefix.
    @ObservationIgnored private var groupScan = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var nodesByID: [Int64: FileNode] = [:]
    @ObservationIgnored private var sceneCache: [String: MapScene] = [:]
    @ObservationIgnored private var sceneCacheOrder: [String] = []
    private var queryGeneration = 0
    private var options = ScanOptions()
    private let cacheRootPath: String?
    private var catalog: LocationCatalog?
    private(set) var legendCategories: [FileCategory] = []
    var scene = MapScene()
    var selectionIDs: Set<Int64> = []
    var selection: Int64? {
        get { selectionIDs.count == 1 ? selectionIDs.first : nil }
        set { selectionIDs = newValue.map { [$0] } ?? [] }
    }
    var selected: FileNode? { selection.flatMap { nodesByID[$0] } }
    var selectedNodes: [FileNode] { selectionIDs.compactMap { nodesByID[$0] } }
    var normalizedSelection: [FileNode] {
        CleanupPlan(root: URL(fileURLWithPath: "/"), items: selectedNodes, mode: .trash).items.map(\.node)
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
    var fitRevision = 0
    var searchRequested = 0
    var isLoading = false
    /// Paths queued for deletion; they disappear from the map until removed.
    private(set) var hiddenPaths: [String] = []
    /// Fully queued containers: their descendants hide while the folder itself stays.
    private(set) var hiddenSubtrees: [String] = []
    /// Raw queue paths as handed in, before hidden-range pruning and collapse.
    @ObservationIgnored private var queuedPaths: [String] = []
    @ObservationIgnored private var hiddenGeneration = 0
    var hasFilters: Bool { !search.isEmpty || suggestion != nil || minimumGB > 0 || olderDays > 0 || !extensionFilter.isEmpty }
    var availableCategories: [FileCategory] {
        let present = Set(legendCategories)
        return FileCategory.allCases.filter { present.contains($0) }
    }

    init(settings: SettingsViewModel, userCacheRoot: URL? = nil, activity: any ApplicationActivityProviding = ApplicationActivityService()) {
        self.settings = settings; self.activity = activity; cacheRootPath = userCacheRoot?.path
        homePath = userCacheRoot?.deletingLastPathComponent().deletingLastPathComponent().path
    }

    func reset() {
        refreshTask?.cancel(); queryGeneration += 1; index = nil; nodesByID = [:]
        sceneCache = [:]; sceneCacheOrder = []
        legendCategories = []; scene = MapScene(); current = nil; selectionIDs = []
        breadcrumbs = []; back = []; forward = []; suggestion = nil; highlightedCategory = nil
        search = ""; minimumGB = 0; olderDays = 0; extensionFilter = ""; scope = .current
        hiddenPaths = []; hiddenSubtrees = []; queuedPaths = []; hiddenGeneration += 1
        isLoading = false
    }

    /// Hides queued deletion items everywhere the explorer queries, and drops their selections.
    /// Subsumed entries collapse immediately; complete-container collapses (which need
    /// child counts) land right after, absorbed by the query debounce.
    func updateHiddenPaths(_ paths: [String]) {
        guard paths != queuedPaths else { return }
        queuedPaths = paths
        selectionIDs = selectionIDs.filter { id in
            guard let node = nodesByID[id] else { return true }
            return !paths.contains { node.path.isWithin($0) }
        }
        hiddenGeneration += 1
        let generation = hiddenGeneration
        applyHidden(HiddenRanges(paths: HiddenRanges.pruneSubsumed(paths), subtrees: []))
        guard let index else { return }
        Task {
            let ranges = await index.coalescedHiddenRanges(for: paths)
            guard generation == hiddenGeneration else { return }
            applyHidden(ranges)
        }
    }

    private func applyHidden(_ ranges: HiddenRanges) {
        guard ranges.paths != hiddenPaths || ranges.subtrees != hiddenSubtrees else { return }
        hiddenPaths = ranges.paths
        hiddenSubtrees = ranges.subtrees
        sceneCache = [:]; sceneCacheOrder = []
        scheduleRefresh()
    }

    func attach(_ index: ScanIndex, options: ScanOptions, grouped: Bool = false) async {
        self.index = index; self.options = options; groupScan = grouped
        let root = await index.node(1)
        guard self.index === index else { return }
        current = root
        await loadResults(); await loadBreadcrumbs()
    }

    func suspendQueries() { refreshTask?.cancel(); queryGeneration += 1 }

    func restoreAfterRefresh() async {
        guard let index else { return }
        sceneCache = [:]; sceneCacheOrder = []
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
        await loadResults(); await loadBreadcrumbs()
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            await loadResults()
        }
    }

    /// Snapshot the query-relevant state. Running-application cache exclusions are resolved
    /// here (main actor) so `ExplorerQueries` stays a plain value type.
    private func makeQueries() -> ExplorerQueries {
        ExplorerQueries(
            current: current, metric: metric, options: options, scope: scope,
            suggestion: suggestion, hiddenPaths: hiddenPaths, hiddenSubtrees: hiddenSubtrees,
            activityExclusions: suggestion != nil ? (homePath.map { activity.blockedCachePaths(home: $0) } ?? []) : [],
            search: search, minimumGB: minimumGB,
            olderDays: olderDays, extensionFilter: extensionFilter,
            cacheRootPath: cacheRootPath, homePath: homePath, cacheAgeDays: settings.cacheAgeDays,
            ageDays: settings.ageDays, largeGB: settings.largeGB, groupScan: groupScan
        )
    }

    func loadResults() async {
        guard let index, let current else { return }
        queryGeneration += 1; let generation = queryGeneration
        isLoading = true
        let revision = await index.revision
        let queries = makeQueries()
        let filtered = queries.hasFilters
        let sceneKey = "\(revision):\(current.id):\(metric.rawValue):\(options.inspectPackages)"
        let resolvedScene: MapScene
        let resolvedLegend: [FileCategory]
        if let cachedScene = filtered ? nil : sceneCache[sceneKey] {
            resolvedScene = cachedScene
            resolvedLegend = await index.categoryList(queries.legendQuery())
        } else {
            // One actor call produces a consistent map and legend for the same revision.
            let snap = await index.mapSnapshot(
                rootID: current.id, mapQuery: queries.sceneQuery(),
                legendQuery: queries.legendQuery(), filtered: filtered)
            guard !Task.isCancelled, snap.revision == revision, generation == queryGeneration, self.index === index else { return }
            resolvedScene = snap.scene
            resolvedLegend = snap.legendCategories
            if !filtered {
                sceneCache[sceneKey] = snap.scene; sceneCacheOrder.removeAll { $0 == sceneKey }; sceneCacheOrder.append(sceneKey)
                while sceneCacheOrder.count > 4 { sceneCache.removeValue(forKey: sceneCacheOrder.removeFirst()) }
            }
        }
        let retainedSelection = selectedNodes
        scene = resolvedScene; legendCategories = resolvedLegend
        nodesByID = Dictionary(resolvedScene.entries.compactMap(\.node).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for n in retainedSelection { nodesByID[n.id] = n }
        selectionIDs.formIntersection(nodesByID.keys); isLoading = false
    }

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
        Task {
            if let owner = await index.node(entry.ownerID), self.index === index, owner.id != current?.id {
                navigate(owner)
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
        current = node; selectionIDs = []; highlightedCategory = nil
        search = ""; suggestion = nil; minimumGB = 0; olderDays = 0; extensionFilter = ""
        refreshTask?.cancel()
        refreshTask = Task { await loadResults(); await loadBreadcrumbs() }
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

    /// Curated description for a node, shown in the map hover card. Nothing is invented:
    /// nodes outside curated locations have no description.
    func description(for node: FileNode) -> String? {
        guard let homePath else { return nil }
        if catalog == nil { catalog = LocationCatalog(home: URL(fileURLWithPath: homePath)) }
        return catalog?.knownLocation(for: node.path)?.explanation
    }
}
