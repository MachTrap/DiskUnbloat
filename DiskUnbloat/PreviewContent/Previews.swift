import SwiftUI
import DiskCore

#Preview("Choose location") { WorkspaceView(model: WorkspaceViewModel()).frame(width: 1100,height: 760) }
#Preview("Scan animation") { ScanningView(model: ScanViewModel(coordinator: ScanCoordinator()), preparing: false, cancel: {}, issues: {}).frame(width: 1100,height: 760) }

#Preview("Compact scanning") { ScanningView(model: ScanViewModel(coordinator: ScanCoordinator()), preparing: true, cancel: {}, issues: {}).frame(width: 960,height: 640) }
#Preview("Nested map · light") {
    TreemapView(scene: PreviewMap.scene, selection: [], style: MapTileStyle(), fitRevision: 0, select: { _,_ in }, open: { _ in }, aggregate: { _ in }, preview: { _ in }, reveal: { _ in }, selectForCleanup: { _ in }, deselectFromCleanup: { _ in }, queuedPaths: [], canClean: true)
        .frame(width: 960,height: 560).padding(16).preferredColorScheme(.light)
}
private enum PreviewMap {
    static var scene: MapScene {
        let folder = FileNode(id: 2,parentID: 1,path: "/Demo/Creative",name: "Creative",isDirectory: true,logicalSize: 14000000,allocatedSize: 14000000,modified: nil,identity: "2")
        let video = FileNode(id: 3,parentID: 2,path: "/Demo/Creative/Film.mov",name: "Film.mov",isDirectory: false,logicalSize: 8000000,allocatedSize: 8000000,modified: nil,identity: "3")
        let archive = FileNode(id: 4,parentID: 2,path: "/Demo/Creative/Assets.zip",name: "Assets.zip",isDirectory: false,logicalSize: 6000000,allocatedSize: 6000000,modified: nil,identity: "4")
        return MapScene(rootID: 1,entries: [
            MapEntry(id: 2,parentID: 1,ownerID: 1,kind: .folder,node: folder,bytes: 14000000),
            MapEntry(id: 3,parentID: 2,ownerID: 2,kind: .file,node: video,bytes: 8000000),
            MapEntry(id: 4,parentID: 2,ownerID: 2,kind: .file,node: archive,bytes: 6000000)
        ],summary: SizeSummary(knownBytes: 14000000,itemCount: 1))
    }
}

@MainActor private func previewQueueModel() -> CleanupQueueModel {
    let cleanup = CleanupViewModel(service: CleanupService())
    cleanup.basket = [
        CleanupEntry(node: PreviewMap.scene.entries[0].node!, operation: .remove),
        CleanupEntry(node: PreviewMap.scene.entries[2].node!, operation: .remove)
    ]
    return CleanupQueueModel(cleanup: cleanup)
}

#Preview("Cleanup queue") {
    CleanupQueueView(model: previewQueueModel(), current: nil, selected: nil, selectedIDs: [], canClean: true, selecting: false, select: { _ in }, deselect: { _ in }, highlight: { _ in }, performCleanup: { _ in }, selectLevel: { _ in }, previewLevel: { _ in nil }, levelEstimates: { [:] })
        .frame(width: 340, height: 620)
}
#Preview("Choose location · Russian") {
    WorkspaceView(model: WorkspaceViewModel()).environment(\.locale,Locale(identifier: "ru")).frame(width: 960,height: 640)
}
