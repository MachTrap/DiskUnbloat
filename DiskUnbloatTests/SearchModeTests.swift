import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Filter search narrows the scene; highlight search keeps the map's layout and only
/// lights matches and the folders containing them.
@MainActor struct SearchModeTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-" + UUID().uuidString)
        for (path, size) in [("Photos/holiday-1.jpg", 9000), ("Photos/holiday-2.jpg", 9000), ("Work/report.pdf", 20000), ("Work/Deep/holiday-plan.txt", 4000)] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return root
    }

    @Test func highlightKeepsGeometryAndLightsMatchesWithTheirFolders() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = root; model.startScan(); await model.waitForScan()
        let explorer = model.explorer
        let unfiltered = explorer.scene
        explorer.searchMode = .highlight
        explorer.search = "holiday"
        await explorer.loadResults()
        #expect(explorer.scene == unfiltered)
        #expect(explorer.searchMatches.count == 3 && !explorer.matchesTruncated)
        let lit = try #require(explorer.tileStyle.searchLit)
        let litNames = Set(explorer.scene.entries.filter { lit.contains($0.id) }.compactMap { $0.node?.name })
        #expect(litNames.isSuperset(of: ["Photos", "Work"]))
        #expect(!litNames.contains("report.pdf"))
        // Switching back to the classic mode filters the scene to matching leaves.
        explorer.searchMode = .filter
        await explorer.loadResults()
        #expect(explorer.tileStyle.searchLit == nil)
        let filteredNames = Set(explorer.scene.entries.compactMap { $0.node?.name })
        #expect(filteredNames.isSubset(of: ["holiday-1.jpg", "holiday-2.jpg", "holiday-plan.txt"]))
        // Tests run inside the shipping app's defaults domain: leave the default mode behind.
        explorer.searchMode = .filter
        await model.shutdown()
    }

    @Test func highlightLookupMatchesDescendantsNotSiblingPrefixes() {
        let highlight = SearchHighlight(paths: ["/a/b/c.txt", "/a/bb"])
        #expect(highlight.lights("/a") && highlight.lights("/a/b") && highlight.lights("/a/b/c.txt"))
        #expect(highlight.lights("/a/bb"))
        #expect(!highlight.lights("/a/b/c") && !highlight.lights("/x"))
    }
}
