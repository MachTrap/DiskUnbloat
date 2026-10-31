import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    var body: some View {
        Form {
            Section("Cleanup suggestions") {
                TextField("Large file threshold (GB)", value: $model.largeGB, format: .number)
                Stepper("Older than \(model.ageDays) days", value: $model.ageDays, in: 1...3650)
                Stepper("Cache age: \(model.cacheAgeDays) days", value: $model.cacheAgeDays, in: 1...3650)
                Text("Suggestions are based on metadata. They do not establish that a file is unused or safe to remove.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Label("Your file index stays on this Mac.", systemImage: "lock.shield")
                Text("No accounts, analytics, uploads, or background monitoring. Temporary indexes are discarded when a scan session closes.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 500, height: 350).padding()
    }
}
