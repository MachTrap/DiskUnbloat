import SwiftUI

struct LocationSelectionView: View {
    @Bindable var model: LocationSelectionViewModel
    let authorization: AuthorizationStore
    let scan: ScanViewModel
    let busy: Bool
    let choose: () -> Void
    let target: (ScanTarget) -> Void
    let restore: (SavedLocation) -> Void
    let drop: ([URL]) -> Bool

    var body: some View {
        ZStack {
            RadialGradient(colors: [.teal.opacity(0.075), .clear], center: .init(x: 0.5, y: 0.22), startRadius: 10, endRadius: 520).ignoresSafeArea()
            VStack {
                Spacer(minLength: 20)
                VStack(spacing: 18) {
                    VStack(spacing: 5) {
                        Text("Make space for what’s next.").font(.system(size: 23, weight: .semibold, design: .rounded))
                        Text("Choose a folder. See the bigger picture.").font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button("Choose folder or disk", systemImage: "folder.badge.plus", action: choose)
                            .buttonStyle(.glassProminent).controlSize(.large).accessibilityIdentifier("chooseLocation")
                        Menu {
                            if authorization.locations.isEmpty { Text("No recent locations") }
                            ForEach(authorization.locations) { saved in Button(saved.name) { restore(saved) } }
                            Divider()
                            ForEach(model.catalog.additional) { item in Button(L10n.text(item.title)) { target(item) } }
                            Menu("Mounted disks") {
                                ForEach(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [], id: \.path) { url in
                                    Button(url.lastPathComponent.isEmpty ? "Startup disk" : url.lastPathComponent) {
                                        target(ScanTarget(id: url.path, title: url.lastPathComponent, symbol: "externaldrive", detail: "", url: url))
                                    }
                                }
                            }
                        } label: { Label("Locations", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("recentLocations")
                    }
                    Label("or drop a folder anywhere in this window", systemImage: "arrow.down.document").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick actions").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        // Map-like mosaic: tile sizes follow each action's weight, like the
                        // treemap itself. A hero tile for the big picture, the two grouped
                        // "everything" scans as wide mid tiles, and the two plain folders
                        // as a short full-width bottom row.
                        GeometryReader { geo in
                            let width = geo.size.width
                            VStack(spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    if let home = quickTarget("home") {
                                        heroTile(home).frame(width: width * 0.49, height: topMosaicHeight)
                                    }
                                    VStack(spacing: 8) {
                                        if let allCaches = quickTarget("allCaches") {
                                            mosaicTile(allCaches, showsCount: true)
                                                .frame(height: cachesRowHeight)
                                        }
                                        if let devTools = quickTarget("devTools") {
                                            mosaicTile(devTools, showsCount: true)
                                                .frame(height: topMosaicHeight - cachesRowHeight - 8)
                                        }
                                    }
                                }
                                HStack(spacing: 8) {
                                    if let downloads = quickTarget("downloads") {
                                        mosaicTile(downloads)
                                            .frame(width: width * 0.44 - 4, height: smallRowHeight)
                                    }
                                    if let caches = quickTarget("caches") {
                                        mosaicTile(caches)
                                            .frame(width: width * 0.56 - 4, height: smallRowHeight)
                                    }
                                }
                            }
                        }
                        .frame(height: mosaicHeight)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 18) {
                        Button { model.showOptions = true } label: { Label("Scan options", systemImage: "slider.horizontal.3") }
                            .popover(isPresented: $model.showOptions) { ScanOptionsView(model: scan) }
                            .accessibilityIdentifier("scanOptions")
                        Spacer()
                        Label("On your Mac. Only your Mac.", systemImage: "lock.shield").foregroundStyle(.secondary)
                    }.font(.caption).buttonStyle(.plain)
                    if busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Opening saved folder…").foregroundStyle(.secondary) }.font(.caption) }
                    Text("Quick actions scan files; they never remove them. macOS may ask you to authorize a location.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(26).frame(maxWidth: 520)
                .background(.regularMaterial, in: .rect(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.08)) }
                Spacer(minLength: 20)
            }.padding(24)
        }
        .disabled(busy)
        .overlay { if model.dropTargeted { RoundedRectangle(cornerRadius: 22).stroke(.teal, style: StrokeStyle(lineWidth: 3, dash: [9, 6])).padding(12).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { model.dropTargeted = $0 }
        .accessibilityIdentifier("locationScreen")
    }

    @ScaledMetric(relativeTo: .callout) private var mosaicHeight: CGFloat = 172

    /// Mosaic rows: the hero column and the big tiles take the top, the two plain
    /// folders share a short full-width bottom row. A single scaled metric drives every
    /// height, so the proportions hold when text scales; widths come from the container.
    private var smallRowHeight: CGFloat { mosaicHeight * 0.26 }
    private var topMosaicHeight: CGFloat { mosaicHeight - smallRowHeight - 8 }
    private var cachesRowHeight: CGFloat { topMosaicHeight * 0.55 }

    /// The pinned quick-action target for one mosaic cell.
    private func quickTarget(_ id: String) -> ScanTarget? {
        model.catalog.targets.first { $0.id == id }
    }

    /// The hero cell: "Home folder" — the same teal wash the map uses for its accents,
    /// carrying the action's detail text because only the largest tile has room for it.
    private func heroTile(_ item: ScanTarget) -> some View {
        Button { target(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: item.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.teal)
                Text(L10n.text(item.title)).font(.title3.weight(.semibold))
                Text(L10n.text(item.detail))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.teal.opacity(0.12), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.teal.opacity(0.25)) }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain).help(pillHelp(item)).accessibilityIdentifier("target-" + item.id)
    }

    /// A mosaic cell: icon and title leading, the location count pinned bottom on the
    /// tall tiles. Width and height come from the layout.
    private func mosaicTile(_ item: ScanTarget, showsCount: Bool = false) -> some View {
        Button { target(item) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.teal)
                    Text(L10n.text(item.title)).font(.callout).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if showsCount {
                    Text(L10n.count("%lld locations", item.roots.count))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)) }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain).help(pillHelp(item)).accessibilityIdentifier("target-" + item.id)
    }

    private func pillHelp(_ item: ScanTarget) -> String {
        let detail = L10n.text(item.detail)
        return (item.grouped ? L10n.count("%lld locations", item.roots.count) : item.url.path) + " — " + detail
    }
}
