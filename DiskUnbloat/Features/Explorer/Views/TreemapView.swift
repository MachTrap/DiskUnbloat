import SwiftUI
import AppKit
import DiskCore

struct TreemapView: View {
    let scene: MapScene
    let selection: Set<Int64>
    let style: MapTileStyle
    /// Breakdown for the unreached-space tile's hover card.
    var unreached: UnreachedSpace?
    var growthNote: (MapEntry) -> String? = { _ in nil }
    let fitRevision: Int
    let select: (MapEntry, Bool) -> Void
    let open: (FileNode) -> Void
    let aggregate: (MapEntry) -> Void
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    /// Cleanup-queue intent: select adds the node (scan roots clean contents in place),
    /// deselect removes the queue entries covering it.
    let selectForCleanup: (FileNode) -> Void
    let deselectFromCleanup: (FileNode) -> Void
    let queuedPaths: [String]
    let canClean: Bool
    /// Fast queue membership via the queue model's rebuild-per-change index.
    var membership: (FileNode) -> QueueMembership = { _ in .none }
    /// Curated description for the hover card, when the node has one.
    var description: (FileNode) -> String? = { _ in nil }
    var refreshFolder: (FileNode) -> Void = { _ in }
    var parent: () -> Void = {}
    var history: (Bool) -> Void = { _ in }
    @State private var tiles: [SceneTile] = []
    @State private var hovered: SceneTile?
    /// Snapshot of the outgoing map during focus navigation, animated from the full
    /// view toward `snapshotTarget` while it fades.
    @State private var snapshot: CGImage?
    @State private var snapshotFrame = CGRect.zero
    @State private var snapshotOpacity = 0.0
    @State private var morph: MapMorph?
    @State private var morphStart = Date()
    @State private var ping: CGRect?
    @State private var pingToken = 0
    @State private var previousRoot: Int64?
    @State private var previousSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let morph {
                        MorphingMapDrawing(morph: morph, start: morphStart, style: style)
                    } else {
                        // Legend highlighting crossfades instead of snapping; geometry is unaffected.
                        MapDrawing(tiles: tiles, style: style).equatable().id(style.crossfadeKey)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: style.crossfadeKey)
                Canvas { context, _ in
                    for tile in tiles where selection.contains(tile.id) {
                        let path = Path(roundedRect: tile.rect, cornerRadius: tile.isContainer ? 7 : 5)
                        context.stroke(path, with: .color(.primary), lineWidth: 2.5)
                    }
                }.allowsHitTesting(false)
                MapMotionOverlay(hovered: morph == nil ? hovered : nil, ping: ping, pingToken: pingToken)
                if let snapshot {
                    Color.clear.overlay(alignment: .topLeading) {
                        Image(decorative: snapshot, scale: displayScale).resizable()
                            .frame(width: snapshotFrame.width, height: snapshotFrame.height)
                            .offset(x: snapshotFrame.minX, y: snapshotFrame.minY)
                            .opacity(snapshotOpacity)
                    }.allowsHitTesting(false)
                }
                if tiles.isEmpty {
                    ContentUnavailableView("No sized items", systemImage: "square.dashed", description: Text(scene.summary.unknownCount > 0 ? "Some sizes are unknown. Adjust filters or navigate the map to inspect the scan." : "This folder is empty, or no items match your filters."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // The hover card settles in the corner opposite the hovered tile, so tiles under the
            // pointer (previously the fixed top-right corner) are never covered by it.
            .overlay(alignment: popupAlignment(in: geometry.size)) {
                if let hovered {
                    hoverCard(hovered).allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: hovered == nil)
            .background(.primary.opacity(0.025), in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let hit = NestedTreemap.hitTest(point, tiles: tiles)
                    if hovered?.id != hit?.id { hovered = hit }
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard let tile = NestedTreemap.hitTest(point, tiles: tiles) else { return }
                if let node = tile.entry.node { open(node) } else { aggregate(tile.entry) }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if let tile = NestedTreemap.hitTest(point, tiles: tiles) { select(tile.entry, NSEvent.modifierFlags.contains(.command)) }
            }
            .onChange(of: selection) { old, new in
                // A single newly selected tile gets a short ring "ping"; bulk selections don't.
                let added = new.subtracting(old)
                guard !reduceMotion, added.count == 1, let id = added.first, let tile = tiles.first(where: { $0.id == id }) else { return }
                ping = tile.rect; pingToken += 1
            }
            .background(MapNavigationAdapter(back: { history(true) }, forward: { history(false) }))
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                if value.magnification <= 0.85 { parent() }
                else if value.magnification >= 1.15 {
                    if let entry = hovered?.entry ?? tiles.first(where: { selection.contains($0.id) })?.entry {
                        if let node = entry.node, node.isDirectory { open(node) }
                        else if let owner = scene.entries.first(where: { $0.id == entry.ownerID })?.node { open(owner) }
                    }
                }
            })
            .contextMenu {
                if let entry = hovered?.entry ?? tiles.first(where: { selection.contains($0.id) })?.entry {
                    if let node = entry.node {
                        if node.isDirectory { Button("Focus folder", systemImage: "arrow.up.left.and.arrow.down.right") { open(node) } }
                        if node.isDirectory && !node.isSymbolicLink { Button("Rescan folder", systemImage: "arrow.clockwise") { refreshFolder(node) } }
                        Button("Quick Look", systemImage: "eye") { preview(node) }
                        Button("Reveal in Finder", systemImage: "arrow.up.forward.square") { reveal(node) }
                        Button("Copy path", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.path, forType: .string) }
                        Divider()
                        cleanupMenu(for: node)
                    } else if entry.kind == .aggregate { Button("Browse these items") { aggregate(entry) } }
                }
            }
            .task(id: LayoutKey(scene: scene, size: geometry.size, revision: fitRevision)) {
                let size = geometry.size
                // Treemap layout is CPU-bound; run it off the main actor so dense maps
                // don't hitch the UI during navigation, resize, and filter changes.
                let newTiles = await Task.detached(priority: .userInitiated) {
                    NestedTreemap.layoutSync(scene, in: CGRect(origin: .zero, size: size))
                }.value
                guard !Task.isCancelled else { return }
                await apply(newTiles, size: size)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage map, \(sizeText(scene.summary.knownBytes)) known.")
            .accessibilityIdentifier("storageMap")
        }
    }


