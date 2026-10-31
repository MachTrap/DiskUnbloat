import SwiftUI
import DiskCore

struct ExplorerView: View {
    @Bindable var model: ExplorerViewModel
    let windowWidth: CGFloat
    let scan: ScanViewModel
    let canClean: Bool
    let basketCount: Int
    let basketBytes: Int64
    let queuedPaths: [String]
    let newScan: () -> Void
    let rescan: () -> Void
    let refreshFolder: (FileNode) -> Void
    let review: () -> Void
    let issues: () -> Void
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let addToBasket: (FileNode) -> Void
    let addSelection: () -> Void
    private var wide: Bool { windowWidth >= 1180 }
    @State private var dragOrigin: CGFloat?
    @State private var showOptions = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if model.hasFilters { filterChips }
            if scan.snapshot?.complete == false {
                HStack {
                    Label(scan.snapshot?.cancelled == true ? "Cancelled scan · partial results · cleanup disabled" : "Some locations couldn’t be read. Map sizes are partial.", systemImage: "exclamationmark.triangle")
                    Spacer(); Button("Details", action: issues).buttonStyle(.plain)
                }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.vertical, 7)
            }
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    TreemapView(scene: model.scene, selection: model.selectionIDs, highlighted: model.highlightedCategory, fitRevision: model.fitRevision, select: model.select, open: { model.navigate($0) }, aggregate: model.openAggregate, preview: preview, reveal: reveal, addToBasket: addToBasket, canClean: canClean, refreshFolder: refreshFolder, parent: model.up, history: model.history)
                        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                        .overlay(alignment: .bottom) { if model.isLoading { ProgressView().controlSize(.small).padding(12).background(.regularMaterial, in: Capsule()).padding(16) } }
                    if model.showFiles {
                        drawerHandle(maxHeight: geometry.size.height * 0.6)
                        AnalysisDrawerView(model: model, canClean: canClean, preview: preview, reveal: reveal, addToBasket: addToBasket, refreshFolder: refreshFolder)
                            .frame(height: min(model.drawerHeight, geometry.size.height * 0.6))
                    }
                }
            }
            if !model.selectionIDs.isEmpty { selectionBar }
            legend
        }
        .inspector(isPresented: Binding(get: { wide && model.showDetails }, set: { if wide { model.showDetails = $0 } })) {
            inspector.inspectorColumnWidth(min: 245, ideal: 275, max: 330)
        }
        .toolbar { toolbar }
        .modifier(RefreshHooks(model: model, queuedPaths: queuedPaths, focusSearch: { searchFocused = true }))
        .focusable().focusEffectDisabled()
        .onKeyPress(.return) { guard let node = model.selected else { return .ignored }; if model.canNavigate(node) { model.navigate(node) } else { preview(node) }; return .handled }
        .onKeyPress(.space) { guard let node = model.selected else { return .ignored }; preview(node); return .handled }
        .onExitCommand { if !model.selectionIDs.isEmpty { model.selectionIDs = [] } else { model.up() } }
        .accessibilityIdentifier("explorerScreen")
    }

    /// Debounced query refreshes keyed to every filter input, extracted to keep `body` tractable.
    private struct RefreshHooks: ViewModifier {
        @Bindable var model: ExplorerViewModel
        let queuedPaths: [String]
        let focusSearch: () -> Void
        func body(content: Content) -> some View {
            content
                .onChange(of: model.drawerTab) { model.scheduleRefresh() }
                .onChange(of: model.candidateRule) { model.scheduleRefresh() }
                .onChange(of: model.search) { model.scheduleRefresh() }
                .onChange(of: model.scope) { model.scheduleRefresh() }
                .onChange(of: model.suggestion) { model.scheduleRefresh() }
                .onChange(of: model.minimumGB) { model.scheduleRefresh() }
                .onChange(of: model.olderDays) { model.scheduleRefresh() }
                .onChange(of: model.extensionFilter) { model.scheduleRefresh() }
                .onChange(of: model.metric) { model.scheduleRefresh() }
                .onChange(of: model.sortName) { model.scheduleRefresh() }
                .onChange(of: model.ascending) { model.scheduleRefresh() }
                .onChange(of: model.searchRequested) { focusSearch() }
                .onChange(of: queuedPaths) { model.updateHiddenPaths(queuedPaths) }
                .onAppear { model.updateHiddenPaths(queuedPaths) }
        }
    }

    private var inspector: some View {
        FileInspector(model: model, root: scan.root, canClean: canClean, preview: preview, reveal: reveal, addToBasket: addToBasket)
    }
    private var pathBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.breadcrumbs) { node in
                        Button { model.navigate(node) } label: {
                            HStack(spacing: 5) { if node.id == model.breadcrumbs.first?.id { Image(systemName: "internaldrive") }; Text(node.name).lineLimit(1) }
                        }.buttonStyle(.plain).font(.callout.weight(node.id == model.current?.id ? .semibold : .regular))
                        if node.id != model.current?.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText(model.scene.summary.knownBytes)).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(model.scene.summary.unknownCount > 0 ? L10n.count("Known · %lld incomplete items", model.scene.summary.unknownCount) : L10n.text(model.metric.rawValue)).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !model.search.isEmpty { chip("“\(model.search)”") { model.search = "" } }
                if let suggestion = model.suggestion { chip(L10n.text(suggestion.rawValue)) { model.suggestion = nil } }
                if model.minimumGB > 0 { chip(L10n.format("%@ GB+", model.minimumGB.formatted())) { model.minimumGB = 0 } }
                if model.olderDays > 0 { chip(L10n.count("Older than %lld days", model.olderDays)) { model.olderDays = 0 } }
                if !model.extensionFilter.isEmpty { chip(".\(model.extensionFilter)") { model.extensionFilter = "" } }
                Text(L10n.text(model.scope.rawValue)).foregroundStyle(.secondary)
                Button("Clear", action: model.clearFilters).buttonStyle(.plain).foregroundStyle(.teal)
            }.font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
        }
    }
    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) { HStack(spacing: 5) { Text(title); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.padding(.horizontal, 9).padding(.vertical, 5).background(.teal.opacity(0.09), in: Capsule()) }.buttonStyle(.plain)
    }
    private var selectionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: model.selected?.isDirectory == true ? "folder" : model.selectionIDs.count > 1 ? "square.stack" : "doc").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selected?.name ?? L10n.count("%lld items selected", model.selectionIDs.count)).font(.callout.weight(.medium)).lineLimit(1)
                Text(sizeText(model.selectionBytes) + L10n.text(" · overlapping selections counted once")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let node = model.selected { Button { preview(node) } label: { Image(systemName: "eye") }.help("Quick Look"); Button { reveal(node) } label: { Image(systemName: "arrow.up.forward.square") }.help("Reveal in Finder") }
            Button("Details", systemImage: "info.circle") { model.showDetails.toggle() }
                .popover(isPresented: Binding(get: { !wide && model.showDetails }, set: { if !wide { model.showDetails = $0 } })) { inspector.frame(width: 290, height: 470) }
            Button("Queue", systemImage: "tray.and.arrow.down", action: addSelection).disabled(!canClean).accessibilityIdentifier("addToReview")
            Button { model.selectionIDs = [] } label: { Image(systemName: "xmark") }.help("Clear selection")
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(model.availableCategories) { category in
                Button { model.highlightedCategory = model.highlightedCategory == category ? nil : category } label: {
                    HStack(spacing: 5) { Circle().fill(category.color).frame(width: 6,height: 6); Text(L10n.text(category.rawValue)) }
                        .opacity(model.highlightedCategory == nil || model.highlightedCategory == category ? 1 : 0.4)
                }.buttonStyle(.plain).accessibilityAddTraits(model.highlightedCategory == category ? .isSelected : [])
            }
            if model.highlightedCategory != nil { Button("Show all") { model.highlightedCategory = nil }.buttonStyle(.plain).foregroundStyle(.teal) }
            Spacer(minLength: 4)
            Button { model.showFiles.toggle() } label: {
                Label(model.showFiles ? L10n.text("Hide files") : L10n.format("Files · %@", model.totalRows.formatted()), systemImage: "list.bullet")
            }.buttonStyle(.plain).accessibilityIdentifier("toggleFiles")
        }.font(.caption2).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private func drawerHandle(maxHeight: CGFloat) -> some View {
        HStack {
            Picker("Analysis", selection: $model.drawerTab) {
                ForEach(AnalysisTab.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 380).accessibilityIdentifier("analysisTabs")
            Spacer(); Capsule().fill(.secondary.opacity(0.3)).frame(width: 34,height: 3); Spacer()
            Button { model.showFiles = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.caption).help("Close file browser")
        }.padding(.horizontal, 16).frame(height: 26).background(.bar)
            .gesture(DragGesture().onChanged { value in
                if dragOrigin == nil { dragOrigin = model.drawerHeight }
                model.drawerHeight = min(max(110, (dragOrigin ?? 190) - value.translation.height), max(110,maxHeight))
            }.onEnded { _ in dragOrigin = nil })
    }
    /// Toolbar tray icon with a small red circle showing the queued item count.
    private var queueBadge: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "tray")
            if basketCount > 0 {
                Text("\(basketCount)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, basketCount > 9 ? 3 : 0)
                    .frame(minWidth: 14, minHeight: 14).background(Circle().fill(.red))
                    .fixedSize().offset(x: 7, y: -7).accessibilityHidden(true)
            }
        }.frame(width: 30, height: 22)
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.history(true) } label: { Label("Back", systemImage: "chevron.left") }.disabled(model.back.isEmpty)
            Button { model.history(false) } label: { Label("Forward", systemImage: "chevron.right") }.disabled(model.forward.isEmpty)
            Button(action: model.up) { Label("Up", systemImage: "arrow.up") }.disabled(model.breadcrumbs.count < 2).keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 145).focused($searchFocused).accessibilityIdentifier("searchFiles")

            Menu {
                Picker("Search scope", selection: $model.scope) { ForEach(ExplorerScope.allCases) { Text(L10n.text($0.rawValue)).tag($0) } }
                Picker("Minimum size", selection: $model.minimumGB) { Text("Any size").tag(0.0); Text("100 MB+").tag(0.1); Text("1 GB+").tag(1.0); Text("10 GB+").tag(10.0) }
                Picker("Modified", selection: $model.olderDays) { Text("Any time").tag(0); Text("Over 30 days").tag(30); Text("Over 180 days").tag(180); Text("Over a year").tag(365) }
                TextField("Extension", text: $model.extensionFilter)
                Divider()
                ForEach(Suggestion.allCases) { group in Button(L10n.text(group.rawValue)) { model.suggestion = group }.help(L10n.text(group.explanation)) }
                Button("Clear filters", action: model.clearFilters)
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
            Menu {
                Picker("Size", selection: $model.metric) { ForEach(SizeMetric.allCases) { Text(L10n.text($0.rawValue)).tag($0) } }
                Toggle("Sort names", isOn: $model.sortName); Toggle("Ascending", isOn: $model.ascending)
                Divider()
                Button("Fit map") { model.fitRevision += 1 }
                Toggle("File browser", isOn: $model.showFiles)
                Toggle("Details", isOn: $model.showDetails)
                Button("Map only") { model.showFiles = false; model.showDetails = false }
                Divider()
                Button("Scan options") { showOptions = true }
                Button("Rescan folder") { if let node = model.current { refreshFolder(node) } }.accessibilityIdentifier("rescanFolder")
                Button("Scan again", action: rescan)
            } label: { Label("Display", systemImage: "rectangle.3.group") }
            Button(action: newScan) { Label("New scan", systemImage: "folder.badge.plus") }
            Button(action: review) { queueBadge }.disabled(basketCount == 0)
                .help(L10n.format("Deletion queue · %lld items · %@ estimated", basketCount, sizeText(basketBytes)))
                .accessibilityIdentifier("reviewCleanup")
        }
        ToolbarItem(placement: .automatic) {
            Color.clear.frame(width: 0,height: 0).popover(isPresented: $showOptions) { ScanOptionsView(model: scan) }
        }
    }
}
