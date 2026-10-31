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
            ScrollView {
                VStack(spacing: 26) {
                    Spacer(minLength: 26)
                    Image(systemName: "square.grid.3x3.square").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(.teal.gradient).accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text("Make space for what’s next.").font(.system(size: 36, weight: .semibold, design: .rounded))
                        Text("Choose a folder. See the bigger picture.").font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
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
                        Label("or drop a folder anywhere in this window", systemImage: "arrow.down.document").font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("A good place to start").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        HStack(spacing: 12) { ForEach(model.commonTargets) { item in targetCard(item) } }
                        DisclosureGroup(isExpanded: $model.showDeveloper) {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(model.developerTargets) { item in targetCard(item) }
                            }.padding(.top, 12)
                        } label: { Label("Developer caches", systemImage: "hammer").font(.callout) }
                    }.frame(maxWidth: 790)
                    HStack(spacing: 20) {
                        Button { model.showOptions = true } label: { Label("Scan options", systemImage: "slider.horizontal.3") }
                            .popover(isPresented: $model.showOptions) { ScanOptionsView(model: scan) }
                            .accessibilityIdentifier("scanOptions")
                        Button("Explore a sample", action: sample).accessibilityIdentifier("loadSample")
                        Spacer()
                        Label("On your Mac. Only your Mac.", systemImage: "lock.shield").foregroundStyle(.secondary)
                    }.font(.caption).buttonStyle(.plain).frame(maxWidth: 790)
                    if busy { HStack { ProgressView().controlSize(.small); Text("Opening saved folder…").foregroundStyle(.secondary) }.font(.callout) }
                    Text("Quick actions scan files; they never remove them. macOS may ask you to authorize a location.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 12)
                }.frame(maxWidth: .infinity).padding(30)
            }
        }
        .disabled(busy)
        .overlay { if model.dropTargeted { RoundedRectangle(cornerRadius: 22).stroke(.teal, style: StrokeStyle(lineWidth: 3, dash: [9, 6])).padding(12).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { model.dropTargeted = $0 }
        .accessibilityIdentifier("locationScreen")
    }

    private func targetCard(_ item: ScanTarget) -> some View {
        Button { target(item) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.teal)
                Text(L10n.text(item.title)).font(.headline)
                Text(L10n.text(item.detail)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(3)
            }.padding(18).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)) }
                .contentShape(.rect(cornerRadius: 16))
        }.buttonStyle(.plain).help(item.url.path).accessibilityIdentifier("target-" + item.id)
    }
}
