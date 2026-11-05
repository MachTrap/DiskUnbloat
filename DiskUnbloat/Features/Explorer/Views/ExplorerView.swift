import SwiftUI
import DiskCore

struct ExplorerView: View {
    @Bindable var model: ExplorerViewModel
    let queue: CleanupQueueModel
    var duplicates: DuplicatesViewModel?
    let scan: ScanViewModel
    let canClean: Bool
    let queuedPaths: [String]
    /// Fast membership via the queue model's rebuild-per-change index.
    var membership: (FileNode) -> QueueMembership = { _ in .none }
    let newScan: () -> Void
    let rescan: () -> Void
    let refreshFolder: (FileNode) -> Void
    let issues: () -> Void
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let selectForCleanup: (FileNode) -> Void
    let deselectFromCleanup: (FileNode) -> Void
    let addSelection: () -> Void
    let performCleanup: (CleanupMode) -> Void
    /// Quick-select recommendations for the cleanup queue panel.
    let selecting: Bool
    let selectLevel: (AutoSelectionLevel) -> Void
    let previewLevel: (AutoSelectionLevel) async -> AutoSelectionPreview?
    let levelEstimates: () async -> [AutoSelectionLevel: AutoSelectionPreview]
    /// Highlights an item on the map, e.g. when a panel row is tapped.
    let highlight: (FileNode) -> Void
    @State private var showOptions = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showQueue: Binding<Bool> {
        Binding(get: { queue.cleanup.showQueue }, set: { queue.cleanup.showQueue = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if model.hasFilters { filterChips }
            if model.highlightSearchActive { matchBar }
            if scan.snapshot?.complete == false {
                HStack {
                    Label(scan.snapshot?.cancelled == true ? "Cancelled scan · partial results · cleanup disabled" : "Some locations couldn’t be read. Map sizes are partial.", systemImage: "exclamationmark.triangle")
                    Spacer(); Button("Details", action: issues).buttonStyle(.plain)
                }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.vertical, 7)
            }
            TreemapView(scene: model.scene, selection: model.selectionIDs, style: model.tileStyle, unreached: model.unreached, growthNote: model.growthNote, fitRevision: model.fitRevision, select: model.select, open: { model.navigate($0) }, aggregate: model.openAggregate, preview: preview, reveal: reveal, selectForCleanup: selectForCleanup, deselectFromCleanup: deselectFromCleanup, queuedPaths: queuedPaths, canClean: canClean, membership: membership, description: model.description, refreshFolder: refreshFolder, parent: model.up, history: model.history)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                .overlay {
                    if model.isLoading {
                        MapLoadingStatus(name: model.current?.name)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.isLoading)
            if !model.selectionIDs.isEmpty { selectionBar }
            legend
        }
        .inspector(isPresented: showQueue) {
            CleanupQueueView(model: queue, current: model.current, selected: model.selected, selectedIDs: model.selectionIDs, canClean: canClean, selecting: selecting, select: selectForCleanup, deselect: deselectFromCleanup, highlight: highlight, performCleanup: performCleanup, selectLevel: selectLevel, previewLevel: previewLevel, levelEstimates: levelEstimates, focusFolder: { model.navigate($0) }, preview: preview, reveal: reveal, refreshFolder: refreshFolder, duplicates: duplicates)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar { toolbar }
        .modifier(RefreshHooks(model: model, queuedPaths: queuedPaths, focusSearch: { searchFocused = true }))
        .focusable().focusEffectDisabled()
        .onKeyPress(.return) { guard let node = model.selected else { return .ignored }; if model.canNavigate(node) { model.navigate(node) } else { preview(node) }; return .handled }
        .onKeyPress(.space) { guard let node = model.selected else { return .ignored }; preview(node); return .handled }
        .onExitCommand { if !model.selectionIDs.isEmpty { model.selectionIDs = [] } else { model.up() } }
        .accessibilityIdentifier("explorerScreen")
    }

    /// Center-of-map loading status shown while the scene for the current query rebuilds
    /// (focus navigation, filter changes, folder refresh). Deliberately large and centered
    /// — it replaced a small bottom-edge spinner that was easy to miss — and names the
    /// scope being loaded when one is known. It never intercepts clicks on the map.
    private struct MapLoadingStatus: View {
        let name: String?

        var body: some View {
            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.regular).tint(.teal)
                    Text("Updating the map…").font(.callout.weight(.medium))
                }
                if let name {
                    Text(name)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Updating the map…")
            .allowsHitTesting(false)
        }
    }

    /// Debounced query refreshes keyed to every filter input, extracted to keep `body` tractable.
    private struct RefreshHooks: ViewModifier {
        @Bindable var model: ExplorerViewModel
        let queuedPaths: [String]
        let focusSearch: () -> Void
        func body(content: Content) -> some View {
            content
                .onChange(of: model.suggestion) { model.scheduleRefresh() }
                .onChange(of: model.search) { model.scheduleRefresh() }
                .onChange(of: model.scope) { model.scheduleRefresh() }
                .onChange(of: model.minimumGB) { model.scheduleRefresh() }
                .onChange(of: model.olderDays) { model.scheduleRefresh() }
                .onChange(of: model.extensionFilter) { model.scheduleRefresh() }
                .onChange(of: model.metric) { model.scheduleRefresh() }
                .onChange(of: model.searchRequested) { focusSearch() }
                .onChange(of: queuedPaths) { Task { await model.updateHiddenPaths(queuedPaths) } }
                .task { await model.updateHiddenPaths(queuedPaths) }
        }
    }

    /// Native-looking search field: leading magnifier, clear button, and its own debounce so
    /// typing does not commit a query (and chip) per keystroke. Return commits immediately.
    private struct SearchField: View {
        @Binding var text: String
        @Binding var mode: SearchMode
        var focused: FocusState<Bool>.Binding
        /// Return on an already committed highlight search steps to the next match.
        var stepToNextMatch: () -> Void = {}
        @State private var draft = ""
        @State private var commitTask: Task<Void, Never>?
        private static let debounce: Duration = .milliseconds(350)

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $draft)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .onSubmit {
                        if mode == .highlight, draft == text, !text.isEmpty { stepToNextMatch() } else { commit(immediately: true) }
                    }
                    .accessibilityIdentifier("searchFiles")
                if !draft.isEmpty {
                    Button { draft = ""; commit(immediately: true) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Clear").accessibilityLabel("Clear")
                }
                Divider().frame(height: 14)
                // Old (filter) and new (highlight) search, switchable at any time.
                Button { mode = mode == .filter ? .highlight : .filter } label: {
                    Image(systemName: mode.symbol).foregroundStyle(mode == .highlight ? Color.accentColor : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(mode == .filter ? L10n.text("Search filters the map. Click to highlight matches instead.") : L10n.text("Search highlights matches on the map. Click to filter instead."))
                .accessibilityLabel(mode.title)
                .accessibilityIdentifier("searchMode")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 232)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
            .onAppear { draft = text }
            .onChange(of: draft) { commit(immediately: false) }
            .onChange(of: text) { if text != draft { commitTask?.cancel(); draft = text } }
            .onDisappear { commitTask?.cancel() }
        }

        private func commit(immediately: Bool) {
            commitTask?.cancel()
            guard draft != text else { return }
            if immediately { text = draft; return }
            commitTask = Task {
                do { try await Task.sleep(for: Self.debounce) } catch { return }
                text = draft
            }
        }
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
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.scene.summary.knownBytes)
                Text(model.scene.summary.unknownCount > 0 ? L10n.count("Known · %lld incomplete items", model.scene.summary.unknownCount) : L10n.text(model.metric.rawValue)).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.searchMode == .filter, !model.search.isEmpty { chip("“\(model.search)”") { model.search = "" } }
                if let suggestion = model.suggestion { chip(L10n.text(suggestion.rawValue)) { model.suggestion = nil } }
                if model.minimumGB > 0 { chip(L10n.format("%@ GB+", model.minimumGB.formatted())) { model.minimumGB = 0 } }
                if model.olderDays > 0 { chip(L10n.count("Older than %lld days", model.olderDays)) { model.olderDays = 0 } }
                if !model.extensionFilter.isEmpty { chip(".\(model.extensionFilter)") { model.extensionFilter = "" } }
                Text(L10n.text(model.scope.rawValue)).foregroundStyle(.secondary)
                Button("Clear", action: model.clearFilters).buttonStyle(.plain).foregroundStyle(.teal)
            }.font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
        }
    }
    /// Highlight search readout: the map is unfiltered, so the count lives here.
    private var matchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "highlighter").foregroundStyle(Color.accentColor)
            Text(model.searchMatches.isEmpty ? L10n.format("No matches for “%@”", model.search)
                 : model.matchesTruncated ? L10n.format("%@+ matches for “%@”", SearchMode.matchCount(ExplorerViewModel.matchLimit), model.search)
                 : L10n.format("%@ matches for “%@”", SearchMode.matchCount(model.searchMatches.count), model.search))
            if !model.searchMatches.isEmpty { Text("Return shows the next one").foregroundStyle(.secondary) }
            Spacer()
            Button("Clear") { model.search = "" }.buttonStyle(.plain).foregroundStyle(.teal)
        }
        .font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("searchMatches")
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
            Button("Select", systemImage: "tray.and.arrow.down", action: addSelection).disabled(!canClean).accessibilityIdentifier("addToReview")
            Button { model.selectionIDs = [] } label: { Image(systemName: "xmark") }.help("Clear selection")
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    /// Colour-mode picker plus the mode's classes with their share of the view. Clicking
    /// a class dims every other one; geometry and filters never change.
    private var legend: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Colour by", selection: $model.colorMode) {
                    ForEach(MapColorMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
                if model.colorMode == .growth {
                    if model.historyDates.isEmpty {
                        Text("No earlier scan of this location yet")
                    } else {
                        Picker("Compare with", selection: $model.compareDate) {
                            ForEach(model.historyDates, id: \.self) { Text($0.formatted(date: .abbreviated, time: .shortened)).tag(Optional($0)) }
                        }.accessibilityIdentifier("compareWith")
                    }
                }
            } label: {
                Label(model.colorMode.title, systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Colour by").accessibilityIdentifier("mapColorMode")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.legendClasses) { tileClass in
                        Button { model.highlightedClass = model.highlightedClass == tileClass ? nil : tileClass } label: {
                            HStack(spacing: 5) {
                                Circle().fill(tileClass.color).frame(width: 7, height: 7)
                                Text(tileClass.title)
                                Text(sizeText(model.classShares[tileClass] ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .opacity(model.highlightedClass == nil || model.highlightedClass == tileClass ? 1 : 0.4)
                        }
                        .buttonStyle(.plain).help(tileClass.explanation)
                        .accessibilityAddTraits(model.highlightedClass == tileClass ? .isSelected : [])
                        .accessibilityIdentifier("legendClass." + tileClass.rawValue)
                    }
                    if model.highlightedClass != nil { Button("Show all") { model.highlightedClass = nil }.buttonStyle(.plain).foregroundStyle(.teal) }
                }
            }
            if let unreached = model.unreached {
                Toggle(isOn: $model.showUnreached) {
                    Text(L10n.format("Unreached ≈ %@", sizeText(unreached.bytes))).monospacedDigit()
                }
                .toggleStyle(.checkbox).fixedSize()
                .help("Show space the scan couldn't reach")
                .accessibilityIdentifier("legendShowUnreached")
            }
            Spacer(minLength: 4)
        }.font(.caption2).padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.colorMode)
    }
    /// Toolbar tray icon with a small badge showing the queued item count.
    private var queueBadge: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: queue.cleanup.showQueue ? "tray.full" : "tray")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? 0 : queue.selectedCount)
            if queue.selectedCount > 0 {
                Text("\(queue.selectedCount)").font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(queue.selectedCount)))
                    .padding(.horizontal, queue.selectedCount > 9 ? 3 : 0)
                    .frame(minWidth: 14, minHeight: 14).background(Circle().fill(.red))
                    .fixedSize().offset(x: 7, y: -7).accessibilityHidden(true)
            }
        }.frame(width: 30, height: 22)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: queue.selectedCount)
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.history(true) } label: { Label("Back", systemImage: "chevron.left") }.disabled(model.back.isEmpty)
            Button { model.history(false) } label: { Label("Forward", systemImage: "chevron.right") }.disabled(model.forward.isEmpty)
            Button(action: model.up) { Label("Up", systemImage: "arrow.up") }.disabled(model.breadcrumbs.count < 2).keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            SearchField(text: $model.search, mode: $model.searchMode, focused: $searchFocused, stepToNextMatch: model.stepToNextMatch)
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
                Divider()
                if model.unreached != nil {
                    Toggle("Show space the scan couldn't reach", isOn: $model.showUnreached).accessibilityIdentifier("showUnreached")
                }
                Button("Fit map") { model.fitRevision += 1 }
                Button("Scan options") { showOptions = true }
                Button("Rescan folder") { if let node = model.current { refreshFolder(node) } }.accessibilityIdentifier("rescanFolder")
                Button("Scan again", action: rescan)
            } label: { Label("Display", systemImage: "rectangle.3.group") }
            Button(action: newScan) { Label("New scan", systemImage: "folder.badge.plus") }
            Button { showQueue.wrappedValue.toggle() } label: { queueBadge }
                .help(L10n.format("Select items to delete · %lld items · %@ estimated", queue.selectedCount, sizeText(queue.selectedBytes)))
                .accessibilityIdentifier("reviewCleanup")
        }
        ToolbarItem(placement: .automatic) {
            Color.clear.frame(width: 0,height: 0).popover(isPresented: $showOptions) { ScanOptionsView(model: scan) }
        }
    }
}
