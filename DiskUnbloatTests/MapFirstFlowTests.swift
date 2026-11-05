import Foundation
import Testing
import DiskCore
@testable import DiskUnbloat

@MainActor struct MapFirstFlowTests {
    @Test func completedScanOpensCleanupQueueWithMap() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        #expect(model.phase == .choosing)
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan()
        await model.waitForPhaseTransitionFromChoosing()
        #expect(model.phase == .scanning)
        #expect(!model.canClean)
        await scanner.ready()
        await scanner.finish()
        await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        // The cleanup queue opens itself once a scan completes.
        #expect(model.cleanup.showQueue)
        #expect(model.cleanup.basket.isEmpty)
        #expect(model.canClean)
        await model.shutdown()
    }

    @Test func cancelledScanRequiresOptInForPartialMapAndDisablesCleanup() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        model.cancel(); await model.waitForScan()
        #expect(model.phase == .cancelled)
        #expect(!model.canClean)
        #expect(!model.cleanup.showQueue)
        model.viewPartialMap(); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(!model.canClean)
        #expect(!model.cleanup.showQueue)
        await model.shutdown()
    }

    @Test func completedPartialScanStillOpensKnownMap() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(partial: true); await model.waitForScan()
        #expect(model.phase == .exploring)
        #expect(model.scan.snapshot?.complete == false)
        #expect(model.explorer.scene.summary.knownBytes == 4096)
        await model.shutdown()
    }

    @Test func failureCanRetryWithoutShowingAnEmptyExplorer() async {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready()
        await scanner.finish(error: "Test failure"); await model.waitForScan()
        if case .failed = model.phase {} else { Issue.record("Failure must have a dedicated screen") }
        model.startScan(); await scanner.ready()
        await scanner.finish(); await model.waitForScan()
        #expect(model.phase == .exploring)
        await model.shutdown()
    }

    @Test func selectionTotalsDoNotDoubleCountParentAndChild() async throws {
        let scanner = ControlledScanner()
        let model = WorkspaceViewModel(coordinator: scanner, fullDiskAccess: GrantedFullDiskAccess())
        model.scan.pendingRoot = URL(fileURLWithPath: "/fixture")
        model.startScan(); await scanner.ready(); await scanner.finish(); await model.waitForScan()
        model.explorer.selectionIDs = [2,3]
        #expect(model.explorer.normalizedSelection.map(\.id) == [2])
        #expect(model.explorer.selectionBytes == 4096)
        let geometryBefore = model.explorer.scene
        model.explorer.highlightedClass = .junk; model.explorer.colorMode = .age
        #expect(model.explorer.scene == geometryBefore)
        await model.shutdown()
    }

    @Test func quickTargetsUseSuppliedRealHomeAndDropsRejectFiles() throws {
        let catalog = LocationCatalog(home: URL(fileURLWithPath: "/Users/tester"))
        #expect(catalog.targets.first?.url.path == "/Users/tester")
        #expect(catalog.targets.first { $0.id == "downloads" }?.url.path == "/Users/tester/Downloads")
        #expect(catalog.additional.map(\.url.path) == ["/Users/tester/Documents","/Users/tester/Pictures"])
        // The chooser's quick actions are one flat list: home, downloads, caches,
        // "All caches", and "Dev tools" — the individual developer-cache targets are gone,
        // their locations already covered by "All caches".
        #expect(catalog.targets.map(\.id) == ["home", "downloads", "caches", "allCaches", "devTools"])
        // Grouped quick actions stack several known locations under one synthetic map root.
        let caches = try #require(catalog.targets.first { $0.id == "allCaches" })
        let tools = try #require(catalog.targets.first { $0.id == "devTools" })
        #expect(caches.grouped && tools.grouped)
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Caches")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Code - Insiders/WebStorage")))
        // Telegram's container root is no longer a static root: only the per-account
        // postbox media directories resolve against the real filesystem, so a fixture
        // home without an install lists no Telegram location at all.
        #expect(!caches.roots.contains { $0.path.contains("6N38VWS5BX.ru.keepcoder.Telegram") })
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.npm/_cacache")))
        // The Phase A expansions join the grouped caches: Adobe's shared media cache,
        // the Cargo/bun package caches, the editors' Chromium caches, and the
        // simulator-side throwaway trees.
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Adobe/Common/Media Cache Files")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.cargo/registry/cache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.bun/install/cache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Cursor/CachedData")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Windsurf/GPUCache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/CoreSimulator/Caches")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/XCTestDevices")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/CoreSimulator/Devices")))
        // The previous-version locations group under dev tools: the new device-support
        // siblings, Gradle distributions, and the automation-browser builds.
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/watchOS DeviceSupport")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/visionOS DeviceSupport")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.gradle/wrapper/dists")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Caches/ms-playwright")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Caches/Cypress")))
        // Phase B: language stores, local ML caches, and the container runtimes join
        // the Dev tools scope.
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.lmstudio")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/go/pkg/mod")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/pnpm/store")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.m2/repository")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.nuget/packages")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.pub-cache")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.cache/torch")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.cache/mlx")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.cache/whisper")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.triton/cache")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.orbstack")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.colima")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.lima")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.local/share/containers")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/.minikube")))
        // This round: game-engine stores, ComfyUI, and the CI caches. Godot's export
        // templates and the runner's work directory group under Dev tools; the Zen
        // store, ComfyUI's Electron caches, and act's cache are curated cache roots
        // under All caches.
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Godot/export_templates")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/actions-runner/_work")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Epic/UnrealEngine/Common/Zen/Data")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Comfy Desktop/Cache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/ComfyUI/GPUCache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.cache/act")))
        // Phase F: Unity, Resolve, Figma's Chromium caches, and the leftover stores
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Unity/cache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/DiskCache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Figma/DesktopProfile/GPUCache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.terraform.d/plugin-cache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/.ivy2/cache")))
        // Phase G: Steam's curated stores join All caches; its games and saves don't.
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Steam/appcache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Steam/steamapps/shadercache")))
        #expect(caches.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Steam/depotcache")))
        #expect(!caches.roots.contains { $0.path.hasSuffix("steamapps/common") })
        #expect(!caches.roots.contains { $0.path.hasSuffix("userData") })
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Unity/Asset Store-5.x")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/Library/Developer/Xcode/Archives")))
        #expect(tools.roots.contains(URL(fileURLWithPath: "/Users/tester/miniconda3/pkgs")))
        let homeTarget = try #require(catalog.targets.first { $0.id == "home" })
        #expect(!homeTarget.grouped && homeTarget.roots == [homeTarget.url])
        let model = LocationSelectionViewModel(catalog: catalog)
        #expect(throws: (any Error).self) { try model.directory(from: []) }
        #expect(throws: (any Error).self) { try model.directory(from: [URL(string: "https://example.com")!]) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try model.directory(from: [file]) }
    }
    @Test func nameSuffixLocationsHoverLibraries() {
        let catalog = LocationCatalog(home: URL(fileURLWithPath: "/Users/tester"))
        // The Final Cut library bundle lives anywhere, so it hovers by name suffix and
        // points users at Final Cut's own generated-files control.
        let hover = try? catalog.knownLocation(for: "/Users/tester/Movies/My Project.fcpbundle")
        #expect(hover?.id == "finalCutLibrary")
        #expect(catalog.knownLocation(for: "/Users/tester/.claude")?.id == "claudeData")
        // Downloads and Desktop are not curated locations; hovering stays quiet there.
        #expect(catalog.knownLocation(for: "/Users/tester/Downloads/notes.txt") == nil)
    }

    @Test func curatedToolAndSystemTreeHoverExplanations() {
        let catalog = LocationCatalog(home: URL(fileURLWithPath: "/Users/tester"))
        // The user-specified tool trees resolve to their own entries...
        for (path, id) in [
            ("/Users/tester/Library/Developer/Xcode/DocumentationCache", "xcodeDocumentationCache"),
            ("/Users/tester/Library/Android/sdk/system-images", "androidSystemImages"),
            ("/Users/tester/Library/Android/sdk/ndk", "androidNdk"),
            ("/Users/tester/Library/Application Support/com.docker.install/in_progress", "dockerInstaller"),
            ("/Users/tester/Library/Application Support/com.isaacmarovitz.Whisky/Libraries", "whiskyLibraries"),
            ("/Users/tester/.rustup/toolchains/stable-aarch64-apple-darwin", "rustup"),
            ("/Users/tester/.gemini/settings.json", "geminiCli"),
            ("/Users/tester/.local/share/pnpm/store", "localShare"),
        ] {
            #expect(catalog.knownLocation(for: path)?.id == id, "path: \(path)")
        }
        // ...every node of the asked-for roots resolves somewhere curatable...
        for root in ["/System/Library/AssetsV2", "/opt/homebrew/Cellar", "/opt/homebrew/Library/Homebrew",
                     "/Users/tester/Library/Android/sdk", "/Users/tester/.android", "/Users/tester/.npm",
                     "/Users/tester/go", "/Users/tester/Library/Application Support",
                     "/Users/tester/Library/Application Support/Steam/steamapps"] {
            #expect(catalog.knownLocation(for: root) != nil, "path: \(root)")
        }
        // ...and finer-grained entries still win over the new parent-level explanations.
        #expect(catalog.knownLocation(for: "/Users/tester/go/pkg/mod")?.id == "goModules")
        #expect(catalog.knownLocation(for: "/Users/tester/.npm/_cacache")?.id == "npmCache")
        #expect(catalog.knownLocation(for: "/Users/tester/.android/avd")?.id == "androidAvd")
        #expect(catalog.knownLocation(for: "/Users/tester/Library/Application Support/Steam/steamapps/common")?.id == "steamGames")
        #expect(catalog.knownLocation(for: "/Users/tester/Library/Application Support/Steam/steamapps/shadercache")?.id == "steamShaderCache")
        #expect(catalog.knownLocation(for: "/Users/tester/Library/Application Support/Steam/steamapps")?.id == "steamLibrary")
        #expect(catalog.knownLocation(for: "/Users/tester/Library/Application Support/Steam")?.id == "steamRoot")
        // Docker's data container lives under Library/Containers; the updater staging
        // folder is the Application Support piece with its own entry.
        #expect(catalog.knownLocation(for: "/Users/tester/Library/Containers/com.docker.docker")?.id == "dockerData")
        #expect(catalog.knownLocation(for: "/opt/homebrew")?.id == "optHomebrew")
        #expect(catalog.knownLocation(for: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_Visual")?.id == "assetsV2")
        // Documents is authored content: the broad Application Support entry never leaks outside it.
        #expect(catalog.knownLocation(for: "/Users/tester/Documents/report.pdf") == nil)
        #expect(catalog.knownLocation(for: "/Users/tester/Movies") == nil)
    }
}

