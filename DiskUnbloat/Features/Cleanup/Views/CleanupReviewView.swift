import SwiftUI
import DiskCore

struct CleanupReviewView: View {
    @Bindable var model: CleanupViewModel
    let canClean: Bool
    let performCleanup: (CleanupMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmTrash = false
    @State private var confirmPermanent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Deletion queue").font(.title2.bold())
                    Text(L10n.format("%lld items · %@ estimated", model.basket.count, sizeText(model.basket.reduce(0) { $0 + $1.displaySize }))).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "tray.full").font(.largeTitle).foregroundStyle(.teal)
            }
            Text("Review every path. Folders include their contents. Cache removal can disrupt applications; cloud deletion may sync to other devices. Actual recovered space may differ.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.basket) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(node.name).fontWeight(.medium); Text(node.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer()
                        Text(sizeText(node.allocatedSize)).foregroundStyle(.secondary)
                        Button { model.removeFromBasket(node) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Remove from queue").disabled(model.cleaning)
                    }.padding(.vertical, 4)
                }
                if !model.results.isEmpty {
                    Section("Last operation") {
                        ForEach(model.results) { result in
                            Label { VStack(alignment: .leading) { Text(URL(fileURLWithPath: result.path).lastPathComponent); Text(L10n.text(result.message)).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(result.succeeded ? .teal : .orange) }
                        }
                    }
                }
            }.listStyle(.inset)
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.cleaning)
                Spacer()
                if model.cleaning { ProgressView().controlSize(.small) }
                Button("Delete permanently…", role: .destructive) { confirmPermanent = true }.disabled(!canClean || model.basket.isEmpty).accessibilityIdentifier("permanentDelete")
                Button("Move to Trash…", systemImage: "trash") { confirmTrash = true }.buttonStyle(.glassProminent).disabled(!canClean || model.basket.isEmpty).accessibilityIdentifier("moveToTrash")
            }
        }.padding(26).frame(width: 760, height: 540)
        .confirmationDialog("Move the reviewed items to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performCleanup(.trash) }
        } message: { Text("If a location does not support Trash, that item will be left in place. Restore trashed files using Finder.") }
        .alert("Permanently delete these items?", isPresented: $confirmPermanent) {
            Button("Delete permanently", role: .destructive) { performCleanup(.permanent) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This immediately removes \(model.basket.count) selections and all contents of selected folders. This cannot be undone. Files will not be moved to Trash.") }
    }
}
