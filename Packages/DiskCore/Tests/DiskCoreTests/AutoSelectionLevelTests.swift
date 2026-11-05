import Testing
import Foundation
@testable import DiskCore

/// The four quick-select levels nest: whatever a level selects, every higher level selects
/// too. Checked per rule of the closed spec over generated child sets, and on an index.
struct AutoSelectionLevelTests {
    private let home = "/Users/levels"

    /// Children mixing versions, families, ages, unknown data, sidecars, installers.
    private func generatedChildren(seed: Int) -> [FileNode] {
        var rng = SeededGenerator(seed: UInt64(seed))
        let names = ["4.2", "5.4", "AutoCAD 2023", "AutoCAD 2025", "chromium-1148", "chromium-1200", "firefox-1466",
                     "models", "hub", "chats", "datasets", "pixel.avd", "pixel.ini", "old.avd", "old.ini",
                     "Setup.dmg", "tool.pkg", "notes.txt", "Xcode.xip", "BuildA", "BuildB", "Live 11.3", "Live 12.1"]
        return names.enumerated().compactMap { index, name -> FileNode? in
            guard Bool.random(using: &rng) || index % 3 == 0 else { return nil }
            let days = Double(Int.random(in: 0...800, using: &rng))
            let unknown = Int.random(in: 0..<10, using: &rng) == 0
            let isFile = name.hasSuffix(".ini") || name.hasSuffix(".dmg") || name.hasSuffix(".pkg") || name.hasSuffix(".txt") || name.hasSuffix(".xip")
            let date = Date().addingTimeInterval(-days * 86400)
            return FileNode(id: Int64(index + 2), parentID: 1, path: "/loc/\(name)", name: name, isDirectory: !isFile,
                            logicalSize: unknown ? nil : 100, allocatedSize: unknown ? nil : 100, modified: date,
                            identity: "\(index)", latestContentModification: date, unknownModificationCount: unknown ? 1 : 0)
        }
    }

