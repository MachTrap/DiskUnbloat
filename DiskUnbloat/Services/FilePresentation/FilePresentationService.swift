import AppKit
import DiskCore

@MainActor protocol FilePresenting {
    func reveal(_ node: FileNode)
}

@MainActor struct FilePresentationService: FilePresenting {
    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
}
