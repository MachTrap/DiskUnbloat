import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct DuplicatesFlowTests {
    @Test func findsCopiesAndQueuesOnlyTheReviewedSubset() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 42, count: 1_500_000)
        try write(data, "Documents/a.mov", in: home, daysOld: 900)
        try write(data, "Downloads/a copy.mov", in: home, daysOld: 10)
        try write(data, "go/pkg/mod/cache/download/a.mov", in: home, daysOld: 5)
        try write(data, "Library/Application Support/App/a.mov", in: home)
        try write(Data("user file".utf8), "Unrelated.txt", in: home)

        let model = await scan(home)
        let index = try #require(model.scan.index)
        let unrelated = try #require(await index.node(path: canonicalURL(home).path + "/Unrelated.txt"))
        model.addToBasket(unrelated)
        model.duplicates.strategy = .oldest
        model.duplicates.find()
        await model.duplicates.waitForWork()

        #expect(model.duplicates.presentation != nil)
        #expect(model.duplicates.selectedCount == 0)
        #expect(model.cleanup.basket.map(\.node.id) == [unrelated.id])
        let group = try #require(model.duplicates.groups.first)
        #expect(group.copies.count == 3)
        #expect(group.copies.allSatisfy { !$0.path.contains("/Library/") })
        let original = try #require(group.copies.first { $0.path.hasSuffix("Documents/a.mov") })
        let download = try #require(group.copies.first { $0.path.hasSuffix("Downloads/a copy.mov") })
        let artifact = try #require(group.copies.first { $0.path.contains("/go/pkg/mod/cache/") })
        #expect(model.duplicates.keeper(in: group).id == original.id)
        #expect(group.support[artifact.id] == .all)
        #expect(group.support[download.id] == DuplicateReviewGroup.SupportCoverage.none)

        model.duplicates.hideSupport = true
        model.duplicates.selectVisible()
        #expect(model.duplicates.proposal.map(\.node.id) == [download.id])
        model.duplicates.clearVisible()
        #expect(model.duplicates.selectedCount == 0)
        model.duplicates.hideSupport = false
        model.duplicates.setChecked(true, node: download, in: group)
        model.duplicates.setChecked(true, node: artifact, in: group)
        model.duplicates.hideSupport = true
        #expect(model.duplicates.selectedCount == 2)
        #expect(model.duplicates.hiddenSelectedCount == 1)
        #expect(!model.duplicates.displayedCopies(in: group).contains { $0.id == artifact.id })
        model.duplicates.filter = .selected
        #expect(model.duplicates.hiddenSelectedCount == 0)
        #expect(model.duplicates.displayedCopies(in: group).count == 3)
        model.duplicates.setChecked(false, node: artifact, in: group)
        model.duplicates.chooseKeeper(download, in: group)
        #expect(model.duplicates.selectedCount == 0)
        model.duplicates.setChecked(true, node: original, in: group)
        #expect(model.duplicates.selectedCount == 1)
        #expect(model.cleanup.basket.map(\.node.id) == [unrelated.id])

        model.cleanup.showQueue = false
        model.duplicates.confirm()
        await model.duplicates.waitForWork()
        #expect(model.duplicates.presentation == nil)
        #expect(model.cleanup.showQueue)
        #expect(model.cleanup.basket.count == 2)
        let entry = try #require(model.cleanup.basket.first { $0.node.id == original.id })
        #expect(entry.survivor?.path == download.path)
        #expect(model.cleanup.basket.contains { $0.node.id == unrelated.id })

        model.duplicates.reopenReview()
        await model.duplicates.waitForWork()
        #expect(model.duplicates.presentation != nil)
        #expect(model.duplicates.selectedCount == 0)
        #expect(model.duplicates.focusedGroup?.id == group.id)
        model.duplicates.dismissReview()
        #expect(model.cleanup.basket.count == 2)

        model.startScan()
        await model.waitForScan()
        #expect(model.duplicates.state == .idle)
        await model.shutdown()
    }

    @Test func selectingAMatchingFolderQueuesVerifiedFilePairsAndRefreshInvalidatesKeepers() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let data = Data(repeating: 19, count: 1_500_000)
        for folder in ["Documents/Original", "Backups/Copy"] {
            try write(data, folder + "/Content.bin", in: home)
            try write(Data("notes".utf8), folder + "/Nested/Notes.txt", in: home)
        }
        try write(data, "Downloads/External.bin", in: home)
        let model = await scan(home)

        model.duplicates.find()
        // Restart before the first run can publish. Both generations use the real search.
        model.duplicates.cancel()
        model.duplicates.find()
        await model.duplicates.waitForWork()
        let folder = try #require(model.duplicates.groups.first { $0.isFolder })
        let file = try #require(model.duplicates.groups.first { !$0.isFolder })
        #expect(folder.fileCount == 2)
        #expect(file.relatedFolderIDs == [folder.id])
        let keptFolder = try #require(folder.copies.first { $0.name == "Original" })
        let copiedFolder = try #require(folder.copies.first { $0.name == "Copy" })
        model.duplicates.chooseKeeper(keptFolder, in: folder)
        model.duplicates.setChecked(true, node: copiedFolder, in: folder)
        #expect(model.duplicates.selectedCount == 2)
        #expect(model.cleanup.basket.isEmpty)
        model.duplicates.confirm()
        await model.duplicates.waitForWork()

        #expect(model.duplicates.presentation == nil)
        #expect(Set(model.cleanup.basket.map { $0.node.name }) == ["Content.bin", "Notes.txt"])
        #expect(model.cleanup.basket.allSatisfy { $0.survivor?.path.isWithin(keptFolder.path) == true })
        #expect(FileManager.default.fileExists(atPath: copiedFolder.path))
        #expect(FileManager.default.fileExists(atPath: keptFolder.path))

        model.refreshFolder(keptFolder)
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.duplicates.state == .idle)
        #expect(model.cleanup.basket.isEmpty)
        await model.shutdown()
    }

    @Test func emptyReviewAndCancelledDraftLeaveTheQueueAlone() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(Data(repeating: 8, count: 1_500_000), "Single.bin", in: home)
        let model = await scan(home)
        model.duplicates.find()
        await model.duplicates.waitForWork()
        #expect(model.duplicates.presentation != nil)
        #expect(model.duplicates.groups.isEmpty)
        #expect(!model.duplicates.canConfirm)
        model.duplicates.dismissReview()
        #expect(model.duplicates.presentation == nil)
        #expect(model.cleanup.basket.isEmpty)
        await model.shutdown()
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dupe-review-" + UUID().uuidString)
    }

    private func write(_ data: Data, _ relativePath: String, in home: URL, daysOld: Double = 0) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if daysOld > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        }
    }

    private func scan(_ home: URL) async -> WorkspaceViewModel {
        let model = WorkspaceViewModel(cleanupService: RecordingCleanupService(), fullDiskAccess: GrantedFullDiskAccess(),
                                       catalog: LocationCatalog(home: home), defaults: isolatedDefaults())
        model.scan.pendingRoot = home
        model.startScan()
        await model.waitForScan()
        return model
    }
}