    @Test func everyRuleNestsAcrossLevels() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let rules = AutoSelectionSpec.rules(home: home)
        #expect(!rules.isEmpty)
        for seed in 0..<40 {
            let children = generatedChildren(seed: seed)
            for rule in rules {
                var previous: Set<String> = []
                for level in AutoSelectionLevel.allCases {
                    let selected = Set(AutoSelection.select(children: children, rule: rule, level: level, unusedBefore: cutoff).map(\.path))
                    #expect(previous.isSubset(of: selected), "\(rule.relativePath ?? "name-matched") at \(level)")
                    previous = selected
                }
            }
        }
    }

    @Test func levelsAreOrderedAndDistinct() {
        #expect(AutoSelectionLevel.allCases == [.junk, .caches, .rebuildable, .deep])
        #expect(AutoSelectionLevel.junk < .caches && AutoSelectionLevel.rebuildable < .deep)
    }

    /// The caches level sits strictly between junk and rebuildable: live app caches and
    /// package stores join, while simulators, models, and project folders wait.
    @Test func cachesLevelAddsLiveCachesAndStoresOnly() async throws {
        let now = Date()
        var id: Int64 = 1
        var nodes = [FileNode(id: 1, parentID: nil, path: home, name: "levels", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: now, identity: "root")]
        @discardableResult func add(_ relative: String, parent: Int64, dir: Bool = true, days: Double = 1) -> Int64 {
            id += 1
            let date = now.addingTimeInterval(-days * 86400)
            nodes.append(FileNode(id: id, parentID: parent, path: home + "/" + relative, name: (relative as NSString).lastPathComponent,
                                  isDirectory: dir, logicalSize: dir ? 0 : 1000, allocatedSize: dir ? 0 : 1000, modified: date, identity: "n\(id)"))
            return id
        }
        let library = add("Library", parent: 1)
        let caches = add("Library/Caches", parent: library)
        add("Library/Caches/com.example.app", parent: caches, dir: false)
        let developer = add("Library/Developer", parent: library)
        let xcode = add("Library/Developer/Xcode", parent: developer)
        let derived = add("Library/Developer/Xcode/DerivedData", parent: xcode)
        add("Library/Developer/Xcode/DerivedData/Build", parent: derived, dir: false)
        let support = add("Library/Developer/Xcode/iOS DeviceSupport", parent: xcode)
        add("Library/Developer/Xcode/iOS DeviceSupport/new", parent: support, dir: false, days: 1)
        add("Library/Developer/Xcode/iOS DeviceSupport/old", parent: support, dir: false, days: 300)
        let store = add(".pnpm-store", parent: 1)
        add(".pnpm-store/v3", parent: store, dir: false)
        let project = add("web", parent: 1)
        add("web/package.json", parent: project, dir: false)
        let modules = add("web/node_modules", parent: project)
        add("web/node_modules/x", parent: modules, dir: false)

        let f = try Fixture(); defer { f.dispose() }
        let index = try f.index()
        try await index.insert(nodes); try await index.aggregate()
        func paths(_ level: AutoSelectionLevel) async -> Set<String> {
            Set(await index.autoSelectionCandidates(home: home, level: level, unusedDays: 90).nodes.map { String($0.path.dropFirst(home.count + 1)) })
        }
        let junk = await paths(.junk), cachesLevel = await paths(.caches), rebuildable = await paths(.rebuildable)
        #expect(junk == ["Library/Developer/Xcode/DerivedData/Build", "Library/Developer/Xcode/iOS DeviceSupport/old"])
        #expect(cachesLevel == junk.union(["Library/Caches/com.example.app", ".pnpm-store/v3"]))
        // DerivedData also joins as a name-matched rebuildable folder; the queue keeps
        // only the topmost entry, which the normalized estimate below reflects.
        #expect(rebuildable == cachesLevel.union(["Library/Developer/Xcode/iOS DeviceSupport/new", "web/node_modules", "Library/Developer/Xcode/DerivedData"]))
        // Estimates are normalized and agree with the per-level candidates.
        let estimates = await index.autoSelectionEstimates(home: home, unusedDays: 90)
        #expect(estimates[.junk]?.items == 2 && estimates[.junk]?.knownBytes == 2000)
        #expect(estimates[.caches]?.items == 4)
        #expect(estimates[.rebuildable]?.items == 6)
        #expect(estimates[.deep]?.items ?? 0 >= 6)
        // Map colouring by safety reads the same rules: lowest level wins, nesting holds.
        let safety = await index.safetyClassification(home: home, unusedDays: 90)
        #expect(safety.level(of: home + "/Library/Developer/Xcode/DerivedData/Build") == .junk)
        // Every child of DerivedData is Junk, so the folder reads as Junk too.
        #expect(safety.level(of: home + "/Library/Developer/Xcode/DerivedData") == .junk)
        #expect(safety.level(of: home + "/Library/Caches/com.example.app") == .caches)
        #expect(safety.level(of: home + "/web/node_modules/x") == .rebuildable)
        #expect(safety.level(of: home + "/web/package.json") == nil)
        #expect(safety.containsSelectable(below: home + "/web") && !safety.containsSelectable(below: home + "/web/package.json"))
        for level in AutoSelectionLevel.allCases {
            for node in await index.autoSelectionCandidates(home: home, level: level, unusedDays: 90).nodes {
                #expect(safety.level(of: node.path).map { $0 <= level } == true, "\(node.path) at \(level)")
            }
        }
        await index.close()
    }

    @Test func safetyClassificationPrefersTheLowestCoveringLevel() {
        let safety = SafetyClassification(levels: ["/h/Caches": .caches, "/h/Caches/old": .junk, "/h/Downloads/a.dmg": .deep])
        #expect(safety.level(of: "/h/Caches/old/x") == .junk)
        #expect(safety.level(of: "/h/Caches/new") == .caches)
        #expect(safety.level(of: "/h/CachesX") == nil)
        #expect(safety.containsSelectable(below: "/h/Downloads") && !safety.containsSelectable(below: "/h/Documents"))
    }
}

