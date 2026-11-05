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
            "legend": .array(explorer.legendClasses.map { .string($0.rawValue + "=" + String(explorer.classShares[$0] ?? 0)) }),
        ]
        if let highlighted = explorer.highlightedClass { fields["highlightedClass"] = .string(highlighted.rawValue) }
        fields["searchMode"] = .string(explorer.searchMode.rawValue)
        fields["search"] = .string(ScreenSnapshot.preview(explorer.search, maxBytes: 128))
        fields["matchCount"] = .integer(Int64(explorer.searchMatches.count))
        fields["litTiles"] = .integer(Int64(explorer.tileStyle.searchLit?.count ?? -1))
        fields["unreachedBytes"] = .integer(explorer.unreached?.bytes ?? 0)
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
        withObservationTracking { _ = fields() } onChange: { [weak self] in
            Task { @MainActor in
                self?.runtime.record("workspace.changed", scope: "current-screen")
                self?.observeChanges()
            }
        }
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
            lifecycle: [.init(kind: .work, name: "scan")],
            ui: .all
        )
    }

    private struct Empty: Decodable {}
    private struct Level: Decodable { let level: String }
    private struct Visible: Decodable { let visible: Bool }
    private struct Path: Decodable { let path: String }
    private struct Mode: Decodable { let mode: String; let highlight: String? }
    private struct Search: Decodable { let text: String; let mode: String? }
    private struct Unreached: Decodable { let megabytes: Int; let visible: Bool? }

    private var actions: [AgentAction] {
        let workspace = workspace, composition = composition
        return [
            AgentAction("scan.home", scope: "current-screen", input: .empty, as: Empty.self,
                        enabled: { !workspace.isBusy }) { _, _ in
                workspace.scan.pendingRoot = composition.home; workspace.startScan(); return .completed
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
