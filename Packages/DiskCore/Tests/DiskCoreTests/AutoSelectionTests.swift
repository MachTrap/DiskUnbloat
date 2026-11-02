import Testing
import Foundation
@testable import DiskCore

/// Two-tier automatic selection: the pure tier decisions, the closed rule spec over the
/// indexed scan, and the hidden-range collapse that keeps bulk selections cheap.
struct AutoSelectionTests {
    private func node(
        _ id: Int64, _ parent: Int64?, _ path: String, dir: Bool,
        modified: Date?, size: Int64 = 1024, latest: Date? = nil, unknown: Bool = false
    ) -> FileNode {
        FileNode(
            id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: dir, logicalSize: unknown ? nil : size, allocatedSize: unknown ? nil : size,
            modified: modified, identity: "\(id)",
            knownLogicalSize: size, knownAllocatedSize: size,
            unknownLogicalCount: unknown ? 1 : 0, unknownAllocatedCount: unknown ? 1 : 0,
            latestContentModification: latest ?? modified)
    }

    private func child(_ id: Int64, _ parent: Int64, _ name: String, days: Double, dir: Bool = true) -> FileNode {
        node(id, parent, "/loc/\(name)", dir: dir, modified: Date().addingTimeInterval(-days * 86400))
    }

    // MARK: Pure tier decisions

    @Test func previousVersionsKeepTheNewestAndFallBackToLongUnused() {
        let keepOne = AutoSelectionRule(relativePath: "x", target: .children, coverage: .previousVersions(keep: 1))
        let recent = child(1, 0, "recent", days: 10)
        let old = child(2, 0, "old", days: 200)
        let older = child(3, 0, "older", days: 300)
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        // Previous versions exist: they are selected, the newest stays even though the
        // rest of the location is old.
        #expect(AutoSelection.select(children: [recent, old, older], rule: keepOne, tier: .safe, unusedBefore: cutoff).map(\.id) == [2, 3])
        // No previous versions: the long-unused ones qualify instead.
        #expect(AutoSelection.select(children: [recent, old], rule: keepOne, tier: .safe, unusedBefore: cutoff).map(\.id) == [2])
        #expect(AutoSelection.select(children: [recent], rule: keepOne, tier: .safe, unusedBefore: cutoff).isEmpty)
        // The single most recent version is preserved even when it is the only one and
        // long-unused: the long-unused fallback never takes the newest.
        let only = child(4, 0, "only", days: 200)
        #expect(AutoSelection.select(children: [only], rule: keepOne, tier: .safe, unusedBefore: cutoff).isEmpty)
        #expect(AutoSelection.select(children: [old, older], rule: keepOne, tier: .safe, unusedBefore: cutoff).map(\.id) == [3])
        // Keeping two simulators leaves every version after the two newest; with just
        // two, the long-unused older one qualifies but the newest is still preserved.
        let keepTwo = AutoSelectionRule(relativePath: "x", target: .children, coverage: .previousVersions(keep: 2))
        #expect(AutoSelection.select(children: [recent, old, older], rule: keepTwo, tier: .safe, unusedBefore: cutoff).map(\.id) == [3])
        #expect(AutoSelection.select(children: [recent, old], rule: keepTwo, tier: .safe, unusedBefore: cutoff).map(\.id) == [2])
        #expect(AutoSelection.select(children: [only], rule: keepTwo, tier: .safe, unusedBefore: cutoff).isEmpty)
    }

