import SwiftUI
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
    /// Selects one tier's recommendation into the queue.
    let selectTier: (AutoSelectionTier) -> Void
    /// Computes one tier's recommendation without touching the queue, for the tier-2 warning.
    let previewTier: (AutoSelectionTier) async -> AutoSelectionPreview?
    @State private var confirmDelete = false
    @State private var confirmPermanent = false
    @State private var regenerablePreview: AutoSelectionPreview?

    private var cleanup: CleanupViewModel { model.cleanup }

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
            .alert(L10n.text("Select everything rebuildable?"), isPresented: Binding(
                get: { regenerablePreview != nil },
                set: { if !$0 { regenerablePreview = nil } })) {
                Button(L10n.text("Select anyway")) {
                    regenerablePreview = nil
                    selectTier(.regenerable)
                }
                Button(L10n.text("Cancel"), role: .cancel) { regenerablePreview = nil }
            } message: {
                if let preview = regenerablePreview {
                    Text(L10n.format(
                        "This selects an extensive cleanup: %lld items (%@ estimated), including live caches, simulator and device data, and rebuildable folders. Removing them can interrupt running apps and developer tools, force re-downloads and rebuilds, and some content can only be restored by re-downloading it. Review the selection before deleting.",
                        preview.items, sizeText(preview.knownBytes)))
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
            if model.isLoading { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Two-tier quick selection: safe junk first, rebuildable content behind a warning.
    private var quickSelect: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                selectTier(.safe)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Select safe items")).font(.callout.weight(.medium))
                    Text(L10n.text("Selects caches, old build data, and other junk that is safe to delete."))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(!canClean || cleanup.cleaning || selecting)
            .accessibilityIdentifier("selectSafeItems")
            Button {
                Task {
                    if let preview = await previewTier(.regenerable) { regenerablePreview = preview }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Select rebuildable items")).font(.callout.weight(.medium))
                    Text(L10n.text("Selects caches, simulator and device data, and rebuildable folders you can restore or rebuild."))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(!canClean || cleanup.cleaning || selecting)
            .accessibilityIdentifier("selectRebuildableItems")
            if selecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Selecting…")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
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
                let expanded = row.hasSelectedDescendants ? !model.collapsed.contains(row.node.path) : model.isPeeked(row.node)
                Button {
                    if row.hasSelectedDescendants { model.toggleCollapsed(row.node) }
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
            Text(sizeText(row.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(row.depth) * 14)
        .background(highlighted ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { highlight(row.node) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.node.name)
        .accessibilityValue(checkStateText(row.checkState))
        .accessibilityIdentifier("queueRow")
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
