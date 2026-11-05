import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

/// Tile colours come from the curated rules (safety) or modification dates (age). The
/// legend's byte shares count leaf tiles only, and restyling never touches the scene.
@MainActor struct MapColoringTests {
    private let home = "/Users/colors"
    private func node(_ id: Int64, _ path: String, dir: Bool = false, days: Double = 1, unknownDates: Int = 0) -> FileNode {
        let date = Date().addingTimeInterval(-days * 86_400)
        return FileNode(id: id, parentID: 1, path: home + path, name: (path as NSString).lastPathComponent, isDirectory: dir,
                        logicalSize: 100, allocatedSize: 100, modified: date, identity: "\(id)",
                        latestContentModification: date, unknownModificationCount: unknownDates)
    }
    private func entry(_ node: FileNode, parent: Int64 = 1, bytes: Int64 = 100) -> MapEntry {
        MapEntry(id: node.id, parentID: parent, ownerID: parent, kind: node.isDirectory ? .folder : .file, node: node, bytes: bytes)
    }

    @Test func safetyOrderIsLevelThenContainsThenProtectedThenYours() {
        let safety = SafetyClassification(levels: [home + "/Library/Caches/app": .caches, home + "/Downloads/old.dmg": .deep])
        let coloring = MapColoring(mode: .safety, safety: safety, roots: [URL(fileURLWithPath: home)],
                                   exemptCacheRoots: CleanupRule.knownCacheRoots(home: home))
        #expect(coloring.tileClass(entry(node(2, "/Library/Caches/app/blob"))) == .caches)
        #expect(coloring.tileClass(entry(node(3, "/Downloads", dir: true))) == .containsReclaimable)
        #expect(coloring.tileClass(entry(node(4, "/Library/Application Support/Something", dir: true))) == .protected)
        #expect(coloring.tileClass(entry(node(5, "/Documents/essay.pages"))) == .yours)
        // Aggregates and other node-less tiles stay uncoloured.
        #expect(coloring.tileClass(MapEntry(id: -2, parentID: 1, ownerID: 1, kind: .aggregate, node: nil, bytes: 10)) == nil)
    }

    @Test func ageBucketsUseNewestContentAndRefuseUnknownDates() {
        let coloring = MapColoring(mode: .age, safety: .empty, roots: [], exemptCacheRoots: [])
        #expect(coloring.tileClass(entry(node(2, "/a", days: 3))) == .month)
        #expect(coloring.tileClass(entry(node(3, "/b", days: 100))) == .halfYear)
        #expect(coloring.tileClass(entry(node(4, "/c", days: 300))) == .year)
        #expect(coloring.tileClass(entry(node(5, "/d", days: 500))) == .twoYears)
        #expect(coloring.tileClass(entry(node(6, "/e", days: 1500))) == .older)
        #expect(coloring.tileClass(entry(node(7, "/f", dir: true, days: 1500, unknownDates: 2))) == .ageUnknown)
    }

    @Test func sharesCountLeafTilesOnceNotTheirContainingFrames() {
        let folder = node(2, "/Projects", dir: true, days: 3)
        let child = node(3, "/Projects/big.bin", days: 500)
        let scene = MapScene(rootID: 1, entries: [entry(folder, bytes: 300), entry(child, parent: 2, bytes: 300)])
        let result = MapColoring(mode: .age, safety: .empty, roots: [], exemptCacheRoots: []).classify(scene)
        #expect(result.classes[2] == .month && result.classes[3] == .twoYears)
        #expect(result.shares == [.twoYears: 300])
    }

    @Test func highlightDimsOnlyOtherClassesOnLeafTiles() {
        let file = SceneTile(entry: entry(node(2, "/x")), rect: .zero, depth: 1, isContainer: false)
        let frame = SceneTile(entry: entry(node(3, "/y", dir: true)), rect: .zero, depth: 1, isContainer: true)
        var style = MapTileStyle(classes: [2: .yours, 3: .junk], highlighted: .junk)
        #expect(style.dimmed(file) && !style.dimmed(frame))
        style.highlighted = .yours
        #expect(!style.dimmed(file))
        #expect(style.crossfadeKey == "safety/yours")
    }
}