@MainActor struct ApplicationActivityGuardTests {
    /// Ownership boundaries: a base owner matches itself and versioned continuations of
    /// its own id, never a fork whose id merely starts with the same text.
    @Test func ownershipMatchesStructureNotPrefixText() {
        #expect(ApplicationActivityService.isOwned("com.microsoft.VSCode", owner: "com.microsoft.VSCode"))
        #expect(ApplicationActivityService.isOwned("com.microsoft.VSCodeInsiders", owner: "com.microsoft.VSCodeInsiders"))
        // The Insiders fork is not owned by the stable owner…
        #expect(!ApplicationActivityService.isOwned("com.microsoft.VSCodeInsiders", owner: "com.microsoft.VSCode"))
        // …while versioned Adobe product ids belong to their base owner.
        #expect(ApplicationActivityService.isOwned("com.adobe.AfterEffects.26", owner: "com.adobe.AfterEffects"))
        #expect(ApplicationActivityService.isOwned("com.adobe.Premiere.Pro-24", owner: "com.adobe.Premiere.Pro"))
        #expect(ApplicationActivityService.isOwned("com.adobe.mediaencoder.core", owner: "com.adobe.mediaencoder"))
        #expect(ApplicationActivityService.isOwned("com.todesktop.230313mzl4w4u92", owner: "com.todesktop.230313mzl4w4u92"))
        #expect(ApplicationActivityService.isOwned("com.exafunction.windsurf", owner: "com.exafunction.windsurf"))
        // Unsegmented lookalikes stay foreign.
        #expect(!ApplicationActivityService.isOwned("com.microsoft.VSCodeExtra", owner: "com.microsoft.VSCode"))
        #expect(!ApplicationActivityService.isOwned("", owner: "com.microsoft.VSCode"))
    }

