#if !DEBUG
#error("DiskUnbloatTesting is a Debug-only agent verification build. Never build it for Release or archive it.")
#endif
import AgentDevKitCore
import AgentDevKitHost
import AppKit
import DiskCore

/// Composition root of the agent Testing app. It reuses the shipping `AppDelegate`
/// (open-file routing, shutdown) and adds the AgentDevKit bridge. Its own bundle ID
/// gives it a separate defaults domain and a clean TCC state; scan indexes and
/// fixture trees live in an isolated `TestingProfile`.
@MainActor final class TestingSession: AppDelegate {
    let composition: TestingComposition
    let workspace: WorkspaceViewModel
    let bridge = AgentSession(label: "DiskUnbloatTesting")
    private let runtime = AgentRuntime()
    private var adapter: DiskUnbloatAgentAdapter?
    private let launchError: (any Error)?

    override init() {
        var options = LaunchOptions()
        var error: (any Error)?
        do { options = try LaunchOptions.parse(appFlags: [TestingComposition.realHomeFlag]) } catch let failure { error = failure }
        launchError = error
        composition = TestingComposition(options: options, realHome: CommandLine.arguments.contains(TestingComposition.realHomeFlag))
        workspace = composition.makeWorkspace()
        super.init()
        model = workspace
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let launchError { bridge.reject(launchError); return }
        let adapter = DiskUnbloatAgentAdapter(workspace: workspace, composition: composition, runtime: runtime)
        self.adapter = adapter
        adapter.observeChanges()
        guard composition.options.enabled else { return }
        let allowMutations = composition.options.allowMutations && composition.profileReady
        let host = AgentHost(adapter: adapter, runtime: runtime, catalog: adapter.catalog, allowMutations: allowMutations)
        bridge.start(host, readOnly: !allowMutations)
        if let fixture = composition.options.fixture, allowMutations {
            Task { _ = try? await adapter.load(fixture) }
        }
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await workspace.shutdown()
            await bridge.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
