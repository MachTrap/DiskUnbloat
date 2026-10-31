import SwiftUI
import AppKit
import DiskCore

struct TreemapView: View {
    let scene: MapScene
    let selection: Set<Int64>
    let highlighted: FileCategory?
    let fitRevision: Int
    let select: (MapEntry, Bool) -> Void
    let open: (FileNode) -> Void
    let aggregate: (MapEntry) -> Void
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let addToBasket: (FileNode) -> Void
    let canClean: Bool
    var refreshFolder: (FileNode) -> Void = { _ in }
    var parent: () -> Void = {}
    var history: (Bool) -> Void = { _ in }
    @State private var tiles: [SceneTile] = []
    @State private var hovered: SceneTile?
    @State private var previousImage: CGImage?
    @State private var transitionOpacity = 0.0
    @State private var transitionScale = 1.0
    @State private var previousRoot: Int64?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                MapDrawing(tiles: tiles, highlighted: highlighted).equatable()
                Canvas { context, _ in
                    for tile in tiles where selection.contains(tile.id) || tile.id == hovered?.id {
                        let path = Path(roundedRect: tile.rect, cornerRadius: tile.isContainer ? 7 : 5)
                        context.stroke(path, with: .color(selection.contains(tile.id) ? .primary : .primary.opacity(0.5)), lineWidth: selection.contains(tile.id) ? 2.5 : 1.5)
                    }
                }.allowsHitTesting(false)
                if let previousImage {
                    Image(decorative: previousImage, scale: 1).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(transitionScale).opacity(transitionOpacity).allowsHitTesting(false)
                }
                if tiles.isEmpty {
                    ContentUnavailableView("No sized items", systemImage: "square.dashed", description: Text(scene.summary.unknownCount > 0 ? "Some sizes are unknown. Open Files to inspect these entries." : "This folder is empty, or no items match your filters."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let hovered {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hovered.entry.localizedTitle).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(scene.summary.knownBytes > 0 ? L10n.format("%@ · %lld%% of view", sizeText(hovered.entry.bytes), Int(Double(hovered.entry.bytes) / Double(scene.summary.knownBytes) * 100)) : sizeText(hovered.entry.bytes))
                            .font(.caption).foregroundStyle(.secondary)
                        if let path = hovered.entry.node?.path { Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        if hovered.entry.kind == .aggregate { Text("Click to browse all items in this folder").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: 340, alignment: .leading).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(12).allowsHitTesting(false)
                }
            }
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
                        Button("Add to cleanup review", systemImage: "tray.and.arrow.down") { addToBasket(node) }.disabled(!canClean)
                    } else { Button("Browse these items") { aggregate(entry) } }
                }
            }
            .task(id: LayoutKey(scene: scene, size: geometry.size, revision: fitRevision)) {
                let size = geometry.size
                let newTiles = await NestedTreemap.layout(scene, in: CGRect(origin: .zero, size: size))
                guard !Task.isCancelled else { return }
                if previousRoot != nil, previousRoot != scene.rootID, !reduceMotion, !tiles.isEmpty {
                    let renderer = ImageRenderer(content: MapDrawing(tiles: tiles, highlighted: highlighted, asynchronous: false).environment(\.colorScheme, scheme).frame(width: size.width, height: size.height))
                    renderer.scale = 1
                    previousImage = renderer.cgImage; transitionOpacity = 1; transitionScale = 1
                }
                tiles = newTiles; previousRoot = scene.rootID; hovered = nil
                if previousImage != nil {
                    withAnimation(.easeOut(duration: 0.24)) { transitionOpacity = 0; transitionScale = 1.06 }
                    try? await Task.sleep(for: .milliseconds(270))
                    guard !Task.isCancelled else { return }; previousImage = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Storage map, \(sizeText(scene.summary.knownBytes)) known. Use Command-2 to open the accessible file browser.")
            .accessibilityIdentifier("storageMap")
        }
    }
    private struct LayoutKey: Equatable { let scene: MapScene; let size: CGSize; let revision: Int }
}

private struct MapDrawing: View, Equatable {
    let tiles: [SceneTile]
    let highlighted: FileCategory?
    var asynchronous = true
    @Environment(\.colorScheme) private var scheme
    nonisolated static func == (a: Self, b: Self) -> Bool { a.tiles == b.tiles && a.highlighted == b.highlighted && a.asynchronous == b.asynchronous }
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: asynchronous) { context, _ in
            for tile in tiles {
                let rect = tile.rect
                guard rect.width > 1, rect.height > 1 else { continue }
                let entry = tile.entry
                let dimmed = highlighted != nil && !tile.isContainer && entry.kind == .file && entry.category != highlighted
                let color: Color = entry.kind == .folder ? .teal : entry.kind == .aggregate ? .gray : entry.category.color
                let path = Path(roundedRect: rect, cornerRadius: tile.isContainer ? 7 : 5)
                if tile.isContainer {
                    context.fill(path, with: .color(.primary.opacity(scheme == .dark ? 0.055 : 0.035)))
                    context.stroke(path, with: .color(.primary.opacity(0.1)), lineWidth: 1)
                } else {
                    let opacity = dimmed ? 0.10 : scheme == .dark ? 0.68 : 0.27
                    context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.7)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                    context.stroke(path, with: .color(color.opacity(dimmed ? 0.08 : 0.22)), lineWidth: 0.5)
                }
                guard rect.width > 62 && rect.height > 23 else { continue }
                let foreground: Color = dimmed ? .secondary.opacity(0.4) : .primary
                let label = Text(entry.localizedTitle).font(.system(size: tile.isContainer ? 11 : 12, weight: .medium)).foregroundStyle(foreground)
                context.draw(label, in: CGRect(x: rect.minX + 9, y: rect.minY + 5, width: rect.width - 18, height: 16))
                if !tile.isContainer && rect.height > 54 && rect.width > 85 {
                    context.draw(Text(sizeText(entry.bytes)).font(.system(size: 11)).foregroundStyle(foreground.opacity(0.65)), at: CGPoint(x: rect.minX + 9, y: rect.minY + 27), anchor: .topLeading)
                    if entry.unknownCount > 0 && rect.height > 78 {
                        context.draw(Text("Partial size").font(.system(size: 10)).foregroundStyle(.orange), at: CGPoint(x: rect.minX + 9,y: rect.minY + 46), anchor: .topLeading)
                    }
                }
            }
        }
    }
}