    /// Every owner's path marker must actually resolve inside the curated cleanup rule,
    /// so an app-owned blocklist entry can never go stale while the rule drifts.
    @Test func appOwnedMarkersResolveInsideTheCuratedRule() throws {
        // Telegram's root resolves per-account against the real filesystem, so the
        // fixture home materializes the postbox-media tree.
        let home = "/Users/Shared/DiskUnbloat-activity-" + UUID().uuidString
        let account = home + "/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-9/postbox/media"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let userCaches = CleanupRule.userCaches.roots(relativeTo: home).map(\.path)
        for (owner, marker) in ApplicationActivityService.appOwnedCaches {
            #expect(userCaches.contains { $0.contains(marker) },
                    "the \(owner) marker '\(marker)' must match a curated cache location")
        }
        // The per-account media path itself must be inside the resolved root list.
        #expect(userCaches.contains { $0.hasSuffix("/postbox/media") },
                "the wildcard-resolved Telegram media cache belongs to the curated rule")
        // The fork markers stay separate: the stable owner's marker never claims the
        // Insiders tree (and vice versa).
        let insiders = userCaches.filter { $0.contains("/Code - Insiders/") }
        let stable = userCaches.filter { $0.contains("/Code/") }
        #expect(!insiders.isEmpty && !stable.isEmpty)
        #expect(insiders.allSatisfy { !$0.contains("/Code/") })
        #expect(stable.allSatisfy { !$0.contains("/Code - Insiders/") })
    }
}
