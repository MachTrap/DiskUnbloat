import SwiftUI

@main struct DiskUnbloatApp: App {
    @State private var model = WorkspaceViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Location…", systemImage: "folder.badge.plus") { model.chooseLocation() }.keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandMenu("Scan") {
                Button("Scan Again", action: model.startScan).keyboardShortcut("r").disabled(model.scan.root == nil || model.isBusy)
                Button("Rescan Folder") { if let node = model.explorer.current { model.refreshFolder(node) } }.disabled(model.phase != .exploring || model.isBusy)
                Button("Cancel Scan", action: model.cancel).keyboardShortcut(".").disabled(!model.scan.scanning)
                Button("Review Cleanup") { model.cleanup.showBasket = true }.keyboardShortcut("k").disabled(model.cleanup.basket.isEmpty)
            }
            CommandMenu("Explore") {
                Group {
                Button("Search") { model.explorer.searchRequested += 1 }.keyboardShortcut("f")
                Button("Map Only") { model.explorer.showFiles = false; model.explorer.showDetails = false }.keyboardShortcut("1")
                Button("Toggle File Browser") { model.explorer.showFiles.toggle() }.keyboardShortcut("2")
                Button("Toggle Details") { model.explorer.showDetails.toggle() }.keyboardShortcut("i")
                Button("Go to Parent", action: model.explorer.up).keyboardShortcut(.upArrow, modifiers: .command)
                }.disabled(model.phase != .exploring)
            }

        }
        Settings { SettingsView(model: model.settings) }
    }
}
