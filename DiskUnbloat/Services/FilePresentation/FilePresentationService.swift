import AppKit
import DiskCore

@MainActor protocol FilePresenting {
    func reveal(_ node: FileNode)
    /// Opens the Trash in Finder so the user can review and empty it themselves.
    func openTrash()
}

@MainActor struct FilePresentationService: FilePresenting {
    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
    func openTrash() {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        NSWorkspace.shared.open(trash)
    }
}
