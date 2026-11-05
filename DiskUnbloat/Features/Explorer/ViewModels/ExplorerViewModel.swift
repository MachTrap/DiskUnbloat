import Foundation
import CoreGraphics
import Observation
import DiskCore

enum ExplorerScope: String, CaseIterable, Identifiable {
    case current = "Current folder", entireScan = "Entire scan"
    var id: Self { self }
}

@MainActor @Observable final class ExplorerViewModel {
    private var me: String { ObjectIdentifier(self).hashValue != 0 ? String(ObjectIdentifier(self).hashValue) : "" }
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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var roots: [URL] = []
    @ObservationIgnored private var exemptCacheRoots: [String] = []
    @ObservationIgnored private var safety = SafetyClassification.empty
    /// What tile colour means; persisted. Restyles only, never re-queries.
    var colorMode: MapColorMode = .safety {
        didSet { defaults.set(colorMode.rawValue, forKey: "mapColorMode"); if colorMode != oldValue { highlightedClass = nil; recolor() } }
    }
    /// Legend highlight: dims every other class. Independent of layout and filters.
    var highlightedClass: TileClass? { didSet { tileStyle.highlighted = highlightedClass } }
    private(set) var tileStyle = MapTileStyle()
    /// Filter (classic) or highlight search; persisted.
    var searchMode: SearchMode = .filter {
        didSet { defaults.set(searchMode.rawValue, forKey: "searchMode"); if searchMode != oldValue, !search.isEmpty { scheduleRefresh() } }
    }
    /// Highlight-search matches in scope (largest first), capped at `matchLimit`.
    private(set) var searchMatches: [FileNode] = []
    private(set) var matchesTruncated = false
    @ObservationIgnored private var searchHighlight: SearchHighlight?
    @ObservationIgnored private var matchCursor = -1
    static let matchLimit = 5000
    /// The map's current layout, handed up by the treemap for keyboard movement. Not
    /// observed: it never drives rendering.
    @ObservationIgnored var layoutTiles: [SceneTile] = []

    /// Arrow keys: select the nearest tile in that direction (siblings first).
    func moveSelection(_ direction: MapDirection) {
        let current = selection.flatMap { id in layoutTiles.first { $0.id == id } }
        guard let next = MapKeyboardNavigator.next(from: current, in: layoutTiles, direction: direction) else { return }
        select(next.entry, extending: false)
    }

    /// Earlier scans of this scope (newest first) and the one Growth compares with.
    private(set) var historyDates: [Date] = []
    var compareDate: Date? { didSet { if compareDate != oldValue { loadBaseline() } } }
    @ObservationIgnored private var historyLoader: (Date) -> ScanHistorySnapshot? = { _ in nil }
    @ObservationIgnored private(set) var growthBaseline: ScanHistorySnapshot?

    func setHistory(dates: [Date], loader: @escaping (Date) -> ScanHistorySnapshot?) {
        historyLoader = loader; historyDates = dates
        compareDate = dates.first
        loadBaseline()
    }

    private func loadBaseline() {
        growthBaseline = compareDate.flatMap(historyLoader)
        recolor()
    }

    /// Hover text for Growth: the change against the compared scan.
    func growthNote(for entry: MapEntry) -> String? {
        guard colorMode == .growth, let baseline = growthBaseline, let node = entry.node else { return nil }
        let date = baseline.date.formatted(date: .abbreviated, time: .omitted)
        guard let previous = baseline.previousBytes(of: node.path, current: entry.bytes) else { return L10n.format("New since %@", date) }
        let delta = entry.bytes - previous
        if delta == 0 { return L10n.format("Unchanged since %@", date) }
        return L10n.format("%@ since %@", (delta > 0 ? "+" : "−") + sizeText(abs(delta)), date)
    }

    /// Space a volume scan could not reach; shown as its own tile at the scan root.
    private(set) var unreached: UnreachedSpace?
    var showUnreached = true {
        didSet { defaults.set(showUnreached, forKey: "showUnreached"); if showUnreached != oldValue, unreached != nil { scheduleRefresh() } }
    }
    var highlightSearchActive: Bool { searchMode == .highlight && !search.isEmpty }
    /// Leaf-tile bytes per class in the current scene, for the legend.
    private(set) var classShares: [TileClass: Int64] = [:]
    var legendClasses: [TileClass] { colorMode.classes.filter { (classShares[$0] ?? 0) > 0 } }
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
    var hasFilters: Bool { (searchMode == .filter && !search.isEmpty) || suggestion != nil || minimumGB > 0 || olderDays > 0 || !extensionFilter.isEmpty }
    init(settings: SettingsViewModel, userCacheRoot: URL? = nil, activity: any ApplicationActivityProviding = ApplicationActivityService(), defaults: UserDefaults = .standard) {
        self.settings = settings; self.activity = activity; self.defaults = defaults; cacheRootPath = userCacheRoot?.path
        colorMode = defaults.string(forKey: "mapColorMode").flatMap(MapColorMode.init(rawValue:)) ?? .safety
        searchMode = defaults.string(forKey: "searchMode").flatMap(SearchMode.init(rawValue:)) ?? .filter
        showUnreached = defaults.object(forKey: "showUnreached") as? Bool ?? true
        homePath = userCacheRoot?.deletingLastPathComponent().deletingLastPathComponent().path
    }

