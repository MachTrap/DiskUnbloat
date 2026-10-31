import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct BrowserPaginationTests {
    @Test func offPageSelectionsRemainAvailableForReview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let index = try ScanIndex(url: url)
        let root = FileNode(id: 1,parentID: nil,path: "/paging",name: "paging",isDirectory: true,logicalSize: 0,allocatedSize: 0,modified: nil,identity: "1")
        let files: [FileNode] = (2...601).map { id in
            FileNode(id: Int64(id),parentID: 1,path: "/paging/\(id)",name: "\(id)",isDirectory: false,logicalSize: 100,allocatedSize: 4096,modified: nil,identity: "\(id)")
        }
        try await index.insert([root] + files); try await index.aggregate()
        let model = ExplorerViewModel(settings: SettingsViewModel())
        await model.attach(index,options: ScanOptions())
        model.changePage(1); await model.waitForPage(); model.select(400)
        model.changePage(1); await model.waitForPage()
        #expect(model.selectionIDs == [400])
        #expect(model.selected?.name == "400")
        #expect(model.selectionBytes == 4096)
        #expect(model.totalRows == 600)
        model.reset(); await index.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
