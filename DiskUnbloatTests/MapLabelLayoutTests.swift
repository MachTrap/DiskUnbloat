import Foundation
import SwiftUI
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor
struct MapLabelLayoutTests {
    private struct Measurement {
        let title: CGSize
        let firstBaseline: CGFloat
        let lastBaseline: CGFloat
        let metadata: CGSize?
        let fitsShallowRect: Bool
    }

    private func measure(_ name: String, size: CGSize, detail: MapLabelDetail, container: Bool = false,
                         kind: MapEntry.Kind = .file, unknownCount: Int = 0) -> Measurement? {
        let rect = CGRect(origin: .zero, size: size)
        let node = kind == .file || kind == .folder
            ? FileNode(id: 2, parentID: 1, path: "/fixture/" + name, name: name, isDirectory: container,
                       logicalSize: 1, allocatedSize: 1, modified: nil, identity: "")
            : nil
        let entry = MapEntry(id: 2, parentID: 1, ownerID: 1, kind: kind, node: node, bytes: 1, unknownCount: unknownCount)
        let tile = SceneTile(entry: entry, rect: rect, depth: 0, isContainer: container)
        var result: Measurement?
        let view = Canvas { context, _ in
            guard let plan = MapLabelLayout.plan(for: tile, in: rect, detail: detail, dimmed: false, context: context) else { return }
            let proposed = CGSize(width: plan.width, height: .greatestFiniteMagnitude)
            result = Measurement(
                title: plan.title.extent,
                firstBaseline: plan.title.text.firstBaseline(in: proposed),
                lastBaseline: plan.title.text.lastBaseline(in: proposed),
                metadata: plan.metadata?.extent,
                fitsShallowRect: plan.fits(in: CGRect(x: 0, y: 0, width: size.width, height: 16))
            )
            plan.draw(in: rect, clippedTo: Path(rect), context: context)
        }
        #expect(ImageRenderer(content: view.frame(width: 160, height: 100)).cgImage != nil)
        return result
    }

    @Test func detailLevelsLabelProgressivelySmallerTiles() {
        #expect(measure("File", size: CGSize(width: 62, height: 24), detail: .compact) == nil)
        #expect(measure("File", size: CGSize(width: 63, height: 23), detail: .compact) == nil)
        #expect(measure("File", size: CGSize(width: 63, height: 24), detail: .compact) != nil)
        #expect(measure("File", size: CGSize(width: 48, height: 20), detail: .balanced) != nil)
        #expect(measure("File", size: CGSize(width: 32, height: 16), detail: .balanced) == nil)
        #expect(measure("File", size: CGSize(width: 32, height: 16), detail: .detailed) != nil)
        #expect(measure("File", size: CGSize(width: 31, height: 80), detail: .detailed) == nil)
        #expect(measure("File", size: CGSize(width: 150, height: 15), detail: .detailed) == nil)
        #expect(measure("File", size: CGSize(width: CGFloat.infinity, height: 80), detail: .detailed) == nil)
    }

    @Test func wrappingChoosesTheLargestCapThatFitsAndDropsMetadataFirst() throws {
        let name = "Development Screenshots Phase Nine Final"
        let one = try #require(measure(name, size: CGSize(width: 52, height: 16), detail: .detailed))
        let two = try #require(measure(name, size: CGSize(width: 52, height: 30), detail: .detailed))
        let three = try #require(measure(name, size: CGSize(width: 52, height: 43), detail: .detailed))
        let withSize = try #require(measure(name, size: CGSize(width: 52, height: 68), detail: .detailed))
        #expect(one.firstBaseline == one.lastBaseline)
        #expect(two.title.height == 2 * one.title.height)
        #expect(three.title.height == 3 * one.title.height)
        #expect(withSize.title == three.title)
        #expect(one.metadata == nil && two.metadata == nil && three.metadata == nil && withSize.metadata != nil)
        #expect(one.fitsShallowRect && !two.fitsShallowRect && !three.fitsShallowRect)

        let balanced = try #require(measure(name, size: CGSize(width: 52, height: 68), detail: .balanced))
        let compact = try #require(measure(name, size: CGSize(width: 70, height: 68), detail: .compact))
        #expect(balanced.title.height > compact.title.height && balanced.title.height < three.title.height)
        #expect(compact.firstBaseline == compact.lastBaseline)
    }

