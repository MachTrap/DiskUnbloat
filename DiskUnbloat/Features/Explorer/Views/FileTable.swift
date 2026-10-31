import SwiftUI
import DiskCore

struct FileTable: View {
    @Bindable var model: ExplorerViewModel
    let canClean: Bool
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let addToBasket: (FileNode) -> Void
    var refreshFolder: (FileNode) -> Void = { _ in }
    var body: some View {
        Table(model.rows, selection: $model.selectionIDs) {
            TableColumn("Name") { node in
                Label(node.name, systemImage: node.isSymbolicLink ? "link" : node.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .primary)
                    .lineLimit(1).help(node.path)
            }.width(min: 180, ideal: 300)
            TableColumn("Size") { node in Text(sizeText(node.size(for: model.metric))).monospacedDigit().foregroundStyle(.secondary) }.width(90)
            TableColumn("Modified") { node in
                if let date = node.modified { Text(date, format: .dateTime.year().month(.abbreviated).day()).foregroundStyle(.secondary) }
                else { Text("Unknown").foregroundStyle(.secondary) }
            }.width(110)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let node = model.rows.first(where: { $0.id == id }) {
                Button("Open Folder") { model.navigate(node) }.disabled(!model.canNavigate(node))
                if ids.count == 1 && node.isDirectory && !node.isSymbolicLink { Button("Rescan folder") { refreshFolder(node) } }
                Button("Quick Look") { preview(node) }
                Button("Reveal in Finder") { reveal(node) }
                Divider()
                Button("Add to Cleanup Review") { addToBasket(node) }.disabled(!canClean)
            }
        } primaryAction: { ids in
            if let id = ids.first, let node = model.rows.first(where: { $0.id == id }) {
                if model.canNavigate(node) { model.navigate(node) } else { preview(node) }
            }
        }
        .onKeyPress(.return) {
            guard let node = model.selected else { return .ignored }
            if model.canNavigate(node) { model.navigate(node) } else { preview(node) }; return .handled
        }
        .onKeyPress(.space) { guard let node = model.selected else { return .ignored }; preview(node); return .handled }
        .accessibilityIdentifier("fileTable")
    }
}
