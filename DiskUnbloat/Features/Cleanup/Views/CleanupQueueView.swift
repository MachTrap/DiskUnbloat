import SwiftUI
import DiskCore

/// The right-hand cleanup queue: selected folders and files as a compact tree, their
/// estimated size, and the reviewed deletion action. Opens automatically after a
/// completed scan and stays available from the explorer toolbar.
struct CleanupQueueView: View {
    @Bindable var model: CleanupQueueModel
    let canClean: Bool
    let select: (FileNode) -> Void
    let deselect: (FileNode) -> Void
    let performCleanup: (CleanupMode) -> Void
    @State private var confirmDelete = false
    @State private var confirmPermanent = false

    private var cleanup: CleanupViewModel { model.cleanup }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.lines.isEmpty { emptyState } else { list }
            Divider()
            footer
        }
        .task(id: cleanup.queueRevision) { await model.refresh() }
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
        .accessibilityIdentifier("cleanupQueue")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup queue").font(.headline)
                Text(L10n.count("%lld items", cleanup.basket.count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
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
                    case .item(let row): itemRow(row)
                    case .more(let node, let depth, let count): moreRow(node, depth: depth, count: count)
                    case .showMore(let node, let depth): showMoreRow(node, depth: depth)
                    }
                }
                if !cleanup.results.isEmpty { resultsSection }
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    private func itemRow(_ row: CleanupQueueRow) -> some View {
        HStack(spacing: 7) {
            if row.hasSelectedDescendants {
                Button {
                    model.toggleCollapsed(row.node)
                } label: {
                    Image(systemName: model.collapsed.contains(row.node.path) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }.buttonStyle(.plain)
                .help(L10n.text(model.collapsed.contains(row.node.path) ? "Expand" : "Collapse"))
                .accessibilityIdentifier("queueChevron")
            } else {
                Color.clear.frame(width: 12, height: 12)
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
        .background(.background.opacity(0.001))
        .contentShape(Rectangle())
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
            .padding(.leading, CGFloat(depth + 1) * 14)
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
