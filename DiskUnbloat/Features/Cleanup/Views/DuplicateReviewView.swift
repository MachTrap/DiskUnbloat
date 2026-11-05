import AppKit
import DiskCore
import SwiftUI

struct DuplicateReviewView: View {
    @Bindable var model: DuplicatesViewModel
    let reveal: (FileNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            results
                .disabled(model.confirming)
            Divider()
            footer
        }
        .frame(minWidth: 710, idealWidth: 880, minHeight: 450, idealHeight: 600)
        .interactiveDismissDisabled(model.confirming)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicateReview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review duplicates").font(.title2.bold())
            Text("File search starts at 1 MiB. Matching folders can include smaller files.")
                .font(.callout).foregroundStyle(.secondary)
            if let search = model.search {
                if search.unreadable > 0 {
                    Text(L10n.count("%lld files could not be compared because they were unreadable or changed.", search.unreadable))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if search.folderLimitExceeded {
                    Text("Some large folders exceeded the comparison limit. Their file matches are listed separately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { searchField; kindPicker; supportToggle }
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    HStack { kindPicker; supportToggle }
                }
            }
            .disabled(model.confirming)
        }
        .padding(18)
    }

    private var searchField: some View {
        TextField("Search names or paths", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 130)
            .disabled(model.filter == .selected)
            .accessibilityIdentifier("duplicateReviewSearch")
    }

