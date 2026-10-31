import SwiftUI

struct LocationSelectionView: View {
    @Bindable var model: LocationSelectionViewModel
    let authorization: AuthorizationStore
    let scan: ScanViewModel
    let busy: Bool
    let choose: () -> Void
    let target: (ScanTarget) -> Void
    let restore: (SavedLocation) -> Void
    let sample: () -> Void
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
                                        target(ScanTarget(id: url.path, title: url.lastPathComponent, symbol: "externaldrive", detail: "", url: url, developer: false))
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
                        HStack(spacing: 8) { ForEach(model.commonTargets) { pill($0) } }
                        DisclosureGroup(isExpanded: $model.showDeveloper) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                                ForEach(model.developerTargets) { pill($0) }
                            }.padding(.top, 8)
                        } label: { Label("Developer caches", systemImage: "hammer").font(.callout) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureGroup("Known cache locations") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.catalog.knownLocations) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.caption.weight(.medium))
                                    Text(item.explanation).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                    HStack(spacing: 18) {
                        Button { model.showOptions = true } label: { Label("Scan options", systemImage: "slider.horizontal.3") }
                            .popover(isPresented: $model.showOptions) { ScanOptionsView(model: scan) }
                            .accessibilityIdentifier("scanOptions")
                        Button("Explore a sample", action: sample).accessibilityIdentifier("loadSample")
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

    private func pill(_ item: ScanTarget) -> some View {
        Button { target(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.teal)
                Text(L10n.text(item.title)).font(.callout)
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.08)) }
                .contentShape(.rect(cornerRadius: 9))
        }.buttonStyle(.plain).help(pillHelp(item)).accessibilityIdentifier("target-" + item.id)
    }

    private func pillHelp(_ item: ScanTarget) -> String {
        let detail = L10n.text(item.detail)
        return (item.grouped ? L10n.count("%lld locations", item.roots.count) : item.url.path) + " — " + detail
    }
}