    func reset() {
        refreshTask?.cancel(); queryGeneration += 1; index = nil; nodesByID = [:]
        sceneCache = [:]; sceneCacheOrder = []
        scene = MapScene(); current = nil; selectionIDs = []
        safety = .empty; roots = []; tileStyle = MapTileStyle(); classShares = [:]; unreached = nil
        historyDates = []; growthBaseline = nil; historyLoader = { _ in nil }
        breadcrumbs = []; back = []; forward = []; suggestion = nil; highlightedClass = nil
        search = ""; minimumGB = 0; olderDays = 0; extensionFilter = ""; scope = .current
        hiddenPaths = []; hiddenSubtrees = []; queuedPaths = []; hiddenGeneration += 1
        isLoading = false
    }

    /// Hides queued deletion items everywhere the explorer queries, and drops their selections.
    /// Subsumed entries collapse immediately; complete-container collapses (which need
    /// child counts) land right after. The scene reloads for each state synchronously:
    /// a queued-path change is infrequent, and the debounced path can be cancelled by
    /// unrelated activity, which once left a stale map with no way back.
    func updateHiddenPaths(_ paths: [String]) async {
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
        // The precise ranges need child counts over the index; the pruned list above may
        // still hide every descendant of a fully queued container until they land.
        let ranges = await index.coalescedHiddenRanges(for: paths)
        guard generation == hiddenGeneration else { return }
        applyHidden(ranges)
        await loadResults()
    }

    /// State change only: the caller owns the reload (the debounced query can be
    /// cancelled by unrelated activity, which once left a stale map with no way back).
    private func applyHidden(_ ranges: HiddenRanges) {
        guard ranges.paths != hiddenPaths || ranges.subtrees != hiddenSubtrees else { return }
        hiddenPaths = ranges.paths
        hiddenSubtrees = ranges.subtrees
        sceneCache = [:]; sceneCacheOrder = []
    }

    func attach(_ index: ScanIndex, options: ScanOptions, grouped: Bool = false, roots: [URL] = []) async {
        self.index = index; self.options = options; groupScan = grouped
        self.roots = roots
        exemptCacheRoots = homePath.map { CleanupRule.knownCacheRoots(home: $0) } ?? []
        let root = await index.node(1)
        guard self.index === index else { return }
        current = root
        await loadResults(); await loadBreadcrumbs()
        await loadSafety()
    }

    /// The safety classes come from the same one-pass quick-select evaluation as the
    /// level picker, so map colours and selections always agree.
    func loadSafety() async {
        guard let index, let homePath else { return }
        let classification = await index.safetyClassification(home: homePath, unusedDays: options.longUnusedDays, inspectPackages: options.inspectPackages)
        guard self.index === index else { return }
        safety = classification
        recolor()
    }

    private func recolor() {
        var coloring = MapColoring(mode: colorMode, safety: safety, roots: roots, exemptCacheRoots: exemptCacheRoots)
        if let baseline = growthBaseline { coloring.growth = { path, bytes in baseline.previousBytes(of: path, current: bytes) } }
        let result = coloring.classify(scene)
        tileStyle = MapTileStyle(classes: result.classes, highlighted: highlightedClass, searchLit: searchLit(), mode: colorMode)
        classShares = result.shares
    }