    /// Installs a new layout, choosing the motion that explains the change: a zoom for
    /// focus navigation, a glide for same-folder geometry changes, an assembling sweep
    /// for the first map. Window resizes and Reduce Motion swap instantly.
    private func apply(_ newTiles: [SceneTile], size: CGSize) async {
        let oldTiles = tiles
        let first = previousRoot == nil
        let rootChanged = previousRoot != nil && previousRoot != scene.rootID
        let resized = previousSize != nil && previousSize != size
        let animate = !reduceMotion && !resized
        let bounds = CGRect(origin: .zero, size: size)
        var target: CGRect?
        var growIn = first
        if animate, rootChanged, !oldTiles.isEmpty {
            if let focus = oldTiles.first(where: { $0.id == scene.rootID })?.rect, let zoomed = MapZoom.expanded(focus: focus, bounds: size) {
                target = zoomed; growIn = true          // drilling into a visible tile
            } else if let previous = previousRoot, let slot = newTiles.first(where: { $0.id == previous })?.rect {
                target = slot                           // going up: shrink back into its tile
            } else {
                target = bounds.insetBy(dx: -size.width * 0.04, dy: -size.height * 0.04); growIn = true
            }
            let renderer = ImageRenderer(content: MapDrawing(tiles: oldTiles, style: style, asynchronous: false)
                .environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
            renderer.scale = displayScale
            snapshot = renderer.cgImage; snapshotFrame = bounds; snapshotOpacity = 1
        }
        let nextMorph: MapMorph? = !animate ? nil
            : growIn ? MapMorph.intro(newTiles, in: size, sweep: first ? 0.3 : 0.14)
            : rootChanged ? nil : MapMorph.relayout(from: oldTiles, to: newTiles)
        tiles = newTiles; previousRoot = scene.rootID; previousSize = size; hovered = nil
        morph = nextMorph; morphStart = Date()
        if let target, snapshot != nil {
            withAnimation(.smooth(duration: 0.34)) { snapshotFrame = target; snapshotOpacity = 0 }
        }
        // Bounded no matter what the layout produced, so the cleanup always runs.
        let wait = min(1, max(snapshot != nil ? 0.36 : 0, nextMorph?.totalDuration ?? 0))
        guard wait.isFinite, wait > 0 else { snapshot = nil; morph = nil; return }
        try? await Task.sleep(for: .seconds(wait + 0.02))
        guard !Task.isCancelled else { return }
        snapshot = nil; morph = nil
    }
    @ViewBuilder private func cleanupMenu(for node: FileNode) -> some View {
        let membership = membership(node)
        if membership == .selected || membership == .insideSelection {
            Button("Deselect", systemImage: "tray") { deselectFromCleanup(node) }.disabled(!canClean)
        } else {
            Button("Select", systemImage: "tray.and.arrow.down") { selectForCleanup(node) }.disabled(!canClean)
        }
    }
    private struct LayoutKey: Equatable { let scene: MapScene; let size: CGSize; let revision: Int }
    private func popupAlignment(in size: CGSize) -> Alignment {
        guard let rect = hovered?.rect else { return .topTrailing }
        let horizontal: HorizontalAlignment = rect.midX > size.width * 0.5 ? .leading : .trailing
        let vertical: VerticalAlignment = rect.midY > size.height * 0.5 ? .top : .bottom
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
    private func hoverCard(_ tile: SceneTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.entry.localizedTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Text(scene.summary.knownBytes > 0 ? L10n.format("%@ · %lld%% of view", sizeText(tile.entry.bytes), Int(Double(tile.entry.bytes) / Double(scene.summary.knownBytes) * 100)) : sizeText(tile.entry.bytes))
                .font(.caption).foregroundStyle(.secondary)
            if let path = tile.entry.node?.path { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if let node = tile.entry.node, let explanation = description(node) {
                Text(explanation).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = growthNote(tile.entry) { Text(note).font(.caption.weight(.medium)).monospacedDigit() }
            if let tileClass = style.tileClass(of: tile) {
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text(tileClass.title).font(.caption.weight(.medium)) } icon: { Circle().fill(tileClass.color).frame(width: 7, height: 7) }
                    if !tileClass.explanation.isEmpty {
                        Text(tileClass.explanation).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 2)
            }
            if tile.entry.kind == .aggregate { Text("Click to browse all items in this folder").font(.caption2).foregroundStyle(.secondary) }
            if tile.entry.kind == .unreached, let unreached {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approximate: the volume's used space minus what this scan read. It includes system data, other users, local snapshots and locations the scan couldn't read.")
                    if let purgeable = unreached.purgeable { Text(L10n.format("macOS can free about %@ of purgeable space on its own.", sizeText(purgeable))) }
                    if let snapshots = unreached.localSnapshots, snapshots > 0 { Text(L10n.count("%lld local snapshots (sizes not reported)", snapshots)) }
                    if unreached.unreadableLocations > 0 { Text(L10n.count("%lld locations couldn’t be read", unreached.unreadableLocations)) }
                }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: 340, alignment: .leading).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(12)
    }
}
