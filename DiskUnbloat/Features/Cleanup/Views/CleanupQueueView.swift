import SwiftUI
import AppKit
import DiskCore

/// The right-hand selection panel: the currently open folder's contents as a
/// size-descending, selectable listing (so the panel is useful before anything is
/// selected), plus the selected-items tree for entries elsewhere in the scan.
struct CleanupQueueView: View {
    @Bindable var model: CleanupQueueModel
    let current: FileNode?
    /// The explorer's current map selection, mirrored into the panel as a highlight.
    let selected: FileNode?
    let selectedIDs: Set<Int64>
    let canClean: Bool
    /// A quick-select recommendation is being computed.
    let selecting: Bool
    let select: (FileNode) -> Void
    let deselect: (FileNode) -> Void
    /// Tapping a row highlights the same item on the map.
    let highlight: (FileNode) -> Void
    let performCleanup: (CleanupMode) -> Void
    /// Selects one level's recommendation into the queue.
    let selectLevel: (AutoSelectionLevel) -> Void
    /// Computes one level's recommendation without touching the queue, for its warning.
    let previewLevel: (AutoSelectionLevel) async -> AutoSelectionPreview?
    /// Normalized estimates for every level, shown under the picker.
    let levelEstimates: () async -> [AutoSelectionLevel: AutoSelectionPreview]
    /// Map-intent parity for the row context menu.
    var focusFolder: (FileNode) -> Void = { _ in }
    var preview: (FileNode) -> Void = { _ in }
    var reveal: (FileNode) -> Void = { _ in }
    var refreshFolder: (FileNode) -> Void = { _ in }
    @State private var confirmDelete = false
    @State private var confirmPermanent = false
    /// The level awaiting confirmation, with its honest estimate.
    @State private var pendingLevel: (level: AutoSelectionLevel, preview: AutoSelectionPreview)?
    @State private var estimates: [AutoSelectionLevel: AutoSelectionPreview] = [:]
    /// The last chosen quick-select level, remembered per viewer.
    @AppStorage("quickSelectLevel") private var levelValue = AutoSelectionLevel.junk.rawValue
    private var level: AutoSelectionLevel { AutoSelectionLevel(rawValue: levelValue) ?? .junk }
    /// Duplicates are a separate choice in the same menu, outside the nested levels.
    @AppStorage("quickSelectDuplicates") private var duplicatesChosen = false
    /// Menu tag: a level's raw value, or 0 for duplicates.
    private var choice: Binding<Int> {
        Binding(get: { duplicatesChosen ? 0 : levelValue },
                set: { value in duplicatesChosen = value == 0; if value != 0 { levelValue = value } })
    }

    private var cleanup: CleanupViewModel { model.cleanup }
    var duplicates: DuplicatesViewModel?
    var developerTools: DeveloperToolsViewModel?

