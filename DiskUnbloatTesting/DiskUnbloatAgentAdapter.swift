import AgentDevKitCore
import AgentDevKitHost
import AppKit
import Observation
import DiskCore

/// The bridge's view of the production workspace. Snapshots are bounded, explicit
/// fields read from the real view models; actions call the same intent methods the
/// views call. Nothing here re-implements a feature.
@MainActor final class DiskUnbloatAgentAdapter: AgentAdapter {
    let workspace: WorkspaceViewModel
    let composition: TestingComposition
    let runtime: AgentRuntime
    private var duplicateReviewSpan: UUID?

    init(workspace: WorkspaceViewModel, composition: TestingComposition, runtime: AgentRuntime) {
        self.workspace = workspace; self.composition = composition; self.runtime = runtime
    }

    // MARK: State

    func snapshot(scope: String) throws -> ScreenSnapshot {
        ScreenSnapshot(screenId: screenID, windowId: "main", ready: ready, fields: fields(), blockers: ready ? [] : [screenID + ".pending"])
    }

    private var screenID: String {
        switch workspace.phase {
        case .choosing: "chooser"
        case .scanning: "scanning"
        case .preparingResults: "preparing"
        case .exploring: "results"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
    private var ready: Bool { workspace.phase != .preparingResults && !(workspace.phase == .exploring && workspace.explorer.isLoading) }

    /// Every field an agent asserts on. Paths are reported relative to the fixture home.
    func fields() -> [String: JSONValue] {
        let scan = workspace.scan, explorer = workspace.explorer, cleanup = workspace.cleanup
        var fields: [String: JSONValue] = [
            "phase": .string(screenID),
            "stage": .string(scan.stage.rawValue),
            "scanning": .bool(scan.scanning),
            "items": .integer(Int64(scan.snapshot?.items ?? 0)),
            "folders": .integer(Int64(scan.snapshot?.folders ?? 0)),
            "discoveredBytes": .integer(scan.snapshot?.bytes ?? 0),
            "issueCount": .integer(Int64(scan.issues.count)),
            "fullDiskAccessOffer": .bool(workspace.showFullDiskAccessOffer),
            "protectedFoldersRefused": .bool(scan.protectedFoldersRefused),
            "sceneEntries": .integer(Int64(explorer.scene.entries.count)),
            "knownBytes": .integer(explorer.scene.summary.knownBytes),
            "mapLoading": .bool(explorer.isLoading),
            "selectionCount": .integer(Int64(explorer.selectionIDs.count)),
            "queueVisible": .bool(cleanup.showQueue),
            "queueCount": .integer(Int64(cleanup.basket.count)),
            "queueBytes": .integer(cleanup.estimatedBytes),
            "realHome": .bool(composition.usesRealHome),
            "colorMode": .string(explorer.colorMode.rawValue),
            "labelDetail": .string(explorer.labelDetail.rawValue),
            "legend": .array(explorer.legendClasses.map { .string($0.rawValue + "=" + String(explorer.classShares[$0] ?? 0)) }),
        ]
        if let highlighted = explorer.highlightedClass { fields["highlightedClass"] = .string(highlighted.rawValue) }
        fields["searchMode"] = .string(explorer.searchMode.rawValue)
        fields["search"] = .string(ScreenSnapshot.preview(explorer.search, maxBytes: 128))
        fields["matchCount"] = .integer(Int64(explorer.searchMatches.count))
        fields["litTiles"] = .integer(Int64(explorer.tileStyle.searchLit?.count ?? -1))
        fields["unreachedBytes"] = .integer(explorer.unreached?.bytes ?? 0)
        switch workspace.duplicates.state {
        case .idle: fields["duplicates"] = "idle"
        case .searching: fields["duplicates"] = "searching"
        case .failed: fields["duplicates"] = "failed"
        case .found(let search):
            fields["duplicates"] = "found"
            fields["duplicateSets"] = .integer(Int64(search.sets.count))
            fields["duplicateCopies"] = .integer(Int64(search.copyCount))
            fields["duplicateFolderSets"] = .integer(Int64(search.folderSets.count))
        }
        let duplicates = workspace.duplicates
        fields["duplicateReviewVisible"] = .bool(duplicates.visiblePresentationID != nil)
        fields["duplicateReviewFilter"] = .string(duplicates.filter.rawValue)
        fields["duplicateReviewVisibleGroups"] = .integer(Int64(duplicates.visibleGroups.count))
        fields["duplicateReviewSelected"] = .integer(Int64(duplicates.selectedCount))
        fields["duplicateReviewHiddenSelected"] = .integer(Int64(duplicates.hiddenSelectedCount))
        fields["duplicateReviewRefusals"] = .integer(Int64(duplicates.refusals.count))
        fields["duplicateReviewGroupIDs"] = .array(duplicates.visibleGroups.prefix(24).map { .integer($0.id) })
        if let group = duplicates.focusedGroup, duplicates.presentation != nil {
            fields["duplicateReviewGroup"] = .integer(group.id)
            fields["duplicateReviewKeeper"] = .integer(duplicates.keeper(in: group).id)
            fields["duplicateReviewCopyIDs"] = .array(group.copies.prefix(24).map { .integer($0.id) })
        }
        fields["diagnostics"] = .array(workspace.diagnostics.entries.suffix(12).map { .string(ScreenSnapshot.preview("[\($0.category)] \($0.message)", maxBytes: 200)) })
        fields["issueGroups"] = .array(workspace.scan.issueGroups.prefix(8).map { .string(ScreenSnapshot.preview($0.message, maxBytes: 80) + " ×\($0.paths.count)") })
        // Map vs queue consistency: every queued path must be absent from the scene, and
        // every scene path must not be queued.
        let queued = Set(cleanup.basket.map(\.node.path))
        let scenePaths = explorer.scene.entries.compactMap { $0.node?.path }
        fields["queuedVisibleOnMap"] = .array(scenePaths.filter { path in queued.contains { path.isWithin($0) } }.prefix(10).map { .string(relative($0)) })
        fields["hiddenPaths"] = .array(explorer.hiddenPaths.prefix(10).map { .string(relative($0)) })
        fields["sceneNames"] = .array(explorer.scene.entries.filter { $0.parentID == explorer.scene.rootID }.compactMap { $0.node?.name }.prefix(40).map { .string($0) })
        fields["tools"] = .array(workspace.developerTools.rows.map { .string($0.id) })
        fields["queuedSurvivors"] = .integer(Int64(cleanup.basket.filter { $0.survivor != nil }.count))
        fields["unreachedTile"] = .bool(explorer.scene.entries.contains { $0.kind == .unreached })
        if let path = scan.awaitingPermission { fields["awaitingPermission"] = .string(relative(path)) }
        if let current = explorer.current { fields["currentFolder"] = .string(relative(current.path)) }
        if let message = workspace.message { fields["message"] = .string(ScreenSnapshot.preview(message)) }
        if case .failed(let reason) = workspace.phase { fields["failure"] = .string(ScreenSnapshot.preview(reason)) }
        return fields
    }

    private func relative(_ path: String) -> String {
        let home = composition.home.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : (composition.usesRealHome ? URL(fileURLWithPath: path).lastPathComponent : path)
    }

    /// Re-records on every observed model change so `wait` conditions re-evaluate.
    func observeChanges() {
        let visibleReview = workspace.duplicates.visiblePresentationID
        if duplicateReviewSpan != visibleReview {
            if let previous = duplicateReviewSpan { runtime.end(id: previous, outcome: .completed) }
            if let visibleReview {
                runtime.begin(.screen, name: "duplicate-review", scope: "current-screen", id: visibleReview)
            }
            duplicateReviewSpan = visibleReview
        }
        withObservationTracking { _ = fields() } onChange: { [weak self] in
            Task { @MainActor in
                self?.runtime.record("workspace.changed", scope: "current-screen")
                self?.observeChanges()
            }
        }
    }

    /// The workspace window (largest visible, non-panel); sheets are composited onto it.
    func window(for windowId: String?) -> NSWindow? {
        NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: Fixtures

    func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue] {
        try await load(id)
    }

    /// Generates the fixture tree in the isolated home and scans it with the real
    /// coordinator. `permission-wait` returns while the simulated dialog is pending.
    @discardableResult
    func load(_ id: String) async throws -> [String: JSONValue] {
        guard FixtureTrees.all.contains(id) else { throw Failure(.fixtureNotFound, "Fixture is not registered.") }
        guard !composition.usesRealHome else { throw Failure(.notReady, "Fixtures need the generated home; relaunch without \(TestingComposition.realHomeFlag).") }
        if workspace.scan.scanning { workspace.cancel(); await workspace.waitForScan() }
        workspace.duplicates.cancel()
        await workspace.duplicates.waitForWork()
        do { try FixtureTrees.build(id, at: composition.home) }
        catch { throw Failure(.internalError, "The fixture tree could not be generated.") }
        if id == "permission-wait" { await composition.scanner.useBlockingPreflight(target: composition.home.appendingPathComponent("Desktop")) }
        else { await composition.scanner.useRealPreflight() }
        workspace.scan.pendingRoot = composition.home
        workspace.startScan()
        if id != "permission-wait" {
            await workspace.waitForScan()
            for _ in 0..<200 where workspace.phase != .exploring || workspace.explorer.isLoading { try? await Task.sleep(for: .milliseconds(25)) }
        }
        return ["fixture": .string(id), "phase": .string(screenID)]
    }

    // MARK: Catalog

    var catalog: AgentCatalog {
        AgentCatalog(
            scopes: ["current-screen"],
            fixtures: FixtureTrees.all,
            actions: actions,
            lifecycle: [
                .init(kind: .work, name: "scan"),
                .init(kind: .work, name: "duplicate-search"),
                .init(kind: .screen, name: "duplicate-review"),
            ],
            ui: .all
        )
    }

    private struct Empty: Decodable {}
    private struct Level: Decodable { let level: String }
    private struct Visible: Decodable { let visible: Bool }
    private struct Path: Decodable { let path: String }
    private struct Paths: Decodable { let paths: [String] }
    private struct PickProbe: Decodable { let path: String; let pick: Bool? }
    private struct Mode: Decodable { let mode: String; let highlight: String? }
    private struct LabelDetail: Decodable { let detail: MapLabelDetail }
    private struct Search: Decodable { let text: String; let mode: String? }
    private struct Unreached: Decodable { let megabytes: Int; let visible: Bool? }
    private struct Strategy: Decodable { let strategy: String? }
    private struct Panel: Decodable { let duplicates: Bool }
    private struct DuplicateFilter: Decodable { let kind: String?; let query: String?; let hideSupport: Bool? }
    private struct DuplicateGroup: Decodable { let group: Int64 }
    private struct DuplicateCopy: Decodable { let group: Int64; let copy: Int64; let checked: Bool? }

    private var actions: [AgentAction] {
        let workspace = workspace, composition = composition, runtime = runtime
        let duplicates = workspace.duplicates
        return [
            AgentAction("scan.home", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { !workspace.isBusy }) { _, _ in
                workspace.scan.pendingRoot = composition.home; workspace.startScan(); return .completed
            },
            // Bisection aid: scan one folder inside the home with the normal flow.
            AgentAction("scan.path", scope: "current-screen", input: ObjectSchema(["path": .string(maxLength: 1024)], required: ["path"]),
                        as: Path.self, enabled: { !workspace.isBusy }) { input, _ in
                let relative = String(input.path.drop(while: { $0 == "~" || $0 == "/" }))
                workspace.scan.pendingRoot = relative.isEmpty ? composition.home : composition.home.appendingPathComponent(relative)
                workspace.startScan(); return .completed
            },
            // TCC experiment probes, run inside this app so macOS attributes them to it.
            AgentAction("probe.list", scope: "current-screen", input: ObjectSchema(["path": .string(maxLength: 1024)], required: ["path"]),
                        as: Path.self) { input, _ in
                let path = composition.home.appendingPathComponent(String(input.path.drop(while: { $0 == "~" || $0 == "/" }))).path
                var names = 0
                if let dir = opendir(path) { while readdir(dir) != nil { names += 1 }; closedir(dir) }
                workspace.diagnostics.record("probe", "listed \(names) names in \(path)")
                return .completed
            },
            AgentAction("probe.stat", scope: "current-screen", input: ObjectSchema(["path": .string(maxLength: 1024)], required: ["path"]),
                        as: Path.self) { input, _ in
                let path = composition.home.appendingPathComponent(String(input.path.drop(while: { $0 == "~" || $0 == "/" }))).path
                var info = stat()
                let result = lstat(path, &info)
                workspace.diagnostics.record("probe", "lstat \(result) on \(path)")
                return .completed
            },
            // TCC experiment: how many children (and their Data folders) of a Library folder
            // can be opened, optionally after the user picks that folder in an open panel.
            AgentAction("probe.readable", scope: "current-screen",
                        input: ObjectSchema(["path": .string(maxLength: 1024), "pick": .boolean], required: ["path"]),
                        as: PickProbe.self) { input, _ in
                let url = composition.home.appendingPathComponent(String(input.path.drop(while: { $0 == "~" || $0 == "/" })))
                if input.pick == true {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
                    panel.directoryURL = url
                    panel.message = "Experiment: you are inside “\(url.lastPathComponent)”. Click Open without selecting anything."
                    panel.prompt = "Open"
                    let picked = panel.runModal() == .OK ? panel.url?.path ?? "none" : "cancelled"
                    workspace.diagnostics.record("probe", "picked \(picked)")
                }
                var total = 0, readable = 0, dataTotal = 0, dataReadable = 0
                let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                for name in names where !name.hasPrefix(".") {
                    let child = url.appendingPathComponent(name).path
                    total += 1
                    if let dir = opendir(child) { _ = readdir(dir); closedir(dir); readable += 1 }
                    let data = child + "/Data"
                    var info = stat()
                    if lstat(data, &info) == 0 {
                        dataTotal += 1
                        if let dir = opendir(data) { _ = readdir(dir); closedir(dir); dataReadable += 1 }
                    }
                }
                workspace.diagnostics.record("probe", "\(url.lastPathComponent): \(readable)/\(total) children open, \(dataReadable)/\(dataTotal) Data folders open")
                return .completed
            },
            AgentAction("scan.cancel", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { workspace.scan.scanning }) { _, _ in workspace.cancel(); return .completed },
            AgentAction("permission.release", scope: "current-screen", input: .empty, as: Empty.self) { _, _ in
                await composition.scanner.release(); return .completed
            },
            AgentAction("permission.skip", scope: "current-screen", input: .empty, as: Empty.self) { _, _ in
                await workspace.scan.skipPermissionRequests(); return .completed
            },
            AgentAction("queue.visible", scope: "current-screen", input: ObjectSchema(["visible": .boolean], required: ["visible"]),
                        as: Visible.self, enabled: { workspace.phase == .exploring }) { input, _ in
                workspace.cleanup.showQueue = input.visible; return .completed
            },
            AgentAction("explorer.navigate", scope: "current-screen", input: ObjectSchema(["path": .string(maxLength: 1024)], required: ["path"]),
                        as: Path.self, enabled: { workspace.phase == .exploring }) { input, _ in
                let path = input.path == "~" ? composition.home.path : composition.home.appendingPathComponent(String(input.path.drop(while: { $0 == "~" || $0 == "/" }))).path
                guard let node = await workspace.scan.index?.node(path: path) else { throw Failure(.invalidParams, "No scanned folder at that path.", details: ["field": "arguments.path"]) }
                workspace.explorer.navigate(node); return .completed
            },
            AgentAction("explorer.colorMode", scope: "current-screen",
                        input: ObjectSchema(["mode": .string(maxLength: 16, oneOf: MapColorMode.allCases.map(\.rawValue)),
                                             "highlight": .string(maxLength: 32, oneOf: TileClass.allCases.map(\.rawValue))], required: ["mode"]),
                        as: Mode.self, enabled: { workspace.phase == .exploring }) { input, _ in
                workspace.explorer.colorMode = MapColorMode(rawValue: input.mode) ?? .safety
                workspace.explorer.highlightedClass = input.highlight.flatMap(TileClass.init(rawValue:))
                return .completed
            },
            AgentAction("explorer.labelDetail", scope: "current-screen",
                        input: ObjectSchema(["detail": .string(maxLength: 16, oneOf: MapLabelDetail.allCases.map(\.rawValue))], required: ["detail"]),
                        as: LabelDetail.self, enabled: { workspace.phase == .exploring }) { input, _ in
                workspace.explorer.setLabelDetail(input.detail)
                return .completed
            },
            AgentAction("explorer.search", scope: "current-screen",
                        input: ObjectSchema(["text": .string(maxLength: 128), "mode": .string(maxLength: 16, oneOf: SearchMode.allCases.map(\.rawValue))], required: ["text"]),
                        as: Search.self, enabled: { workspace.phase == .exploring }) { input, _ in
                if let mode = input.mode.flatMap(SearchMode.init(rawValue:)) { workspace.explorer.searchMode = mode }
                workspace.explorer.search = input.text
                await workspace.explorer.loadResults()
                return .completed
            },
            // Fixture homes are not volume roots; this feeds the same entry point a volume
            // scan uses so the tile can be inspected without scanning a whole disk.
            AgentAction("unreached.set", scope: "current-screen",
                        input: ObjectSchema(["megabytes": .integer(minimum: 0, maximum: 10_000_000), "visible": .boolean], required: ["megabytes"]),
                        as: Unreached.self, enabled: { workspace.phase == .exploring }) { input, _ in
                if let visible = input.visible { workspace.explorer.showUnreached = visible }
                workspace.explorer.setUnreached(input.megabytes == 0 ? nil : UnreachedSpace(bytes: Int64(input.megabytes) << 20, purgeable: 3 << 20, localSnapshots: 2, unreadableLocations: 4))
                await workspace.explorer.loadResults()
                return .completed
            },
            AgentAction("duplicates.find", scope: "current-screen",
                        input: ObjectSchema(["strategy": .string(maxLength: 16, oneOf: DuplicateKeepStrategy.allCases.map(\.rawValue))]),
                        as: Strategy.self, enabled: { workspace.canClean && !duplicates.searching && duplicates.presentation == nil }) { input, command in
                if let strategy = input.strategy.flatMap(DuplicateKeepStrategy.init(rawValue:)) { duplicates.strategy = strategy }
                duplicates.find()
                guard duplicates.searching else { throw Failure(.notReady, "Duplicate search is unavailable.") }
                let id = UUID()
                runtime.begin(.work, name: "duplicate-search", scope: "current-screen", id: id, correlationId: command.requestId)
                Task {
                    await duplicates.waitForWork()
                    let outcome: LifecycleEvent.Outcome
                    switch duplicates.state {
                    case .found: outcome = .completed
                    case .failed: outcome = .failed
                    default: outcome = .cancelled
                    }
                    runtime.end(id: id, outcome: outcome)
                }
                return .accepted(operationId: id)
            },
            AgentAction("duplicates.review.filter", scope: "current-screen", input: ObjectSchema([
                "kind": .string(maxLength: 12, oneOf: DuplicateReviewFilter.allCases.map(\.rawValue)),
                "query": .string(maxLength: 256), "hideSupport": .boolean,
            ]), as: DuplicateFilter.self, enabled: { duplicates.presentation != nil && !duplicates.confirming }) { input, _ in
                if let filter = input.kind.flatMap(DuplicateReviewFilter.init(rawValue:)) { duplicates.filter = filter }
                if let query = input.query { duplicates.query = query }
                if let hideSupport = input.hideSupport { duplicates.hideSupport = hideSupport }
                return .completed
            },
            AgentAction("duplicates.review.focus", scope: "current-screen",
                        input: ObjectSchema(["group": .integer(minimum: 1)], required: ["group"]),
                        as: DuplicateGroup.self, enabled: { duplicates.presentation != nil && !duplicates.confirming }) { input, _ in
                guard let group = duplicates.groups.first(where: { $0.id == input.group }) else {
                    throw Failure(.notReady, "Duplicate group is unavailable.")
                }
                duplicates.focus(group)
                return .completed
            },
            AgentAction("duplicates.review.check", scope: "current-screen",
                        input: ObjectSchema(["group": .integer(minimum: 1), "copy": .integer(minimum: 1), "checked": .boolean],
                                            required: ["group", "copy", "checked"]),
                        as: DuplicateCopy.self, enabled: { duplicates.presentation != nil && !duplicates.confirming }) { input, _ in
                guard let group = duplicates.visibleGroups.first(where: { $0.id == input.group }),
                      let copy = group.copies.first(where: { $0.id == input.copy }), let checked = input.checked else {
                    throw Failure(.notReady, "Duplicate copy is unavailable.")
                }
                duplicates.setChecked(checked, node: copy, in: group)
                return .completed
            },
            AgentAction("duplicates.review.keeper", scope: "current-screen",
                        input: ObjectSchema(["group": .integer(minimum: 1), "copy": .integer(minimum: 1)], required: ["group", "copy"]),
                        as: DuplicateCopy.self, enabled: { duplicates.presentation != nil && !duplicates.confirming }) { input, _ in
                guard let group = duplicates.visibleGroups.first(where: { $0.id == input.group }),
                      let copy = group.copies.first(where: { $0.id == input.copy }) else {
                    throw Failure(.notReady, "Duplicate copy is unavailable.")
                }
                duplicates.chooseKeeper(copy, in: group)
                return .completed
            },
            AgentAction("duplicates.review.selectVisible", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { duplicates.presentation != nil && !duplicates.confirming }) { _, _ in
                duplicates.selectVisible(); return .completed
            },
            AgentAction("duplicates.review.confirm", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { duplicates.canConfirm }) { _, _ in
                duplicates.confirm()
                await duplicates.waitForWork()
                return .completed
            },
            AgentAction("duplicates.review.cancel", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { duplicates.presentation != nil && !duplicates.confirming }) { _, _ in
                duplicates.dismissReview(); return .completed
            },
            // The panel's choice is the same stored preference its menu writes.
            AgentAction("quickSelect.panel", scope: "current-screen", input: ObjectSchema(["duplicates": .boolean], required: ["duplicates"]),
                        as: Panel.self) { input, _ in
                UserDefaults.standard.set(input.duplicates, forKey: "quickSelectDuplicates"); return .completed
            },
            AgentAction("tools.open", scope: "current-screen", input: .empty, as: Empty.self) { _, _ in
                await workspace.developerTools.open(); return .completed
            },
            AgentAction("issues.show", scope: "current-screen", input: .empty, as: Empty.self) { _, _ in
                workspace.scan.showIssues = true; return .completed
            },
            AgentAction("message.dismiss", scope: "current-screen", input: .empty, as: Empty.self) { _, _ in
                workspace.message = nil; return .completed
            },
            // The panel checkbox's own intents (checked → deselect, otherwise select).
            AgentAction("queue.toggle", scope: "current-screen", input: ObjectSchema(["paths": .array(.string(maxLength: 1024), maxItems: 16)], required: ["paths"]),
                        as: Paths.self, enabled: { workspace.phase == .exploring }) { input, _ in
                for raw in input.paths {
                    let path = raw == "~" ? composition.home.path : composition.home.appendingPathComponent(String(raw.drop(while: { $0 == "~" || $0 == "/" }))).path
                    guard let node = await workspace.scan.index?.node(path: path) else { continue }
                    if workspace.cleanup.membership(node) == .selected || workspace.cleanup.membership(node) == .insideSelection {
                        workspace.deselect(node)
                    } else {
                        workspace.addToBasket(node)
                    }
                }
                return .completed
            },
            AgentAction("quickSelect.apply", scope: "current-screen",
                        input: ObjectSchema(["level": .string(maxLength: 16, oneOf: AutoSelectionLevel.allCases.map(\.agentName))], required: ["level"]),
                        as: Level.self, enabled: { workspace.phase == .exploring }) { input, _ in
                guard let level = AutoSelectionLevel.allCases.first(where: { $0.agentName == input.level }) else { throw Failure(.invalidParams, "Unknown level.") }
                workspace.selectItems(level); return .completed
            },
        ]
    }
}

extension AutoSelectionLevel {
    var agentName: String { String(describing: self) }
}
