import SwiftUI

@main struct DiskUnbloatApp: App {
    @State private var model = WorkspaceViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 660, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Location…", systemImage: "folder.badge.plus") { model.chooseLocation() }.keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandMenu("Scan") {
                Button("Scan Again", action: model.startScan).keyboardShortcut("r").disabled(model.scan.root == nil || model.isBusy)
                Button("Rescan Folder") { if let node = model.explorer.current { model.refreshFolder(node) } }.disabled(model.phase != .exploring || model.isBusy)
                Button("Cancel Scan", action: model.cancel).keyboardShortcut(".").disabled(!model.scan.scanning)
                Button("Select items to delete") { model.cleanup.showQueue.toggle() }.keyboardShortcut("k").disabled(model.phase != .exploring)
            }
            CommandMenu("Explore") {
                Group {
                Button("Search") { model.explorer.searchRequested += 1 }.keyboardShortcut("f")
                Button("Go to Parent", action: model.explorer.up).keyboardShortcut(.upArrow, modifiers: .command)
                }.disabled(model.phase != .exploring)
            }

        }
        Settings { SettingsView(model: model.settings) }
    }
}