    private struct RefreshKey: Equatable { let revision: Int; let currentID: Int64? }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Divider()
                quickSelect
                Divider()
                if model.lines.isEmpty { emptyState } else { list }
                Divider()
                footer
            }
            .task(id: RefreshKey(revision: cleanup.queueRevision, currentID: current?.id)) {
                await model.refresh(current: current)
                // Cached per index revision, so this is free unless the scan changed.
                estimates = await levelEstimates()
            }
            .onChange(of: selectedIDs) { _, ids in
                // Mirror the map selection into the panel: expand the folder chain so the
                // row exists, then bring it into view.
                guard let node = selected, ids.contains(node.id) else { return }
                Task {
                    await model.revealForSelection(node)
                    try? await Task.sleep(for: .milliseconds(30))
                    proxy.scrollTo("item-\(node.id)", anchor: .center)
                }
            }
            .confirmationDialog(L10n.text("Delete selected items?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { performCleanup(.trash) }
                Button("Delete permanently…", role: .destructive) { confirmPermanent = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(L10n.format(
                    "%lld items · %@ estimated. Folders include their contents. Scanned folders are emptied but kept. If a location does not support Trash, that item will stay in place. Cache removal can disrupt applications; cloud deletion may sync to other devices.",
                    cleanup.basket.count, sizeText(cleanup.estimatedBytes)))
            }
            .alert(L10n.text("Permanently delete these items?"), isPresented: $confirmPermanent) {
                Button("Delete permanently", role: .destructive) { performCleanup(.permanent) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(L10n.text("This immediately removes the selected items and all contents of selected folders. Scanned folders stay in place but are emptied. This cannot be undone. Files will not be moved to Trash."))
            }
            .alert(pendingLevel.map { Self.confirmationTitle($0.level) } ?? "", isPresented: Binding(
                get: { pendingLevel != nil },
                set: { if !$0 { pendingLevel = nil } })) {
                Button(L10n.text("Select anyway")) {
                    if let level = pendingLevel?.level { selectLevel(level) }
                    pendingLevel = nil
                }
                Button(L10n.text("Cancel"), role: .cancel) { pendingLevel = nil }
            } message: {
                if let pending = pendingLevel {
                    Text(Self.confirmationMessage(pending.level, pending.preview))
                }
            }
            .accessibilityIdentifier("cleanupQueue")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Select items to delete").font(.headline)
                Text(L10n.count("%lld items", cleanup.basket.count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.regular).tint(.teal)
                    Text("Updating the list…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                cleanup.clearSelection()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(cleanup.basket.isEmpty || cleanup.cleaning)
            .help(L10n.text("Clear selection"))
            .accessibilityLabel(L10n.text("Clear selection"))
            .accessibilityIdentifier("queueClearSelection")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Nested quick selection: each level adds to the previous one. Junk selects at once;
    /// every broader level first shows a warning with its honest estimate.
    private var quickSelect: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.text("Quick select"), selection: choice) {
                ForEach(AutoSelectionLevel.allCases) { level in
                    Text(Self.title(level)).tag(level.rawValue)
                }
                if duplicates != nil {
                    Divider()
                    Text(L10n.text("Duplicate files")).tag(0)
                }
            }
            // A menu picker has no width floor: four segmented labels (longer still in
            // Russian) forced the inspector past its maximum and pushed the map out.
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("selectionLevel")
            if duplicatesChosen, let duplicates {
                DuplicatesSection(model: duplicates, canClean: canClean && !cleanup.cleaning && !selecting)
            } else {
            Text(Self.subtitle(level))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    choose(level)
                } label: {
                    Text(L10n.text("Select")).frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent).tint(.teal)
                .disabled(!canClean || cleanup.cleaning || selecting)
                .accessibilityIdentifier("selectLevelItems")
                if selecting {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Selecting…")).font(.caption).foregroundStyle(.secondary)
                } else if let estimate = estimates[level] {
                    Text(estimate.items == 0
                         ? L10n.text("Nothing recommended in this scan.")
                         : L10n.count("%lld items", estimate.items) + " · " + L10n.format("%@ estimated", sizeText(estimate.knownBytes)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("selectionLevelEstimate")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let developerTools {
                Button { Task { await developerTools.open() } } label: {
                    Label(L10n.text("Developer tools…"), systemImage: "hammer")
                }
                .buttonStyle(.borderless).font(.caption)
                .accessibilityIdentifier("openDeveloperTools")
                .sheet(isPresented: Binding(get: { developerTools.showSheet }, set: { developerTools.showSheet = $0 })) {
                    DeveloperToolsSheet(model: developerTools)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)

    }

    private func choose(_ level: AutoSelectionLevel) {
        guard level > .junk else { selectLevel(level); return }
        Task {
            if let preview = await previewLevel(level) { pendingLevel = (level, preview) }
        }
    }

    static func title(_ level: AutoSelectionLevel) -> String {
        switch level {
        case .junk: L10n.text("Junk")
        case .caches: L10n.text("Caches")
        case .rebuildable: L10n.text("Rebuildable")
        case .deep: L10n.text("Deep clean")
        }
    }

    static func subtitle(_ level: AutoSelectionLevel) -> String {
        switch level {
        case .junk: L10n.text("Old versions, build data, and curated caches that are safe to delete.")
        case .caches: L10n.text("Adds every application cache and package-manager store.")
        case .rebuildable: L10n.text("Adds current simulator and device data, local models, and project folders like node_modules that can be rebuilt or downloaded again.")
        case .deep: L10n.text("Adds settings left by older app versions and long-unused installer files. Review carefully.")
        }
    }

    static func confirmationTitle(_ level: AutoSelectionLevel) -> String {
        switch level {
        case .junk, .caches: L10n.text("Select all caches?")
        case .rebuildable: L10n.text("Select everything rebuildable?")
        case .deep: L10n.text("Select a deep clean?")
        }
    }

    static func confirmationMessage(_ level: AutoSelectionLevel, _ preview: AutoSelectionPreview) -> String {
        switch level {
        case .junk, .caches:
            L10n.format("This selects %lld items (%@ estimated): junk plus every application cache and package-manager store. Apps may sign you out, lose offline data, or rebuild their indexes, and package managers download again. Review the selection before deleting.", preview.items, sizeText(preview.knownBytes))
        case .rebuildable:
            L10n.format("This selects an extensive cleanup: %lld items (%@ estimated), including live caches, simulator and device data, and rebuildable folders. Removing them can interrupt running apps and developer tools, force re-downloads and rebuilds, and some content can only be restored by re-downloading it. Review the selection before deleting.", preview.items, sizeText(preview.knownBytes))
        case .deep:
            L10n.format("This selects the deepest cleanup: %lld items (%@ estimated) — everything rebuildable plus settings folders of older app versions and long-unused installer files. An older version opened again starts with default settings, and installers must be downloaded again. Review every item before deleting.", preview.items, sizeText(preview.knownBytes))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing selected",
            systemImage: "tray",
            description: Text("Select a folder or file on the map to add it here."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.lines) { line in
                    switch line {
                    case .directoryHeader(let node): directoryHeader(node)
                    case .item(let row): itemRow(row)
                    case .more(let node, let depth, let count): moreRow(node, depth: depth, count: count)
                    case .showMore(let node, let depth): showMoreRow(node, depth: depth)
                    }
                }
                if !cleanup.results.isEmpty { resultsSection }
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func directoryHeader(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Current folder").font(.caption).foregroundStyle(.secondary)
            Text(node.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .help(node.path)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 2).padding(.bottom, 5)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queueFolderHeader")
    }

    private func itemRow(_ row: CleanupQueueRow) -> some View {
        let highlighted = selectedIDs.contains(row.node.id)
        return HStack(spacing: 7) {
            if row.hasSelectedDescendants || row.canPeek {
                let expanded = row.coversAllChildren
                    ? model.coveredExpanded.contains(row.node.path)
                    : (row.hasSelectedDescendants ? !model.collapsed.contains(row.node.path) : model.isPeeked(row.node))
                Button {
                    if row.coversAllChildren { model.toggleCoveredExpanded(row.node) }
                    else if row.hasSelectedDescendants { model.toggleCollapsed(row.node) }
                    else { model.togglePeek(row.node) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .help(L10n.text(expanded ? "Collapse" : "Expand"))
                .accessibilityIdentifier("queueChevron")
            } else {
                Color.clear.frame(width: 20, height: 20)
            }
            checkbox(row)
            Image(systemName: row.node.isSymbolicLink ? "link" : row.node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(row.node.isDirectory ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.node.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.node.path)
                if row.keepsFolder {
                    Text("Keeps folder").font(.caption2).foregroundStyle(.teal)
                }
            }
            Spacer(minLength: 8)
            Text(queueRowSizeText(selected: row.bytes, total: row.totalBytes))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(row.depth) * 14)
        .background(highlighted ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { highlight(row.node) }
        .contextMenu { rowMenu(row) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.name)
        .accessibilityValue(checkStateText(row.checkState))
        .accessibilityIdentifier("queueRow")
    }

    /// Row context menu, matching the map's: navigate and inspect the item, or change
    /// its place in the selection.
    @ViewBuilder private func rowMenu(_ row: CleanupQueueRow) -> some View {
        let node = row.node
        if node.isDirectory {
            Button("Focus folder", systemImage: "arrow.up.left.and.arrow.down.right") { focusFolder(node) }
        }
        if node.isDirectory && !node.isSymbolicLink {
            Button("Rescan folder", systemImage: "arrow.clockwise") { refreshFolder(node) }
        }
        Button("Quick Look", systemImage: "eye") { preview(node) }
        Button("Reveal in Finder", systemImage: "arrow.up.forward.square") { reveal(node) }
        Button("Copy path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
        Divider()
        if row.checkState == .checked {
            Button("Deselect", systemImage: "tray") { deselect(node) }.disabled(!canClean || cleanup.cleaning)
        } else {
            Button("Select", systemImage: "tray.and.arrow.down") { select(node) }.disabled(!canClean || cleanup.cleaning)
        }
    }

    private func checkbox(_ row: CleanupQueueRow) -> some View {
        Button {
            switch row.checkState {
            case .checked: deselect(row.node)
            case .partial, .unchecked: select(row.node)
            }
        } label: {
            Image(systemName: row.checkState == .checked ? "checkmark.square.fill" : row.checkState == .partial ? "minus.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(row.checkState == .unchecked ? Color.secondary : Color.accentColor)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(!canClean || cleanup.cleaning)
        .accessibilityLabel(Text(row.node.name))
        .accessibilityValue(checkStateText(row.checkState))
        .accessibilityAddTraits(row.checkState == .unchecked ? [] : .isSelected)
        .accessibilityIdentifier("queueCheckbox")
    }

    private func moreRow(_ node: FileNode, depth: Int, count: Int) -> some View {
        Button {
            model.toggleRevealed(node)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.teal)
                    .frame(width: 16, height: 16)
                Text(L10n.count("%lld more items", count)).font(.caption).foregroundStyle(.teal)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth + 1) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("Show unselected items in this folder"))
        .accessibilityIdentifier("queueExpand")
    }

    private func showMoreRow(_ node: FileNode, depth: Int) -> some View {
        Button {
            Task { await model.loadMore(of: node) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.compact.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                Text("Show more items").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("queueShowMore")
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 6)
            Text("Last operation").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(cleanup.results) { result in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(result.succeeded ? .teal : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: result.path).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(L10n.text(result.message)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }.padding(.horizontal, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected for deletion").font(.caption).foregroundStyle(.secondary)
                    Text(sizeText(cleanup.estimatedBytes))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    if cleanup.hasUnknownSizes {
                        Text("Some selected sizes are unknown.").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .buttonStyle(.glassProminent)
                .disabled(!canClean || cleanup.basket.isEmpty || cleanup.cleaning)
                .accessibilityIdentifier("queueDeleteSelected")
            }
            if cleanup.cleaning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cleaning…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func checkStateText(_ state: CleanupQueueCheckState) -> String {
        switch state {
        case .checked: L10n.text("Selected for deletion")
        case .partial: L10n.text("Partly selected")
        case .unchecked: L10n.text("Not selected")
        }
    }
}

/// Duplicate discovery stays in the queue panel. A finished search opens the review.
private struct DuplicatesSection: View {
    let model: DuplicatesViewModel
    let canClean: Bool
    @FocusState private var reviewFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finds files with identical contents by reading them. Your own files only: nothing in Library, app bundles or protected folders.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch model.state {
            case .idle, .failed:
                findButton
                if case .failed(let reason) = model.state {
                    Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            case .searching(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let total = progress.total, total > 0 {
                            ProgressView(value: Double(progress.completed), total: Double(total))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel", action: model.cancel)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("cancelDuplicates")
                    }
                    Text(progress.stage == .verifyingFolders ? L10n.text("Verifying matching folders…") : L10n.text("Comparing files…"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let total = progress.total, total > 0, progress.stage == .comparingFiles {
                        Text(L10n.format("%@ of %@ files", progress.completed.formatted(), total.formatted()))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            case .found:
                HStack(spacing: 8) {
                    Button("Review duplicates", action: model.reopenReview)
                        .buttonStyle(.borderedProminent).tint(.teal).disabled(!canClean)
                        .focused($reviewFocused)
                        .accessibilityIdentifier("selectDuplicates")
                    Spacer(minLength: 0)
                    findButton
                }
                if model.groups.isEmpty {
                    Text("No duplicates found.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("duplicatesEstimate")
                } else {
                    Text(L10n.count("%lld matches", model.groups.count))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("duplicatesEstimate")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicatesSection")
        .onChange(of: model.presentation?.id) { previous, current in
            if previous != nil, current == nil { reviewFocused = true }
        }
    }

    private var findButton: some View {
        Button(action: model.find) {
            if model.search == nil {
                Text("Find duplicates")
            } else {
                Label("Find again", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
        }
        .disabled(!canClean)
        .accessibilityIdentifier("findDuplicates")
    }
}
