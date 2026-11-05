import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Duplicates go through the queue like any quick-select level: the kept copy is never
/// queued, every queued copy records it as its survivor, and app data is left alone.
@MainActor struct DuplicatesFlowTests {
    @Test func findThenSelectQueuesCopiesButNeverTheKeptOne() async throws {
        let home = URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("dupe-flow-" + UUID().uuidString).path)
        let data = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        for (path, days) in [("Documents/a.mov", 900.0), ("Downloads/a copy.mov", 10), ("Library/Application Support/App/a.mov", 5), ("Library/Application Support/App/b.mov", 5)] {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        let model = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess(), catalog: LocationCatalog(home: home), defaults: isolatedDefaults())
        model.scan.pendingRoot = home; model.startScan(); await model.waitForScan()
        model.duplicates.strategy = .oldest
        model.duplicates.find()
        for _ in 0..<200 where model.duplicates.search == nil { try await Task.sleep(for: .milliseconds(20)) }
        let search = try #require(model.duplicates.search)
        // The two copies inside ~/Library are app data and never offered.
        #expect(search.sets.count == 1 && search.sets[0].files.count == 2)
        #expect(search.sets[0].files.allSatisfy { !$0.path.contains("/Library/") })
        let outcome = try #require(model.duplicates.select())
        #expect(outcome.applied == 1 && outcome.skipped == 0)
        let entry = try #require(model.cleanup.basket.first)
        #expect(model.cleanup.basket.count == 1)
        #expect(entry.node.path.hasSuffix("Downloads/a copy.mov"))
        #expect(entry.survivor?.path.hasSuffix("Documents/a.mov") == true)
        // A new scan invalidates the results: they describe an index that is gone.
        model.startScan(); await model.waitForScan()
        #expect(model.duplicates.state == .idle)
        await model.shutdown()
    }
}