    @Test func unusedRulesRespectTheThresholdAndTheKeptNewest() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let recent = child(1, 0, "recent", days: 10)
        let old = child(2, 0, "old", days: 200)
        let older = child(3, 0, "older", days: 300)
        let keepingNewest = AutoSelectionRule(relativePath: "x", target: .children, coverage: .unusedKeepingNewest)
        // The most recent simulator stays even when it too is long-unused — and a sole
        // simulator is the most recent one, so it always stays.
        #expect(AutoSelection.select(children: [old, older], rule: keepingNewest, tier: .safe, unusedBefore: cutoff).map(\.id) == [3])
        #expect(AutoSelection.select(children: [recent, old], rule: keepingNewest, tier: .safe, unusedBefore: cutoff).map(\.id) == [2])
        #expect(AutoSelection.select(children: [old], rule: keepingNewest, tier: .safe, unusedBefore: cutoff).isEmpty)
        let unusedOnly = AutoSelectionRule(relativePath: "x", target: .children, coverage: .unusedOnly)
        #expect(AutoSelection.select(children: [recent, old, older], rule: unusedOnly, tier: .safe, unusedBefore: cutoff).map(\.id) == [2, 3])
        // Every tier-2 location is covered in full.
        #expect(AutoSelection.select(children: [recent, old, older], rule: unusedOnly, tier: .regenerable, unusedBefore: cutoff).count == 3)
    }

    @Test func unknownDataNeverEstablishesLongUnused() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let unknownDate = node(1, 0, "/loc/undated", dir: true, modified: nil)
        let unknownSize = node(2, 0, "/loc/unsized", dir: true, modified: Date().addingTimeInterval(-300 * 86400), unknown: true)
        let rule = AutoSelectionRule(relativePath: "x", target: .children, coverage: .unusedOnly)
        #expect(AutoSelection.select(children: [unknownDate, unknownSize], rule: rule, tier: .safe, unusedBefore: cutoff).isEmpty)
    }

    @Test func versionedFamiliesGroupPerBuildLine() {
        #expect(AutoSelection.versionedFamilyKey("chromium-1148") == "chromium")
        #expect(AutoSelection.versionedFamilyKey("chromium_headless_shell-1148") == "chromium_headless_shell")
        #expect(AutoSelection.versionedFamilyKey("1.41.1") == "1.41.1")
        #expect(AutoSelection.versionedFamilyKey("27.0.12077973") == "27.0.12077973")
        #expect(AutoSelection.versionedFamilyKey("DeviceA2") == "DeviceA2")
        // Only a trailing run of digits after a dash forms a family; anything else stays
        // a family of its own rather than over-grouping lookalike names.
        #expect(AutoSelection.versionedFamilyKey("device-A2") == "device-A2")
    }

    @Test func browserFamiliesKeepOneVersionEachAndSoleBuildsStay() {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let playwright = AutoSelectionRule(relativePath: "x", target: .children, coverage: .previousVersionsPerFamily(keep: 1))
        var buildID: Int64 = 400
        func build(_ name: String, _ days: Double) -> FileNode {
            buildID += 1
            return child(buildID, 0, name, days: days)
        }
        let chromiumOld = build("chromium-1124", 200)
        let chromiumNew = build("chromium-1148", 10)
        let firefoxNewer = build("firefox-1471", 300)
        let firefoxOlder = build("firefox-1470", 350)
        let webkitSole = build("webkit-2079", 80)
        let ffmpegSole = build("ffmpeg-1011", 400)
        // One version per browser family: the older chromium and the older firefox go,
        // each family's newest build stays, and sole families keep their only build.
        let selected = AutoSelection.select(
            children: [chromiumNew, chromiumOld, firefoxNewer, firefoxOlder, webkitSole, ffmpegSole],
            rule: playwright, tier: .safe, unusedBefore: cutoff)
        #expect(Set(selected.map(\.name)) == ["chromium-1124", "firefox-1470"])
        // Tier 2 covers every build of every family.
        #expect(AutoSelection.select(
            children: [chromiumNew, chromiumOld, firefoxNewer, firefoxOlder, webkitSole, ffmpegSole],
            rule: playwright, tier: .regenerable, unusedBefore: cutoff).count == 6)
    }

    @Test func pairedSidecarsTravelWithTheirSimulator() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let oldAvd = node(1, 0, "/loc/pixel-old.avd", dir: true, modified: Date().addingTimeInterval(-300 * 86400))
        let oldIni = node(2, 0, "/loc/pixel-old.ini", dir: false, modified: Date().addingTimeInterval(-300 * 86400))
        let newAvd = node(3, 0, "/loc/pixel-new.avd", dir: true, modified: Date().addingTimeInterval(-5 * 86400))
        let newIni = node(4, 0, "/loc/pixel-new.ini", dir: false, modified: Date().addingTimeInterval(-5 * 86400))
        let loose = node(5, 0, "/loc/notes.txt", dir: false, modified: Date().addingTimeInterval(-300 * 86400))
        let rule = AutoSelectionRule(
            relativePath: "x", target: .children, coverage: .unusedKeepingNewest,
            sidecarPairing: SidecarPairing(directorySuffix: ".avd", sidecarSuffix: ".ini"))
        let selected = AutoSelection.select(children: [oldAvd, oldIni, newAvd, newIni, loose], rule: rule, tier: .safe, unusedBefore: cutoff)
        #expect(Set(selected.map(\.id)) == [1, 2])
        #expect(Set(AutoSelection.select(children: [oldAvd, oldIni, newAvd, newIni, loose], rule: rule, tier: .regenerable, unusedBefore: cutoff).map(\.id)) == [1, 2, 3, 4])
    }

    @Test func safeTierNeverTouchesUserCachesButRegenerableDoes() {
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        let cache = node(1, 0, "/loc/c", dir: true, modified: Date().addingTimeInterval(-300 * 86400))
        let live = AutoSelectionRule(relativePath: "Library/Caches", target: .children, coverage: .none)
        #expect(AutoSelection.select(children: [cache], rule: live, tier: .safe, unusedBefore: cutoff).isEmpty)
        #expect(AutoSelection.select(children: [cache], rule: live, tier: .regenerable, unusedBefore: cutoff).map(\.id) == [1])
    }

    // MARK: The closed spec over an indexed scan

    /// Builds a grouped-scan-shaped index: a synthetic wrapper with curated locations as
    /// direct children, exactly like the "Dev tools"/"All caches" quick actions index.
    private func buildIndex(_ nodes: [FileNode]) async throws -> (Fixture, ScanIndex) {
        let fixture = try Fixture()
        let index = try fixture.index()
        try await index.insert(nodes)
        try await index.aggregate()
        return (fixture, index)
    }

    @Test func devToolsScopeMatchesTheRequestedTierSets() async throws {
        let home = "/Users/devtools"
        let now = Date()
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        var id: Int64 = 10
        func child(_ parent: Int64, _ path: String, _ days: Double) -> FileNode {
            id += 1
            return FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                            isDirectory: true, logicalSize: 1000, allocatedSize: 1000, modified: d(days), identity: "n\(id)")
        }
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "Dev tools", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: nil, identity: "wrapper")
        var nodes = [wrapper]
        func location(_ path: String) -> Int64 {
            id += 1
            let node = FileNode(id: id, parentID: 1, path: home + "/" + path, name: URL(fileURLWithPath: path).lastPathComponent,
                                isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: d(1), identity: "n\(id)")
            nodes.append(node)
            return node.id
        }
        let derived = location("Library/Developer/Xcode/DerivedData")
        nodes += [child(derived, home + "/Library/Developer/Xcode/DerivedData/BuildA", 400), child(derived, home + "/Library/Developer/Xcode/DerivedData/BuildB", 10)]
        let support = location("Library/Developer/Xcode/iOS DeviceSupport")
        nodes += [child(support, home + "/Library/Developer/Xcode/iOS DeviceSupport/iPhone 15 (17.0)", 10),
                  child(support, home + "/Library/Developer/Xcode/iOS DeviceSupport/iPhone 12 (16.5)", 200),
                  child(support, home + "/Library/Developer/Xcode/iOS DeviceSupport/iPhone X (15.2)", 300)]
        let simulators = location("Library/Developer/CoreSimulator/Devices")
        nodes += [child(simulators, home + "/Library/Developer/CoreSimulator/Devices/AAAA", 10),
                  child(simulators, home + "/Library/Developer/CoreSimulator/Devices/BBBB", 100),
                  child(simulators, home + "/Library/Developer/CoreSimulator/Devices/CCCC", 200),
                  child(simulators, home + "/Library/Developer/CoreSimulator/Devices/DDDD", 300)]
        let images = location("Library/Android/sdk/system-images")
        nodes += [child(images, home + "/Library/Android/sdk/system-images/android-35", 10),
                  child(images, home + "/Library/Android/sdk/system-images/android-30", 300)]
        let ndk = location("Library/Android/sdk/ndk")
        nodes += [child(ndk, home + "/Library/Android/sdk/ndk/27.0.12077973", 5),
                  child(ndk, home + "/Library/Android/sdk/ndk/25.2.9519653", 300)]
        let avd = location(".android/avd")
        for (name, days) in [("pixel-new", 10.0), ("pixel-old", 300.0)] {
            id += 1
            nodes.append(FileNode(id: id, parentID: avd, path: home + "/.android/avd/\(name).avd", name: "\(name).avd",
                                  isDirectory: true, logicalSize: 500, allocatedSize: 500, modified: d(days), identity: "n\(id)"))
            id += 1
            nodes.append(FileNode(id: id, parentID: avd, path: home + "/.android/avd/\(name).ini", name: "\(name).ini",
                                  isDirectory: false, logicalSize: 10, allocatedSize: 10, modified: d(days), identity: "n\(id)"))
        }
        let models = location(".cache/lm-studio")
        // Regenerable children (models, runtime backends, internal caches) are candidates;
        // the user's chat history and presets never are, in either tier.
        nodes += [child(models, home + "/.cache/lm-studio/models", 200), child(models, home + "/.cache/lm-studio/extensions", 10),
                  child(models, home + "/.cache/lm-studio/chats", 300), child(models, home + "/.cache/lm-studio/conversations", 300)]
        // Scan-only developer data: never selected by either tier.
        let docker = location("Library/Containers/com.docker.docker")
        nodes += [child(docker, home + "/Library/Containers/com.docker.docker/Data", 400)]

        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 90)
        #expect(Set(safe.nodes.map(\.name)) == [
            "BuildA", "BuildB",
            "iPhone 12 (16.5)", "iPhone X (15.2)",
            "CCCC", "DDDD",
            "android-30", "25.2.9519653",
            "pixel-old.avd", "pixel-old.ini",
            "models",
        ])
        // Full coverage of DerivedData lets a scan root collapse to one emptied entry.
        let derivedGroup = try #require(safe.groups.first { $0.location.path.hasSuffix("DerivedData") })
        #expect(derivedGroup.coversAllChildren)
        #expect(safe.groups.first { $0.location.path.hasSuffix("com.docker.docker") } == nil)
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 90)
        #expect(Set(all.nodes.map(\.name)) == [
            "BuildA", "BuildB", "DerivedData",
            "iPhone 15 (17.0)", "iPhone 12 (16.5)", "iPhone X (15.2)",
            "AAAA", "BBBB", "CCCC", "DDDD",
            "android-35", "android-30", "27.0.12077973", "25.2.9519653",
            "pixel-new.avd", "pixel-old.avd", "pixel-new.ini", "pixel-old.ini",
            "models", "extensions",
        ])
        await destroy(index)
    }

    @Test func soleVersionsArePreservedByTheSafeTier() async throws {
        // The real one-version-each machine: a sole system image, NDK, AVD, simulator,
        // and device-support version must survive "Select safe items" — the single most
        // recent version is never selected, even when it is long-unused.
        let home = "/Users/sole"
        let now = Date()
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        var id: Int64 = 10
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "Dev tools", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: nil, identity: "wrapper")
        var nodes = [wrapper]
        func location(_ path: String) -> Int64 {
            id += 1
            let node = FileNode(id: id, parentID: 1, path: home + "/" + path, name: URL(fileURLWithPath: path).lastPathComponent,
                                isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: d(1), identity: "n\(id)")
            nodes.append(node)
            return node.id
        }
        func child(_ parent: Int64, _ path: String, _ days: Double, dir: Bool = true) {
            id += 1
            nodes.append(FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                                  isDirectory: dir, logicalSize: 1000, allocatedSize: 1000, modified: d(days), identity: "n\(id)"))
        }
        let images = location("Library/Android/sdk/system-images")
        child(images, home + "/Library/Android/sdk/system-images/android-37.0", 120)
        let ndk = location("Library/Android/sdk/ndk")
        child(ndk, home + "/Library/Android/sdk/ndk/27.1.12297006", 120)
        let avd = location(".android/avd")
        child(avd, home + "/.android/avd/Pixel_9.avd", 120)
        child(avd, home + "/.android/avd/Pixel_9.ini", 120, dir: false)
        let simulators = location("Library/Developer/CoreSimulator/Devices")
        child(simulators, home + "/Library/Developer/CoreSimulator/Devices/AAAA", 200)
        let support = location("Library/Developer/Xcode/iOS DeviceSupport")
        child(support, home + "/Library/Developer/Xcode/iOS DeviceSupport/iPhone 15 (17.0)", 200)

        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 90)
        #expect(safe.nodes.isEmpty)
        // Tier 2 is allowed to take every version, sole ones included.
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 90)
        #expect(Set(all.nodes.map(\.name)) == [
            "android-37.0", "27.1.12297006", "Pixel_9.avd", "Pixel_9.ini", "AAAA", "iPhone 15 (17.0)",
        ])
        await destroy(index)
    }

    @Test func lmStudioUserDataIsNeverSelectedByEitherTier() async throws {
        // ~/.cache/lm-studio holds user-authored content (chats, conversations, presets)
        // beside regenerable caches. The user content is neither safe junk nor
        // rebuildable: it is never selected automatically, in either tier.
        let home = "/Users/lms"
        let now = Date()
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        var id: Int64 = 10
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "Dev tools", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: nil, identity: "wrapper")
        var nodes = [wrapper]
        id += 1
        let location = FileNode(id: id, parentID: 1, path: home + "/.cache/lm-studio", name: "lm-studio",
                                isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: d(1), identity: "loc")
        nodes.append(location)
        func child(_ name: String, _ days: Double, dir: Bool = true) {
            id += 1
            nodes.append(FileNode(id: id, parentID: location.id, path: home + "/.cache/lm-studio/\(name)", name: name,
                                  isDirectory: dir, logicalSize: 1000, allocatedSize: 1000, modified: d(days), identity: "n\(id)"))
        }
        child("models", 200)
        child("extensions", 10)
        child(".internal", 200)
        child(".session_cache", 10)
        child("chats", 300)
        child("conversations", 300)
        child("config-presets", 300)
        child("downloads.json", 300, dir: false)
        child("bin", 300)

        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        // Tier 1: only long-unused regenerable children. Tier 2: every regenerable
        // child. The user's chat history and presets stay out of both.
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 90)
        #expect(Set(safe.nodes.map(\.name)) == ["models", ".internal"])
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 90)
        #expect(Set(all.nodes.map(\.name)) == ["models", "extensions", ".internal", ".session_cache"])
        await destroy(index)
    }

    @Test func allCachesScopeTier1ExcludesUserCachesAndTier2TakesEverything() async throws {
        let home = "/Users/allcaches"
        let now = Date()
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        var id: Int64 = 10
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "All caches", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: nil, identity: "wrapper")
        var nodes = [wrapper]
        func location(_ path: String) -> Int64 {
            id += 1
            let node = FileNode(id: id, parentID: 1, path: home + "/" + path, name: URL(fileURLWithPath: path).lastPathComponent,
                                isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: d(1), identity: "n\(id)")
            nodes.append(node)
            return node.id
        }
        func child(_ parent: Int64, _ path: String, _ days: Double) {
            id += 1
            nodes.append(FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                                  isDirectory: true, logicalSize: 1000, allocatedSize: 1000, modified: d(days), identity: "n\(id)"))
        }
        let caches = location("Library/Caches")
        child(caches, home + "/Library/Caches/com.example.live", 10)
        child(caches, home + "/Library/Caches/com.example.stale", 200)
        let npm = location(".npm/_cacache")
        child(npm, home + "/.npm/_cacache/content-v2", 200)
        location(".gradle/caches")
        let derived = location("Library/Developer/Xcode/DerivedData")
        child(derived, home + "/Library/Developer/Xcode/DerivedData/BuildA", 200)

        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        // Tier 1: every listed cache location in full except the live ~/Library/Caches tree.
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 90)
        #expect(Set(safe.nodes.map(\.path)) == [
            home + "/.npm/_cacache/content-v2",
            home + "/.gradle/caches",
            home + "/Library/Developer/Xcode/DerivedData/BuildA",
        ])
        // Tier 2: absolutely everything, the live caches included. The DerivedData folder
        // additionally matches the name-matched rebuildable rule, which selects the
        // folder itself.
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 90)
        #expect(Set(all.nodes.map(\.path)) == [
            home + "/Library/Caches/com.example.live",
            home + "/Library/Caches/com.example.stale",
            home + "/.npm/_cacache/content-v2",
            home + "/.gradle/caches",
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/DerivedData/BuildA",
        ])
        await destroy(index)
    }

    @Test func phaseALocationsMatchTheTierSets() async throws {
        // The Phase A additions — per-family browser builds, Gradle distributions, the
        // Cargo/bun package caches, the editors' Chromium caches, and Adobe's shared
        // media cache — each follow their per-location coverage in both tiers.
        let home = "/Users/phasea"
        let now = Date()
        func d(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        var id: Int64 = 10
        let wrapper = FileNode(id: 1, parentID: nil, path: ScanGroup.path, name: "All caches", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: nil, identity: "wrapper")
        var nodes = [wrapper]
        func location(_ path: String) -> Int64 {
            id += 1
            let node = FileNode(id: id, parentID: 1, path: home + "/" + path, name: URL(fileURLWithPath: path).lastPathComponent,
                                isDirectory: true, logicalSize: 0, allocatedSize: 0, modified: d(1), identity: "n\(id)")
            nodes.append(node)
            return node.id
        }
        func child(_ parent: Int64, _ path: String, _ days: Double, dir: Bool = true) {
            id += 1
            nodes.append(FileNode(id: id, parentID: parent, path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                                  isDirectory: dir, logicalSize: 1000, allocatedSize: 1000, modified: d(days), identity: "n\(id)"))
        }
        // Playwright: one version per browser family stays in tier 1; sole families
        // (webkit, ffmpeg) always keep their only build.
        let playwright = location("Library/Caches/ms-playwright")
        child(playwright, home + "/Library/Caches/ms-playwright/chromium-1124", 200)
        child(playwright, home + "/Library/Caches/ms-playwright/chromium-1148", 10)
        child(playwright, home + "/Library/Caches/ms-playwright/firefox-1471", 300)
        child(playwright, home + "/Library/Caches/ms-playwright/firefox-1470", 350)
        child(playwright, home + "/Library/Caches/ms-playwright/webkit-2079", 80)
        child(playwright, home + "/Library/Caches/ms-playwright/ffmpeg-1011", 400)
        // Cypress versions are plain versioned children; the newest stays.
        let cypress = location("Library/Caches/Cypress")
        child(cypress, home + "/Library/Caches/Cypress/1.41.1", 10)
        child(cypress, home + "/Library/Caches/Cypress/1.40.2", 120)
        child(cypress, home + "/Library/Caches/Cypress/1.39.0", 300)
        // Gradle wrapper downloads every historical distribution; older ones are previous
        // versions in tier 1.
        let gradle = location(".gradle/wrapper/dists")
        child(gradle, home + "/.gradle/wrapper/dists/gradle-8.10.2", 10)
        child(gradle, home + "/.gradle/wrapper/dists/gradle-7.6.4", 200)
        child(gradle, home + "/.gradle/wrapper/dists/gradle-6.9.4", 400)
        // Pure package caches and the editors' Chromium caches: the location itself is
        // a tier-1 candidate.
        location(".cargo/registry/cache")
        location(".cargo/registry/src")
        location(".cargo/git/checkouts")
        location(".cargo/git/db")
        location(".bun/install/cache")
        location("Library/Developer/CoreSimulator/Caches")
        location("Library/Application Support/Code/CachedExtensionVSIXs")
        // Adobe's shared media cache: children go in full in tier 1 — while an Adobe
        // video app runs the app-activity guard refuses the removal instead.
        let adobe = location("Library/Application Support/Adobe/Common/Media Cache Files")
        child(adobe, home + "/Library/Application Support/Adobe/Common/Media Cache Files/clips.cfa", 5)
        child(adobe, home + "/Library/Application Support/Adobe/Common/Media Cache Files/old.cfa", 400)
        let mediaDB = location("Library/Application Support/Adobe/Common/Media Cache")
        child(mediaDB, home + "/Library/Application Support/Adobe/Common/Media Cache/Media Cache.db", 50, dir: false)
        // The editors' user data beside the caches never qualifies in either tier.
        id += 1
        nodes.append(FileNode(id: id, parentID: 1, path: home + "/Library/Application Support/Code/User", name: "User",
                              isDirectory: true, logicalSize: 500, allocatedSize: 500, modified: d(1), identity: "user"))

        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 30)
        #expect(Set(safe.nodes.map(\.path)) == [
            home + "/.bun/install/cache",
            home + "/.cargo/git/checkouts",
            home + "/.cargo/git/db",
            home + "/.cargo/registry/cache",
            home + "/.cargo/registry/src",
            home + "/.gradle/wrapper/dists/gradle-6.9.4",
            home + "/.gradle/wrapper/dists/gradle-7.6.4",
            home + "/Library/Application Support/Adobe/Common/Media Cache Files/clips.cfa",
            home + "/Library/Application Support/Adobe/Common/Media Cache Files/old.cfa",
            home + "/Library/Application Support/Adobe/Common/Media Cache/Media Cache.db",
            home + "/Library/Application Support/Code/CachedExtensionVSIXs",
            home + "/Library/Caches/Cypress/1.39.0",
            home + "/Library/Caches/Cypress/1.40.2",
            home + "/Library/Caches/ms-playwright/chromium-1124",
            home + "/Library/Caches/ms-playwright/firefox-1470",
            home + "/Library/Developer/CoreSimulator/Caches",
        ])
        // Tier 2 additionally takes every family's newest build.
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 30)
        let notYetSafe = [
            home + "/.gradle/wrapper/dists/gradle-8.10.2",
            home + "/Library/Caches/Cypress/1.41.1",
            home + "/Library/Caches/ms-playwright/chromium-1148",
            home + "/Library/Caches/ms-playwright/ffmpeg-1011",
            home + "/Library/Caches/ms-playwright/firefox-1471",
            home + "/Library/Caches/ms-playwright/webkit-2079",
        ]
        #expect(Set(all.nodes.map(\.path)) == Set(safe.nodes.map(\.path)).union(notYetSafe))
        await destroy(index)
    }

    @Test func nameMatchedRebuildableFoldersJoinOnlyTheRegenerableTier() async throws {
        let home = "/Users/rebuild"
        let root = FileNode(id: 1, parentID: nil, path: home, name: "rebuild", isDirectory: true,
                            logicalSize: 0, allocatedSize: 0, modified: Date(), identity: "root")
        let project = FileNode(id: 2, parentID: 1, path: home + "/project", name: "project", isDirectory: true,
                               logicalSize: 0, allocatedSize: 0, modified: Date(), identity: "project")
        let modules = FileNode(id: 3, parentID: 2, path: home + "/project/node_modules", name: "node_modules", isDirectory: true,
                               logicalSize: 500, allocatedSize: 500, modified: Date(), identity: "modules")
        let notes = FileNode(id: 4, parentID: 2, path: home + "/project/notes.md", name: "notes.md", isDirectory: false,
                             logicalSize: 10, allocatedSize: 10, modified: Date(), identity: "notes")
        let (fixture, index) = try await buildIndex([root, project, modules, notes])
        defer { fixture.dispose() }
        let safe = await index.autoSelectionCandidates(home: home, tier: .safe, unusedDays: 90)
        #expect(safe.nodes.isEmpty)
        let all = await index.autoSelectionCandidates(home: home, tier: .regenerable, unusedDays: 90)
        #expect(all.nodes.map(\.path) == [home + "/project/node_modules"])
        await destroy(index)
    }

    // MARK: Hidden-range collapse

    @Test func hiddenRangesCollapseCompleteSiblingsAndPruneSubsumedPaths() async throws {
        let home = "/Users/hidden"
        let root = FileNode(id: 1, parentID: nil, path: home, name: "hidden", isDirectory: true,
                            logicalSize: 0, allocatedSize: 0, modified: Date(), identity: "root")
        var nodes = [root]
        for (i, name) in ["a", "b", "c"].enumerated() {
            nodes.append(FileNode(id: Int64(2 + i), parentID: 1, path: home + "/\(name)", name: name, isDirectory: true,
                                  logicalSize: 10, allocatedSize: 10, modified: Date(), identity: "c\(i)"))
        }
        nodes.append(FileNode(id: 9, parentID: 2, path: home + "/a/deep", name: "deep", isDirectory: true,
                              logicalSize: 5, allocatedSize: 5, modified: Date(), identity: "deep"))
        let (fixture, index) = try await buildIndex(nodes)
        defer { fixture.dispose() }
        // Every child queued: the container collapses to one descendants-only range.
        let complete = await index.coalescedHiddenRanges(for: [home + "/a", home + "/b", home + "/c"])
        #expect(complete.paths.isEmpty)
        #expect(complete.subtrees == [home])
        // One child left out: no collapse, and nested entries are pruned as subsumed.
        let partial = await index.coalescedHiddenRanges(for: [home + "/a", home + "/a/deep", home + "/b"])
        #expect(partial.paths == [home + "/a", home + "/b"])
        #expect(partial.subtrees.isEmpty)
        await destroy(index)
    }
}