    @Test func folderHeaderCapsHeightAndPartialMetadataReplacesBytes() throws {
        let name = "Final Project Screenshots Archive Imported Files"
        let header = try #require(measure(name, size: CGSize(width: 113, height: 88), detail: .detailed,
                                          container: true, kind: .folder))
        let atomic = try #require(measure(name, size: CGSize(width: 113, height: 88), detail: .detailed, kind: .folder))
        #expect(header.title.height <= 22)
        #expect(header.title.height < atomic.title.height)
        #expect(header.metadata == nil && atomic.metadata != nil)

        // Allow room for the longer Russian partial-size caption inside Compact's insets.
        let metadataTile = CGSize(width: 150, height: 70)
        let partial = try #require(measure("One", size: metadataTile, detail: .compact, unknownCount: 1))
        let complete = try #require(measure("One", size: metadataTile, detail: .compact))
        #expect(partial.metadata != nil && complete.metadata != nil)
        #expect(partial.metadata != complete.metadata)
    }

    @Test func syntheticAndUnicodeTitlesRespectTheBand() throws {
        let unicode = "Изображение e\u{301} 👨‍👩‍👧‍👦\nملف документаБезПробелов"
        let measured = try #require(measure(unicode, size: CGSize(width: 58, height: 90), detail: .detailed))
        #expect(measured.title.width <= 52 && measured.title.height <= 87)
        #expect(measured.lastBaseline > measured.firstBaseline)
        let oneGrapheme = try #require(measure("e\u{301}", size: CGSize(width: 32, height: 16), detail: .detailed))
        #expect(oneGrapheme.lastBaseline == oneGrapheme.firstBaseline)
        #expect(measure("", size: CGSize(width: 32, height: 16), detail: .detailed, kind: .unreached) == nil)
        #expect(measure("", size: CGSize(width: 150, height: 70), detail: .detailed, kind: .unreached) != nil)
        #expect(measure("", size: CGSize(width: 150, height: 70), detail: .detailed, kind: .aggregate) != nil)
    }
}

@MainActor
struct MapLabelDetailTests {
    @Test func detailRestoresAcrossExplorerInstancesAndScanReset() {
        let defaults = isolatedDefaults()
        let settings = SettingsViewModel(defaults: defaults)
        let explorer = ExplorerViewModel(settings: settings, defaults: defaults)
        #expect(explorer.labelDetail == .compact)
        for detail in MapLabelDetail.allCases {
            explorer.setLabelDetail(detail)
            #expect(ExplorerViewModel(settings: settings, defaults: defaults).labelDetail == detail)
        }
        explorer.reset()
        #expect(explorer.labelDetail == .detailed)
        defaults.set("future-level", forKey: "mapLabelDetail")
        #expect(ExplorerViewModel(settings: settings, defaults: defaults).labelDetail == .compact)
    }

    @Test func detailChangesOnlyTheDrawingForAnExistingScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MapLabelDetail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["report draft.pdf", "Work plan.txt"] {
            try Data(repeating: 1, count: 12_000).write(to: root.appendingPathComponent(name))
        }
        let defaults = isolatedDefaults()
        let workspace = WorkspaceViewModel(fullDiskAccess: GrantedFullDiskAccess(), defaults: defaults)
        workspace.scan.pendingRoot = root
        workspace.startScan()
        await workspace.waitForScan()
        let explorer = workspace.explorer
        #expect(workspace.phase == .exploring)
        explorer.searchMode = .highlight
        explorer.search = "report"
        await explorer.loadResults()
        if let entry = explorer.scene.entries.first { explorer.select(entry, extending: false) }
        explorer.highlightedClass = .yours
        let scene = explorer.scene
        let selection = explorer.selectionIDs
        let style = explorer.tileStyle
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let tiles = NestedTreemap.layoutSync(scene, in: bounds)
        let current = explorer.current
        let revision = explorer.fitRevision
        let compact = MapDrawing(tiles: tiles, style: style, labelDetail: .compact)
        for detail in MapLabelDetail.allCases {
            explorer.setLabelDetail(detail)
            #expect(explorer.scene == scene && explorer.selectionIDs == selection && explorer.tileStyle == style)
            #expect(explorer.current == current && explorer.fitRevision == revision && !explorer.isLoading)
            #expect(NestedTreemap.layoutSync(explorer.scene, in: bounds) == tiles)
            #expect((MapDrawing(tiles: tiles, style: style, labelDetail: detail) == compact) == (detail == .compact))
        }
        await workspace.shutdown()
    }
}