/// Deterministic generator so property runs are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct DeepLevelTests {
    @Test func versionFamiliesGroupAppVersions() {
        let key = AutoSelection.appVersionFamilyKey
        #expect(key("chromium-1148") == "chromium")
        #expect(key("chromium_headless_shell-1148") == "chromium_headless_shell")
        #expect(key("AutoCAD 2023") == "AutoCAD" && key("AutoCAD 2025") == "AutoCAD")
        #expect(key("Live 11.3.4") == "Live")
        #expect(key("Maxon Cinema 4D 2024_8A6D4B5E") == "Maxon Cinema 4D")
        #expect(key("Maxon Cinema 4D 2025_11C0FFEE") == "Maxon Cinema 4D")
        #expect(key("4.2") == key("5.4") && key("2024") == key("4.2"))
        // Names without a version token never join a family.
        #expect(key("Cinema 4D") == "Cinema 4D")
        #expect(key("config") == "config")
        #expect(key("iPhone 15 (17.0)") == "iPhone 15 (17.0)")
    }

    private func node(_ id: Int64, _ path: String, dir: Bool, days: Double, unknown: Bool = false) -> FileNode {
        let date = Date().addingTimeInterval(-days * 86400)
        return FileNode(id: id, parentID: 1, path: path, name: (path as NSString).lastPathComponent, isDirectory: dir,
                        logicalSize: unknown ? nil : 100, allocatedSize: unknown ? nil : 100, modified: date,
                        identity: "\(id)", latestContentModification: date)
    }

    @Test func installersNeedTheThresholdAndAnInstallerExtension() throws {
        let rule = try #require(AutoSelectionSpec.rules(home: "/Users/d").first { $0.relativePath == "Downloads" })
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let children = [node(2, "/d/Old.dmg", dir: false, days: 200), node(3, "/d/New.pkg", dir: false, days: 3),
                        node(4, "/d/Xcode.XIP", dir: false, days: 400), node(5, "/d/report.pdf", dir: false, days: 900),
                        node(6, "/d/Folder.dmg", dir: true, days: 900), node(7, "/d/Unknown.pkg", dir: false, days: 500, unknown: true)]
        for level in [AutoSelectionLevel.junk, .caches, .rebuildable] {
            #expect(AutoSelection.select(children: children, rule: rule, level: level, unusedBefore: cutoff).isEmpty)
        }
        let deep = AutoSelection.select(children: children, rule: rule, level: .deep, unusedBefore: cutoff).map(\.name)
        #expect(Set(deep) == ["Old.dmg", "Xcode.XIP"])
    }

    @Test func olderAppVersionsAreDeepOnlyAndTheNewestStays() async throws {
        let home = "/Users/deep"
        let blender = home + "/Library/Application Support/Blender"
        let f = try Fixture(); defer { f.dispose() }
        let index = try f.index()
        var nodes = [FileNode(id: 1, parentID: nil, path: home, name: "deep", isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: Date(), identity: "r")]
        var id: Int64 = 1
        func add(_ path: String, _ parent: Int64, dir: Bool = true, days: Double = 1) -> Int64 {
            id += 1
            nodes.append(node(id, path, dir: dir, days: days).withParent(parent))
            return id
        }
        let library = add(home + "/Library", 1)
        let support = add(home + "/Library/Application Support", library)
        let app = add(blender, support)
        _ = add(blender + "/5.4", app, days: 2)
        _ = add(blender + "/4.2", app, days: 300)
        _ = add(blender + "/3.6", app, days: 600)
        _ = add(blender + "/notes", app, days: 900)
        try await index.insert(nodes); try await index.aggregate()
        for level in [AutoSelectionLevel.junk, .caches, .rebuildable] {
            #expect(await index.autoSelectionCandidates(home: home, level: level, unusedDays: 90).isEmpty)
        }
        let deep = await index.autoSelectionCandidates(home: home, level: .deep, unusedDays: 90)
        #expect(Set(deep.nodes.map(\.name)) == ["4.2", "3.6"])
        #expect(deep.exemptPaths == [blender + "/4.2", blender + "/3.6"])
        await index.close()
    }
}

extension FileNode {
    func withParent(_ parent: Int64) -> FileNode {
        FileNode(id: id, parentID: parent, path: path, name: name, isDirectory: isDirectory, logicalSize: logicalSize,
                 allocatedSize: allocatedSize, modified: modified, identity: identity, latestContentModification: latestContentModification)
    }
}

/// Vendor layouts mix version folders with shared, non-versioned items; only older
/// versions of one family are ever selected.
@Test func vendorVersionLayoutsKeepSharedItems() throws {
    let rules = AutoSelectionSpec.rules(home: "/Users/v")
    let cutoff = Date().addingTimeInterval(-90 * 86400)
    func child(_ id: Int64, _ name: String, _ days: Double) -> FileNode {
        let d = Date().addingTimeInterval(-days * 86400)
        return FileNode(id: id, parentID: 1, path: "/x/\(name)", name: name, isDirectory: true, logicalSize: 1, allocatedSize: 1, modified: d, identity: "\(id)", latestContentModification: d)
    }
    let cases: [(String, [FileNode], Set<String>)] = [
        ("Library/Preferences/Autodesk/maya", [child(2, "2025", 1), child(3, "2024", 200), child(4, "Maya.env", 900), child(5, "scripts", 900)], ["2024"]),
        ("Library/Preferences/Maxon", [child(2, "Maxon Cinema 4D 2025_AB12", 1), child(3, "Maxon Cinema 4D 2024_CD34", 300), child(4, "python27", 900)], ["Maxon Cinema 4D 2024_CD34"]),
        ("Library/Preferences/Ableton", [child(2, "Live 12.1", 1), child(3, "Live 11.3.4", 400), child(4, "Live Reports", 900)], ["Live 11.3.4"]),
    ]
    for (path, children, expected) in cases {
        let rule = try #require(rules.first { $0.relativePath == path })
        #expect(AutoSelection.select(children: children, rule: rule, level: .rebuildable, unusedBefore: cutoff).isEmpty)
        #expect(Set(AutoSelection.select(children: children, rule: rule, level: .deep, unusedBefore: cutoff).map(\.name)) == expected, "\(path)")
    }
}