    private var kindPicker: some View {
        Picker("Show", selection: $model.filter) {
            ForEach(DuplicateReviewFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("duplicateReviewKind")
    }

    private var supportToggle: some View {
        Toggle("Hide generated and support items", isOn: $model.hideSupport)
            .fixedSize()
            .disabled(model.filter == .selected)
            .accessibilityIdentifier("duplicateReviewHideSupport")
    }

    @ViewBuilder private var results: some View {
        if model.groups.isEmpty {
            ContentUnavailableView("No duplicates found.", systemImage: "document.on.document",
                                   description: Text("The current scan locations were compared."))
                .safeAreaInset(edge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.scopePaths, id: \.self) { path in
                                Text(verbatim: path).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxHeight: 80)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
        } else if model.visibleGroups.isEmpty {
            if model.filter == .selected {
                ContentUnavailableView("No copies selected", systemImage: "checkmark.square")
            } else {
                ContentUnavailableView("No matches for these filters", systemImage: "line.3.horizontal.decrease")
            }
        } else {
            HSplitView {
                List(selection: $model.focusedGroupID) {
                    ForEach(model.visibleGroups) { group in
                        DuplicateMatchRow(group: group)
                            .tag(group.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 190, idealWidth: 235, maxWidth: 285)
                if let group = model.focusedGroup {
                    comparison(for: group)
                        .frame(minWidth: 365)
                        .id(group.id)
                }
            }
        }
    }

    private func comparison(for group: DuplicateReviewGroup) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(group.title).font(.headline).textSelection(.enabled)
                if !group.commonParent.isEmpty {
                    Label {
                        Text(verbatim: group.commonParent)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(group.commonParent)
                }
                if group.isFolder {
                    Text("Only verified files will be added to the queue. The folder structure stays.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(group.relatedFolderIDs, id: \.self) { id in
                    if let folder = model.groups.first(where: { $0.id == id }) {
                        Button(L10n.format("Compare matching folders for %@", folder.title)) { model.focus(folder) }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("duplicateReviewRelatedFolder")
                    }
                }
                Picker(L10n.text("Keep"), selection: $model.strategy) {
                    ForEach(DuplicateKeepStrategy.allCases) { strategy in
                        Text(strategy.reviewTitle).tag(strategy)
                    }
                }
                .accessibilityIdentifier("duplicateStrategy")
                ForEach(model.displayedCopies(in: group)) { copy in
                    DuplicateReviewCopyRow(
                        group: group, copy: copy, keeper: model.keeper(in: group),
                        isChecked: model.isChecked(copy, in: group), canCheck: model.canCheck(copy, in: group),
                        setChecked: { model.setChecked($0, node: copy, in: group) },
                        chooseKeeper: { model.chooseKeeper(copy, in: group) },
                        reveal: { reveal(copy) }
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.refusals.isEmpty {
                Text("Review the copies that could not be added.").font(.callout.bold())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.refusals) { refusal in
                            if !refusal.path.isEmpty { Text(verbatim: refusal.path).textSelection(.enabled) }
                            Text(refusal.reason).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 78)
                .font(.caption)
                .accessibilityIdentifier("duplicateReviewRefusals")
            }
            HStack(spacing: 10) {
                Button("Select visible copies", action: model.selectVisible)
                    .disabled(model.visibleGroups.isEmpty || model.filter == .selected || model.confirming)
                    .accessibilityIdentifier("duplicateReviewSelectVisible")
                Button("Clear visible", action: model.clearVisible)
                    .disabled(model.selectedCount == 0 || model.confirming)
                    .accessibilityIdentifier("duplicateReviewClearVisible")
                Spacer()
                Text(L10n.count("%lld files selected", model.selectedCount))
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("duplicateReviewSelectedSummary")
                Text(L10n.format("%@ estimated", sizeText(model.selectedBytes))).font(.callout).foregroundStyle(.secondary)
            }
            if model.hiddenSelectedCount > 0 {
                Text(L10n.count("%lld selected files are hidden by filters.", model.hiddenSelectedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.hasUnknownSizes {
                Text("The estimate includes known sizes only.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Files moved to Trash occupy space until you empty it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.confirming { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: model.dismissReview)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.confirming)
                    .accessibilityIdentifier("duplicateReviewCancel")
                Button("Add selected copies to cleanup queue", action: model.confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirm)
                    .accessibilityIdentifier("duplicateReviewConfirm")
            }
        }
        .padding(16)
    }
}

private struct DuplicateMatchRow: View {
    let group: DuplicateReviewGroup

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).lineLimit(1)
                Text(L10n.count("%lld copies", group.copies.count))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: pathPreview).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } icon: {
            Image(systemName: group.isFolder ? "folder.on.folder" : "document.on.document")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("duplicateReviewGroup")
    }

    private var pathPreview: String {
        group.copies.prefix(2).map {
            let differing = group.differingPath(of: $0)
            if group.isFolder { return differing }
            let parent = (differing as NSString).deletingLastPathComponent
            return parent.isEmpty ? differing : parent
        }.joined(separator: "  ·  ")
    }
}

private struct DuplicateReviewCopyRow: View {
    private struct FilePair: Identifiable {
        let candidate: FileNode
        let keeper: FileNode
        var id: Int64 { candidate.id }
    }

    let group: DuplicateReviewGroup
    let copy: FileNode
    let keeper: FileNode
    let isChecked: Bool
    let canCheck: Bool
    let setChecked: (Bool) -> Void
    let chooseKeeper: () -> Void
    let reveal: () -> Void
    @State private var expanded = false

    private var isKeeper: Bool { copy.id == keeper.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { isChecked }, set: setChecked)) {
                    Text(verbatim: copy.name).font(.callout.bold())
                }
                .toggleStyle(.checkbox)
                .disabled(!canCheck && !isChecked)
                .accessibilityLabel(L10n.format("Queue copy at %@", copy.path))
                .accessibilityIdentifier("duplicateReviewCopy")
                Spacer(minLength: 8)
                if isKeeper {
                    Label("Kept copy", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Keep this copy", action: chooseKeeper)
                        .accessibilityLabel(L10n.format("Keep copy at %@", copy.path))
                        .accessibilityIdentifier("duplicateReviewKeeper")
                }
                Menu {
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy.path, forType: .string)
                    }
                    Button("Reveal in Finder", action: reveal)
                } label: {
                    Label("Path actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("duplicateReviewPathActions")
            }
            Text(verbatim: group.differingPath(of: copy))
                .font(.caption.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .help(copy.path)
                .accessibilityLabel(Text(verbatim: copy.path))
            HStack {
                if let modified = copy.modified {
                    Text(modified, format: .dateTime.year().month().day())
                } else {
                    Text("Modification date unknown")
                }
                Text(verbatim: "·").accessibilityHidden(true)
                Text(verbatim: sizeText(group.allocatedBytes(in: copy)))
                if group.isFolder {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(L10n.count("%lld verified files", group.fileCount))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if group.support[copy.id] == .all {
                Text("Tagged by a cleanup recommendation").font(.caption).foregroundStyle(.secondary)
            }
            if group.support[copy.id] == .mixed {
                Text("Contains both tagged and untagged files").font(.caption).foregroundStyle(.secondary)
            }
            if group.isFolder, !isKeeper {
                DisclosureGroup("Compare verified file paths", isExpanded: $expanded) {
                    if expanded {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(filePairs) { pair in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.format("Queue %@", pair.candidate.path))
                                    Text(L10n.format("Keep %@", pair.keeper.path)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                    }
                }
                .accessibilityIdentifier("duplicateReviewFilePairs")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
    }

    private var filePairs: [FilePair] {
        zip(group.files(in: copy), group.files(in: keeper)).map { FilePair(candidate: $0, keeper: $1) }
    }

}

extension DuplicateKeepStrategy {
    var reviewTitle: String {
        switch self {
        case .oldest: L10n.text("Keep the oldest copy")
        case .newest: L10n.text("Keep the newest copy")
        case .shortestPath: L10n.text("Keep the copy with the shortest path")
        }
    }
}
