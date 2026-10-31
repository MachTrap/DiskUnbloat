import SwiftUI
import DiskCore

struct FileInspector: View {
    @Bindable var model: ExplorerViewModel
    let roots: [URL]
    let canClean: Bool
    let preview: (FileNode) -> Void
    let reveal: (FileNode) -> Void
    let addToBasket: (FileNode) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.selectionIDs.count > 1 {
                    Image(systemName: "square.stack").font(.system(size: 44,weight: .light)).foregroundStyle(.teal)
                    Text("\(model.selectionIDs.count) selected").font(.title2.bold())
                    detail("Known size", sizeText(model.selectionBytes))
                    Text("Overlapping folder and file selections are counted once. Review paths before removing anything.").font(.caption).foregroundStyle(.secondary)
                    Button("Add selections to deletion queue", systemImage: "tray.and.arrow.down") { model.normalizedSelection.forEach(addToBasket) }.disabled(!canClean)
                    ForEach(Array(model.normalizedSelection.prefix(20))) { node in Text(node.name).font(.caption).lineLimit(1) }
                } else if let node = model.selected {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 48)).foregroundStyle(.teal.gradient).padding(.top, 12)
                    Text(node.name).font(.title2.bold()).textSelection(.enabled)
                    Text(L10n.text(node.isSymbolicLink ? "Symbolic link · not followed" : node.isPackage ? "Package" : node.isDirectory ? "Folder" : "File")).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    detail(node.allocatedSize == nil ? "Known on disk · incomplete" : "On disk", sizeText(node.allocatedSize ?? node.knownAllocatedSize))
                    detail("Logical size", sizeText(node.logicalSize))
                    if let date = node.modified { detail("Last modified", date.formatted(date: .abbreviated, time: .shortened)) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Location").font(.caption).foregroundStyle(.secondary)
                        Text(node.path).font(.callout).textSelection(.enabled).lineLimit(nil)
                    }
                    if let home = model.homePath, let known = LocationCatalog(home: URL(fileURLWithPath: home)).knownLocation(for: node.path) {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(known.title).font(.headline)
                            Text(known.explanation).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Divider()
                    Button("Quick Look", systemImage: "eye") { preview(node) }
                    Button("Reveal in Finder", systemImage: "arrow.up.forward.square") { reveal(node) }
                    if model.canNavigate(node) { Button("Explore folder", systemImage: "folder") { model.navigate(node) } }
                    if !roots.isEmpty, let reason = CleanupSafety.blockedReason(node, roots: roots, exemptingCacheRoots: CleanupRule.knownCacheRoots(home: model.homePath ?? "")) {
                        Label(L10n.text(reason), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Add to deletion queue", systemImage: "tray.and.arrow.down") { addToBasket(node) }
                            .buttonStyle(.glass).disabled(!canClean).accessibilityIdentifier("addToReview")
                    }
                } else {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary).padding(.top, 28)
                    Text("Every byte has a story.").font(.title3.weight(.medium))
                    Text("Select a tile or file to see its size, location, and available actions.").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                Label("Sizes are estimates", systemImage: "info.circle").font(.caption.bold())
                Text("Hard links are counted once within the scanned scope. APFS shared blocks, snapshots, and purgeable storage mean file sizes do not predict exactly how much free space cleanup will recover. Unknown metadata and inaccessible folders can make totals incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(L10n.text(label)).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).monospacedDigit() }
    }
}