    func suspendQueries() {
        refreshTask?.cancel(); queryGeneration += 1 }

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
        await loadSafety()
    }

    /// Waits for the pending navigation or debounced refresh to commit (tests, agent bridge).
    func settle() async { await refreshTask?.value }

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
        return ExplorerQueries(
            current: current, metric: metric, options: options, scope: scope,
            suggestion: suggestion, hiddenPaths: hiddenPaths, hiddenSubtrees: hiddenSubtrees,
            activityExclusions: suggestion != nil ? (homePath.map { activity.blockedCachePaths(home: $0) } ?? []) : [],
            search: searchMode == .filter ? search : "", minimumGB: minimumGB,
            olderDays: olderDays, extensionFilter: extensionFilter,
            cacheRootPath: cacheRootPath, homePath: homePath, cacheAgeDays: settings.cacheAgeDays,
            ageDays: settings.ageDays, largeGB: settings.largeGB, groupScan: groupScan
        )
    }

    func setUnreached(_ value: UnreachedSpace?) {
        unreached = value
        Task { await loadResults() }
    }

    /// The unreached tile sits beside the root's children, only on the unfiltered root
    /// view in on-disk size (the volume's used space is an on-disk measure).
    private func withUnreached(_ scene: MapScene, filtered: Bool) -> MapScene {
        guard let unreached, showUnreached, !filtered, metric == .allocated, unreached.bytes > 0,
              scene.rootID == 1, current?.id == 1 else { return scene }
        let entry = MapEntry(id: MapEntry.unreachedID, parentID: scene.rootID, ownerID: scene.rootID, kind: .unreached, node: nil, bytes: unreached.bytes)
        return MapScene(rootID: scene.rootID, entries: scene.entries + [entry], summary: scene.summary)
    }

    private func searchLit() -> Set<Int64>? {
        guard let searchHighlight else { return nil }
        return Set(scene.entries.compactMap { entry in entry.node.flatMap { searchHighlight.lights($0.path) ? entry.id : nil } })
    }

    /// Highlight search: matching names anywhere in scope (folders included), without
    /// filtering the scene. Capped, and the cap is reported, never hidden.
    private func loadSearchMatches(index: ScanIndex, queries: ExplorerQueries) async {
        guard highlightSearchActive else {
            searchMatches = []; matchesTruncated = false; searchHighlight = nil; matchCursor = -1; return
        }
        var q = FileQuery()
        q.search = search; q.inspectPackages = options.inspectPackages; q.metric = metric
        q.subtreePath = queries.subtreeScope(); q.hiddenPaths = hiddenPaths; q.hiddenSubtrees = hiddenSubtrees
        q.limit = Self.matchLimit + 1
        let found = await index.query(q)
        guard self.index === index else { return }
        matchesTruncated = found.count > Self.matchLimit
        searchMatches = Array(found.prefix(Self.matchLimit))
        searchHighlight = SearchHighlight(paths: searchMatches.map(\.path))
        matchCursor = -1
    }

    /// Return in the search field: open the next match's folder and select it.
    func stepToNextMatch() {
        guard highlightSearchActive, !searchMatches.isEmpty, let index else { return }
        matchCursor = (matchCursor + 1) % searchMatches.count
        let match = searchMatches[matchCursor]
        let cursor = matchCursor
        Task {
            guard let parentID = match.parentID, let parent = await index.node(parentID), self.index === index, cursor == matchCursor else { return }
            if parent.id != current?.id { navigate(parent) }
            nodesByID[match.id] = match
            selectionIDs = [match.id]
        }
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
        if let cachedScene = filtered ? nil : sceneCache[sceneKey] {
            resolvedScene = cachedScene
        } else {
            // One actor call produces a consistent map and legend for the same revision.
            let snap = await index.mapSnapshot(
                rootID: current.id, mapQuery: queries.sceneQuery(),
                legendQuery: queries.legendQuery(), filtered: filtered)
            // Task cancellation never invalidates this computation on its own: a newer
            // query generation owns fresher state, and an equal generation with the same
            // index means the result is exactly what was asked for — commit it, or a
            // cancelled-but-current load silently leaves the previous map in place.
            guard snap.revision == revision, generation == queryGeneration, self.index === index else { return }
            resolvedScene = snap.scene
            if !filtered {
                sceneCache[sceneKey] = snap.scene; sceneCacheOrder.removeAll { $0 == sceneKey }; sceneCacheOrder.append(sceneKey)
                while sceneCacheOrder.count > 4 { sceneCache.removeValue(forKey: sceneCacheOrder.removeFirst()) }
            }
        }
        let retainedSelection = selectedNodes
        scene = withUnreached(resolvedScene, filtered: filtered)
        await loadSearchMatches(index: index, queries: queries)
        guard generation == queryGeneration else { return }
        recolor()
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
        node.isBrowsable(inspectPackages: options.inspectPackages)
    }
    func navigate(_ node: FileNode, record: Bool = true) {
        guard canNavigate(node), node.id != current?.id else { return }
        if record, let current { back.append(current.id); forward = [] }
        current = node; selectionIDs = []
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
