import AppKit

/// Not final: the agent Testing build subclasses it to own the bridge session.
@MainActor class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpen: [URL]?
    var model: WorkspaceViewModel? {
        didSet {
            if let model, let pendingOpen { self.pendingOpen = nil; _ = model.openLocations(pendingOpen) }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        sender.reply(toOpenOrPrint: routeOpen(urls) ? .success : .failure)
    }
    @discardableResult func routeOpen(_ urls: [URL]) -> Bool {
        if let model { return model.openLocations(urls) }
        if pendingOpen == nil { pendingOpen = urls } else { pendingOpen?.append(contentsOf: urls) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
